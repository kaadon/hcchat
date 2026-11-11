import 'package:hive/hive.dart';

/// 消息渲染高度缓存（2026-09-20 进会话防跳优化）。
///
/// 聊天页每条消息行首帧渲染后把实测高度记到这里（key=服务端 msgId）；
/// 用于把消息列表首帧 `cacheExtent` 顶到「已缓存实测 + 按类型估算」的总量，
/// 让 ListView 首帧就把首屏 20 条全部布局完——maxScrollExtent 首帧即精确值，
/// 贴底定位一次到位（此前靠估算值多帧链式收敛 = 进群聊肉眼跳动）。
///
/// 存储纪律与 LocalStore 一致：LazyBox<String>（只存 JSON 字符串，不写
/// TypeAdapter）。key 直接用 msgId（全局唯一，无需会话维度隔离）。
/// 容量护栏：条数超 8000 全清（自愈型缓存，丢了也只是退回估算）。
///
/// 同步内存层（2026-09-20 残余跳修复）：首帧 `initialScrollOffset` 是同步计算
/// 的，异步 Hive get 赶不上——所以 open box 时把全量条目载入进程内 Map，
/// `getSync` 立即可用。ensureLoaded() 幂等：进聊天页前（会话列表预热路径）
/// await 一次，App 启动也可 fire-and-forget 预热。全量 ≤8000 条、每条不到
/// 10 字节，内存与加载成本可忽略。
class MsgHeightCache {
  MsgHeightCache._();

  static LazyBox<String>? _box;
  static final Map<String, double> _mem = {};
  static const int _maxEntries = 8000;
  static Future<void>? _loading;

  /// 幂等预热：打开 box 并把全部实测高度载入内存层。
  /// 返回值仅供调用方 await 时序保证，不抛错（失败退回纯估算）。
  static Future<void> ensureLoaded() => _loading ??= _load();

  static Future<void> _load() async {
    try {
      final b = await Hive.openLazyBox<String>('msg_heights');
      if (b.length > _maxEntries) {
        await b.clear(); // 自愈：超容量整体清空，退回估算兜底
        _box = b;
        return;
      }
      _box = b;
      for (final key in b.keys) {
        final raw = await b.get(key);
        final v = raw == null ? null : double.tryParse(raw);
        if (v != null && v > 10 && v < 2000) {
          _mem[key.toString()] = v; // 与 get 相同的合理区间钳制
        }
      }
    } catch (_) {
      _box = null; // 缓存失败不阻断：全部走估算兜底
    }
  }

  /// 同步读实测高度（内存层）；未预热/未命中返回 null
  static double? getSync(String msgId) {
    if (msgId.isEmpty) return null;
    return _mem[msgId];
  }

  /// 异步读实测高度（兼容旧调用）；未命中/异常返回 null
  static Future<double?> get(String msgId) async {
    if (msgId.isEmpty) return null;
    await ensureLoaded();
    return getSync(msgId);
  }

  /// 写实测高度；与上次值差 <1px 不写盘（省 IO）。内存层即时生效。
  static Future<void> put(String msgId, double height) async {
    if (msgId.isEmpty || height <= 0) return;
    final old = _mem[msgId];
    if (old != null && (old - height).abs() < 1.0) return;
    _mem[msgId] = height; // 同步层先写：本次会话内立即可用
    await ensureLoaded();
    final b = _box;
    if (b == null) return;
    try {
      await b.put(msgId, height.toStringAsFixed(1));
    } catch (_) {}
  }

  /// 测试/登出清理：内存层清空（box 保留由 Hive 全局管理）
  static void clearMem() => _mem.clear();
}
