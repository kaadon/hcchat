import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Android 保活服务（前台服务，flutter_foreground_task）
///
/// 设计：
///   - 仅 Android 启动：iOS 没有前台服务概念，强杀即销毁（离线推送兜底）。
///   - 目的：让 App 进程退到后台/划掉任务后仍存活，WS 长连接不断，
///     在线消息继续实时收；进程真被杀时走极光离线推送兜底。
///   - 通知权限在登录进首页后（HomeShell → start()）通过插件 API 申请
///     （覆盖 Android 13+ POST_NOTIFICATIONS），不在打开 App 时弹框；
///     顺带引导用户加电池优化白名单（国产 ROM 杀后台的主因）。
///   - 服务本身是"空任务"：不处理数据，只维持进程与通知栏常驻入口。
///   - 附带静音循环保活（start 成功后自动开启，stop 时停止）：后台循环
///     -60dB 极低音量音频（原生 SilentAudioPlayer），让厂商省电策略把
///     本应用当「正在播放媒体」豁免后台冻结——前台服务只能保进程不被杀，
///     保不住心跳定时器不被冻结（MIUI/ColorOS 等会冻结整个进程）。
///
/// 注意：
///   - 服务类型只用 remoteMessaging（无时长限制）；dataSync 在 Android 15
///     （targetSdk 35）有 24 小时内最多 6 小时硬限制，超时整个服务被系统
///     强制停止（通知栏消失、保活失效），不能用。
///   - 各厂商（小米/OPPO/VIVO/荣耀）的自启动/后台权限仍需用户手动开启，
///     通知权限弹框只是第一步。
///   - 物理限制：锁屏/深度省电时厂商 ROM 可能冻结主 isolate 的 Dart 定时器，
///     WS 心跳停发 90s 后服务端判离线（在线状态掉线、消息走推送通道），
///     这是 Android 省电机制的固有行为，前台服务只能尽量延长，无法 100% 保证。
class KeepAliveService {
  KeepAliveService._();
  static final KeepAliveService instance = KeepAliveService._();

  bool _inited = false;

  /// 进程级初始化：必须在 runApp 之前调用（main.dart），注册通信端口。
  void init() {
    if (kIsWeb) return; // 插件不支持 Web
    FlutterForegroundTask.initCommunicationPort();
  }

  /// 登录进首页后调用（HomeShell.initState）：
  /// 申请通知权限 + 电池优化白名单，然后启动前台服务。
  Future<void> start() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      _ensureInit();
      // Android 13+ 通知权限：未授权则弹系统授权框（只弹一次）
      final perm = await FlutterForegroundTask.checkNotificationPermission();
      if (perm != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      // 电池优化白名单：国产 ROM 杀后台的头号原因，未加白则弹系统申请框
      if (!(await FlutterForegroundTask.isIgnoringBatteryOptimizations)) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
      // 启动前台服务（已在运行时插件内部会返回失败结果，不会抛异常）
      // notificationIcon：单色小图标（白色气泡），必须配合 AndroidManifest 的
      // meta-data io.github.imapp.keep_alive.notification_icon 使用；
      // 不传则插件回退 launcher 彩色图标 → 通知栏只渲染 alpha 通道显示灰色空白方块
      // serviceTypes 只留 remoteMessaging：无时长限制的消息类场景；
      // dataSync 在 Android 15 有 24h/6h 硬限制，超时服务整体被杀（通知栏消失），
      // 且与 Manifest 声明不匹配时 Android 14+ 启动直接抛 SecurityException
      final result = await FlutterForegroundTask.startService(
        serviceTypes: const [
          ForegroundServiceTypes.remoteMessaging,
        ],
        notificationTitle: '消息服务运行中',
        notificationText: '保持连接以确保消息及时送达',
        notificationIcon: const NotificationIcon(
          metaDataName: 'io.github.imapp.keep_alive.notification_icon',
        ),
        callback: startCallback,
      );
      if (result is ServiceRequestFailure) {
        debugPrint('[KeepAlive] start failed: ${result.error}');
      } else {
        debugPrint('[KeepAlive] foreground service started');
        // 静音循环保活（默认开启，用户已知情接受耗电代价）：后台循环 -60dB
        // 极低音量音频，让厂商省电策略把本应用当「正在播放媒体」豁免后台冻结，
        // 避免 WS 心跳被冻结后几分钟掉线（物理上冻结无法用前台服务对抗）
        try {
          await const MethodChannel('im_app/rom')
              .invokeMethod('startSilentAudio');
        } catch (_) {}
      }
    } catch (e) {
      // 保活失败不影响主流程（还有极光离线推送兜底）
      debugPrint('[KeepAlive] start error: $e');
    }
  }

  /// 退出登录时调用：停掉前台服务（通知栏消失，进程可被正常回收）
  Future<void> stop() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    // 停静音保活音频（与前台服务生命周期一致）
    try {
      await const MethodChannel('im_app/rom').invokeMethod('stopSilentAudio');
    } catch (_) {}
    try {
      if (!(await FlutterForegroundTask.isRunningService)) return;
      final result = await FlutterForegroundTask.stopService();
      if (result is ServiceRequestFailure) {
        debugPrint('[KeepAlive] stop failed: ${result.error}');
      }
    } catch (e) {
      debugPrint('[KeepAlive] stop error: $e');
    }
  }

  void _ensureInit() {
    if (_inited) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'keep_alive_service',
        channelName: '消息保活服务',
        channelDescription: '保持与消息服务器的连接，确保消息及时送达',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        showBadge: false,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        // 空任务：不注册周期回调，纯粹维持进程存活
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: true,
        // WS 长连接依赖 CPU 与 Wi-Fi，保持唤醒
        allowWakeLock: true,
        allowWifiLock: true,
        // 服务被厂商 ROM / 系统杀死后自动重启（兜底）
        allowAutoRestart: true,
      ),
    );
    _inited = true;
  }
}

/// 前台服务入口：必须是顶层函数 + vm:entry-point（isolate 重入 Flutter 引擎用）
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());
}

/// 空任务处理器：只保活，不处理数据/事件
class _KeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
