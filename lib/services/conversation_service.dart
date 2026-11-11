import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import 'api_client.dart';
import '../l10n/app_locale.dart';
import 'local_store.dart';
import '../models/link_card.dart';

/// 服务端业务错误（HTTP 200 + code != 0）：带 code 供页面区分处理
/// （如 4006 成员隐私 → 显示"群主已开启成员隐私"而不是报错）
class ApiException implements Exception {
  final int code;
  final String message;
  ApiException(this.code, this.message);
  @override
  String toString() => message;
}

class ConvItem {
  final Map<String, dynamic> conversation;
  final int unread;
  final Map<String, dynamic>? lastMessage;
  final int memberCount;
  final bool mute;
  final bool pinned;
  final String conversationName;
  final bool peerOnline; // 单聊对方在线（需求4）
  final List<dynamic> peerOnlineDev; // 在线设备：["mobile","web",...]
  final String peerOnlineZh; // 单聊对方在线类型中文
  final String peerShortId; // 单聊对方靓号/ID
  final bool peerVipShortId; // 对方是否靓号（预留池已绑定）→ 资料页显示「靓ID」徽标
  final String peerRemark; // 我对对方设置的备注（需求：备注优先显示）
  final String peerId; // 单聊对方用户 ID（顶层字段，雪花 ID 字符串）
  final dynamic peerRole; // 对方账号角色（1 普通/2 管理/3 客服，客服勾判定）
  // 注意：后端 ConvItem 的 peerRole 在【顶层】（service/conversation.go:134），
  // 不在 conversation map 里——以前客户端去 map 里找恒为 null，消息列表客服勾
  // 永远不亮（二十七批修复）。contacts_page 注入路径写的是 conversation map，
  // 所以这里两处都兜。

  ConvItem.fromJson(Map<String, dynamic> j)
      : conversation = j['conversation'] ?? {},
        unread = (j['unread'] as num?)?.toInt() ?? 0,
        lastMessage = j['lastMessage'],
        memberCount = (j['memberCount'] as num?)?.toInt() ?? 0,
        mute = j['mute'] ?? false,
        pinned = j['pinned'] ?? false,
        conversationName = j['conversationName'] ?? '',
        peerOnline = j['peerOnline'] == true,
        peerOnlineDev = (j['peerOnlineDev'] as List<dynamic>?) ?? [],
        peerOnlineZh = j['peerOnlineZh']?.toString() ?? '',
        peerShortId = j['peerShortId']?.toString() ?? '',
        peerVipShortId = j['peerVipShortId'] == true,
        peerRemark = j['peerRemark']?.toString() ?? '',
        peerId = j['peerId']?.toString() ?? '',
        peerRole =
            j['peerRole'] ?? (j['conversation'] as Map?)?['peerRole'];

  /// 客服判定用角色（顶层优先，contacts 注入的 conversation map 兜底）
  dynamic get peerRoleAny => peerRole ?? conversation['peerRole'];

  /// 会话 ID（雪花 ID 全程字符串，H5 上 int 会丢精度）
  String get id => conversation['id']?.toString() ?? '';

  /// 是否小助手会话（助手是虚拟 uid -1；消息列表/通讯录用它显示「官方」标识）
  /// 优先读顶层 peerId（服务端 ConvItem 结构），旧数据回落 conversation.peerId
  bool get isAssistant =>
      (peerId == '-1') || (conversation['peerId']?.toString() ?? '') == '-1';

  /// 会话头像（群头像 / 单聊对方头像），可能为空
  String get avatarUrl {
    final v = conversation['avatar'] ?? conversation['peerAvatar'];
    return v?.toString() ?? '';
  }

  /// 单聊对方最近上线时间（ISO8601 字符串；服务端单聊接口实时下发，可能为空）
  String get lastLoginAt => conversation['lastLoginAt']?.toString() ?? '';

  String get lastMsgPreview {
    final t = AppLocalizations.instance.t;
    final m = lastMessage;
    if (m == null) return '';
    if (m['recalled'] == true) return t('svcMsgRecalled');
    final type = (m['type'] as num?)?.toInt() ?? 1;
    if (type == 7) return _callPreview(m['content']);
    // 红包/转账：显示专门样式（不透出 JSON）
    if (type == 8) {
      final note = _moneyNote(m['content']);
      return note.isEmpty
          ? t('svcRedPacket')
          : t('svcRedPacketNote', {'note': note});
    }
    if (type == 9) {
      final note = _moneyNote(m['content']);
      return note.isEmpty
          ? t('svcTransfer')
          : t('svcTransferNote', {'note': note});
    }
    if (type == 11) {
      // 链接卡片（功能 B）：区分白名单内（小程序）/ 白名单外（网址），
      // 显示「[小程序] 标题」或「[网址] 域名」。JSON 解析失败兜底「[网址]」。
      final link = _tryParseLink(m['content']);
      if (link == null) return t('svcLink');
      final label = link.inApp ? t('svcMiniProgram') : t('svcLink');
      final body = link.title.trim().isNotEmpty
          ? link.title.trim()
          : (link.displayName.isNotEmpty ? link.displayName : link.domain);
      return body.isEmpty ? label : '$label $body';
    }
    final typeMap = {
      2: t('svcImage'),
      3: t('svcFile'),
      4: t('svcVoice'),
      5: t('svcVideo'),
      6: t('svcSystem'), // 系统消息：列表预览显示标签（页内另有完整文案转换）
      10: t('svcCard'), // 个人名片
      12: t('svcMerge'), // 合并转发（聊天记录）
      13: t('svcE2Text'), // 端到端加密文本：列表只显示标签（§36）
      14: t('svcLocation') // 位置消息（2026-09-21）
    };
    final label = typeMap[type] ?? '';
    // 文本(type=1)直接拼接内容；图片/文件/语音/视频仅显示类型标签，不透出 URL/原始内容
    if (type == 1) return label + (m['content']?.toString() ?? '');
    return label;
  }

