/// 统一本地持久化入口（2026-10-03 Web 修复）。
///
/// 背景：flutter_secure_storage 的 Web 实现依赖 WebCrypto（crypto.subtle），
/// 该 API 仅在安全上下文（HTTPS / localhost）下存在。用 HTTP 直接访问 H5 时
/// 登录写 token 会崩溃（Null check operator used on a null value）。
///
/// 方案：所有业务代码统一改用 [CompatStorage]：
/// - 移动端 / 桌面端（IO 平台）：仍走 flutter_secure_storage（加密存储）；
/// - Web：走 localStorage（HTTP / HTTPS 均可用，不依赖 crypto.subtle）。
///   注意：localStorage 为明文存储，Web 端敏感度要求高的场景应尽快上 HTTPS。
///
/// 用法：`import 'storage_compat.dart';` + `const CompatStorage()`
/// （条件导出，按平台自动选择实现，业务代码无感知）。
export 'storage_compat_stub.dart'
    if (dart.library.html) 'storage_compat_web.dart'
    if (dart.library.io) 'storage_compat_io.dart';
