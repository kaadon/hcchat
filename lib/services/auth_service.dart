import 'dart:convert';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

import 'api_client.dart';
import 'rom_settings.dart';
import 'update_service.dart';
import '../l10n/app_locale.dart';
import '../utils/web_user_agent.dart';

/// 需要邀请码（服务端 2003）：后台开启邀请码强制时，新游客未携带有效码。
/// 老游客同设备幂等复用不校验，调用方可据此「先静默登录、报此错再弹码」。
class InviteRequiredException implements Exception {
  const InviteRequiredException();
  @override
  String toString() => 'invite code required';
}

/// 登录验证终态异常（被拒绝 / 已过期 / 次数过多）：
/// 轮询时应停止轮询并向用户提示，不应与「网络抖动」混为一谈。
class VerifyTerminalException implements Exception {
  final String message;
  const VerifyTerminalException(this.message);
  @override
  String toString() => message;
}

class AuthConfig {
  final String authMode; // none / sms / email（存量字段：新后台由 register_type 派生）
  final bool inviteCodeOn;
  /// 邀请码三态（2026-11-04 需求）：off 关闭 / optional 选填 / required 必填。
  /// 空串 = 老服务端未下发该字段，调用方回退 inviteCodeOn（true→required / false→off）。
  final String inviteCodeMode;
  final bool registerOn;
  final bool guestOn;

  /// 图形验证码开关（后端未部署该字段时缺失 → 兜底 false，不会崩）
  final bool captchaOn;

  /// 注册方式（2026-09-22 需求6）：account（默认）/ phone / email。
  /// 空串 = 老服务端未下发该字段（调用方按 authMode 推导兜底）
  final String registerType;

  /// 开启注册认证（2026-09-22 需求6）：null = 老服务端未下发该字段
  /// （调用方沿用 authMode != none 的旧语义）；true 时仅手机/邮箱注册需要验证码
  final bool? registerVerifyOn;
  // 品牌信息（后端 /auth/config 提供，前端用于登录/注册页 logo + 名称展示）
  final String appName;
  final String appLogo;
  final String brandName;
  final String brandLogo;

  bool get inviteCodeVisible {
    final mode = inviteCodeMode.trim();
    if (mode.isEmpty) return inviteCodeOn;
    return mode != 'off';
  }

  bool get inviteCodeRequired {
    final mode = inviteCodeMode.trim();
    if (mode.isEmpty) return inviteCodeOn;
    return mode == 'required';
  }

  AuthConfig.fromJson(Map<String, dynamic> j)
      : authMode = j['authMode'] ?? 'none',
        inviteCodeOn = j['inviteCodeOn'] ?? false,
        inviteCodeMode = (j['inviteCodeMode'] ?? '').toString(),
        registerOn = j['registerOn'] ?? true,
        guestOn = j['guestOn'] ?? false,
        captchaOn = j['captchaOn'] ?? false,
        registerType = (j['registerType'] ?? '').toString(),
        registerVerifyOn =
            j['registerVerifyOn'] == null ? null : j['registerVerifyOn'] == true,
        appName = (j['appName'] ?? j['app_name'] ?? 'ChatPulse').toString(),
        appLogo = (j['appLogo'] ?? j['app_logo'] ?? '').toString(),
        brandName =
            (j['brandName'] ?? j['brand_name'] ?? j['appName'] ?? 'ChatPulse')
                .toString(),
        brandLogo = (j['brandLogo'] ?? j['brand_logo'] ?? j['appLogo'] ?? '')
            .toString();
}

class Captcha {
  final String captchaId;
  final String imageBase64;

  Captcha.fromJson(Map<String, dynamic> j)
      : captchaId = j['captchaId'],
        imageBase64 = j['image'];
}

class AuthResult {
  final String accessToken;
  final String refreshToken;
  final Map<String, dynamic> user;
  final bool isNewGuest;
  final bool verifyRequired; // 需要二次验证（账户安全验证）
  final String verifyTicket; // 验证会话 ticket
  final String verifyMethod; // 'code' | 'approve'
  final int verifyExpiresIn; // 会话有效期（秒）

  AuthResult.fromJson(Map<String, dynamic> j)
      : accessToken = j['accessToken'] ?? '',
        refreshToken = j['refreshToken'] ?? '',
        user = j['user'] ?? {},
        isNewGuest = j['isNewGuest'] ?? false,
        verifyRequired = j['verifyRequired'] == true,
        verifyTicket = (j['verifyTicket'] ?? '').toString(),
        verifyMethod = (j['method'] ?? '').toString(),
        verifyExpiresIn = j['expiresIn'] is int ? j['expiresIn'] as int : 0;
}

