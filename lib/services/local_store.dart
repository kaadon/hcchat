import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'e2ee_service.dart'; // E2EE 本机私钥随登出清理（引用环：Dart 允许，编译无碍）

/// 本地持久化缓存（Hive，缓存方案 P0-1）
///
/// 存储策略：**只存服务端原始 JSON**（LazyBox<String>），不写 TypeAdapter——
/// 免 build_runner 代码生成、免 adapter 版本迁移；结构演进时旧数据由
/// fromJson 默认值兜底（数据源是服务端，随时可重拉）。
///
/// 分层：内存（ConversationService._historyCache 等）→ Hive（本文件）→ 服务端。
///
/// ## 为什么用 LazyBox（不是普通 Box）
/// Hive 的**普通 Box 在 open 时把所有 value 一次性读入内存**——
/// `conv_messages` 里存的是所有会话的消息，一个用户有 50 个会话就意味着
/// 开 App 就把 50×80 条全量载入，单条越大越炸。
/// LazyBox 只在 `get(key)` 时从磁盘读那一条，常驻内存按会话隔离。
///
/// ## 单条消息 JSON 过大怎么办（三重防线）
/// 1. 单条 content 超 [maxContentChars] → 截断并打 `_trunc` 标记。
///    注意：**内存里网络返回的数据是完整的**，只有落盘副本被截断，
///    冷启动直出的极短时间内可能显示半截，联网刷新立刻覆盖为完整内容。
/// 2. 单条消息 JSON 超 [maxMessageChars] → 这条**不落盘**，
///    绝不因为一条脏大消息污染整个会话的缓存。
/// 3. 整个会话缓存超 [maxConvChars] → 从最旧往新丢，直到达标（硬上限）。
///
/// ## 数据损坏 / 写失败的兜底（不能只 catch 不处理）
/// - 解析失败 → `delete(key)` 清脏数据 + 计数 + 触发 [addCorruptListener]
///   通知上层**主动重拉**，UI 侧必须有"重新加载"入口（绝不停在空白页）
/// - 写入失败（磁盘满/配额）→ 计数，同一 key 连续 [maxFailures] 次 → **熔断**，
///   不再尝试写这个 key，避免"写坏 → 重拉 → 又写坏"的死循环
/// - 开箱失败 → 删盘重建一次；仍失败则放弃本地缓存（App 照常可用，只是没加速）
/// - 所有异常都过 [_log]（debug 可见），排查不用靠猜
///
/// Box 一览：
/// - conv_messages：key = convId，value = 该会话最近一页原始消息 JSON 数组
/// - local_meta：key = conv_list，value = 会话列表原始 JSON 数组
class LocalStore {
  LocalStore._();

  static LazyBox<String>? _messagesBox;
  static LazyBox<String>? _metaBox;

  /// 每会话最多保留的最近消息条数
  static const int maxMessagesPerConv = 80;

  /// 单会话缓存的字符上限（256K 字符；UTF-8 落盘最坏约 768KB）
  static const int maxConvChars = 256 * 1024;

  /// 单条 content 字符上限（超过截断 + 打 `_trunc` 标记）
  static const int maxContentChars = 8000;

  /// 单条消息 JSON 字符上限（超过这条不落盘）
  static const int maxMessageChars = 64 * 1024;

  /// 损坏 / 写失败的熔断阈值（达到后停止写该 key）
  static const int maxFailures = 3;

  /// key（'conv_list' 或 convId）→ 连续失败次数
  static final Map<String, int> _failures = {};

  /// 已熔断、不再写入的 key
  static final Set<String> _disabled = {};

  static bool isDisabled(String key) => _disabled.contains(key);

  static void _log(String msg) {
    if (kDebugMode) debugPrint('[LocalStore] $msg');
  }

