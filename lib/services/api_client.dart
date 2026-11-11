import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cross_file/cross_file.dart'; // XFile（uploadXFile 的 H5 适配）
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'storage_compat.dart';

import '../config/app_config.dart';
import 'keep_alive_service.dart';
import 'local_store.dart';
import 'push_service.dart';

/// HTTP 客户端封装：baseUrl 来自 AppConfig（编译期 dart-define → 运行时 json → 默认值）

/// 静默刷新结果三态：
/// - ok：拿到新 access token
/// - invalid：服务端明确拒绝（rt 作废/过期）→ 应清登录态回登录页
/// - network：网络不通/超时/存储读取失败 → **绝不能清登录态**，
///   重试即可。之前把网络错误也当 invalid，杀进程重开 App 时
///   网络还没就绪，一次刷新失败就把 token 全删了 → 用户被强制重新登录。
enum AuthRefreshResult { ok, invalid, network }

/// 隐私接口**网络层**错误类型（页面据此取 l10n 文案，服务层不做 i18n）：
/// - unsupported：HTTP 404 —— 服务端镜像过旧、没有该路由（用户旧 Docker 镜像实测）
/// - network：连接失败 / 超时等其余网络错误
enum PrivacyNetErrorType { unsupported, network }

/// DioException 的友好化包装。信封 code!=0 仍抛 Exception(服务端 message)，不走这里。
class PrivacyNetException implements Exception {
  final PrivacyNetErrorType type;
  final Object? cause;

  PrivacyNetException(this.type, [this.cause]);

  @override
  String toString() => 'PrivacyNetException(${cause ?? type})';
}

class ApiClient {
  /// 进程启动时刻（≈单例创建）：连接类失败的自动重试预算以此为基准，
  /// 前 5 分钟是 iOS「无线数据」授权弹窗的高发窗口（见构造函数注释）。
  static final DateTime _bootTime = DateTime.now();

