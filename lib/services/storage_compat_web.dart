// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:html' as html;

/// Web 实现：localStorage。
///
/// 不用 flutter_secure_storage_web：其内部依赖 WebCrypto crypto.subtle，
/// 仅 HTTPS / localhost 存在，HTTP 访问会直接崩溃（null check 失败）。
/// localStorage 在 HTTP / HTTPS 下均可用，且同步 API 包一层 Future 即可
/// 与 IO 实现签名保持一致。
class CompatStorage {
  const CompatStorage();

  html.Storage get _ls => html.window.localStorage;

  Future<String?> read({required String key}) async {
    try {
      return _ls[key];
    } catch (_) {
      // 隐私模式 / 存储被禁时读失败 → 当作未存储
      return null;
    }
  }

  Future<void> write({required String key, required String? value}) async {
    try {
      if (value == null || value.isEmpty) {
        _ls.remove(key);
      } else {
        _ls[key] = value;
      }
    } catch (_) {
      // 写失败不阻断主流程（配额满 / 存储被禁）
    }
  }

  Future<void> delete({required String key}) async {
    try {
      _ls.remove(key);
    } catch (_) {}
  }
}
