import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import 'web_media_permissions.dart';

/// 音视频通话的运行时权限申请。
///
/// 背景：腾讯云 TRTC Flutter 插件**不会**自动申请麦克风/摄像头权限
/// （插件 android 目录下既没有 AndroidManifest，也没有任何 requestPermissions 代码）。
/// 而 im-app 的 android/app/src/main/AndroidManifest.xml 原本一条权限声明都没有，
/// 导致安卓端进房后设备打不开、双方都听不到声音，界面却显示「通话中」。
///
/// 使用：在真实进房（TRTC 已启用）前调用，未授权时提前给出提示。
class CallPermissions {
  const CallPermissions._();

  /// 语音通话：麦克风。
  /// H5（2026-09-21 用户明确）：点击拨打时用 getUserMedia 先请求浏览器
  /// 授权，成功才继续；原生走系统权限弹窗。
  static Future<bool> ensureForVoice() async {
    if (kIsWeb) return WebMediaPermissions.mic();
    return _request([Permission.microphone]);
  }

  /// 视频通话：麦克风 + 摄像头
  static Future<bool> ensureForVideo() =>
      _request([Permission.microphone, Permission.camera]);

  /// 视频通话拆分申请：麦克风是通话底线（拒绝=无法通话），摄像头尽力而为
  /// （被拒/无设备时降级为「纯语音 + 仅接收对方画面 + 头像占位」，不再挂死通话）。
  static Future<({bool mic, bool cam})> ensureForVideoSplit() async {
    if (kIsWeb) return WebMediaPermissions.micCam();
    try {
      final result = await [
        Permission.microphone,
        Permission.camera,
      ].request();
      return (
        mic: result[Permission.microphone]?.isGranted == true,
        cam: result[Permission.camera]?.isGranted == true,
      );
    } catch (_) {
      // 插件在未支持的平台上会抛异常，降级放行由 TRTC 自己报错
      return (mic: true, cam: true);
    }
  }

  /// 申请权限，全部授予才返回 true（仅原生路径；H5 见 WebMediaPermissions）。
  static Future<bool> _request(List<Permission> perms) async {
    if (kIsWeb) return true;
    try {
      final result = await perms.request();
      return perms.every((p) => result[p]?.isGranted == true);
    } catch (_) {
      // 插件在未支持的平台上会抛异常，降级放行由 TRTC 自己报错
      return true;
    }
  }

  /// 权限被永久拒绝时引导用户去系统设置页开启
  static Future<void> openSettings() async {
    if (kIsWeb) return;
    try {
      await openAppSettings();
    } catch (_) {}
  }
}