  ApiClient._() {
    // HTTP 连接保活：Dart HttpClient 默认 idleTimeout 只有 15s，聊天时两条消息
    // 间隔一超过 15s，下一条发送就要重新做 TLS 握手——实测本服务端冷握手约 1.6s
    // （预热后 TTFB 仅 0.2~0.4s），这就是「发消息要转圈好久、重进会话又好了」的
    // 主因。拉长空闲保活到 5 分钟，让后续请求复用已握手的连接（二十六批需求3）。
    // H5（flutter build web）适配：IOHttpClientAdapter 底层是 dart:io HttpClient，
    // Web 上首次请求就会抛 Unsupported operation: Platform._version，导致所有接口
    // 报 DioException [unknown]（注册/登录必挂）。Web 下不覆盖适配器，让 dio 走
    // 默认的 BrowserHttpClientAdapter（src/adapter.dart 条件导入自动选择）。
    if (!kIsWeb) {
      _dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final c = HttpClient()
            ..idleTimeout = const Duration(minutes: 5)
            ..connectionTimeout = const Duration(seconds: 5);
          return c;
        },
      );
    }

    // 连接类失败自动重试（iOS 首次安装「无线数据」授权修复，2026-09-19）：
    // 国行/中国区 iOS 首次安装，App 发起网络请求时系统弹「允许 App 使用无线数据」，
    // 弹窗挂起期间所有请求立即失败（DNS 解析失败/连接错误）。用户同意后网络才
    // 真正可用——但之前请求失败后各页面只显示错误，不会自动再请求，客户只能杀掉
    // App 重开（客户不会秒同意，实测踩坑）。
    // 做法：仅对「请求从未发出」的错误类型（连接超时/连接错误/DNS 失败）延迟重试——
    // 这条边界保证重试绝不会造成重复提交（服务端根本没收到过请求）。
    // 预算：启动后 5 分钟内（授权弹窗高发窗口）最多重试 10 次 × 3s ≈ 30s，
    // 覆盖「用户迟疑一会儿才同意」；窗口外只补 1 次（连接抖动兜底，不拖慢真离线）。
    _dio.interceptors.add(InterceptorsWrapper(
      onError: (e, handler) async {
        final connectFailure = switch (e.type) {
          DioExceptionType.connectionTimeout ||
          DioExceptionType.connectionError =>
            true,
          DioExceptionType.unknown => e.error is SocketException,
          _ => false,
        };
        if (!connectFailure) return handler.next(e);
        // FormData 无法二次发送（发过一次即 finalize）：上传被服务器/反代中途
        // 掐断属于连接错误，若重试必然抛 "FormData has already been finalized"，
        // 直接透传原错误。真正的解法是把反代 client_max_body_size 调大（2026-09-24）。
        final opts = e.requestOptions;
        if (opts.data is FormData) return handler.next(e);
        final count = (opts.extra['_netRetry'] as int?) ?? 0;
        final inStartupWindow =
            DateTime.now().difference(_bootTime) < const Duration(minutes: 5);
        final maxRetry = inStartupWindow ? 10 : 1;
        if (count >= maxRetry) return handler.next(e);
        opts.extra['_netRetry'] = count + 1;
        await Future.delayed(const Duration(seconds: 3));
        try {
          final resp = await _dio.fetch(opts);
          return handler.resolve(resp);
        } on DioException catch (e2) {
          return handler.next(e2);
        } catch (_) {
          return handler.next(e);
        }
      },
    ));

    // 401 统一处理：用 refreshToken 换新 access → 重试原请求；刷新失败清登录态并回调跳登录
    _dio.interceptors.add(InterceptorsWrapper(
      onError: (e, handler) async {
        final status = e.response?.statusCode;
        final retried = e.requestOptions.extra['_retried'] == true;
        // _skipAuth：刷新 token / 退出登录这类"本来就不需要登录态"的请求，
        // 401 属于预期结果，不能再走刷新 + 踢登录页那一套
        // （否则退出登录的通知请求会把刚登录的新账号一起踢掉，B-18）
        final skipAuth = e.requestOptions.extra['_skipAuth'] == true;
        if (status == 401 && !retried && !skipAuth) {
          final r = await _tryRefresh();
          if (r == AuthRefreshResult.ok) {
            final token = await readToken();
            final opts = e.requestOptions;
            // FormData 不可重发（finalize 后二次 send 直接抛异常，2026-09-24）
            if (opts.data is FormData) return handler.next(e);
            opts.extra['_retried'] = true;
            opts.headers['Authorization'] = 'Bearer $token';
            try {
              final resp = await _dio.fetch(opts);
              return handler.resolve(resp);
            } catch (_) {
              return handler.next(e);
            }
          } else if (r == AuthRefreshResult.invalid) {
            await _clearAuth();
            onUnauthorized?.call();
          }
          // network：不动登录态（网络恢复后重试即可），原错误透传，
          // 页面各自显示失败态/重试按钮
        }
        handler.next(e);
      },
    ));
  }

  static final ApiClient instance = ApiClient._();
  final Dio _dio = Dio(BaseOptions(
    // 需求5：接口地址统一走 AppConfig（支持 config/app_config.json 运行时配置）
    baseUrl: AppConfig.instance.apiBase,
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 10),
  ));
  final _storage = const CompatStorage();

  static const _tokenKey = 'im_access_token';

  /// 公开 Dio 实例（供 service 层使用）
  Dio get dio => _dio;

  /// 401 且刷新失败 → 由 main 注册回调跳转登录页
  void Function()? onUnauthorized;

  Future<void> saveToken(String token) async {
    _cachedToken = token;
    await _storage.write(key: _tokenKey, value: token);
  }

  /// 内存缓存：flutter_secure_storage 在部分安卓机型上偶发读取慢/失败/挂起，
  /// 每个请求都现读一次会放大该问题（表现为聊天页等页面转圈后空白，重进恢复）。
  /// 读一次后走内存，写/清时同步维护缓存。
  String? _cachedToken;

  Future<String?> readToken() async {
    final c = _cachedToken;
    if (c != null && c.isNotEmpty) return c;
    final t = await _storage.read(key: _tokenKey);
    if (t != null && t.isNotEmpty) _cachedToken = t;
    return t;
  }

  /// token 读取超时：3s 封顶。
  ///
  /// 【修 R-14 · 真·永久转圈】`await readToken()` 以前**没有超时**：
  /// flutter_secure_storage 在部分安卓机型上会挂起（不是报错，是永远不返回），
  /// 于是 `try/catch` 永远不触发、气泡永远停在 sending —— 用户只能杀 App。
  /// 与 `_tryRefresh` 里已有的 `.timeout(5s)` 写法对齐（发送路径更急，取 3s）。
  static const Duration _tokenTimeout = Duration(seconds: 3);

  Future<String?> readTokenSafe() async {
    try {
      return await readToken().timeout(_tokenTimeout);
    } catch (_) {
      // 读不到 token 就当没登录态：让请求快速失败（401 → 刷新 → 重试），
      // 也好过整个发送流程卡死在一个永远不返回的 await 上。
      return null;
    }
  }

  /// 统一的鉴权请求头。所有 service 层都应该用它，而不是各自 `await readToken()`
  /// （各自调用就各自可能漏掉超时保护）。
  Future<Map<String, String>> authHeaders() async {
    final t = await readTokenSafe();
    return <String, String>{'Authorization': 'Bearer ${t ?? ''}'};
  }

  static const _refreshKey = 'im_refresh_token';
  Future<void> saveRefresh(String t) =>
      _storage.write(key: _refreshKey, value: t);
  Future<String?> readRefresh() => _storage.read(key: _refreshKey);

  /// 持久化设备号：首次生成 UUID(v4) 存入安全存储，之后复用。
  /// 游客注册以设备号为幂等键，保证同一设备只对应一个游客账号。
  /// Web 平台 FlutterSecureStorage 在部分 origin（隐私模式 / 跨域 iframe / 存储被禁）
  /// 偶发抛错；用 try/catch 兜底，写失败仍返回本次 UUID（仅当前会话持久），
  /// 不让设备号获取失败阻断游客登录主流程。
  static const _deviceIdKey = 'device_id';
  Future<String> getDeviceId() async {
    String? existing;
    try {
      existing = await readPref(_deviceIdKey);
    } catch (_) {
      // 读失败（如 Web 上 FSS 异常）→ 当作未持久化，继续生成新 UUID
    }
    if (existing != null && existing.isNotEmpty) return existing;
    final rnd = Random.secure();
    final b = List<int>.generate(16, (_) => rnd.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant 10xx
    final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    final uuid =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20, 32)}';
    try {
      await writePref(_deviceIdKey, uuid);
    } catch (_) {
      // 写失败也不阻断：本次登录可用；关页面后设备号丢失（下次会当新游客）
    }
    return uuid;
  }

  /// 轻量本地偏好（非敏感 UI 状态，如公告关闭记录）
  Future<String?> readPref(String key) => _storage.read(key: 'pref_$key');
  Future<void> writePref(String key, String? v) => v == null || v.isEmpty
      ? _storage.delete(key: 'pref_$key')
      : _storage.write(key: 'pref_$key', value: v);

  /// 用 refreshToken 刷新 accessToken。
  /// 三态返回：ok / invalid（服务端拒绝，清登录态）/ network（网络故障，保留登录态）。
  Future<AuthRefreshResult> refreshSession() => _tryRefresh();

  /// 刷新单飞（single-flight）：同一时刻只允许一次在途刷新，并发 401 共享同一结果。
  ///
  /// 【修「被挤下线后登录页反复跳十几遍」（2026-09-19，iOS 实测）】
  /// 之前每个 401 各自独立 POST /auth/refresh：被挤后 rt 已被服务端作废，
  /// 十几个并发 401 → 十几次刷新全判 invalid → 每个都各自清登录态 +
  /// 跳登录页 → 登录页连续跳十几遍。单飞后 N 个 401 只发一次刷新请求、
  /// 共享同一个结果，跳转也只触发一次（配合 main.dart 的时间窗去重双保险）。
  Completer<AuthRefreshResult>? _refreshFlight;

  Future<AuthRefreshResult> _tryRefresh() {
    final inFlight = _refreshFlight;
    if (inFlight != null) return inFlight.future;
    final c = Completer<AuthRefreshResult>();
    _refreshFlight = c;
    _doRefresh().then((r) {
      if (!c.isCompleted) c.complete(r);
    }).catchError((Object _) {
      // _doRefresh 内部已捕获全部异常，这里纯防御
      if (!c.isCompleted) c.complete(AuthRefreshResult.network);
    }).whenComplete(() {
      if (identical(_refreshFlight, c)) _refreshFlight = null;
    });
    return c.future;
  }

  Future<AuthRefreshResult> _doRefresh() async {
    // secure storage 在部分安卓机型上偶发读取失败/挂起：
    // 重试 3 次（每次 5s 封顶），都读不到按 network 处理 ——
    // "读不到 refresh token" ≠ "没登录过"，不能因此清凭据。
    String? rt;
    for (var i = 0; i < 3; i++) {
      try {
        rt = await _storage
            .read(key: _refreshKey)
            .timeout(const Duration(seconds: 5));
        break;
      } catch (_) {
        if (i == 2) return AuthRefreshResult.network;
        await Future.delayed(const Duration(milliseconds: 400));
      }
    }
    if (rt == null || rt.isEmpty) return AuthRefreshResult.invalid;
    final refreshToken = rt; // 固定为非空局部量，闭包内可安全使用
    try {
      final r = await _withTransientRetry(() => _dio.post(
          '/api/v1/auth/refresh',
          data: {'refreshToken': refreshToken},
          options: Options(extra: {'_skipAuth': true})));
      final data = (r.data as Map<String, dynamic>);
      if ((data['code'] as num?)?.toInt() == 0) {
        final d = data['data'] as Map<String, dynamic>? ?? {};
        final access = d['accessToken']?.toString() ?? '';
        if (access.isNotEmpty) {
          await saveToken(access);
          return AuthRefreshResult.ok;
        }
      }
      // 服务端有响应但拒绝：rt 确实作废
      return AuthRefreshResult.invalid;
    } catch (_) {
      // 网络不通/超时：瞬时故障，不能当"token 作废"
      return AuthRefreshResult.network;
    }
  }

  Future<void> _clearAuth() async {
    await clearAuth();
  }

  /// 清空本地登录态（access + refresh）。
  /// 公开给 AuthGate 用：启动静默续期失败说明 refresh token 已被服务端
  /// 作废（多端登录挤掉 / Redis 白名单过期），留着只会让下次启动再空跑一次。
  Future<void> clearAuth() async {
    _cachedToken = null;
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _refreshKey);
  }

  /// 清本地登录态 + 各类用户缓存（换账号前不能闪现上一个账号资料）。
  /// 主动 logout 与 服务端强制 forceLogout 共用，避免逻辑漂移。
  Future<void> _clearLocalData() async {
    await clearAuth(); // access + refresh 一起删
    // 清 UI 缓存（我的资料/通讯录/发现列表/会话列表/关于页配置）：
    // 换账号登录时不能闪现上一个账号的资料
    unawaited(writePref('profile', null));
    unawaited(writePref('contacts', null));
    unawaited(writePref('discoverApps', null));
    unawaited(writePref('assistantAvatar', null));
    // 会话列表 + 每会话最近消息（Hive）：换账号必须清，否则能看到上一个人的聊天
    unawaited(LocalStore.clearUserData());
    unawaited(writePref('authConfig', null));
    // 极光推送解绑 alias：避免注销后仍收到该账号的离线推送
    unawaited(PushService.instance.stop());
    // 停掉保活前台服务：通知栏消失，进程可被正常回收
    unawaited(KeepAliveService.instance.stop());
  }

  /// 服务端强制下线（后台禁用账号 / 踢人）→ 清登录态并跳登录页。
  /// 与用户主动 logout 不同：不发服务端注销请求（账号已被服务端作废，
  /// 本地 token 即将/已经失效）。由 ws_service 的 forceLogout 事件驱动，
  /// WS 连接的关闭也由事件监听方（GlobalWs）负责，避免 api_client 反向依赖 ws_service。
  Future<void> forceLogout() async {
    await _clearLocalData();
    onUnauthorized?.call();
  }

  /// 退出登录：调后端注销 + 清本地 token
  /// 退出登录：**先清本地登录态，再通知服务端**。
  ///
  /// 之前是"先发请求、成功后再清本地"，dio 的 connect 5s + receive 10s，
  /// 服务器慢或不可达时最多要等 15s —— 用户点了"退出登录"却半天没反应（B-18）。
  /// 本地 token 必须先清（这是退出登录唯一必须成功的事），
  /// 服务端通知失败不影响本地已登出，且整段调用 4s 封顶。
  Future<void> logout() async {
    final t = await readToken();
    await _clearLocalData(); // 先清本地：登录态 + 各类用户缓存一起删
    if (t == null || t.isEmpty) return;
    try {
      await _dio
          .post(
            '/api/v1/auth/logout',
            options: Options(
              headers: {'Authorization': 'Bearer $t'},
              // 这个请求 401 是预期结果（token 已清），别触发"踢登录页"
              extra: {'_skipAuth': true},
            ),
          )
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      // 忽略网络错误，本地已清
    }
  }

  // ===== 多账号切换（Telegram 式，上限 10 个）=====
  // 本机记住的已登录账号列表，存 JSON 于 pref 键。每项：
  // {id, account, nickname, avatar, accessToken, refreshToken, loginAt}
  static const _accountsKey = 'accounts_list';
  static const int maxAccounts = 10;

  Future<List<Map<String, dynamic>>> readAccounts() async {
    try {
      final raw = await readPref(_accountsKey);
      if (raw == null || raw.isEmpty) return [];
      final d = jsonDecode(raw);
      if (d is List) {
        return d.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
    } catch (_) {}
    return [];
  }

  Future<void> _writeAccounts(List<Map<String, dynamic>> list) async {
    await writePref(_accountsKey, jsonEncode(list));
  }

  /// 登录/刷新成功后把账号 upsert 进列表（最新登录排最前，超上限截断）。
  /// [id] 用户 ID；[account] 登录账号/用户名；[nickname]/[avatar] 展示用。
  Future<void> rememberAccount({
    required String id,
    required String account,
    String nickname = '',
    String avatar = '',
    required String accessToken,
    required String refreshToken,
  }) async {
    if (id.isEmpty || accessToken.isEmpty) return;
    final list = await readAccounts();
    list.removeWhere((a) => a['id'] == id);
    list.insert(0, {
      'id': id,
      'account': account,
      'nickname': nickname,
      'avatar': avatar,
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'loginAt': DateTime.now().millisecondsSinceEpoch,
    });
    if (list.length > maxAccounts) list.removeRange(maxAccounts, list.length);
    await _writeAccounts(list);
  }

  /// 从列表移除某个账号（返回是否移除成功）。
  Future<void> removeAccount(String id) async {
    final list = await readAccounts();
    list.removeWhere((a) => a['id'] == id);
    await _writeAccounts(list);
  }

  /// 切换账号：写目标账号 access/refresh token（供 AuthGate/HomeShell 重建）。
  /// 若目标 access token 可能过期，先用其 refresh token 静默续期（失败不阻断）。
  /// 返回切换后的账号信息；目标不存在返回 null。
  Future<Map<String, dynamic>?> switchToAccount(String id) async {
    final list = await readAccounts();
    final matches = list.where((a) => a['id'] == id).toList();
    if (matches.isEmpty) return null;
    final target = matches.first;
    var token = (target['accessToken'] ?? '').toString();
    final rt = (target['refreshToken'] ?? '').toString();
    // 静默续期：目标账号可能「睡久了」，access token 已过期
    if (rt.isNotEmpty) {
      try {
        final r = await _withTransientRetry(() => _dio.post(
            '/api/v1/auth/refresh',
            data: {'refreshToken': rt},
            options: Options(extra: {'_skipAuth': true})));
        final data = (r.data as Map<String, dynamic>);
        if ((data['code'] as num?)?.toInt() == 0) {
          final d = data['data'] as Map<String, dynamic>? ?? {};
          final access = d['accessToken']?.toString() ?? '';
          if (access.isNotEmpty) {
            token = access;
            target['accessToken'] = access;
            target['loginAt'] = DateTime.now().millisecondsSinceEpoch;
            await _writeAccounts(list);
          }
        }
      } catch (_) { /* 续期失败仍尝试切换，让 HomeShell 兜底走登录 */ }
    }
    await saveToken(token);
    await saveRefresh(rt);
    return target;
  }

  /// 瞬时故障判定：连接/读/发超时、连接错误、服务端 5xx。
  /// HTTP 200 + code!=0（业务失败）不在此列，由各 service 层自行处理。
  /// 公开给调用方做友好错误提示（如登录页把超时转成「网络连接失败」而不是 dump 原始异常）。
  static bool isTransient(Object e) {
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.connectionError:
          return true;
        case DioExceptionType.badResponse:
          return (e.response?.statusCode ?? 0) >= 500;
        default:
          return false;
      }
    }
    return false;
  }

  /// 瞬时失败自动重试（最多 2 次，退避 500ms/1s）。
  /// 登录后首页一批 GET 并发打出去，网络/服务端抖一下就直接失败——
  /// 表现为"通讯录加载失败/头像不显示，点重新加载又好了"。
  /// 自动重试把这类瞬时故障消化在客户端。只用于幂等请求（GET/refresh），
  /// POST/PUT 不重试，避免消息重复提交。
  Future<Response<T>> _withTransientRetry<T>(
      Future<Response<T>> Function() run) async {
    var attempt = 0;
    while (true) {
      try {
        return await run();
      } catch (e) {
        if (!isTransient(e) || attempt >= 2) rethrow;
        attempt++;
        await Future.delayed(Duration(milliseconds: 500 * attempt));
      }
    }
  }

  Future<Response> get(String path, {Map<String, dynamic>? query}) async {
    final token = await readToken();
    return _withTransientRetry(() => _dio.get(path,
        queryParameters: query,
        options: Options(headers: {'Authorization': 'Bearer $token'})));
  }

  Future<Response> post(String path, {Object? data}) async {
    final token = await readToken();
    return _dio.post(path,
        data: data,
        options: Options(headers: {'Authorization': 'Bearer $token'}));
  }

  /// 幂等安全 POST 的瞬时重试版本。登录时无 token；其他幂等 POST
  /// （如扫码进群 join，重复调用服务端按"已是成员"跳过）需传 headers 带 token。
  /// 服务端偶发响应慢 >10s（登录/进群首请求冷启动），自动重试（最多 2 次，
  /// 退避 500ms/1s）把这类瞬时故障消化在客户端。
  Future<Response> postIdempotent(String path,
      {Object? data, Map<String, dynamic>? headers}) async {
    return _withTransientRetry(
        () => _dio.post(path, data: data, options: Options(headers: headers)));
  }

  Future<Response> put(String path, {Object? data}) async {
    final token = await readToken();
    return _dio.put(path,
        data: data,
        options: Options(headers: {'Authorization': 'Bearer $token'}));
  }

  /// DELETE 请求（带 token）。朋友圈删自己的评论等场景使用。
  Future<Response> delete(String path, {Object? data}) async {
    final token = await readToken();
    return _dio.delete(path,
        data: data,
        options: Options(headers: {'Authorization': 'Bearer $token'}));
  }

  // ---------------- 设备会话（活跃会话 / 注销设备） ----------------
  // 契约见 im-server/doc/API.md「设备会话」节：
  // - 列表 GET /user/devices：X-Device-ID(可选) 用于服务端标记 current
  // - 注销 DELETE /user/devices/:deviceId：吊销该设备 refresh 槽位 + 断其 WS
  // - 信封仍是 HTTP 200 + code!=0，此处统一抛出 message 由页面提示

  /// 活跃会话列表：正在登录中的设备（按 lastActiveAt 倒序）。
  /// 返回原始 DeviceSession Map（deviceId/deviceType/platform/lastActiveAt/
  /// lastIp/online/current/createdAt），由页面自行解析。
  Future<List<Map<String, dynamic>>> fetchDevices() async {
    final headers = await authHeaders();
    final id = await getDeviceId();
    if (id.isNotEmpty) headers['X-Device-ID'] = id;
    final r = await _withTransientRetry(() =>
        _dio.get('/api/v1/user/devices', options: Options(headers: headers)));
    final body = r.data as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw Exception((body['message'] ?? '加载失败').toString());
    }
    final data = body['data'] as Map<String, dynamic>? ?? {};
    final list = data['list'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// 注销单台设备（不能是当前设备——服务端校验 1003）。
  /// 成功后服务端会向该设备推 forceLogout(device_logged_out) 并在 200ms 后断其 WS。
  Future<void> logoutDevice(String deviceId) async {
    final headers = await authHeaders();
    final r = await _dio.delete('/api/v1/user/devices/$deviceId',
        options: Options(headers: headers));
    final body = r.data as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw Exception((body['message'] ?? '注销失败').toString());
    }
  }

  /// 上报推送 token（个推 client id）：服务端存 device.push_token 并按别名绑定。
  /// 契约见 im-server/doc/API.md「推送 token」节。必须带 X-Device-ID 定位设备行。
  /// unbind=true 用于退出登录时解绑（token 可空，服务端查库取已存 cid）。
  Future<void> reportPushToken(String provider, String token,
      {bool unbind = false}) async {
    final headers = await authHeaders();
    final id = await getDeviceId();
    if (id.isNotEmpty) headers['X-Device-ID'] = id;
    final r = await _dio.post('/api/v1/user/push-token',
        data: {'provider': provider, 'token': token, 'unbind': unbind},
        options: Options(headers: headers));
    final body = r.data as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw Exception((body['message'] ?? '上报失败').toString());
    }
  }

  // ---------------- 隐私设置（user/privacy） ----------------
  // 契约见 im-server/doc/API.md「隐私设置」节：
  // - GET /user/privacy：读**自己**的隐私设置（phoneVisible / onlineVisible 三档
  //   all/contacts/nobody + 4 个布尔开关 + gender）
  // - PUT /user/privacy：**逐字段指针语义**——null/缺省 = 不修改，非 null 才写入
  //   （布尔 false 能正常落库，与 PUT /user/profile 的判空是两套语义）。
  //   枚举非法时服务端**整次拒绝**（1001，不做部分写入）。

  /// 读取当前登录用户自己的隐私设置（code!=0 抛 Exception(message)）。
  /// 返回原始 data Map（phoneVisible/onlineVisible/phoneSearchable/...），
  /// 由页面自行解析，缺字段时页面用服务端默认值兜底。
  /// 网络层错误抛 [PrivacyNetException]（404 → unsupported，其余 → network）。
  Future<Map<String, dynamic>> fetchPrivacy() async {
    final headers = await authHeaders();
    final Response r;
    try {
      r = await _withTransientRetry(() =>
          _dio.get('/api/v1/user/privacy', options: Options(headers: headers)));
    } on PrivacyNetException {
      rethrow;
    } catch (e) {
      throw _privacyNetError(e);
    }
    final body = r.data as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw Exception((body['message'] ?? '加载失败').toString());
    }
    return body['data'] as Map<String, dynamic>? ?? {};
  }

  /// 更新隐私设置。[fields] 只放**本次要改**的字段（指针语义：缺省 = 不改）。
  /// 服务端拒绝抛 Exception(message)；网络层错误抛 [PrivacyNetException]。
  /// 页面回滚 UI 并 toast（不再把 DioException 原文弹给用户）。
  Future<void> updatePrivacy(Map<String, dynamic> fields) async {
    final Response r;
    try {
      r = await _dio.put('/api/v1/user/privacy',
          data: fields, options: Options(headers: await authHeaders()));
    } on PrivacyNetException {
      rethrow;
    } catch (e) {
      throw _privacyNetError(e);
    }
    final body = r.data as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw Exception((body['message'] ?? '保存失败').toString());
    }
  }

  /// DioException → [PrivacyNetException]：404 = 服务端没有该路由（镜像过旧），
  /// 其余（连接失败/超时/取消）一律归为 network。非 DioException 原样上抛。
  PrivacyNetException _privacyNetError(Object e) {
    if (e is DioException && e.response?.statusCode == 404) {
      return PrivacyNetException(PrivacyNetErrorType.unsupported, e);
    }
    if (e is DioException) {
      return PrivacyNetException(PrivacyNetErrorType.network, e);
    }
    return e is PrivacyNetException
        ? e
        : PrivacyNetException(PrivacyNetErrorType.network, e);
  }

  /// 上传文件到 MinIO，返回 URL（需求3：图片发送）
  ///
  /// 【修 R-26】以前没设 sendTimeout：大图在弱网下会一直占着连接。
  /// 【修 2026-09-24】sendTimeout 60s 对大视频必炸（dio 的 sendTimeout 是
  /// 「发完整个请求体」的总时限，39.8MB 视频实测直接 send timeout）。
  /// 改为按体积放宽：600s 下限（用户指定），再按 ~128KB/s 慢速上行估算放大；
  /// receiveTimeout 保持 60s（只管等响应，与体积无关）。
  /// [onSendProgress] 供调用方画进度条（多图时展示「第 n/m 张」）。
  Future<Map<String, dynamic>> uploadFile(String filePath, String fileName,
      {String dir = 'chat/', void Function(int, int)? onSendProgress}) async {
    final headers = await authHeaders();
    var sizeBytes = 0;
    try {
      sizeBytes = await File(filePath).length();
    } catch (_) {}
    // 【二修 2026-09-24】128KB/s 对家宽/弱移动网上行仍偏紧（48MB 视频在
    // 200KB/s 上行需 ~250s，慢网更久），改按 48KB/s 极慢上行估算，宁可多等。
    final sendSecs = max(600, (sizeBytes / (48 * 1024)).ceil());
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(filePath, filename: fileName),
      'dir': dir,
    });
    final r = await _dio.post('/api/v1/upload',
        data: form,
        onSendProgress: onSendProgress,
        options: Options(
          headers: headers,
          sendTimeout: Duration(seconds: sendSecs),
          receiveTimeout: const Duration(seconds: 60),
        ));
    final body = r.data as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      // 上传接口同样是 HTTP 200 + code!=0 的信封，不判的话调用方拿到的
      // data 是 null，`up['url']` 直接变成空串 → 发出去一条打不开的空消息。
      throw Exception((body['message'] ?? '上传失败').toString());
    }
    return (body['data'] as Map<String, dynamic>? ?? {});
  }

  /// 上传内存字节（与 [uploadFile] 同一接口、同一信封校验）。
  ///
  /// 用途：把 **App 内置资源**（注册页的 6 张预设头像）当头像上传。
  /// 走字节而不是先落盘再 [uploadFile]，是为了不引入 path_provider 与临时文件清理。
  Future<Map<String, dynamic>> uploadBytes(Uint8List bytes, String fileName,
      {String dir = 'chat/', void Function(int, int)? onSendProgress}) async {
    final headers = await authHeaders();
    // 与 uploadFile 同款体积放宽（2026-09-24 二修）：600s 下限 + 48KB/s 估算
    final sendSecs = max(600, (bytes.length / (48 * 1024)).ceil());
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: fileName),
      'dir': dir,
    });
    final r = await _dio.post('/api/v1/upload',
        data: form,
        onSendProgress: onSendProgress,
        options: Options(
          headers: headers,
          sendTimeout: Duration(seconds: sendSecs),
          receiveTimeout: const Duration(seconds: 60),
        ));
    final body = r.data as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw Exception((body['message'] ?? '上传失败').toString());
    }
    return (body['data'] as Map<String, dynamic>? ?? {});
  }

  /// 上传 XFile（image_picker 返回的通用文件对象，H5/原生通吃，2026-09-16）。
  ///
  /// H5：XFile.path 是 blob URL，dart:io 读不了 → readAsBytes 走 [uploadBytes]
  ///（选中即读，blob 在页面生命周期内一直有效）。
  /// 原生：保持 [uploadFile] 按路径流式上传（大文件不进内存、支持进度回调）。
  Future<Map<String, dynamic>> uploadXFile(XFile f, String fileName,
      {String dir = 'chat/', void Function(int, int)? onSendProgress}) async {
    if (kIsWeb) {
      final bytes = await f.readAsBytes();
      return uploadBytes(bytes, fileName,
          dir: dir, onSendProgress: onSendProgress);
    }
    return uploadFile(f.path, fileName,
        dir: dir, onSendProgress: onSendProgress);
  }
}
