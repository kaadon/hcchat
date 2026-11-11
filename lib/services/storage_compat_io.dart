import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// IO 平台（Android / iOS / Windows / macOS / Linux）实现：
/// 沿用 flutter_secure_storage，行为与原代码完全一致。
class CompatStorage {
  const CompatStorage();

  static const FlutterSecureStorage _impl = FlutterSecureStorage();

  Future<String?> read({required String key}) => _impl.read(key: key);

  Future<void> write({required String key, required String? value}) async {
    if (value == null || value.isEmpty) {
      await _impl.delete(key: key);
    } else {
      await _impl.write(key: key, value: value);
    }
  }

  Future<void> delete({required String key}) => _impl.delete(key: key);
}