  /// 记录一次失败（数据损坏 / 写失败）；达阈值熔断该 key 的写入
  static void _noteFailure(String key, String reason) {
    final n = (_failures[key] ?? 0) + 1;
    _failures[key] = n;
    _log('$reason (key=$key, failures=$n)');
    if (n >= maxFailures && !_disabled.contains(key)) {
      _disabled.add(key);
      _log('cache disabled for key=$key after $n failures');
    }
  }

  // ===== 损坏事件：通知上层主动重拉 =====

  static final List<void Function(String key)> _corruptListeners = [];

  /// 订阅"缓存损坏"事件。上层收到后应主动触发一次网络重拉，
  /// 而不是等下次冷启动才恢复。
  static void addCorruptListener(void Function(String key) fn) {
    if (!_corruptListeners.contains(fn)) _corruptListeners.add(fn);
  }

  static void removeCorruptListener(void Function(String key) fn) {
    _corruptListeners.remove(fn);
  }

  static void _fireCorrupted(String key) {
    for (final fn in List.of(_corruptListeners)) {
      try {
        fn(key);
      } catch (e) {
        _log('corrupt listener error: $e');
      }
    }
  }

  /// 删除坏数据（失败只记日志，不向上抛：缓存层不能拖垮业务）
  static Future<void> _drop(LazyBox<String>? box, String key) async {
    try {
      await box?.delete(key);
    } catch (e) {
      _log('delete failed (key=$key): $e');
    }
  }

  // ===== 初始化 =====

