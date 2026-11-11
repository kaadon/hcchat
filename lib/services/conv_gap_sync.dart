import 'dart:async';

import 'conversation_service.dart';
import 'local_store.dart';

/// 非当前会话的断点补拉器（修 R-20）。
///
/// 背景：以前只有 `chat_page` 注册 `onReconnected` 补拉，于是：
///   - 站在会话列表页 / 其它 tab 时重连 → 所有会话都不补拉；
///   - 回前台也不刷（home_shell 只刷钱包与好友申请）；
/// 其它会话的消息只能等用户**点进去**时才拉 80 条历史 —— 离线较久时
/// 缺口 >80 条就永久漏掉了。
///
/// 这个补拉器只做「把缺口补上」这一件事：
///   - 断点从 LocalStore 读、补完写回（与 chat_page 共用同一份持久化断点）；
///   - 只推进未读相关的服务端状态，不解析消息内容，不碰任何 UI；
///   - 每个会话最多翻 [maxPages] 页，避免大群一次性拉爆；
///   - 并发保护：同一轮没跑完不会叠加。
///
/// 注意：**不负责渲染**。补到新消息后由调用方刷新会话列表（拉 lastMessage/未读）。
class ConvGapSync {
  ConvGapSync({ConversationService? service})
      : _svc = service ?? ConversationService();

  final ConversationService _svc;

  /// 全局单例（P0：常驻 WS 补拉与周期对账都走它，与页面生命周期解耦）。
  static final ConvGapSync instance = ConvGapSync();

  /// 全局常驻 seq 断档检测的回调：补到新消息后通知 UI 刷新（由会话列表页注册）。
  void Function()? onAfterSync;

  /// 单个会话一轮最多翻的页数（每页 500 条 → 上限 5000 条/会话/轮）
  static const int maxPages = 10;

  /// 一轮最多处理多少个会话（防止会话极多时一次打出几百个请求）
  static const int maxConvsPerRound = 50;

  bool _running = false;

  bool get isRunning => _running;

  // ===== P0：全局常驻 WS 补拉（与页面生命周期解耦，覆盖列表页期间非当前会话）=====
  // 以前只有 chat_page 单页做 seq 断档检测，用户在列表页时非当前会话的在线丢帧
  // （网关写缓冲满 / 分片队列满被丢弃）会静默漏收，直到断线或回前台。
  // 现在把「每会话 lastSeq 跟踪 + 断档检测」下沉到常驻 WS 层，任何页面都能自愈。
  final Map<String, int> _lastSeqByConv = {};

  /// 待补拉的会话集合（去抖后批量 syncOne）
  final Set<String> _pendingFill = {};
  Timer? _fillTimer;
  bool _fillRunning = false;

  /// 实时收到一条消息时调用：跟踪该会话 lastSeq，发现断档（seq 跳号）即补拉。
  /// [convId] 来自消息对象的 conversationId，[seq] 来自消息对象的 seq（服务端单调水位）。
  Future<void> track(String convId, int seq) async {
    if (convId.isEmpty || seq <= 0) return;
    var prev = _lastSeqByConv[convId];
    if (prev == null) {
      // 首见该会话：以本地持久化断点为基准，避免「启动后第一条就误判断档」
      prev = await LocalStore.loadLastSeq(convId);
      if (_lastSeqByConv[convId] == null) _lastSeqByConv[convId] = prev;
    }
    if (seq <= prev) return; // 重复/乱序：不回退 lastSeq
    if (seq > prev + 1) _scheduleFill(convId); // 跳号 = 中间被丢，补拉
    _lastSeqByConv[convId] = seq;
  }

  void _scheduleFill(String convId) {
    _pendingFill.add(convId);
    _fillTimer?.cancel();
    _fillTimer = Timer(const Duration(milliseconds: 300), _runFill);
  }

  Future<void> _runFill() async {
    if (_fillRunning) return;
    _fillRunning = true;
    try {
      final ids = _pendingFill.toList();
      _pendingFill.clear();
      var changed = 0;
      for (final id in ids) {
        if (_running) break; // syncAll 正在跑：让给它，下一轮再补
        final n = await syncOne(id);
        if (n > 0) changed++;
      }
      if (changed > 0) onAfterSync?.call();
    } finally {
      _fillRunning = false;
    }
  }

  /// P0：周期对账定时器（终极兜底，不依赖任何帧到达 / 断线事件）。
  /// 全量枚举会话列表并 syncAll，覆盖「在线但整条推送通道失效」等极端场景。
  Future<int> reconcileAll() async {
    if (_running) return 0;
    try {
      final convs = await _svc.list();
      if (convs.isEmpty) return 0;
      final changed = await syncAll(convs); // 不过滤当前会话：兜底一切
      if (changed > 0) onAfterSync?.call();
      return changed;
    } catch (_) {
      return 0;
    }
  }

  /// 给一批会话补拉缺口，返回**有新消息**的会话数。
  ///
  /// [excludeConvId]：当前正在看的会话（它有自己的补拉与实时推送，跳过以免重复）。
  Future<int> syncAll(List<dynamic> convs, {String? excludeConvId}) async {
    if (_running || convs.isEmpty) return 0;
    _running = true;
    var changed = 0;
    try {
      var handled = 0;
      for (final c in convs) {
        if (handled >= maxConvsPerRound) break;
        final convId = _idOf(c);
        if (convId.isEmpty || convId == excludeConvId) continue;
        handled++;
        final n = await syncOne(convId);
        if (n > 0) changed++;
      }
    } finally {
      _running = false;
    }
    return changed;
  }

  /// 补拉单个会话，返回补到的新消息条数。
  Future<int> syncOne(String convId) async {
    if (convId.isEmpty) return 0;
    var cursor = await LocalStore.loadLastSeq(convId);
    var total = 0;
    try {
      for (var page = 0; page < maxPages; page++) {
        final r = await _svc.syncV2(convId, cursor);
        if (r.reset) {
          // 水位回退（服务端 Redis 丢过数据）：以服务端为准**强制**重写断点。
          // 聊天页里还会提示用户「正在重新同步」；列表页这里静默处理即可——
          // 下一轮补拉会从新断点继续，用户的未读红点由调用方刷新。
          await LocalStore.saveLastSeq(convId, r.serverSeq, force: true);
          return total;
        }
        total += r.list.length;
        if (r.maxSeq > cursor) cursor = r.maxSeq;
        await LocalStore.saveLastSeq(convId, cursor);
        if (!r.hasMore) break;
        if (r.list.isEmpty) break; // 无进展，停
      }
    } catch (_) {
      // 单个会话失败不影响其它会话（下次重连/回前台会再试）
    }
    return total;
  }

  static String _idOf(dynamic c) {
    if (c is ConvItem) return c.id;
    if (c is Map) {
      final conv = c['conversation'];
      if (conv is Map) return conv['id']?.toString() ?? '';
      return c['id']?.toString() ?? '';
    }
    return '';
  }
}