  /// 红包/转账留言解析（JSON {kind,amount,note}）
  String _moneyNote(dynamic content) {
    try {
      final j = content is String ? jsonDecode(content) : content;
      if (j is Map) return (j['note'] ?? '').toString();
    } catch (_) {}
    return '';
  }

  /// 容错解析 type=11 链接卡片 content（JSON）。
  /// 坏 JSON / 非 Map / 缺 url → null，调用方降级为 [网址] 兜底标签。
  LinkCardData? _tryParseLink(dynamic content) {
    if (content == null) return null;
    try {
      return LinkCardData.tryParse(
          content is String ? content : jsonEncode(content));
    } catch (_) {
      return null;
    }
  }

  /// 通话记录预览：invite/reject/cancel/hangup 解析成人话
  String _callPreview(dynamic content) {
    final t = AppLocalizations.instance.t;
    // 一通电话一条记录（content=invite，可能带 status/duration 最终态）。
    // 列表预览不区分通话状态（用户要求）：一律显示「语音通话 / 视频通话」。
    var isVideo = false;
    if (content != null) {
      try {
        final sig = content is String
            ? (jsonDecode(content) as Map<String, dynamic>)
            : (content as Map<String, dynamic>);
        isVideo = sig['callType']?.toString() == 'video';
      } catch (_) {}
    }
    return isVideo ? t('svcCallVideo') : t('svcCallVoice');
  }

  String get timeText {
    final raw = lastMessage?['createdAt'] ?? conversation['createdAt'];
    if (raw == null) return '';
    final dt = DateTime.tryParse(raw.toString())?.toLocal();
    if (dt == null) return '';
    final now = DateTime.now();
    final hm =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return hm;
    }
    final yesterday = now.subtract(const Duration(days: 1));
    if (dt.year == yesterday.year &&
        dt.month == yesterday.month &&
        dt.day == yesterday.day) {
      return AppLocalizations.instance.t('svcYesterday', {'time': hm});
    }
    return '${dt.month}/${dt.day}';
  }
}

/// 增量补拉结果（对应服务端 service.SyncResult）。
///
/// 相比旧的「裸 List」，多了三个字段，客户端才能做对两件事：
///  - [hasMore]：还有后续 → 循环翻页，不再只拉一页就停（修 R-07）
///  - [serverSeq]：服务端水位 → 与本地断点比对，识别水位回退（修 R-04）
///  - [reset]：服务端判定水位确实回退了 → 客户端必须以服务端为准重置断点，
///    否则会面对一个「静默不动」的会话而毫无察觉
class SyncResult {
  final List<Map<String, dynamic>> list;
  final bool hasMore;
  final int maxSeq;
  final int serverSeq;
  final bool reset;

  const SyncResult({
    this.list = const <Map<String, dynamic>>[],
    this.hasMore = false,
    this.maxSeq = 0,
    this.serverSeq = 0,
    this.reset = false,
  });

  factory SyncResult.fromJson(Map<String, dynamic> j) => SyncResult(
        list: ((j['list'] as List<dynamic>?) ?? const <dynamic>[])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(),
        hasMore: j['hasMore'] == true,
        maxSeq: (j['maxSeq'] as num?)?.toInt() ?? 0,
        serverSeq: (j['serverSeq'] as num?)?.toInt() ?? 0,
        reset: j['reset'] == true,
      );

  bool get isEmpty => list.isEmpty;
  int get length => list.length;
}

class ConversationService {
  final Dio _dio = ApiClient.instance.dio;
  final _api = ApiClient.instance;

  /// 最近一次会话列表接口的原始数据（供页面落本地缓存）
  List<dynamic> lastConvRaw = [];

  /// 进程内历史消息缓存：convId → 最近一页原始消息。
  /// 打开会话先直出缓存再后台刷新，消掉转圈；WS 新消息实时追加。
  /// 2026-09-28：加 LRU 上限（默认插入序即访问序，读时 touch 移到队尾）——
  /// 反复进出不同聊天页时此缓存只增不减，长期循环后内存与 GC 压力上升。
  static final Map<String, List<Map<String, dynamic>>> _historyCache = {};
  static const int _historyCacheMax = 40;

  /// 写入缓存并执行 LRU 淘汰（移除最久未访问的会话）。
  static void _historyCachePut(
      String convId, List<Map<String, dynamic>> list) {
    _historyCache.remove(convId); // 重新插入 = 移到队尾（最新）
    _historyCache[convId] = list;
    while (_historyCache.length > _historyCacheMax) {
      _historyCache.remove(_historyCache.keys.first);
    }
  }

  static List<Map<String, dynamic>>? historyCached(String convId) {
    final c = _historyCache[convId];
    if (c != null) {
      // touch：命中即移到队尾，保证「最近使用」语义
      _historyCache.remove(convId);
      _historyCache[convId] = c;
    }
    return c;
  }