class AuthService {
  final Dio _dio = ApiClient.instance.dio;
  final _api = ApiClient.instance;

  // ===== 品牌配置缓存（2026-09-17：启动页预加载，登录页首帧即有 logo/名字）=====
  // 进程内静态缓存：启动页（main.dart _decide 转圈期）就触发 preloadConfig，
  // 网络回来前先落磁盘缓存（'authConfig' 键，about/me 页同款格式）——
  // 登录页 initState 直接读缓存渲染，不再「进页面才拉接口、logo 闪一下才出现」。
  static AuthConfig? cachedConfig;
  static Future<AuthConfig?>? _preloading;

  /// 预取品牌配置：磁盘缓存直出 → 网络刷新（失败保留缓存）。
  /// 重复调用共享同一个在途 Future，不会并发打多次接口。
  Future<AuthConfig?> preloadConfig() {
    return _preloading ??= _doPreload().whenComplete(() => _preloading = null);
  }

  Future<AuthConfig?> _doPreload() async {
    // 1) 磁盘缓存直出（冷启动首帧即有上次的品牌）
    if (cachedConfig == null) {
      try {
        final raw = await _api.readPref('authConfig');
        if (raw != null && raw.isNotEmpty) {
          final d = jsonDecode(raw);
          if (d is Map) {
            cachedConfig = AuthConfig.fromJson(Map<String, dynamic>.from(d));
          }
        }
      } catch (_) {}
    }
    // 2) 网络刷新并回写磁盘（失败静默，保留磁盘缓存）
    try {
      final r = await _api.get('/api/v1/auth/config');
      final d = (r.data['data'] as Map<String, dynamic>?);
      if (d != null && d.isNotEmpty) {
        cachedConfig = AuthConfig.fromJson(d);
        unawaited(
            _api.writePref('authConfig', jsonEncode(d)).catchError((_) {}));
      }
    } catch (_) {}
    return cachedConfig;
  }

  Future<AuthConfig> getConfig() async {
    final r = await _api.get('/api/v1/auth/config');
    return AuthConfig.fromJson(r.data['data']);
  }

  Future<Captcha> getCaptcha() async {
    final r = await _api.get('/api/v1/auth/captcha');
    return Captcha.fromJson(r.data['data']);
  }

  /// 账号可用性查询（公开接口 `GET /api/v1/auth/check-account`）。
  ///
  /// 注册页第 1 步点「下一步」时调用：返回 true 表示该用户名/邮箱/手机号可注册。
  /// 注意本项目**HTTP 恒 200、业务错误在 body.code**，所以必须走 [_check]。
  Future<bool> checkAccount(String account) async {
    final r = await _api
        .get('/api/v1/auth/check-account', query: {'account': account});
    _check(r);
    final data = r.data['data'] as Map<String, dynamic>? ?? {};
    return data['available'] == true;
  }

  /// 发送验证码。channel: sms(短信) / email(邮箱)，为空时由后端按 AUTH_MODE 决定。
  /// 返回实际发送渠道（'sms' / 'email'），供 UI 提示"已发送至短信/邮箱"。
  /// 注意：必须检查响应 code，否则短信发送失败会被静默吞掉（用户看到"已发送"却收不到码）。
  Future<String> sendCode(String account, String captchaId, String captchaCode,
      {String countryCode = '+86', String channel = 'sms'}) async {
    final r = await _dio.post('/api/v1/auth/send-code', data: {
      'account': account,
      'countryCode': countryCode,
      'captchaId': captchaId,
      'captchaCode': captchaCode,
      'channel': channel,
    });
    _check(r);
    final data = r.data['data'];
    return (data is Map && data['channel'] is String)
        ? data['channel'] as String
        : channel;
  }