  static Future<void> init() async {
    await Hive.initFlutter();
    // 开箱失败（文件损坏 / 版本不兼容）→ 删盘重建一次；
    // 再失败就放弃本地缓存，由 main() 的 try/catch 兜住，App 仍可正常使用
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        _messagesBox = await Hive.openLazyBox<String>('conv_messages');
        _metaBox = await Hive.openLazyBox<String>('local_meta');
        _log('init ok');
        return;
      } catch (e) {
        _log('init failed (attempt $attempt): $e');
        await _resetBoxes();
      }
    }
  }

  static Future<void> _resetBoxes() async {
    for (final box in [_messagesBox, _metaBox]) {
      try {
        await box?.close();
      } catch (_) {}
    }
    _messagesBox = null;
    _metaBox = null;
    for (final name in const ['conv_messages', 'local_meta']) {
      try {
        await Hive.deleteBoxFromDisk(name);
        _log('deleted box from disk: $name');
      } catch (_) {}
    }
  }

  // ===== 会话列表 =====

  /// 读取持久化的会话列表原始数据；无缓存 / 损坏返回 null
  /// （损坏时会清掉脏数据并通知订阅方重拉）
  static Future<List<dynamic>?> loadConvList() async {
    const key = 'conv_list';
    final box = _metaBox;
    if (box == null) return null;
    String? raw;
    try {
      raw = await box.get(key);
    } catch (e) {
      _noteFailure(key, 'read error: $e');
      return null;
    }
    if (raw == null || raw.isEmpty) return null;
    try {
      final data = jsonDecode(raw);
      if (data is List) return data;
      throw const FormatException('conv_list is not a List');
    } catch (e) {
      await _drop(box, key);
      _noteFailure(key, 'decode error: $e');
      _fireCorrupted(key);
      return null;
    }
  }

  static Future<void> saveConvList(List<dynamic> raw) async {
    const key = 'conv_list';
    if (raw.isEmpty || _disabled.contains(key)) return;
    try {
      await _metaBox?.put(key, jsonEncode(raw));
      _failures.remove(key); // 写成功 → 清零失败计数
    } catch (e) {
      _noteFailure(key, 'write error: $e');
    }
  }

  // ===== 每会话最近消息 =====

  /// 读取某会话最近一页消息（原始 map 列表）；无缓存 / 损坏返回 null
  static Future<List<Map<String, dynamic>>?> loadMessages(String convId) async {
    final box = _messagesBox;
    if (convId.isEmpty || box == null) return null;
    String? raw;
    try {
      raw = await box.get(convId);
    } catch (e) {
      _noteFailure(convId, 'read error: $e');
      return null;
    }
    if (raw == null || raw.isEmpty) return null;
    try {
      final data = jsonDecode(raw);
      if (data is! List) throw const FormatException('messages is not a List');
      return data
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (e) {
      await _drop(box, convId);
      _noteFailure(convId, 'decode error: $e');
      _fireCorrupted(convId);
      return null;
    }
  }

  /// 整体覆盖保存（网络刷新成功后调用）
  static Future<void> saveMessages(
      String convId, List<Map<String, dynamic>> list) async {
    if (convId.isEmpty || list.isEmpty || _disabled.contains(convId)) return;
    var keep = list.length > maxMessagesPerConv
        ? list.sublist(list.length - maxMessagesPerConv)
        : List<Map<String, dynamic>>.from(list);
    // 防线 1+2：截断超长 content、剔除单条过大的消息
    keep = keep
        .map(_sanitize)
        .where((m) => _sizeOf(m) <= maxMessageChars)
        .toList();
    await _writeMessages(convId, keep);
  }

  /// 追加一条（WS 推送 / 发送成功）：按 msgId/clientMsgId 幂等去重，
  /// 超上限丢最旧。会话尚无缓存时静默跳过（等下次全量拉取）。
  static Future<void> appendMessage(
      String convId, Map<String, dynamic> raw) async {
    if (convId.isEmpty || _disabled.contains(convId)) return;
    final list = await loadMessages(convId);
    if (list == null) return; // 无本地缓存：不凭空建，等全量拉取
    final id = raw['msgId']?.toString() ?? '';
    final cm = raw['clientMsgId']?.toString() ?? '';
    for (final x in list) {
      if ((id.isNotEmpty && x['msgId']?.toString() == id) ||
          (cm.isNotEmpty && x['clientMsgId']?.toString() == cm)) {
        return; // 已存在（WS 回显与发送成功响应重复）
      }
    }
    final item = _sanitize(raw);
    if (_sizeOf(item) > maxMessageChars) return; // 防线 2：单条过大不入缓存
    list.add(item);
    await _writeMessages(convId, list);
  }

  /// 通话记录最终态回写：invite 的 content 被服务端原地改写（status/duration），
  /// 磁盘缓存同步替换，否则重进会话仍显示「点击回拨」中间态。
  static Future<void> replaceMessageContent(
      String convId, String msgId, String content) async {
    if (convId.isEmpty || msgId.isEmpty || _disabled.contains(convId)) return;
    final list = await loadMessages(convId);
    if (list == null) return;
    var hit = false;
    for (final x in list) {
      if (x['msgId']?.toString() == msgId) {
        x['content'] = content;
        hit = true;
      }
    }
    if (hit) await _writeMessages(convId, list);
  }

  /// 撤回态回写：磁盘缓存里对应消息标记 recalled=true（与
  /// replaceMessageContent 同款机制，2026-09-17 撤回缓存不同步问题）。
  static Future<void> markMessageRecalled(
      String convId, String msgId) async {
    if (convId.isEmpty || msgId.isEmpty || _disabled.contains(convId)) return;
    final list = await loadMessages(convId);
    if (list == null) return;
    var hit = false;
    for (final x in list) {
      if (x['msgId']?.toString() == msgId) {
        x['recalled'] = true;
        hit = true;
      }
    }
    if (hit) await _writeMessages(convId, list);
  }

  /// 落盘：防线 3 —— 整体超 [maxConvChars] 时从最旧往新丢（每轮丢 20%）
  static Future<void> _writeMessages(
      String convId, List<Map<String, dynamic>> keep) async {
    if (keep.isEmpty) {
      await _drop(_messagesBox, convId);
      return;
    }
    var list = keep;
    String encoded;
    try {
      encoded = jsonEncode(list);
      while (encoded.length > maxConvChars && list.length > 1) {
        list = list.sublist((list.length * 0.2).ceil());
        encoded = jsonEncode(list);
      }
    } catch (e) {
      _noteFailure(convId, 'encode error: $e');
      return;
    }
    try {
      await _messagesBox?.put(convId, encoded);
      _failures.remove(convId);
    } catch (e) {
      _noteFailure(convId, 'write error: $e');
    }
  }

  /// 防线 1：超长 content 截断并打 `_trunc` 标记。
  /// 只影响落盘副本——内存里的网络数据是完整的，联网刷新会覆盖回来。
  static Map<String, dynamic> _sanitize(Map<String, dynamic> m) {
    final c = m['content'];
    if (c is String && c.length > maxContentChars) {
      return <String, dynamic>{
        ...m,
        'content': c.substring(0, maxContentChars),
        '_trunc': true,
      };
    }
    return m;
  }

  /// 单条消息的序列化体积（字符数）；无法序列化时返回"超过上限"让它被剔除
  static int _sizeOf(Map<String, dynamic> m) {
    try {
      return jsonEncode(m).length;
    } catch (_) {
      return maxMessageChars + 1;
    }
  }

  // ===== 每会话补拉断点（lastSeq）=====
  //
  // 为什么必须落盘（修 R-05）：`_lastSeq` 以前只活在内存里，页面销毁即归零。
  // 于是每次进会话后的第一次重连都从 seq=0 补拉——拉到的是**最早**的一批，
  // 还会被插到列表头部造成「内容上翻」，而最近的消息反而拉不到。
  //
  // 所有会话的断点存在同一个 key 里（而不是每会话一个 key）：
  //   1) 退出登录时一次删除即可，不用遍历；
  //   2) 断点很小（每会话一个整数），整体读写比逐个 key 便宜。
  static const String _seqKey = 'last_seqs';

  /// 读取全部会话断点；无缓存/损坏返回空 map
  static Future<Map<String, int>> _loadSeqMap() async {
    final box = _metaBox;
    if (box == null || _disabled.contains(_seqKey)) return <String, int>{};
    String? raw;
    try {
      raw = await box.get(_seqKey);
    } catch (e) {
      _noteFailure(_seqKey, 'read error: $e');
      return <String, int>{};
    }
    if (raw == null || raw.isEmpty) return <String, int>{};
    try {
      final data = jsonDecode(raw);
      if (data is! Map) throw const FormatException('last_seqs is not a Map');
      final out = <String, int>{};
      data.forEach((k, v) {
        final n = v is num ? v.toInt() : int.tryParse(v?.toString() ?? '');
        if (n != null && n > 0) out[k.toString()] = n;
      });
      return out;
    } catch (e) {
      await _drop(box, _seqKey);
      _noteFailure(_seqKey, 'decode error: $e');
      _fireCorrupted(_seqKey);
      return <String, int>{};
    }
  }

  /// 读取某会话的补拉断点（无记录返回 0）
  static Future<int> loadLastSeq(String convId) async {
    if (convId.isEmpty) return 0;
    return (await _loadSeqMap())[convId] ?? 0;
  }

  /// 推进某会话的补拉断点。**只前进不回退**——断点回退会让客户端重复拉取
  /// 已经拿过的消息（表现为「反复重连就重复插入同一批」）。
  ///
  /// [force]=true 时允许回退：只在「服务端水位确实回退过（SyncResult.reset）」
  /// 这条路径上使用，此时不回退反而会让客户端永远拉不到东西。
  static Future<void> saveLastSeq(String convId, int seq,
      {bool force = false}) async {
    if (convId.isEmpty || seq < 0 || _disabled.contains(_seqKey)) return;
    try {
      final m = await _loadSeqMap();
      if (!force && (m[convId] ?? 0) >= seq) return; // 已更靠前，无需写盘
      m[convId] = seq;
      await _metaBox?.put(_seqKey, jsonEncode(m));
      _failures.remove(_seqKey);
    } catch (e) {
      _noteFailure(_seqKey, 'write error: $e');
    }
  }

  // ===== 群成员 / 会话置顶缓存 =====
  //
  // 修「每次进群聊都跳一下 + 头像变一下」：群成员昵称/头像此前零缓存，
  // 首帧 _members 为空 → 消息行显示「...短号 + 占位头像」，网络回来 setState
  // 集体翻转（头像闪一次、昵称变长换行数变 → 行高变 → 列表跳）。
  // 置顶条同理：首帧无置顶条、网络回来插入 → 整个列表下移一格。
  // 这里按会话缓存成员/置顶，进页首帧即渲染缓存、网络回来仅静默校准。
  static const String _membersKey = 'group_members';
  static const String _pinsKey = 'conv_pins';
  static const int maxCachedAuxConvs = 20; // 最多缓存的会话数（防 meta 无限膨胀）

  static Future<Map<String, dynamic>> _loadAuxMap(String key) async {
    final box = _metaBox;
    if (box == null || _disabled.contains(key)) return {};
    String? raw;
    try {
      raw = await box.get(key);
    } catch (_) {
      return {};
    }
    if (raw == null || raw.isEmpty) return {};
    try {
      final d = jsonDecode(raw);
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    return {};
  }

  static Future<void> _saveAuxMap(
      String key, Map<String, dynamic> m) async {
    try {
      await _metaBox?.put(key, jsonEncode(m));
      _failures.remove(key);
    } catch (e) {
      _noteFailure(key, 'write error: $e');
    }
  }

  /// 读取某群缓存的成员列表（无缓存返回空表）
  static Future<List<Map<String, dynamic>>> loadGroupMembers(
      String convId) async {
    if (convId.isEmpty) return const [];
    final v = (await _loadAuxMap(_membersKey))[convId];
    if (v is List) {
      return v
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const [];
  }

  /// 缓存群成员列表（截前 200 条：大群只缓存可见范围，超限回落网络兜底）
  static Future<void> saveGroupMembers(
      String convId, List<Map<String, dynamic>> list) async {
    if (convId.isEmpty || _disabled.contains(_membersKey)) return;
    final m = await _loadAuxMap(_membersKey);
    while (m.length >= maxCachedAuxConvs && !m.containsKey(convId)) {
      m.remove(m.keys.first);
    }
    m[convId] = list.length > 200 ? list.sublist(0, 200) : list;
    await _saveAuxMap(_membersKey, m);
  }

  /// 读取某会话缓存的置顶列表（无缓存返回空表）
  static Future<List<Map<String, dynamic>>> loadConvPins(String convId) async {
    if (convId.isEmpty) return const [];
    final v = (await _loadAuxMap(_pinsKey))[convId];
    if (v is List) {
      return v
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const [];
  }

  /// 缓存会话置顶列表（最多 20 条）
  static Future<void> saveConvPins(
      String convId, List<Map<String, dynamic>> list) async {
    if (convId.isEmpty || _disabled.contains(_pinsKey)) return;
    final m = await _loadAuxMap(_pinsKey);
    while (m.length >= maxCachedAuxConvs && !m.containsKey(convId)) {
      m.remove(m.keys.first);
    }
    m[convId] = list.length > 20 ? list.sublist(0, 20) : list;
    await _saveAuxMap(_pinsKey, m);
  }

  // ===== 本地发件箱（outbox）=====
  //
  // 修 R-13：乐观气泡以前只活在内存 `_msgs` 里，App 被杀 / 页面重建 →
  // sending 态消息彻底消失（用户以为发出去了，其实什么都没有）。
  // 这里把「已点发送但还没拿到服务端确认」的消息落盘，
  // App 启动 / 进会话时扫描：用同一个 clientMsgId 重发（服务端幂等），
  // 已落库的会被幂等命中直接回填，不会重复插入。
  //
  // 结构：{ convId: [ {conversationId, clientMsgId, type, content, replyTo?, file?} ] }
  // **不存支付密码**（红包/转账不入 outbox：重发需要密码，只能交给用户手动重试）。
  static const String _outboxKey = 'outbox';
  static const int maxOutboxPerConv = 20; // 每会话最多保留的待确认条数（防异常堆积）

  static Future<Map<String, List<Map<String, dynamic>>>>
      _loadOutboxMap() async {
    final box = _metaBox;
    if (box == null || _disabled.contains(_outboxKey)) {
      return <String, List<Map<String, dynamic>>>{};
    }
    String? raw;
    try {
      raw = await box.get(_outboxKey);
    } catch (e) {
      _noteFailure(_outboxKey, 'read error: $e');
      return <String, List<Map<String, dynamic>>>{};
    }
    if (raw == null || raw.isEmpty)
      return <String, List<Map<String, dynamic>>>{};
    try {
      final data = jsonDecode(raw);
      if (data is! Map) throw const FormatException('outbox is not a Map');
      final out = <String, List<Map<String, dynamic>>>{};
      data.forEach((k, v) {
        if (v is! List) return;
        out[k.toString()] = v
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      });
      return out;
    } catch (e) {
      await _drop(box, _outboxKey);
      _noteFailure(_outboxKey, 'decode error: $e');
      _fireCorrupted(_outboxKey);
      return <String, List<Map<String, dynamic>>>{};
    }
  }

  /// 取某会话的待确认消息（按插入顺序）
  static Future<List<Map<String, dynamic>>> loadOutbox(String convId) async {
    if (convId.isEmpty) return const <Map<String, dynamic>>[];
    return (await _loadOutboxMap())[convId] ?? const <Map<String, dynamic>>[];
  }

  /// 登记一条待确认消息（按 clientMsgId 幂等，重复登记不新增）
  static Future<void> appendOutbox(
      String convId, Map<String, dynamic> item) async {
    if (convId.isEmpty || _disabled.contains(_outboxKey)) return;
    final cm = item['clientMsgId']?.toString() ?? '';
    if (cm.isEmpty) return;
    try {
      final all = await _loadOutboxMap();
      final list = all[convId] ?? <Map<String, dynamic>>[];
      for (final x in list) {
        if (x['clientMsgId']?.toString() == cm) return; // 已在箱
      }
      list.add(Map<String, dynamic>.from(item));
      if (list.length > maxOutboxPerConv) {
        list.removeRange(0, list.length - maxOutboxPerConv);
      }
      all[convId] = list;
      await _metaBox?.put(_outboxKey, jsonEncode(all));
      _failures.remove(_outboxKey);
    } catch (e) {
      _noteFailure(_outboxKey, 'write error: $e');
    }
  }

  /// 移除一条已确认 / 已放弃的待发消息
  static Future<void> removeOutbox(String convId, String clientMsgId) async {
    if (convId.isEmpty ||
        clientMsgId.isEmpty ||
        _disabled.contains(_outboxKey)) {
      return;
    }
    try {
      final all = await _loadOutboxMap();
      final list = all[convId];
      if (list == null) return;
      list.removeWhere((x) => x['clientMsgId']?.toString() == clientMsgId);
      if (list.isEmpty) {
        all.remove(convId);
      } else {
        all[convId] = list;
      }
      await _metaBox?.put(_outboxKey, jsonEncode(all));
      _failures.remove(_outboxKey);
    } catch (e) {
      _noteFailure(_outboxKey, 'write error: $e');
    }
  }

  // ===== 钱包余额快照（首屏直出用） =====

  /// 读取持久化的钱包余额快照 {balance, frozen}；无/损坏返回 null。
  ///
  /// **只用于首屏展示**，消除冷启动"先显示 ¥0 再跳成真实值"的闪动。
  /// 任何金额的计算、校验、扣款都必须以服务端返回为准——
  /// 这份快照可能过期（用户可能在 PC 端/后台改过余额）。
  /// 涉及资金操作的页面（提现/转账/红包）都会先 refresh() 再用。
  static Future<Map<String, dynamic>?> loadWallet() async {
    const key = 'wallet';
    final box = _metaBox;
    if (box == null) return null;
    String? raw;
    try {
      raw = await box.get(key);
    } catch (e) {
      _noteFailure(key, 'read error: $e');
      return null;
    }
    if (raw == null || raw.isEmpty) return null;
    try {
      final data = jsonDecode(raw);
      if (data is Map) return Map<String, dynamic>.from(data);
      throw const FormatException('wallet is not a Map');
    } catch (e) {
      await _drop(box, key);
      _noteFailure(key, 'decode error: $e');
      return null;
    }
  }

  /// 保存余额快照（每次服务端返回真实余额后调用）
  static Future<void> saveWallet(
      {required double balance, required double frozen}) async {
    const key = 'wallet';
    if (_disabled.contains(key)) return;
    try {
      await _metaBox?.put(
          key,
          jsonEncode({
            'balance': balance,
            'frozen': frozen,
            'ts': DateTime.now().millisecondsSinceEpoch,
          }));
      _failures.remove(key);
    } catch (e) {
      _noteFailure(key, 'write error: $e');
    }
  }

  // ===== 搜索历史 =====

  /// 最多保留的搜索历史条数
  static const int maxSearchHistory = 10;

  /// 搜索历史（最近搜索的关键词，最新的在前）
  static Future<List<String>> loadSearchHistory() async {
    const key = 'search_history';
    final box = _metaBox;
    if (box == null) return const [];
    String? raw;
    try {
      raw = await box.get(key);
    } catch (e) {
      _noteFailure(key, 'read error: $e');
      return const [];
    }
    if (raw == null || raw.isEmpty) return const [];
    try {
      final data = jsonDecode(raw);
      if (data is List) {
        return data.map((e) => e.toString()).toList();
      }
      throw const FormatException('search_history is not a List');
    } catch (e) {
      await _drop(box, key);
      _noteFailure(key, 'decode error: $e');
      return const [];
    }
  }

  /// 记录一次搜索：去重后放到最前，超出 [maxSearchHistory] 丢最旧的
  static Future<void> addSearchHistory(String kw) async {
    const key = 'search_history';
    final text = kw.trim();
    if (text.isEmpty || _disabled.contains(key)) return;
    try {
      final list = await loadSearchHistory();
      list.removeWhere((e) => e == text); // 去重（重复搜索不占两个位置）
      list.insert(0, text);
      final trimmed = list.length > maxSearchHistory
          ? list.sublist(0, maxSearchHistory)
          : list;
      await _metaBox?.put(key, jsonEncode(trimmed));
      _failures.remove(key);
    } catch (e) {
      _noteFailure(key, 'write error: $e');
    }
  }

  static Future<void> clearSearchHistory() async {
    await _drop(_metaBox, 'search_history');
  }

  // ===== 清理 =====

  /// 退出登录 / 被踢下线：清会话与消息缓存（换账号不能看到上一个账号的聊天）。
  /// 钱包快照、搜索历史同样要清——都是用户私有数据。
  /// global 配置类（公告等）保留。
  static Future<void> clearUserData() async {
    try {
      // E2EE 本机私钥也是用户私有数据：换号必须清（内部自带 UserCache 兜底）
      await E2eeService.instance.resetLocal();
      await _messagesBox?.clear();
      await _drop(_metaBox, 'conv_list');
      await _drop(_metaBox, 'wallet');
      await _drop(_metaBox, 'search_history');
      // 换账号必须清掉补拉断点与本地发件箱：
      // 否则新账号会拿着上一个账号的 seq 去补拉（拉不到还可能误判水位回退），
      // 也会把上一个账号没发出去的消息重发出去。
      await _drop(_metaBox, _seqKey);
      await _drop(_metaBox, _outboxKey);
      // 群成员昵称/头像、置顶列表也是用户私有数据，换账号必须清
      await _drop(_metaBox, _membersKey);
      await _drop(_metaBox, _pinsKey);
      _failures.clear();
      _disabled.clear();
    } catch (e) {
      _log('clearUserData failed: $e');
    }
  }
}