  /// WS 收到/发送成功后把原始消息追加进缓存（按 msgId/clientMsgId 幂等去重）
  static void historyCacheAppend(String convId, Map<String, dynamic> raw) {
    final c = _historyCache[convId];
    if (c == null) return;
    final id = raw['msgId']?.toString() ?? '';
    final cm = raw['clientMsgId']?.toString() ?? '';
    for (final x in c) {
      if ((id.isNotEmpty && x['msgId']?.toString() == id) ||
          (cm.isNotEmpty && x['clientMsgId']?.toString() == cm)) {
        return;
      }
    }
    c.add(raw);
    if (c.length > 80) c.removeRange(0, c.length - 80);
    // 同步落盘（异步，不阻塞 UI）：杀进程后重开仍能看到这些消息
    unawaited(LocalStore.appendMessage(convId, raw));
  }

  /// 通话记录最终态回写：invite 消息的 content 被服务端原地改写
  /// （status=done/rejected/missed + duration，call_update 事件驱动）。
  /// 内存缓存与磁盘缓存里的旧 content（「点击回拨」中间态）必须同步替换，
  /// 否则重进会话又变回中间态。
  /// [extra] 可选附加字段合并进该缓存条目（如编辑事件的 {'edited': true}，
  /// 2026-09-28），否则重进会话前缓存里的消息丢失「已编辑」标记。
  static void historyCacheReplaceContent(
      String convId, String msgId, String content,
      {Map<String, dynamic>? extra}) {
    final c = _historyCache[convId];
    if (c == null || msgId.isEmpty || content.isEmpty) return;
    for (final x in c) {
      if (x['msgId']?.toString() == msgId) {
        x['content'] = content;
        if (extra != null) x.addAll(extra);
        unawaited(LocalStore.replaceMessageContent(convId, msgId, content));
        return;
      }
    }
  }

  /// 撤回态回写：消息被撤回（自己撤回 / 收到 recall 事件）后，内存与磁盘
  /// 缓存里的原消息同步标记 recalled=true，否则重进会话又显示原消息。
  static void historyCacheMarkRecalled(String convId, String msgId) {
    final c = _historyCache[convId];
    if (c == null || msgId.isEmpty) return;
    for (final x in c) {
      if (x['msgId']?.toString() == msgId) {
        if (x['recalled'] == true) return;
        x['recalled'] = true;
        unawaited(LocalStore.markMessageRecalled(convId, msgId));
        return;
      }
    }
  }

  /// 后台屏蔽/删除对账：服务端历史接口已不再下发的消息（blocked=true 被
  /// 过滤）从内存与磁盘缓存移除。msgIds 为空或无命中时不写盘。
  static void historyCacheRemoveAll(String convId, Set<String> msgIds) {
    final c = _historyCache[convId];
    if (c == null || msgIds.isEmpty) return;
    final before = c.length;
    c.removeWhere((x) => msgIds.contains(x['msgId']?.toString()));
    if (c.length != before) {
      unawaited(LocalStore.saveMessages(convId, c));
    }
  }

  /// 「删除双方聊天记录」：整会话历史清空（内存 + 磁盘）。
  /// 服务端只推进软删位点（消息本体保留），本地必须把缓存清干净，
  /// 否则重进会话还会从缓存直出已删消息。
  static void historyCacheClearConv(String convId) {
    if (convId.isEmpty) return;
    _historyCache.remove(convId);
    unawaited(LocalStore.saveMessages(convId, const <Map<String, dynamic>>[]));
  }

  /// 冷启动兜底：内存没缓存时从本地持久化（Hive）回填。
  /// 返回 true 表示有数据可直出（调用方再读 historyCached 即可）。
  static Future<bool> hydrateFromDisk(String convId) async {
    if (_historyCache.containsKey(convId)) return true;
    final disk = await LocalStore.loadMessages(convId);
    if (disk == null || disk.isEmpty) return false;
    _historyCachePut(convId, disk); // 2026-09-28：走 LRU 写入
    return true;
  }

  // ---- 群成员 / 置顶的进程内缓存（磁盘层在 LocalStore，进群聊首帧即渲染，
  // ---- 消「每次进群聊跳一下 + 头像变一下」；与 _historyCache 同一生命周期）----
  static final Map<String, List<Map<String, dynamic>>> _membersCache = {};
  static final Map<String, List<Map<String, dynamic>>> _pinsCache = {};

  static List<Map<String, dynamic>>? membersCached(String convId) =>
      _membersCache[convId];

  static void cacheMembers(String convId, List<Map<String, dynamic>> list) {
    if (convId.isEmpty || list.isEmpty) return;
    _membersCache[convId] = list;
  }

  static List<Map<String, dynamic>>? pinsCached(String convId) =>
      _pinsCache[convId];

  static void cachePins(String convId, List<Map<String, dynamic>> list) {
    if (convId.isEmpty) return;
    _pinsCache[convId] = list;
  }

  /// 订阅 Hive 缓存损坏事件：脏数据已被 LocalStore 清掉，这里同步把
  /// **内存缓存也失效**，保证下次打开该会话走网络重拉并重新落盘
  /// （否则损坏的脏数据会一直留在内存里，UI 反复显示错误内容）。
  /// 'conv_list' 由 chat_list_page 自己处理（它本来每次进页都全量刷新）。
  static void bindLocalStore() {
    LocalStore.addCorruptListener((key) {
      if (key == 'conv_list') return;
      _historyCache.remove(key);
    });
  }

