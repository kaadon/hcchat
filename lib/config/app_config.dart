/// 应用配置（需求5：接口地址可改，不用每次重新编译）
///
/// 优先级（以本文件实现为准）：
/// 1. 运行时 assets/config/app_config.json —— 由 tool/apply_config.dart 从
///    config/app_build.json 生成。它在打包时被塞进 APK，**改动后必须重新编译才生效**
///    （只改磁盘文件、不重新 build，对已安装的 App 无效）。
/// 2. 编译期 --dart-define=API_BASE_URL / WS_BASE_URL —— 仅在 json 未提供时生效。
/// 3. 代码内默认值 —— 局域网调试兜底（192.168.1.11）。
library;

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// 全局配置单例
class AppConfig {
  AppConfig._();

  static final AppConfig instance = AppConfig._();

  String? _apiBase;
  String? _wsBase;
  String? _jpushAppKey;

  /// 极光推送 AppKey（客户端公开值，Master Secret 只存服务端，不要放这里）
  String get jpushAppKey {
    if (_jpushAppKey != null) return _jpushAppKey!;
    // 1) 编译期注入（--dart-define=JPUSH_APP_KEY=xxx）
    const fromEnv = String.fromEnvironment('JPUSH_APP_KEY');
    if (fromEnv.isNotEmpty) return fromEnv;
    // 2) 运行时 config/app_config.json 的 jpushAppKey 字段
    // 3) 默认空：未配置时 PushService 静默跳过，不影响其它功能
    return '';
  }

  /// API 基地址（不含 /api/v1）
  String get apiBase {
    if (_apiBase != null) return _apiBase!;
    // 1) 编译期注入（--dart-define=API_BASE_URL=http://192.168.1.11:8080）
    const fromEnv = String.fromEnvironment('API_BASE_URL');
    if (fromEnv.isNotEmpty) return fromEnv;
    // 2) H5 走同源反代（相对路径）
    if (kIsWeb) return '';
    // 3) 默认局域网地址（改这里即可，或写 config/app_config.json）
    return 'http://192.168.1.11:8080';
  }

  /// WS 基地址
  String get wsBase {
    if (_wsBase != null) return _wsBase!;
    const fromEnv = String.fromEnvironment('WS_BASE_URL');
    if (fromEnv.isNotEmpty) return fromEnv;
    if (kIsWeb) return '/ws';
    return 'ws://192.168.1.11:9090/ws';
  }

  /// 资源 URL 归一化：存量数据里 MinIO 资源地址写的是 127.0.0.1:9000 /
  /// localhost:9000（服务端本机地址，见 im-server .env 的 MINIO_PUBLIC_URL），
  /// 手机/模拟器上访问 127.0.0.1 是访问设备自己 → 必然加载失败。
  /// 这里换成 API 同域主机（端口保留：服务器 9000 对外开放），
  /// 与 PC 端 utils/format.js asset() 同款兜底。治本方案是服务端把
  /// MINIO_PUBLIC_URL 配成设备可达的公网地址。
  /// 资源 URL 归一化：存量数据里 MinIO 资源地址写的是 127.0.0.1:9000 /
  /// localhost:9000（服务端本机地址，见 im-server .env 的 MINIO_PUBLIC_URL），
  /// 手机/模拟器上访问 127.0.0.1 是访问设备自己 → 必然加载失败。
  /// 这里换成 API 同域主机（端口保留：服务器 9000 对外开放），
  /// 与 PC 端 utils/format.js asset() 同款兜底。治本方案是服务端把
  /// MINIO_PUBLIC_URL 配成设备可达的公网地址。
  ///
  /// 混合内容兜底（2026-09-21 用户实测：H5 在 iPhone Safari 头像全不加载、
  /// Chrome 正常）：头像/文件 URL 是上传那一刻按当时的 minio_public_url 烧进
  /// 数据库的绝对地址，后台改配置不回写存量。存量 http:// 地址在 https 页面里
  /// 属混合内容——Chrome 会自动升级成 https 加载（所以 Chrome 看是好的），
  /// Safari/WebKit 直接拦截 → 头像静默失败只剩占位。页面是 https 时统一把
  /// http:// 升级（线上 https://im.example.com/im-files/ 已实测 200 可达）。
  static String assetUrl(String url) {
    if (url.isEmpty) return url;
    var fixed = url;
    // 2026-10-31 修复「APP 个人中心不显示头像」：MINIO_PUBLIC_URL 协议相对 URL 兼容
    if (fixed.startsWith('//')) {
      fixed = 'http:$fixed';
    }
    if (fixed.contains('127.0.0.1') || fixed.contains('localhost')) {
      try {
        final host = Uri.parse(instance.apiBase).host;
        if (host.isNotEmpty) {
          fixed = fixed
              .replaceAll('://127.0.0.1', '://$host')
              .replaceAll('://localhost', '://$host');
        }
      } catch (_) {}
    }
    if (kIsWeb) {
      try {
        if (Uri.base.scheme == 'https' && fixed.startsWith('http://')) {
          fixed = 'https://${fixed.substring('http://'.length)}';
        }
      } catch (_) {}
    }
    return fixed;
  }

  /// 运行时覆盖（从 config/app_config.json 读取）
  Future<void> loadRuntimeConfig() async {
    try {
      final raw = await rootBundle.loadString('assets/config/app_config.json');
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (map['apiBase'] is String && (map['apiBase'] as String).isNotEmpty) {
        _apiBase = map['apiBase'] as String;
      }
      if (map['wsBase'] is String && (map['wsBase'] as String).isNotEmpty) {
        _wsBase = map['wsBase'] as String;
      }
      if (map['jpushAppKey'] is String &&
          (map['jpushAppKey'] as String).isNotEmpty) {
        _jpushAppKey = map['jpushAppKey'] as String;
      }
      debugPrint('[AppConfig] 运行时配置已加载 api=$_apiBase ws=$_wsBase');
    } catch (_) {
      // 无配置文件则用默认值
    }
  }
}
