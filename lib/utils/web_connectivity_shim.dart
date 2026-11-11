import 'dart:async';

import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';

/// Web 端 connectivity 垫片。
///
/// 根因（2026-09-21 苹果 H5 实测）：Flutter 3.35+ 移除了老式 web 插件注册
/// （`registerWith(Registrar)`），connectivity_plus 6.1.x 的 web 实现仍是老式
/// 签名 → 新 SDK 构建时被**静默跳过**，H5 上一调
/// `Connectivity().checkConnectivity()` 就抛
/// `MissingPluginException(No implementation found for method check ...)`。
/// livekit_client 的 signal_client 用它做断网检测（join 前必调）→
/// H5 直接「连接 LiveKit 房间失败」进不了房间。
///
/// 垫片语义：浏览器里页面能跑 = 在线，checkConnectivity 恒报 wifi；
/// onConnectivityChanged 给永空流（livekit 只用它感知断网触发重连，
/// 空流 = 永不误报断网）。原生端不走此垫片，行为不变。
class WebConnectivityShim extends ConnectivityPlatform {
  WebConnectivityShim._();

  /// 仅 web 调用（main.dart kIsWeb 分支），把平台实现换成垫片
  static void register() {
    ConnectivityPlatform.instance = WebConnectivityShim._();
  }

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      const [ConnectivityResult.wifi];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream<List<ConnectivityResult>>.empty();
}
