import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:getuiflut/getuiflut.dart';
import 'package:jpush_flutter/jpush_flutter.dart';
import 'package:jpush_flutter/jpush_interface.dart'
    show NotificationSettingsIOS;

import '../app_navigator.dart';
import '../config/app_config.dart';
import '../pages/chat_page.dart';
import 'api_client.dart';
import 'app_badge.dart';
import 'conversation_service.dart';

/// 极光推送服务（离线消息兜底）
///
/// 设计：
///   - alias = 用户 ID 字符串。登录进首页后 setAlias(uid)，退出登录 deleteAlias；
///     服务端在接收方不在线时按 alias 下发系统通知（在线用户走 WS 长连接，不推）。
///   - 一台设备同一时刻只有一个 alias：换账号时先解绑旧的再绑新的。
///   - AppKey 走 AppConfig（dart-define / assets/config/app_config.json），
///     未配置时静默跳过，不影响其它功能。
class PushService with WidgetsBindingObserver {
  PushService._();
  static final PushService instance = PushService._();

  final _api = ApiClient.instance;
  dynamic _jpush; // JPush 实例（jpush_flutter 3.x：JPush.newJPush()）
  Getuiflut? _getui; // 个推实例（iOS 默认通道，服务端 provider!=jpush 且凭据下发时启用）
  bool _inited = false;
  bool _getuiHandlersInited = false;
  bool _badgeLifecycleObserved = false; // iOS 角标清理 observer 是否已注册
  String? _getuiCid; // 个推 client id（上报/解绑用）
  String? _alias; // 当前绑定的 alias（= 用户 ID）
  String? _myId; // 缓存我的用户 ID（点击通知跳会话页需要）

  // ---- 推送绑定诊断（「关于」页展示，离线推送排障不再盲猜）----
  /// 极光 RegistrationID（空串 = SDK 尚未注册到极光服务器）
  final ValueNotifier<String> regId = ValueNotifier('');

  /// 最近一次绑定流程状态描述
  final ValueNotifier<String> diag = ValueNotifier('未初始化');