  /// 设备类型探测（与 im-server 约定一致：1 Android / 2 iOS / 3 Web / 4 Windows / 5 macOS）。
  /// 此前密码登录/注册把 deviceType 写死 1 且不带 deviceId → 服务端 device 表
  /// 没有本机行（或类型错），设备页「当前设备」显示未知、活跃会话缺本机。
  static int detectDeviceType() {
    if (kIsWeb) return 3;
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 2;
      case TargetPlatform.windows:
        return 4;
      case TargetPlatform.macOS:
        return 5;
      case TargetPlatform.android:
      default:
        return 1;
    }
  }

  /// 设备型号探测（落服务端 device.device_name，设备页/后台详情/对方在线展示用）：
  /// native = 厂商+型号（RomSettings MethodChannel），Web = 手机网页/电脑网页（UA 判定）。
  /// 任何失败都回落到「Android/iOS/手机网页」等平台名，不阻断登录。
  static Future<String> detectDeviceName() async {
    if (kIsWeb) {
      final ua = webUserAgent();
      final mobile = RegExp('Mobile|Android|iPhone|iPad', caseSensitive: false)
          .hasMatch(ua);
      return mobile ? '手机网页' : '电脑网页';
    }
    try {
      final rom = await RomSettings.getRomInfo();
      final name = [rom['brand'], rom['model']]
          .where((e) => e != null && e.trim().isNotEmpty)
          .map((e) => e!.trim())
          .join(' ');
      if (name.isNotEmpty) return name;
    } catch (_) {}
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'iOS',
      TargetPlatform.windows => 'Windows',
      TargetPlatform.macOS => 'macOS',
      _ => 'Android',
    };
  }

  Future<AuthResult> login(String account, String password,
      {String deviceId = '', int? deviceType, String? deviceName}) async {
    // 登录 POST 幂等（重复提交无害）：走瞬时重试，服务端冷启动/首连慢时
    // 第一次 receive timeout 自动再试，不再让用户手动登第二次
    // X-Client-Version：服务端据此判定本客户端支持「账户安全验证」，缺失则
    // 按老客户端保底直接发 token（见 im-server 设计 §6.1）。移动端此前未带该头，
    // 会导致新设备验证永远不触发，这里补齐。
    final r = await _api.postIdempotent('/api/v1/auth/login',
        data: {
          'account': account,
          'password': password,
          'deviceId': deviceId,
          'deviceType': deviceType ?? detectDeviceType(),
          'deviceName': deviceName ?? await detectDeviceName(),
        },
        headers: {'X-Client-Version': UpdateService.currentVersion});
    _check(r);
    return AuthResult.fromJson(r.data['data']);
  }

  /// 账户安全验证（新设备侧，验证码方式）：提交 6 位码换取 token。
  /// 错误（验证码错/失效/次数过多）抛 [Exception]，message 为可读提示。
  Future<AuthResult> verifyByCode(String verifyTicket, String code) async {
    final r = await _dio.post('/api/v1/auth/verify/code', data: {
      'verifyTicket': verifyTicket,
      'code': code,
    });
    _check(r);
    return AuthResult.fromJson(r.data['data']);
  }

  /// 账户安全验证（新设备侧）：轮询验证结果（新设备尚未登录、无 token，走公开接口）。
  /// 返回 [AuthResult] 表示已批准（含 token）；返回 null 表示仍在等待（pending）；
  /// 被拒绝/过期/次数过多则抛 [VerifyTerminalException]（终态，应停止轮询）。
  Future<AuthResult?> verifyPoll(String ticket) async {
    final r = await _dio.get('/api/v1/auth/verify/poll',
        queryParameters: {'ticket': ticket});
    final body = r.data as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw VerifyTerminalException((body['message'] ?? '验证失败').toString());
    }
    final data = body['data'] as Map<String, dynamic>? ?? {};
    if (data['status'] == 'pending') return null;
    return AuthResult.fromJson(data);
  }

  /// 账户安全验证（审批方侧）：允许/拒绝新设备登录。
  /// 需已登录 + 当前设备 X-Device-ID 命中审批设备（服务端校验）。
  /// [decision] 取值 'allow' | 'reject'。
  Future<void> verifyApprove(String verifyTicket, String decision) async {
    final headers = await ApiClient.instance.authHeaders();
    final id = await ApiClient.instance.getDeviceId();
    if (id.isNotEmpty) headers['X-Device-ID'] = id;
    final r = await _dio.post(
      '/api/v1/auth/verify/approve',
      data: {'verifyTicket': verifyTicket, 'decision': decision},
      options: Options(headers: headers),
    );
    _check(r);
  }

  /// 切换验证方式（新设备侧）：同一 verify 会话在 code/approve 间切换。
  /// method='code' 需小助手开启（服务端经小助手发码）；method='approve' 需存在可信设备。
  Future<void> verifySwitch(String ticket, String method) async {
    final r = await _dio.post('/api/v1/auth/verify/switch',
        data: {'verifyTicket': ticket, 'method': method});
    _check(r);
  }

  Future<AuthResult> register({
    required String account,
    required String password,
    String nickname = '',
    String? code,
    String? inviteCode,
    String? captchaId,
    String? captchaCode,
    String? channel,
    String deviceId = '',
    int? deviceType,
    String? deviceName,
  }) async {
    final data = <String, dynamic>{
      'account': account,
      'password': password,
      'nickname': nickname,
      'inviteCode': inviteCode,
      'deviceId': deviceId,
      'deviceType': deviceType ?? detectDeviceType(),
      'deviceName': deviceName ?? await detectDeviceName(),
    };
    // 认证模式为 none 时不要带 channel/code：
    // 后端 `req.Channel != ""` 会强制走短信分支，拿空 code 去 Redis 比对必然报 2002
    // 「验证码错误或过期」，而这个报错与图形验证码开关无关。
    if (channel != null && channel.isNotEmpty) {
      data['channel'] = channel;
    }
    if (code != null && code.isNotEmpty) {
      data['code'] = code;
    }
    // 图形验证码（需要时才传）
    if (captchaId != null && captchaId.isNotEmpty) {
      data['captchaId'] = captchaId;
      data['captchaCode'] = captchaCode ?? '';
    }
    final r = await _dio.post('/api/v1/auth/register', data: data);
    _check(r);
    return AuthResult.fromJson(r.data['data']);
  }

  /// 绑定手机号：发送短信验证码（需登录 + 图形验证码）
  Future<void> sendBindPhoneCode(String phone, String countryCode,
      String captchaId, String captchaCode) async {
    final r = await _dio.post('/api/v1/user/bind-phone/send-code', data: {
      'phone': phone,
      'countryCode': countryCode,
      'captchaId': captchaId,
      'captchaCode': captchaCode,
    });
    _check(r);
  }

  /// 绑定手机号：校验短信验证码后写入
  Future<void> bindPhone(String phone, String countryCode, String code) async {
    final r = await _dio.post('/api/v1/user/bind-phone', data: {
      'phone': phone,
      'countryCode': countryCode,
      'code': code,
    });
    _check(r);
  }

  /// 游客注册/登录：按设备号幂等（后端处理）。返回登录态，用法同 login。
  /// [inviteCode]：后台开启邀请码开关时，**新游客**必填——服务端强制校验，
  /// 无效/为空抛 [InviteRequiredException]（2003）；老游客同设备幂等复用
  /// 不校验邀请码（2026-09-17 二次需求：再次登录不弹码直接进）。
  Future<AuthResult> guestRegister(
      {required String deviceId,
      int deviceType = 1,
      String? deviceName,
      String inviteCode = ''}) async {
    final r = await _dio.post('/api/v1/auth/guest', data: {
      'deviceId': deviceId,
      'deviceType': deviceType,
      'deviceName': deviceName ?? await detectDeviceName(),
      if (inviteCode.isNotEmpty) 'inviteCode': inviteCode,
    });
    final biz = r.data['code'];
    if (biz == 2003) throw const InviteRequiredException();
    _check(r);
    return AuthResult.fromJson(r.data['data']);
  }

  /// 登录后补填邀请码（游客/普通用户通用），复用后端现有邀请码逻辑自动加好友。
  Future<void> bindInviteCode(String code) async {
    final r = await _api.post('/api/v1/invite/bind', data: {
      'code': code,
    });
    _check(r);
  }

  /// 设置 / 修改支付密码。
  /// [oldPassword]：已设置过 → 必填（校验原密码）；首次设置可传 null/空。
  /// 后端按是否已设置自动分流到 SetPayPwd / ChangePayPwd。
  Future<void> setPayPwd(
      {String? oldPassword, required String newPassword}) async {
    final r = await _dio.post('/api/v1/user/paypwd/set', data: {
      if (oldPassword != null && oldPassword.isNotEmpty)
        'oldPassword': oldPassword,
      'newPassword': newPassword,
    });
    _check(r);
  }

  void _check(Response r) {
    final code = r.data['code'];
    if (code != 0) {
      throw Exception(
          r.data['message'] ?? AppLocalizations.instance.t('svcRequestFailed'));
    }
  }
}
