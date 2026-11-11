import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

import 'api_client.dart';

/// 版本更新：本地基准版本 + 后台最新版本配置（三端独立检测）
///
/// - 本地基准版本（currentVersion）由 tool/apply_config.dart 自动同步自
///   config/app_build.json 的 versionName，【不要手改】。
/// - 后台配置项（sys_config）：android_version / ios_version / pc_version /
///   update_log / android_url / ios_url / pc_url。
///   安卓/iOS 未单独配置时后端回退旧键 app_version，存量部署平滑过渡。
/// - 检测规则：安卓比 androidVersion、iOS 比 iosVersion、H5 不检测；
///   比对走 versionName 字符串对比；versionCode 仅用于系统覆盖安装判断。
class UpdateService {
  /// 当前 App 版本（与打包 versionName 一致，apply_config 自动同步）
  static const currentVersion = '1.4.6';

  /// 拉取后台版本配置；网络失败返回 null（调用方静默处理，不打扰用户）
  static Future<UpdateInfo?> fetch() async {
    try {
      final r = await ApiClient.instance.get('/api/v1/auth/config');
      final body = r.data as Map<String, dynamic>;
      final d = (body['data'] as Map?) ?? {};
      return UpdateInfo(
        androidVersion: d['androidVersion']?.toString() ?? '',
        iosVersion: d['iosVersion']?.toString() ?? '',
        pcVersion: d['pcVersion']?.toString() ?? '',
        log: d['updateLog']?.toString() ?? '',
        androidUrl: d['androidUrl']?.toString() ?? '',
        iosUrl: d['iosUrl']?.toString() ?? '',
        pcUrl: d['pcUrl']?.toString() ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// 后台版本配置快照
class UpdateInfo {
  final String androidVersion; // 后台配置的安卓最新版本（android_version）
  final String iosVersion; // 后台配置的 iOS 最新版本（ios_version）
  final String pcVersion; // 后台配置的 PC 最新版本（pc_version）
  final String log; // 更新内容（update_log，三端共用）
  final String androidUrl; // 安卓 APK 下载地址
  final String iosUrl; // iOS 下载地址
  final String pcUrl; // PC 下载地址

  const UpdateInfo({
    required this.androidVersion,
    required this.iosVersion,
    required this.pcVersion,
    required this.log,
    required this.androidUrl,
    required this.iosUrl,
    required this.pcUrl,
  });

  /// 当前平台对应的后台最新版本号（H5 返回空串 → 永不提示更新）
  String get latestForPlatform {
    if (kIsWeb) return ''; // H5 不检测更新
    if (Platform.isIOS) return iosVersion;
    return androidVersion; // android 及其他移动端
  }

  /// 当前平台对应的下载地址（安卓优先回退 iOS，覆盖历史配置只有单地址的情况）
  String get downloadUrlForPlatform {
    if (Platform.isIOS) return iosUrl.isNotEmpty ? iosUrl : androidUrl;
    return androidUrl.isNotEmpty ? androidUrl : iosUrl;
  }

  /// 后台版本 **大于** 本地版本 → 有新版本。
  ///
  /// 此前是「不等于即更新」（!=）：后台配置回落到旧版本号（如 1.3.0）时，
  /// 本地 1.3.3 也会被提示更新——方向反了。改为语义化比较，只认升级。
  bool get hasNew {
    final latest = latestForPlatform;
    if (latest.isEmpty) return false;
    return compareVersions(latest, UpdateService.currentVersion) > 0;
  }

  /// 语义化版本比较：a>b 返回 1，相等返回 0，a<b 返回 -1。
  /// 按 '.' 分段转整数逐段比较，段数不齐短侧补 0（1.3 与 1.3.0 相等）；
  /// 非数字段按 0 处理，不抛异常。
  static int compareVersions(String a, String b) {
    List<int> parse(String v) =>
        v.trim().split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final pa = parse(a), pb = parse(b);
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x > y ? 1 : -1;
    }
    return 0;
  }

  /// 是否配置了下载地址（有新版本时用它判断能否引导下载）
  bool get hasUrl => downloadUrlForPlatform.isNotEmpty;
}
