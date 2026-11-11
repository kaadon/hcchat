/// 兜底桩：不应被任何平台命中（Web 命中 storage_compat_web，其余命中 io）。
class CompatStorage {
  const CompatStorage();

  Future<String?> read({required String key}) async =>
      throw UnsupportedError('CompatStorage: 当前平台无实现');

  Future<void> write({required String key, required String? value}) async =>
      throw UnsupportedError('CompatStorage: 当前平台无实现');

  Future<void> delete({required String key}) async =>
      throw UnsupportedError('CompatStorage: 当前平台无实现');
}
