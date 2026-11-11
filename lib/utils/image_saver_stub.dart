import 'dart:typed_data';

/// 平台保存兜底占位：条件导入在 web（dart.library.html）与原生
/// （dart.library.io）下分别选 web/io 实现，此文件实际不会被选中。
Future<bool> saveImageBytes(
    Uint8List? bytes, String fileName, String url) async {
  return false;
}
