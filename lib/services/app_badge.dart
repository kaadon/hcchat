import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 桌面图标角标（未读红点）：
///
/// - Android：走 im_app/rom 通道按未读总数实时设置（native 端各厂商逐一尝试、
///   静默失败）。部分国产 ROM 无公开角标 API（OPPO 需白名单、小米跟通知走），
///   这些机型上本接口无效果但不报错，离线推送的通知角标由系统自动维护。
/// - iOS：桌面红点由离线推送 payload 的 badge "+1"（服务端 jpush/getui 下发）
///   累加维护，App 内不做增量写、只负责「清零」——未读归零或打开 App 时经
///   推送 SDK 清角标（原生内部同时置 applicationIconBadgeNumber=0 并同步
///   服务商侧计数器，避免下一条 "+1" 从旧计数继续累加）。清理 delegate 由
///   PushService 按当前服务商注入；未注入（离线推送未启用）时静默跳过。
class AppBadge {
  AppBadge._();
  static const MethodChannel _channel = MethodChannel('im_app/rom');

  static int _last = -1; // 去重：同一数值不重复发通道

  /// iOS 清零 delegate（PushService 初始化时注入，内部走 jpush/getui 原生清法）
  static Future<void> Function()? iosDelegate;

  /// 同步未读总数到桌面角标（UnreadStore.update 里调用）
  static Future<void> sync(int unreadTotal) async {
    final n = unreadTotal < 0 ? 0 : unreadTotal;
    if (n == _last) return;
    _last = n;
    if (kIsWeb) return; // Web 无桌面图标
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // iOS：仅在归零时清（>0 的角标由推送 payload "+1" 维护，不重复写）
      if (n == 0) {
        try {
          await iosDelegate?.call();
        } catch (_) {
          // SDK 未就绪/清零失败静默：下次归零或前台切换时会再清
        }
      }
      return;
    }
    try {
      await _channel.invokeMethod('setBadge', n);
    } catch (_) {
      // 通道不可用（非 Android / 引擎未就绪）静默
    }
  }

  /// 复位去重缓存：外部把角标清掉后，下一次 sync 一定重新下发
  static void resetCache() {
    _last = -1;
  }
}