  /// 登录态就绪后调用（HomeShell.initState，覆盖启动/登录/注册/扫码四条入口）。
  Future<void> start() async {
    if (kIsWeb) {
      diag.value = 'Web 平台不支持离线推送';
      return;
    }
    // iOS 桌面角标清理（打开 App / 未读归零时清零 + 同步服务商计数器），
    // 无论走极光还是个推都要注册（delegate 内部按实例是否就绪分流）
    _ensureBadgeLifecycle();
    // 服务端下发推送服务商（sys_config push_provider_ios，随 /auth/config 下发）：
    // iOS 默认个推（getui），可显式切回极光；Android 固定极光。
    String gtAppId = '', gtAppKey = '', gtAppSecret = '';
    try {
      final cfg = await _api.get('/api/v1/auth/config');
      final cd = ((cfg.data as Map<String, dynamic>)['data'] as Map?) ?? {};
      // 2026-11-08：iOS 默认走个推（getui），服务端 push_provider_ios=jpush
      // 可显式切回极光；个推凭据（getuiAppId）未下发时回落极光分支。
      final provider = cd['pushProviderIos']?.toString() ?? 'getui';
      if (defaultTargetPlatform == TargetPlatform.iOS &&
          provider == 'getui' &&
          (cd['getuiAppId']?.toString() ?? '').isNotEmpty) {
        gtAppId = cd['getuiAppId'].toString();
        gtAppKey = cd['getuiAppKey']?.toString() ?? '';
        gtAppSecret = cd['getuiAppSecret']?.toString() ?? '';
        await _startGetui(gtAppId, gtAppKey, gtAppSecret);
        return;
      }
    } catch (e) {
      debugPrint('[PushService] auth/config 读取失败，回落极光：$e');
    }
    // 未配置极光 AppKey（线上 config/app_config.json 无 jpushAppKey 字段）时
    // 必须直接跳过，绝不能带着空 AppKey 去初始化原生 SDK：
    // 极光在原生层校验 appKey，空值会抛未捕获异常直接崩进程，
    // Dart 的 try/catch 接不住（不是 PlatformException，是 JVM 层崩溃）。
    if (AppConfig.instance.jpushAppKey.isEmpty) {
      debugPrint('[PushService] jpushAppKey 未配置，跳过极光初始化');
      diag.value = '极光 AppKey 未配置（离线推送未启用）';
      return;
    }
    try {
      // Android 13+ 通知权限由 KeepAliveService 统一申请（HomeShell 更早触发），
      // 这里不再重复弹框
      final p = await _api.get('/api/v1/user/profile');
      final data =
          (p.data as Map<String, dynamic>)['data'] as Map<String, dynamic>? ??
              {};
      final uid = data['id']?.toString() ?? '';
      if (uid.isEmpty) {
        diag.value = 'profile 未返回用户 ID，跳过绑定';
        return;
      }
      _myId = uid;
      final jpush = _ensure();
      if (jpush == null) {
        diag.value = '极光初始化失败';
        return; // AppKey 缺失/初始化失败：静默跳过
      }
      // 冷启动兜底：点通知拉起 App 时系统已把角标加上，首次初始化完成即清
      // （lifecycle resumed 可能早于本方法注册 observer 而收不到事件）
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        unawaited(_clearIosBadge());
      }
      unawaited(_pollRegId(jpush)); // RegistrationID 异步补齐，不阻塞绑定
      if (_alias == uid) {
        diag.value = 'alias 已绑定：$uid';
        return; // 已绑定同一账号
      }
      if (_alias != null && _alias != uid) {
        // 换账号：先解绑旧 alias
        try {
          await jpush.deleteAlias();
        } catch (_) {}
      }
      await jpush.setAlias(uid);
      _alias = uid;
      diag.value = 'alias 绑定成功：$uid';
      debugPrint('[PushService] alias bound: $uid');
    } catch (e) {
      // profile 拉取失败 / 极光初始化失败：静默，下次进首页重试
      diag.value = '绑定流程异常：$e';
    }
  }

  // ============ iOS 桌面角标清理（红点不会自己消失的修复） ============
  //
  // 根因：服务端 jpush/getui 离线推送 payload 都是 badge "+1"（累加），而
  // App 端从不清零 applicationIconBadgeNumber，也从不回同步服务商计数器 →
  // 红点永远挂在桌面图标上。修复两层：
  //   ① 打开/回到前台（resumed）即清零 —— 微信同语义「打开 App 红点消失」；
  //   ② App 内未读归零（AppBadge.sync(0) 经 iosDelegate 回调到 _clearIosBadge）。
  // 清零走当前生效的推送 SDK，原生内部会同时置 applicationIconBadgeNumber=0
  // 并把服务商侧计数器归零 —— 不回同步的话下一条 "+1" 会从旧计数继续累加，
  // 本地图标清了红点数值却越挂越大。

  void _ensureBadgeLifecycle() {
    if (_badgeLifecycleObserved) return;
    _badgeLifecycleObserved = true;
    AppBadge.iosDelegate = _clearIosBadge;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        defaultTargetPlatform == TargetPlatform.iOS) {
      unawaited(_clearIosBadge());
    }
  }

  Future<void> _clearIosBadge() async {
    try {
      if (_getui != null) {
        // 个推：resetBadge = 清本地角标 + 同步个推服务端计数（GeTuiSdk resetBadge）
        _getui!.resetBadge();
      } else if (_jpush != null) {
        // 极光：JPUSHService setBadge(0) = 置本地 applicationIconBadgeNumber 0 + 同步极光计数
        await (_jpush as dynamic).setBadge(0);
      } else {
        return; // 推送 SDK 尚未初始化，无从同步计数（本次跳过，下次前台再清）
      }
      AppBadge.resetCache(); // 复位去重，未读再变化时重新下发
    } catch (e) {
      debugPrint('[PushService] iOS 角标清理失败: $e');
    }
  }

  /// 轮询 RegistrationID：setup 刚完成时 SDK 可能还没和极光服务器完成注册
  /// （此时返回空串），间隔重试，拿到即停，最多 6 次（约 12 秒）。
  Future<void> _pollRegId(dynamic jpush) async {
    for (var i = 0; i < 6; i++) {
      try {
        final rid = (await jpush.getRegistrationID())?.toString() ?? '';
        if (rid.isNotEmpty) {
          regId.value = rid;
          return;
        }
      } catch (e) {
        diag.value = '获取 RegistrationID 失败：$e';
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  /// 退出登录：解绑 alias，避免注销后仍收到该账号的离线推送
  Future<void> stop() async {
    if (kIsWeb) return;
    if (_getui != null && _getuiCid != null && _getuiCid!.isNotEmpty) {
      try {
        await _api.reportPushToken('getui', _getuiCid!, unbind: true);
      } catch (_) {}
    }
    if (_jpush != null) {
      try {
        await _jpush.deleteAlias();
      } catch (_) {}
    }
    _alias = null;
    diag.value = 'alias 已解绑（退出登录）';
  }

  // ============ 个推（iOS 默认通道，服务端 push_provider_ios 默认 getui） ============

  /// 初始化个推 SDK（iOS）：startSdk 需要 appId/appKey/appSecret 三件套
  /// （getuiflut 插件机制要求，由服务端 /auth/config 下发）。
  /// client id 到手后 POST /user/push-token 上报，服务端存库 + 绑定别名（=uid）。
  Future<void> _startGetui(
      String appId, String appKey, String appSecret) async {
    try {
      final p = await _api.get('/api/v1/user/profile');
      final data =
          (p.data as Map<String, dynamic>)['data'] as Map<String, dynamic>? ??
              {};
      final uid = data['id']?.toString() ?? '';
      if (uid.isEmpty) {
        diag.value = '个推分支：profile 未返回用户 ID，跳过绑定';
        return;
      }
      _myId = uid;
      _alias = uid;
      final gt = _ensureGetuiHandlers();
      // startSdk 返回 void（非 Future），不能 await
      gt.startSdk(appId: appId, appKey: appKey, appSecret: appSecret);
      // 冷启动兜底：清上次遗留的桌面角标（同极光分支，见 _clearIosBadge）
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        unawaited(_clearIosBadge());
      }
      // 时序注意：onReceiveClientId 可能在 startSdk 返回前就回调（cid 已到手并
      // 触发上报），此时不能再覆盖为「等待」，否则诊断卡误导（2026-09-21 实测）。
      if (_getuiCid == null || _getuiCid!.isEmpty) {
        diag.value = '个推 SDK 已启动，等待 client id';
      }
      // 冷启动场景：点击系统通知拉起 App 的那条通知（getLaunchNotification 是 getter）
      try {
        final launch = await gt.getLaunchNotification;
        if (launch.isNotEmpty) {
          _openFromGetuiClick(Map<String, dynamic>.from(launch));
        }
      } catch (_) {}
    } catch (e) {
      diag.value = '个推初始化失败：$e';
    }
  }

  Getuiflut _ensureGetuiHandlers() {
    final gt = _getui ?? Getuiflut();
    _getui = gt;
    if (_getuiHandlersInited) return gt;
    _getuiHandlersInited = true;
    // 0.2.41 的 addEventHandler 全参数必填，未用的回调传空实现
    gt.addEventHandler(
      onReceiveClientId: (String cid) async {
        _getuiCid = cid;
        regId.value = cid;
        debugPrint('[PushService] getui cid: $cid');
        await _reportGetuiCid(cid);
      },
      // iOS：通知栏点击回调（App 前台/后台/被杀后点击拉起）
      onReceiveNotificationResponse: (Map<String, dynamic> message) async {
        _openFromGetuiClick(message);
      },
      // Android 厂商通道点击（当前 Android 不走个推，兜底）
      onNotificationMessageClicked: (Map<String, dynamic> msg) async {
        _openFromGetuiClick(msg);
      },
      // iOS 透传/前台展示等（当前只用通知样式，空实现）
      onNotificationMessageArrived: (Map<String, dynamic> msg) async {},
      onTransmitUserMessageReceive: (Map<String, dynamic> msg) async {},
      onReceivePayload: (Map<String, dynamic> message) async {},
      onRegisterDeviceToken: (String token) async {
        debugPrint('[PushService] getui deviceToken: $token');
      },
      onReceiveOnlineState: (String online) async {},
      onAppLinkPayload: (String payload) async {},
      onPushModeResult: (Map<String, dynamic> result) async {},
      onSetTagResult: (Map<String, dynamic> result) async {},
      onAliasResult: (Map<String, dynamic> result) async {},
      onQueryTagResult: (Map<String, dynamic> result) async {},
      onWillPresentNotification: (Map<String, dynamic> message) async {},
      onOpenSettingsForNotification: (Map<String, dynamic> message) async {},
      onGrantAuthorization: (String granted) async {},
      onLiveActivityResult: (Map<String, dynamic> result) async {},
      onRegisterPushToStartTokenResult: (Map<String, dynamic> result) async {},
    );
    return gt;
  }

  Future<void> _reportGetuiCid(String cid) async {
    try {
      await _api.reportPushToken('getui', cid);
      diag.value = '个推 cid 已上报并绑定：$cid';
    } catch (e) {
      diag.value = '个推 cid 上报失败：$e';
    }
  }

  /// 解析个推通知点击的 payload 并跳转。
  /// 服务端 iOS 侧 extras 在 aps payload 根层（push_channel.ios.payload），
  /// Android 侧在 notification click_type=payload JSON 字符串里。
  void _openFromGetuiClick(Map<String, dynamic> message) {
    Map<String, dynamic> extras = {};
    final raw = message['payload'];
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) extras = Map<String, dynamic>.from(decoded);
      } catch (_) {}
    } else if (raw is Map) {
      extras = Map<String, dynamic>.from(raw);
    }
    // 兜底：键直接平铺在 message 上（iOS 点击回调常见）
    extras.putIfAbsent('conversationId', () => message['conversationId'] ?? '');
    final convId = extras['conversationId']?.toString() ?? '';
    if (convId.isEmpty || _myId == null || _myId!.isEmpty) return;
    final convType = int.tryParse(extras['convType']?.toString() ?? '') ?? 1;
    final item = ConvItem.fromJson({
      'conversation': {'id': convId, 'type': convType},
      'conversationName': extras['convName']?.toString() ?? '',
    });
    final nav = appNavigatorKey.currentState;
    if (nav != null) {
      nav.push(MaterialPageRoute(
          builder: (_) => ChatPage(conv: item, myId: _myId!)));
    }
  }

  dynamic _ensure() {
    if (_inited) return _jpush;
    // 双重保险：_ensure 也可能被其它路径调用，空 AppKey 一律不初始化
    if (AppConfig.instance.jpushAppKey.isEmpty) return null;
    final jpush = JPush.newJPush();
    // 官方要求：addEventHandler 放在 setup 之前
    jpush.addEventHandler(
      onReceiveNotification: (Map<String, dynamic> message) async {},
      // 点击通知栏消息（App 在前台/后台被杀后点击拉起）
      onOpenNotification: (Map<String, dynamic> message) async {
        _openFromPush(message);
      },
      onReceiveMessage: (Map<String, dynamic> message) async {},
    );
    jpush.setup(
      appKey: AppConfig.instance.jpushAppKey,
      channel: 'default',
      production: !kDebugMode,
      debug: kDebugMode,
    );
    // iOS：申请推送权限（系统授权框只弹一次）
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      jpush.applyPushAuthority(
          NotificationSettingsIOS(sound: true, alert: true, badge: true));
      // 冷启动场景：点击系统通知拉起 App 的那条通知
      jpush.getLaunchAppNotification().then((launch) {
        if (launch is Map && launch.isNotEmpty) {
          _openFromPush(Map<String, dynamic>.from(launch));
        }
      }).catchError((_) => null);
    }
    _inited = true;
    _jpush = jpush;
    return jpush;
  }

  /// 解析推送 extras 并跳转到对应会话页
  /// 服务端 extras：conversationId / msgId / senderId / convType / convName
  void _openFromPush(Map<String, dynamic> message) {
    Map<String, dynamic> extras = {};
    final raw = message['extras'];
    if (raw is Map) {
      extras = Map<String, dynamic>.from(raw);
      // Android 自定义 extras 在 cn.jpush.android.EXTRA 子 Map 里，iOS 直接平铺
      final android = raw['cn.jpush.android.EXTRA'];
      if (android is Map) extras = Map<String, dynamic>.from(android);
    }
    final convId = extras['conversationId']?.toString() ?? '';
    if (convId.isEmpty || _myId == null || _myId!.isEmpty) return;
    final convType = int.tryParse(extras['convType']?.toString() ?? '') ?? 1;
    final item = ConvItem.fromJson({
      'conversation': {'id': convId, 'type': convType},
      'conversationName': extras['convName']?.toString() ?? '',
    });
    final nav = appNavigatorKey.currentState;
    if (nav != null) {
      nav.push(MaterialPageRoute(
          builder: (_) => ChatPage(conv: item, myId: _myId!)));
    }
  }
}
