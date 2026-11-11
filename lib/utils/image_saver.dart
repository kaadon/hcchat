import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../config/app_config.dart';
import 'image_saver_stub.dart'
    if (dart.library.html) 'image_saver_web.dart'
    if (dart.library.io) 'image_saver_io.dart' as saver_impl;

/// 网络图片保存（朋友圈九宫格长按 / 大图页按钮共用）。
///
/// 全平台统一入口：下载字节 → 按平台落盘——
/// - 原生：Android/iOS 相册（ImageGallerySaverPlus，见 image_saver_io.dart）
/// - Web：blob + <a download> 浏览器下载（跨域拿不到字节时兜底新标签页打开，
///   见 image_saver_web.dart）
class ImageSaver {
  ImageSaver._();

  /// 下载并保存图片，成功返回 true；失败返回 false / 抛异常（由调用方统一 toast）。
  static Future<bool> saveNetworkImage(String url) async {
    // 相对路径兜底：补全接口域名（正常图片 URL 已是完整地址）
    var full = url;
    if (!full.startsWith('http')) {
      final base = AppConfig.instance.apiBase;
      full = full.startsWith('/') ? '$base$full' : '$base/$full';
    }
    // 下载（全平台通用；web 走 XHR，需要图片服务带 CORS 头，拿不到时
    // 由平台实现自行兜底）。原生下载失败也会以 null 进平台实现直接失败。
    Uint8List? bytes;
    try {
      final resp = await Dio().get<List<int>>(
        full,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 15),
        ),
      );
      final data = resp.data;
      if (data != null && data.isNotEmpty) bytes = Uint8List.fromList(data);
    } catch (_) {
      bytes = null;
    }
    return saver_impl.saveImageBytes(bytes, _fileNameFromUrl(full), full);
  }

  /// 从 URL 提取安全的下载文件名（web 端 <a download> 用）
  static String _fileNameFromUrl(String url) {
    var name =
        url.split('?').first.split('#').first.split('/').last;
    name = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (name.isEmpty || name == '_') {
      name = 'image_${DateTime.now().millisecondsSinceEpoch}.jpg';
    }
    if (!name.contains('.')) name = '$name.jpg';
    return name;
  }
}
