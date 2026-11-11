import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// 原生端保存：Android/iOS 写入系统相册（原 image_saver.dart 逻辑迁移）。
Future<bool> saveImageBytes(
    Uint8List? bytes, String fileName, String url) async {
  if (bytes == null || bytes.isEmpty) return false;
  // Android ≤12 写相册需要存储权限；13+ request() 直接返回 denied，不影响保存
  if (defaultTargetPlatform == TargetPlatform.android) {
    try {
      await Permission.storage.request();
    } catch (_) {
      // 权限插件异常不阻断保存（Android 13+ 无需权限也能写入 MediaStore）
    }
  }
  final r = await ImageGallerySaverPlus.saveImage(bytes, quality: 100);
  // Android 返回 {isSuccess: bool, filePath: String}；iOS 返回保存路径字符串
  if (r is Map) {
    return r['isSuccess'] == true ||
        (r['filePath']?.toString().isNotEmpty ?? false);
  }
  return r != null && r.toString().isNotEmpty;
}
