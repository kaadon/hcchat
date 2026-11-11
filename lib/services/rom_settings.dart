import 'package:flutter/services.dart';

/// ROM / 厂商设置辅助（Android 原生 MethodChannel）
///
/// 用途：设置引导页需要
///   1. 读取设备厂商（Build.MANUFACTURER 等）→ 展示对应引导步骤
///   2. 直接跳转厂商「自启动 / 后台管理」设置页（组件清单在 MainActivity.kt，
///      未命中时原生侧自动退回应用详情页）
class RomSettings {
  RomSettings._();
  static const MethodChannel _ch = MethodChannel('im_app/rom');

  /// 设备信息：manufacturer / brand / model（拿不到时返回空 Map）
  static Future<Map<String, String>> getRomInfo() async {
    try {
      final r = await _ch.invokeMethod<Map<dynamic, dynamic>>('getRomInfo');
      return r?.map((k, v) => MapEntry(k.toString(), v.toString())) ?? {};
    } on MissingPluginException {
      return {};
    } catch (_) {
      return {};
    }
  }

  /// 跳转厂商自启动设置页。
  /// 返回 true = 命中厂商专用页；false = 已退回应用详情页（需用户手动找）
  static Future<bool> openAutoStartSettings() async {
    try {
      return await _ch.invokeMethod<bool>('openAutoStartSettings') ?? false;
    } on MissingPluginException {
      await openAppDetails();
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 打开电池优化白名单设置（原生三级 fallback）。
  /// 返回实际打开的层级：1=直接授权弹窗 2=电池优化列表页（需手动找本应用选"不允许"） 3=应用详情页
  static Future<int> openBatterySettings() async {
    try {
      return await _ch.invokeMethod<int>('openBatterySettings') ?? 3;
    } on MissingPluginException {
      await openAppDetails();
      return 3;
    } catch (_) {
      return 3;
    }
  }

  /// 打开本应用的应用详情页（兜底入口）
  static Future<void> openAppDetails() async {
    try {
      await _ch.invokeMethod('openAppDetails');
    } catch (_) {}
  }
}