  Future<List<ConvItem>> list() async {
    final r = await _api.get('/api/v1/conversation/list');
    final data = r.data['data'] as List<dynamic>? ?? [];
    lastConvRaw = data;
    return data
        .map((e) => ConvItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 所有 ID 参数均为 String（雪花 ID 字符串，H5 精度安全）
  Future<Map<String, dynamic>> createDirect(String userId) async {
    final r = await _dio.post('/api/v1/conversation/direct',
        data: {'userId': userId},
        options: Options(headers: await _api.authHeaders()));
    return (r.data as Map<String, dynamic>)['data'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> send(String convId, String content,
      {String? clientMsgId, String? replyTo, List<String>? mentions}) async {
    // 修 R-14：token 读取必须带超时（见 ApiClient.readTokenSafe 注释）
    final r = await _dio.post('/api/v1/message/send',
        data: {
          'conversationId': convId,
          'type': 1,
          'content': content,
          'clientMsgId': clientMsgId,
          'replyTo': replyTo,
          'mention': mentions,
        },
        options: Options(headers: await _api.authHeaders()));
    return _unwrapSend(r.data);
  }

  /// 发送类接口的信封校验（修 R-15）。
  ///
  /// 服务端业务失败一律 **HTTP 200 + code!=0**（如「你已被禁言」=4005），
  /// 此时 data 为 null。旧代码直接 `data as Map` → 抛 TypeError → 被上层
  /// catch 统一标「发送失败」，**真实原因被吞掉**（用户以为网络坏了，其实是禁言）。
  /// 抛 [ApiException] 后，气泡能显示服务端原文。
  Map<String, dynamic> _unwrapSend(dynamic raw) {
    final body = raw as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw ApiException(code, (body['message'] ?? '发送失败').toString());
    }
    return (body['data'] as Map<String, dynamic>? ?? {});
  }

  /// 通用发送（转发等场景）：type/content 由调用方决定，信封处理与 sendMoney 一致
  /// （code!=0 抛错，避免 HTTP 200 + 失败被上层当成"发送成功"）
  ///
  /// [file]：文件消息（type=3）元数据，非 null 时随请求一起提交。
  /// 键名必须与后端 `SendMsgReq.File` / `buildConvFile` 约定一致：
  /// object（MinIO 对象名，必填，否则后端不写 conv_files）、name、size、mimeType、url。
  Future<Map<String, dynamic>> sendRaw(String convId, int type, String content,
      {String? clientMsgId,
      String? replyTo,
      Map<String, dynamic>? file}) async {
    final r = await _dio.post('/api/v1/message/send',
        data: {
          'conversationId': convId,
          'type': type,
          'content': content,
          'clientMsgId': clientMsgId ?? _genClientMsgId(),
          'replyTo': replyTo,
          if (file != null) 'file': file,
        },
        options: Options(headers: await _api.authHeaders()));
    return _unwrapSend(r.data);
  }

  /// clientMsgId 生成（service 内独立实现，避免依赖页面）：
  /// 毫秒时间戳 + 随机数，保证同批转发多条也不冲突
  String _genClientMsgId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(99999)}';

  /// 需求3：发送图片消息（type=2，content=URL）
  Future<Map<String, dynamic>> sendImage(String convId, String url,
      {String? clientMsgId}) async {
    final r = await _dio.post('/api/v1/message/send',
        data: {
          'conversationId': convId,
          'type': 2,
          'content': url,
          'clientMsgId': clientMsgId,
        },
        options: Options(headers: await _api.authHeaders()));
    return _unwrapSend(r.data);
  }

  /// 红包/转账（type=8 红包 / type=9 转账，content=JSON 自定义负载）
  /// [payPassword]：支付密码（发红包/转账时由客户端采集，服务端强制校验）。
  Future<Map<String, dynamic>> sendMoney(
      String convId, int type, Map<String, dynamic> contentData,
      {String? clientMsgId, String? payPassword}) async {
    contentData['ts'] = DateTime.now().millisecondsSinceEpoch;
    final r = await _dio.post('/api/v1/message/send',
        data: {
          'conversationId': convId,
          'type': type,
          'content': jsonEncode(contentData),
          'clientMsgId': clientMsgId,
          if (payPassword != null) 'payPassword': payPassword,
        },
        options: Options(headers: await _api.authHeaders()));
    // 业务 code 必须判：后端余额不足 / 参数错误时 HTTP 仍是 200 但 data 为 null，
    // 不判 code 的话上层会当成"发送成功"（B-19：0 余额也能把红包发出去）。
    return _unwrapSend(r.data);
  }

  /// 历史消息（服务端返回**时间正序**：最旧在前）。
  ///
  /// [beforeMsgId]：分页游标，传当前最旧一条的 msgId 拉更早的（0/'0' = 拉最新一页）。
  /// 类型用 String 而非 int——雪花 ID 在 Web（JS）上超过 2^53 会丢精度。
  ///
  /// limit 固定 80：与 LocalStore.maxMessagesPerConv 对齐。
  /// 之前是 50，导致冷启动先用 Hive 的 80 条缓存渲染、网络回来只给 50 条，
  /// 列表凭空少 30 条（上翻时会发现消息断层）。
  Future<List<Map<String, dynamic>>> history(String convId,
      {String beforeMsgId = '0'}) async {
    final r = await _dio.get('/api/v1/message/history',
        queryParameters: {
          'convId': convId,
          'beforeMsgId': beforeMsgId,
          'limit': 80
        },
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    final list =
        ((r.data as Map<String, dynamic>)['data'] as List<dynamic>? ?? [])
            .map((e) => e as Map<String, dynamic>)
            .toList();
    // 只缓存"最新一页"（无 beforeMsgId 的首拉），上翻加载的更早历史不覆盖。
    // 首拉**无条件**写内存缓存（含空列表）：空会话不缓存会导致每次进页都转圈。
    if (beforeMsgId == '0') {
      _historyCachePut(convId, list); // 2026-09-28：走 LRU 写入
      // 空列表不落盘 Hive：避免脏空覆盖磁盘上已有的历史数据
      if (list.isNotEmpty) {
        unawaited(LocalStore.saveMessages(convId, list)); // 落盘：冷启动秒开
      }
    }
    return list;
  }

  Future<void> markRead(String convId, String msgId) async {
    await _dio.post('/api/v1/message/read',
        data: {'conversationId': convId, 'msgId': msgId},
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
  }

  /// 群置顶消息列表（按置顶顺序，含 content/senderName/type/createdAt）
  Future<List<Map<String, dynamic>>> pinnedMessages(String convId) async {
    final r = await _dio.get('/api/v1/conversation/$convId/pins',
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    final data = (r.data['data'] as List<dynamic>?) ?? [];
    return data.map((e) => (e as Map).cast<String, dynamic>()).toList();
  }

  /// 增量补拉（新接口）：重连补偿 / 空洞填补（seq > afterSeq）。
  ///
  /// 返回 [SyncResult]，调用方**必须**按 hasMore 循环翻页并把断点推进到 maxSeq，
  /// 否则大群断线积压 >500 条时第 501 条之后永远拉不到（旧实现的 R-06/R-07）。
  ///
  /// [limit] 上限 500（服务端硬上限一致）；默认 500 一页尽量少跑几趟。
  Future<SyncResult> syncV2(String convId, int afterSeq,
      {int limit = 500}) async {
    final r = await _dio.get('/api/v1/message/sync',
        queryParameters: {
          'convId': convId,
          'afterSeq': '$afterSeq',
          'limit': limit,
        },
        options: Options(headers: await _api.authHeaders()));
    final body = r.data as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw ApiException(code, (body['message'] ?? '补拉失败').toString());
    }
    final data = body['data'];
    if (data is Map<String, dynamic>) return SyncResult.fromJson(data);
    // 兼容老后端（返回裸数组）：当作只有一页、无水位信息
    if (data is List) {
      return SyncResult(
        list: data
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(),
      );
    }
    return const SyncResult();
  }

  /// 服务端该会话当前最新 seq（水位）。
  /// 进会话时调一次，把本地断点与服务端对齐（成本可忽略，收益是不再盲目从 0 拉）。
  Future<int> lastSeqOf(String convId) async {
    final r = await _dio.get('/api/v1/message/lastSeq',
        queryParameters: {'convId': convId},
        options: Options(headers: await _api.authHeaders()));
    final body = r.data as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw ApiException(code, (body['message'] ?? '查询失败').toString());
    }
    final d = body['data'];
    if (d is Map<String, dynamic>) return (d['seq'] as num?)?.toInt() ?? 0;
    return 0;
  }

  // ============ 会话设置 ============

  Future<bool> setPin(String convId, bool pinned) async {
    final r = await _dio.put('/api/v1/conversation/$convId/pin',
        data: {'pinned': pinned},
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return (r.data as Map<String, dynamic>)['code'] == 0;
  }

  Future<bool> setMute(String convId, bool mute) async {
    final r = await _dio.put('/api/v1/conversation/$convId/mute',
        data: {'mute': mute},
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return (r.data as Map<String, dynamic>)['code'] == 0;
  }

  Future<bool> quit(String convId) async {
    final r = await _dio.post('/api/v1/conversation/$convId/quit',
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return (r.data as Map<String, dynamic>)['code'] == 0;
  }

  /// 删除聊天记录（仅单聊；2026-09-18 新接口）：
  /// `POST /api/v1/conversation/:id/clear-history`。
  /// scope: "self" 仅为我删除（只推进自己位点）/ "both" 为双方删除（推进双方位点）。
  /// 服务端软删——消息本体保留（后台可查），位点后 History/会话列表不再下发。
  /// 返回 data.clearedMsgId（空会话为 "0"）。
  Future<String> clearHistory(String convId, {String scope = 'both'}) async {
    final r = await _dio.post('/api/v1/conversation/$convId/clear-history',
        data: {'scope': scope},
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    final body = r.data as Map<String, dynamic>;
    if (body['code'] != 0) {
      throw Exception(body['message'] ?? 'clear failed');
    }
    final data = body['data'];
    if (data is Map<String, dynamic>) {
      return data['clearedMsgId']?.toString() ?? '0';
    }
    return '0';
  }

  Future<bool> disband(String convId) async {
    final r = await _dio.post('/api/v1/conversation/$convId/disband',
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return (r.data as Map<String, dynamic>)['code'] == 0;
  }

  /// 删除会话（从我列表移除，不影响群成员身份）：`DELETE /api/v1/conversation/:id`。
  /// 服务端把 conversation_member.hidden 置 1；ConvList 过滤 hidden=0，
  /// 故重拉 /conversation/list 时该会话不再出现（收到新消息会经 UnhideConv 自动重现，符合预期）。
  /// 会话列表侧滑删除、会话设置「删除并退出」等入口共用。
  Future<bool> deleteConversation(String convId) async {
    final r = await _dio.delete('/api/v1/conversation/$convId',
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return (r.data as Map<String, dynamic>)['code'] == 0;
  }

  /// 投诉会话/用户（会话设置「投诉」入口，2026-09-15 第九批建，第十批接真）。
  ///
  /// `POST /api/v1/conversation/report`（后端已上线，见 doc/API.md「## 投诉」节）。
  /// body: {'convId', 'peerId', 'category', 'note'}；HTTP 恒 200、业务码看 body.code，
  /// code!=0 抛 ApiException（页面捕获后 toast 服务端 message）。
  /// category 为客户端词条 key（服务端不校验枚举，管理后台原样展示）。
  Future<bool> reportConversation({
    required String convId,
    String peerId = '',
    required String category,
    String note = '',
  }) async {
    final r = await _dio.post('/api/v1/conversation/report',
        data: {
          'convId': convId,
          'peerId': peerId,
          'category': category,
          'note': note,
        },
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    final body = r.data as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw ApiException(code, body['message']?.toString() ?? '提交失败');
    }
    return true;
  }

  /// 按类型筛选历史消息（2026-09-15 第十二批二轮：好友资料页媒体行）。
  /// 契约（API.md :1382）：`GET /api/v1/message/filter`
  /// `?conversationId=&type=image|video|voice|file|link&beforeSeq=&limit=`；
  /// seq 倒序存储、**输出时间正序**，游标分页传「已加载集合中最早的 seq」作
  /// [beforeSeq] 拉更早一页。data 为轻量消息卡：
  /// `{id,seq,type,digest,url(omitempty),createdAt}`。
  Future<List<Map<String, dynamic>>> filterMessages({
    required String conversationId,
    required String type,
    int limit = 30,
    int? beforeSeq,
  }) async {
    final r = await _dio.get('/api/v1/message/filter',
        queryParameters: {
          'conversationId': conversationId,
          'type': type,
          'limit': limit,
          if (beforeSeq != null) 'beforeSeq': beforeSeq,
        },
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    final body = r.data as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw ApiException(code, body['message']?.toString() ?? '');
    }
    return ((body['data'] as List<dynamic>?) ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// 创建群聊：name + 成员 ID（含自己自动添加为群主）
  /// 创建群聊。2026-09-29 创建页（图4）扩参：[avatar] 头像 URL（先 /upload）、
  /// [isPublic] 群组类型（null=默认公开；false=私密群组，不可被搜索仅受邀加入）。
  Future<Map<String, dynamic>> createGroup(String nameZh, List<String> memberIds,
      {String avatar = '', bool? isPublic}) async {
    final r = await _dio.post('/api/v1/conversation/group',
        data: {
          'nameZh': nameZh,
          'memberIds': memberIds,
          if (avatar.isNotEmpty) 'avatar': avatar,
          if (isPublic != null) 'isPublic': isPublic,
        },
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return (r.data as Map<String, dynamic>)['data'] as Map<String, dynamic>;
  }

  /// 创建频道（type=3 会话，频道 ID 即会话 ID，渲染分支已预留于 chat_list_page type==3）。
  /// 端点已定稿（im-server/doc/API.md「## 频道（Channel）」）：
  /// `POST /api/v1/channel` —— 创建者即频道主（role=1）；
  /// nameZh/nameEn 必填其一（sheet 只有单一名称框 → 填 nameZh）；
  /// isPublic=false = 私密频道（qrJoinEnabled=0，不可自助关注）。
  /// [shortId] 自定义频道 ID（选填）：3-20 位字母/数字/下划线，全局唯一；
  /// 空 = 未填写不传。重复时后端返回业务码 3008（ApiException.message 可直接展示）。
  /// 已关注频道自动出现在 /conversation/list（type=3）。
  Future<Map<String, dynamic>> createChannel(String name,
      {bool isPublic = true, String shortId = ''}) async {
    final r = await _dio.post('/api/v1/channel',
        data: {
          'nameZh': name,
          'isPublic': isPublic,
          if (shortId.isNotEmpty) 'shortId': shortId,
        },
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return (r.data as Map<String, dynamic>)['data'] as Map<String, dynamic>;
  }

  /// 最近一次 members() 响应携带的群成员总数（隐私限量模式下列表被截断，总数照实下发）
  int _lastMembersCount = 0;
  int get lastMembersCount => _lastMembersCount;

  /// 最近一次 members() 响应携带的群在线人数（be-channel 第十批新增，
  /// `GET /conversation/:id/members` 响应顶层，与 memberCount 并列，见 API.md）
  int _lastOnlineCount = 0;
  int get lastOnlineCount => _lastOnlineCount;

  /// 会话成员列表（群设置用）；code!=0 抛 ApiException（如 4006 成员隐私）。
  /// 2026-09-29 支持服务端分页：page/size 均 >0 时按 LIMIT/OFFSET 下发，
  /// memberCount 恒为全量总数（群资料页「先 20 个 + 手动加载更多」用）。
  Future<List<Map<String, dynamic>>> members(String convId,
      {int page = 0, int size = 0}) async {
    final r = await _dio.get('/api/v1/conversation/$convId/members',
        queryParameters: {
          if (page > 0 && size > 0) 'page': page,
          if (page > 0 && size > 0) 'size': size,
        },
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    final body = r.data as Map<String, dynamic>;
    _lastMembersCount = (body['memberCount'] as num?)?.toInt() ?? 0;
    _lastOnlineCount = (body['onlineCount'] as num?)?.toInt() ?? 0;
    return _dataList(body);
  }

  List<Map<String, dynamic>> _dataList(dynamic body) {
    final map = body as Map<String, dynamic>;
    final code = (map['code'] as num?)?.toInt() ?? 0;
    if (code != 0) throw ApiException(code, map['message']?.toString() ?? '');
    return ((map['data'] as List<dynamic>?) ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Map<String, dynamic> _dataMap(dynamic body) {
    final map = body as Map<String, dynamic>;
    final code = (map['code'] as num?)?.toInt() ?? 0;
    if (code != 0) throw ApiException(code, map['message']?.toString() ?? '');
    return ((map['data'] as Map?) ?? {})
        .map((k, v) => MapEntry(k.toString(), v));
  }

  // ============ 群聊管理 ============

  /// 读取群管理设置（muteAll/privacyEnabled/allowMemberInvite/qrJoinEnabled）
  Future<Map<String, dynamic>> groupSettings(String convId) async {
    final r = await _dio.get('/api/v1/conversation/$convId/settings',
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return _dataMap(r.data);
  }

  /// 更新群管理设置（仅群主；未传的开关服务端保持原值）
  Future<bool> setGroupSettings(String convId,
      {bool? muteAll,
      bool? privacyEnabled,
      bool? allowInvite,
      bool? qrJoin,
      bool? showMembers,
      // 2026-09-28 编辑群组页四项权限开关（对普通成员生效，群主/管理员豁免）
      bool? sendMedia,
      bool? sendLink,
      bool? memberPin,
      bool? albumView,
      // 2026-09-28（晚）图1 新增：允许管理员添加成员 / 群组类型（私密=不可搜索仅受邀）
      bool? adminCanInvite,
      bool? isPublic,
      // 2026-09-29 新成员历史限制：新进群的普通成员只能查看入群后的消息
      bool? historyLimited,
    }) async {
    final r = await _dio.put('/api/v1/conversation/$convId/settings',
        data: {
          if (muteAll != null) 'muteAll': muteAll,
          if (privacyEnabled != null) 'privacyEnabled': privacyEnabled,
          if (allowInvite != null) 'allowMemberInvite': allowInvite,
          if (qrJoin != null) 'qrJoinEnabled': qrJoin,
          // 需求5（2026-09-22）：显示群成员人数/在线人数
          if (showMembers != null) 'showMembers': showMembers,
          if (sendMedia != null) 'sendMediaAllowed': sendMedia,
          if (sendLink != null) 'sendLinkAllowed': sendLink,
          if (memberPin != null) 'memberPinAllowed': memberPin,
          if (albumView != null) 'albumViewAllowed': albumView,
          if (adminCanInvite != null) 'adminCanInvite': adminCanInvite,
          if (isPublic != null) 'isPublic': isPublic,
          if (historyLimited != null) 'newMemberHistoryLimited': historyLimited,
        },
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return ((r.data as Map<String, dynamic>)['code'] as num?)?.toInt() == 0;
  }

  /// 设置群组号（2026-09-28，仅群主）：shortId 为空串=清除。
  /// 凭群组号可在搜索页「凭 ID 加入」命中该群。
  /// 返回业务 code：0 成功 / 1001 格式非法 / 3008 已被占用。
  Future<int> setGroupShortId(String convId, String shortId) async {
    final r = await _dio.put('/api/v1/conversation/$convId/short-id',
        data: {'shortId': shortId},
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return ((r.data as Map<String, dynamic>)['code'] as num?)?.toInt() ?? 500;
  }

  /// 设置/取消群管理员（仅群主）
  Future<bool> setGroupAdmin(String convId, String userId, bool admin) async {
    final r = await _dio.put('/api/v1/conversation/$convId/admin',
        data: {'userId': userId, 'admin': admin},
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return ((r.data as Map<String, dynamic>)['code'] as num?)?.toInt() == 0;
  }

  /// 转让群主（2026-09-28（晚），仅群主）：目标须为在群成员；
  /// 转让后原群主降为管理员，并发群系统消息
  Future<bool> transferOwner(String convId, String userId) async {
    final r = await _dio.put('/api/v1/conversation/$convId/transfer-owner',
        data: {'userId': userId},
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return ((r.data as Map<String, dynamic>)['code'] as num?)?.toInt() == 0;
  }

  /// 设置成员群昵称（2026-09-28（晚））：群主/管理员可改他人，成员可改自己；
  /// 空串=清除。写 conversation_member.nickname
  Future<bool> setGroupNickname(
      String convId, String userId, String nickname) async {
    final r = await _dio.put('/api/v1/conversation/$convId/member-nickname',
        data: {'userId': userId, 'nickname': nickname},
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return ((r.data as Map<String, dynamic>)['code'] as num?)?.toInt() == 0;
  }

  /// 禁言/解除禁言成员（群主/管理员；minutes 为禁言时长分钟数）
  Future<bool> muteMember(String convId, String userId, bool mute,
      {int minutes = 10}) async {
    final r = await _dio.put('/api/v1/conversation/$convId/mute-member',
        data: {'userId': userId, 'mute': mute, 'minutes': minutes},
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return ((r.data as Map<String, dynamic>)['code'] as num?)?.toInt() == 0;
  }

  /// 进群（返回会话对象）。join 幂等（重复调用服务端按"已是成员"跳过）→ 走瞬时
  /// 重试，服务端偶发 >10s 响应慢时自动重试，不再报「进群失败 receive timeout」。
  /// 2026-09-28 需求2：via 标记入群来源（qrcode=扫码 / search=搜索群号），
  /// 服务端透传给入群系统消息（"XX通过二维码扫码入群 / XX通过搜索群号入群"）。
  Future<Map<String, dynamic>> joinGroup(String convId, {String via = 'qrcode'}) async {
    final r = await _api.postIdempotent(
        '/api/v1/conversation/$convId/join?via=$via',
        headers: {'Authorization': 'Bearer ${await _api.readToken()}'});
    return _dataMap(r.data);
  }

  /// 关注频道（十四批 #6：搜索频道 ID 后订阅）。端点见 API.md「频道（Channel）」：
  /// `POST /api/v1/channel/:id/follow` —— 仅公开频道可自助关注；
  /// 已关注则幂等返回。成功后频道自动出现在会话列表。
  /// 返回 Conversation（type=3，id 即频道 ID）。
  Future<Map<String, dynamic>> followChannel(String channelId) async {
    final r = await _dio.post('/api/v1/channel/$channelId/follow',
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return _dataMap(r.data);
  }

  /// 频道资料（十四批 #7：频道名片解析）。端点见 API.md「频道（Channel）」：
  /// `GET /api/v1/channel/:id` —— 公开频道任何人可见；私密频道非成员 4001。
  /// 返回 {conversation(type=3 原样会话对象), isPublic, ownerId, ownerName,
  /// ownerAvatar, followerCount, followed}。
  Future<Map<String, dynamic>> channelDetail(String channelId) async {
    final r = await _api.get('/api/v1/channel/$channelId');
    return _dataMap(r.data);
  }

  /// 扫码进群前的群信息预览（二次确认页：conversation + memberCount）。
  /// GET 走 ApiClient.get（自带瞬时重试）
  Future<Map<String, dynamic>> groupPreview(String convId) async {
    final r = await _api.get('/api/v1/conversation/$convId/preview');
    return _dataMap(r.data);
  }

  /// 邀请成员进群（群主/管理员，或开启"允许成员邀请"的普通成员）
  Future<bool> inviteMembers(String convId, List<String> userIds) async {
    final r = await _dio.post('/api/v1/conversation/$convId/invite',
        data: {'memberIds': userIds},
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    final body = r.data as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) throw ApiException(code, body['message']?.toString() ?? '');
    return code == 0;
  }

  /// 移除群成员（群主/管理员）
  Future<bool> removeMember(String convId, String userId) async {
    final r = await _dio.delete('/api/v1/conversation/$convId/members/$userId',
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    final body = r.data as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) throw ApiException(code, body['message']?.toString() ?? '');
    return code == 0;
  }

  /// 更新群信息（群名/群头像；name 双语同值，App 内单语言展示）
  Future<bool> updateGroupInfo(String convId,
      {String? name, String? avatar}) async {
    final r = await _dio.put('/api/v1/conversation/$convId',
        data: {
          if (name != null) ...{'nameZh': name, 'nameEn': name},
          if (avatar != null) 'avatar': avatar,
        },
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    final body = r.data as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) throw ApiException(code, body['message']?.toString() ?? '');
    return code == 0;
  }

  // ============ 搜索 / 收藏 ============

  /// 消息搜索（仅自己参与的会话）。2026-09-29 会话内搜索：[convId] 非空时
  /// 只搜该会话（后端 ?convId= 既有参数）；结果项含 senderNickname/senderAvatar。
  Future<Map<String, dynamic>> searchMessages(String kw,
      {int page = 1, String? convId}) async {
    final r = await _dio.get('/api/v1/message/search',
        queryParameters: {
          'kw': kw,
          'page': page,
          'size': 20,
          if (convId != null && convId.isNotEmpty) 'convId': convId,
        },
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return (r.data as Map<String, dynamic>)['data'] as Map<String, dynamic>;
  }

  Future<bool> favoriteAdd(String convId, String msgId) async {
    final r = await _dio.post('/api/v1/message/favorite',
        data: {'conversationId': convId, 'msgId': msgId},
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return (r.data as Map<String, dynamic>)['code'] == 0;
  }

  // ============ 群功能 ============

  /// 置顶/取消置顶消息（群主/管理员；pinned=false 按 msgId 取消置顶）
  Future<bool> setPinMessage(
      String convId, String msgId, String content,
      {bool pinned = true}) async {
    final r = await _dio.put('/api/v1/conversation/$convId/pin-message',
        data: {'msgId': msgId, 'content': content, 'pinned': pinned},
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return (r.data as Map<String, dynamic>)['code'] == 0;
  }

  /// 更新群公告（群主/管理员）
  Future<bool> updateAnnouncement(String convId, String zh, String en) async {
    final r = await _dio.put('/api/v1/conversation/$convId/announcement',
        data: {'announcementZh': zh, 'announcementEn': en},
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return (r.data as Map<String, dynamic>)['code'] == 0;
  }

  /// 撤回消息（本人 2min / 群主管理员）
  Future<bool> recall(String msgId) async {
    final r = await _dio.post('/api/v1/message/$msgId/recall',
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return (r.data as Map<String, dynamic>)['code'] == 0;
  }

  /// 群消息已读详情（L1）：拉取某条消息的已读名单 + 已读人数 + 群成员总数。
  /// 端点 GET /api/v1/message/receipts（契约见 im-server/doc/API.md）。
  /// 服务端「按需拉取、不广播」：只在用户打开详情时聚合查询，无扇出。
  /// 返回 data 对象：{receipts:[{conversationId,msgId,userId,readAt}], readCount, memberCount}。
  /// code!=0 抛 ApiException（如 4001 非成员）。
  Future<Map<String, dynamic>> receipts(
      String convId, String msgId) async {
    final r = await _dio.get('/api/v1/message/receipts',
        queryParameters: {'convId': convId, 'msgId': msgId},
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return _dataMap(r.data);
  }

  Future<List<Map<String, dynamic>>> favorites({int limit = 50}) async {
    final r = await _dio.get('/api/v1/message/favorites',
        queryParameters: {'limit': limit},
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return ((r.data as Map<String, dynamic>)['data'] as List<dynamic>? ?? [])
        .map((e) => e as Map<String, dynamic>)
        .toList();
  }
}
