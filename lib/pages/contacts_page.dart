import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lpinyin/lpinyin.dart';

import '../services/api_client.dart';
import '../services/conversation_service.dart';
import '../services/friend_service.dart';
import '../services/user_cache.dart';
import '../services/wide_layout_store.dart';
import '../services/ws_service.dart';
import '../utils/breakpoints.dart';
import '../services/friend_req_store.dart';
import '../services/feature_flags.dart';
import '../l10n/app_locale.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/brand_loading.dart';
import '../widgets/official_tag.dart';
import '../widgets/v2_kit.dart';
import '../widgets/v2_tags.dart';
import '../widgets/v2_seal_badge.dart';
import 'add_friend_page.dart';
import 'chat_page.dart';
import 'friend_detail_page.dart';
import 'my_groups_page.dart';
import 'my_channels_page.dart';
import 'new_friends_page.dart';

// ============================================================
// ===== 通讯录页 V2 实测色值（基准：参考截图逻辑宽 420 / DPR 3）=====
// ============================================================
// 全部数值来自 `measure_contacts.md`（唯一权威尺寸来源），渲染时统一
// `* v2Scale(context)`，这样 360/390/412 等窄屏上「元素与屏宽的比值」与截图一致。
// 深色模式不另造一套配色：只做「底色转黑 / 文字转白」级别的替换。
const Color _kBg = Color(0xFFF5F5F5); // 页面底 / 分组头带
const Color _kCard = Color(0xFFFFFFFF); // 白卡 / 行底
const Color _kTitle = Color(0xFF000000); // 大标题
const Color _kInk = Color(0xFF0C0D12); // 功能行图标与文字
const Color _kName = Color(0xFF121826); // 联系人名字
const Color _kSub = Color(0xFF6C737D); // 副标题
const Color _kSectionLetter = Color(0xFF7E7E7E); // 分组头字母
const Color _kIndexLetter = Color(0xFF6F6F6F); // 右侧索引字母
const Color _kSearchFill = Color(0xFFF7F7F7); // 搜索框填充
const Color _kSearchHint = Color(0xFF8F8E93); // 放大镜 / 占位文字
const Color _kLine = Color(0xFFE5E5E5); // 分隔线与底边线

// ===== 列表骨架固定尺寸（索引条点击跳转要按这些值累加「好友段」内的模型偏移）=====
const double _kSectionH = 38.7; // 分组头带
const double _kRowH = 86.7; // 联系人行
const double _kRowLineH = 0.7; // 组内分隔线

Color _bgOf(BuildContext c) => c.v2IsDark ? const Color(0xFF000000) : _kBg;
Color _cardOf(BuildContext c) => c.v2IsDark ? const Color(0xFF1C1C1E) : _kCard;
Color _titleOf(BuildContext c) => c.v2IsDark ? Colors.white : _kTitle;
Color _inkOf(BuildContext c) => c.v2IsDark ? const Color(0xFFE6E6EA) : _kInk;
Color _nameOf(BuildContext c) => c.v2IsDark ? Colors.white : _kName;
Color _subOf(BuildContext c) => c.v2IsDark ? const Color(0xFF98989F) : _kSub;
Color _lineOf(BuildContext c) => c.v2IsDark ? const Color(0xFF2C2C2E) : _kLine;
Color _hintOf(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF98989F) : _kSearchHint;
Color _fillOf(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF2C2C2E) : _kSearchFill;
Color _sectionOf(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF98989F) : _kSectionLetter;
Color _indexOf(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF98989F) : _kIndexLetter;

/// 通讯录：好友列表 + 搜索添加 + 收到的申请
class ContactsPage extends StatefulWidget {
  const ContactsPage({super.key});

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  final _svc = FriendService();
  final _api = ApiClient.instance;
  final _searchCtrl = TextEditingController();
  List<Map<String, dynamic>> _friends = [];
  List<Map<String, dynamic>> _filteredFriends = [];
  List<FriendRequest> _requests = [];
  String _assistantAvatar = ''; // 后台配置的小助手头像（通讯录官方入口显示）
  bool _loading = true;
  bool _loadFailed = false; // 好友列表加载失败（无缓存数据时显示"重新加载"，不再误显"暂无好友"）
  bool _searching = false;
  final String _msg = '';
  String _myId = '';
  VoidCallback? _wsCancel;

  // 头像色板统一走主题，保证与其它页面一致
  static const _colors = AppTheme.avatarColors;

  // ===== 拼音分组 / 索引条 =====
  final ScrollController _listCtrl = ScrollController();

  /// 首字母缓存：排序、分组、索引条会反复问同一个昵称，
  /// 中文还要先做繁→简转换，缓存掉（纯函数结果，无需清理）。
  final Map<String, String> _initialCache = {};

  /// 排序键缓存（同上，避免排序比较器里反复算全拼）。
  final Map<String, String> _sortKeyCache = {};

  /// 每个分组头的 GlobalKey（按字母存取，值稳定跨 build）。
  final Map<String, GlobalKey> _groupKeys = {};

  /// 分组头在「好友段」内的模型偏移（逻辑 px，未乘 s），build 时刷新。
  Map<String, double> _groupOffsets = {};

  /// 列表可视区（= ScrollView 视口）的 RenderBox，用于点击跳转时换算坐标。
  final GlobalKey _viewportKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _loadCached();
    _load();
    _loadMyId();
    _loadAssistantAvatar();
    // 功能开关（2026-09-22 需求2）：小助手关闭时隐藏通讯录官方入口
    unawaited(FeatureFlags.instance.load());
    // 需求6：被添加好友 → WS friend 事件 → 刷新申请列表（红点）
    _wsCancel = GlobalWs.instance.onFriend((_) {
      _load();
    });
    GlobalWs.instance.ensureConnected();
  }

  /// 先渲染本地缓存的好友/申请/助手头像，网络回来后覆盖刷新。
  /// 解决切到通讯录时整页菊花等待的问题。
  Future<void> _loadCached() async {
    try {
      final raw = await _api.readPref('contacts');
      if (raw != null && raw.isNotEmpty && mounted && _friends.isEmpty) {
        final data = jsonDecode(raw);
        if (data is Map) {
          setState(() {
            _friends =
                ((data['friends'] as List?) ?? []).whereType<Map>().map((e) {
              final m = <String, dynamic>{};
              e.forEach((k, v) => m[k.toString()] = v);
              return m;
            }).toList();
            _requests = ((data['requests'] as List?) ?? [])
                .whereType<Map>()
                .map(
                    (e) => FriendRequest.fromJson(Map<String, dynamic>.from(e)))
                .toList();
            _assistantAvatar = data['assistantAvatar']?.toString() ?? '';
            if (_friends.isNotEmpty || _requests.isNotEmpty) _loading = false;
          });
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _wsCancel?.call();
    _listCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadMyId() async {
    // 进程内缓存命中直接用（一次登录会话只拉一次 /user/profile）
    final cached = UserCache.myId;
    if (cached != null && cached.isNotEmpty) {
      if (mounted) setState(() => _myId = cached);
      return;
    }
    try {
      final r = await _api.get('/api/v1/user/profile');
      final d = (r.data['data'] as Map<String, dynamic>?);
      UserCache.setMyProfile(d ?? {});
      final id = d?['id']?.toString() ?? '';
      if (mounted && id.isNotEmpty) setState(() => _myId = id);
    } catch (_) {}
  }

  /// 小助手头像：后台「智能小助手」配置（/auth/config 下发 assistantAvatar）
  Future<void> _loadAssistantAvatar() async {
    try {
      final r = await _api.get('/api/v1/auth/config');
      final data = (r.data as Map<String, dynamic>)['data'];
      final av =
          (data is Map ? data['assistantAvatar'] : null)?.toString() ?? '';
      if (mounted) setState(() => _assistantAvatar = av);
      await _api.writePref('assistantAvatar', av);
    } catch (_) {}
  }

  Future<void> _load() async {
    List<Map<String, dynamic>>? friends;
    try {
      friends = await _svc.list();
    } catch (_) {
      // 好友列表失败：有数据（缓存/上次结果）则保留并提示；首进无数据显示重试态
      if (mounted) {
        setState(() => _loading = false);
        if (_friends.isEmpty && _requests.isEmpty) {
          setState(() => _loadFailed = true);
        } else {
          AppDialogs.toast(
              context, AppLocalizations.of(context).t('contactsRefreshFailed'));
        }
      }
      return;
    }
    var requests = <FriendRequest>[];
    var reqFailed = false;
    try {
      requests = await _svc.incoming();
    } catch (_) {
      reqFailed = true; // 申请列表失败不拖累好友展示
    }
    if (mounted) {
      setState(() {
        _friends = friends ?? [];
        if (!reqFailed) _requests = requests;
        _loading = false;
        _loadFailed = false;
      });
      // 好友/申请/助手头像一并落缓存，下次进页首帧直出
      unawaited(_api.writePref(
          'contacts',
          jsonEncode({
            'friends': friends,
            'requests': (reqFailed ? _requests : requests)
                .map((r) => {
                      'id': r.id,
                      'fromUser': r.fromUser,
                      'message': r.message,
                      'status': r.status,
                    })
                .toList(),
            'assistantAvatar': _assistantAvatar,
          })));
    }
  }

  /// 失败态手动重试
  void _retryLoad() {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    _load();
  }

  /// 本地过滤通讯录好友（按昵称 / 账号 / 手机号）
  void _filter(String kw) {
    final q = kw.trim().toLowerCase();
    setState(() {
      _searching = q.isNotEmpty;
      if (q.isEmpty) {
        _filteredFriends = [];
        return;
      }
      _filteredFriends = _friends.where((f) {
        final name = _friendName(f).toLowerCase();
        final account = (f['account']?.toString() ?? '').toLowerCase();
        final phone = (f['phone']?.toString() ?? '').toLowerCase();
        final sid = (f['shortId']?.toString() ?? '').toLowerCase();
        return name.contains(q) ||
            account.contains(q) ||
            phone.contains(q) ||
            sid.contains(q);
      }).toList();
    });
  }

  Future<void> _handleReq(String reqId, bool agree) async {
    await _svc.handle(reqId, agree);
    await _load();
    // 审批后主动刷新全局申请数：被申请方收不到 friend.accepted WS 事件，
    // 不主动刷则底部"通讯录"tab 红点要等杀进程重进才消失
    FriendReqStore.instance.refresh();
  }

  Color _color(String id) => _colors[id.hashCode.abs() % _colors.length];

  String _friendName(Map<String, dynamic> u) {
    final r = u['remark']?.toString() ?? '';
    if (r.isNotEmpty) return r;
    return u['nickname']?.toString() ??
        u['account']?.toString() ??
        AppLocalizations.of(context).t('contactsUser');
  }

  void _goAddFriend() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const AddFriendPage()));
  }

  /// 需求10：打开小助手会话（小助手虚拟 uid=-1，后端固定名"小助手"）
  Future<void> _openAssistant() async {
    try {
      final convSvc = ConversationService();
      // 先找会话列表里已存在的小助手会话
      final list = await convSvc.list();
      final assistant = list.where((c) => c.conversationName == '小助手').toList();
      if (assistant.isNotEmpty) {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ChatPage(conv: assistant.first, myId: _myId)));
        return;
      }
      // 没有则创建单聊（-1 = 小助手）
      final conv = await convSvc.createDirect('-1');
      final item = ConvItem.fromJson({
        'conversation': conv,
        'conversationName': '小助手',
      });
      await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ChatPage(conv: item, myId: _myId)));
    } catch (_) {
      if (mounted)
        AppDialogs.toast(context,
            AppLocalizations.of(context).t('contactsAssistantUnavailable'));
    }
  }

  /// **拼音**首字母：中文取拼音首字母（「产品顾问」→`C`、「活动助手」→`H`），
  /// 拉丁字母原样透传（lpinyin 会把非中文原样返回），其余（数字/emoji/生僻字）归 `#`。
  ///
  /// 截图右侧索引条是 C/H/J/V/Y，正是「产品顾问/活动助手/技术支持」的拼音首字母，
  /// 所以这里必须走拼音、不能只认拉丁字符。
  /// 被 `_sortKey`（排序）、`_grouped`（分组）、`_indexBar`（索引条）多处调用 → 结果记忆化。
  String _initialLetter(String name) {
    return _initialCache.putIfAbsent(name, () {
      final n = name.trim();
      if (n.isEmpty) return '#';
      try {
        final short = PinyinHelper.getShortPinyin(n);
        if (short.isNotEmpty) {
          final c = short[0].toUpperCase();
          final code = c.codeUnitAt(0);
          if (code >= 65 && code <= 90) return c;
        }
      } catch (_) {
        // lpinyin 对词典外的字会抛 PinyinException —— 归 '#' 组，别让分组逻辑炸
      }
      return '#';
    });
  }

  /// 排序键：首字母（`#` 组排到最后）→ 全拼小写 → 原名兜底。
  String _sortKey(String name) {
    return _sortKeyCache.putIfAbsent(name, () {
      final n = name.trim();
      // '~' 排在所有大写字母之后 ⇒ '#' 组垫底（与微信一致）
      final letter = _initialLetter(name);
      final head = letter == '#' ? '~' : letter;
      var full = '';
      try {
        full = PinyinHelper.getPinyinE(n).toLowerCase();
      } catch (_) {
        // 同上：单字查不到就算了，退化成按原名排
      }
      return '$head|$full|$n';
    });
  }

  /// 渲染用的好友列表（按拼音首字母 + 全拼排序的**副本**）。
  /// 不改 `_friends` 里服务端给的原始顺序语义；**好友与搜索结果两条路径都要过这里**，
  /// 否则分组会乱序/重复（C→J→C）。
  List<Map<String, dynamic>> _sorted(List<Map<String, dynamic>> src) {
    final out = List<Map<String, dynamic>>.of(src);
    out.sort(
        (a, b) => _sortKey(_friendName(a)).compareTo(_sortKey(_friendName(b))));
    return out;
  }

  /// 按首字母分组（保持传入顺序 ⇒ 已排序的输入得到升序的组）。
  List<MapEntry<String, List<Map<String, dynamic>>>> _grouped(
      List<Map<String, dynamic>> sorted) {
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final f in sorted) {
      groups.putIfAbsent(_initialLetter(_friendName(f)), () => []).add(f);
    }
    return groups.entries.toList();
  }

  // ============================================================
  // ===== V2 视觉层（以下全部按 measure_contacts.md 的逻辑 px 落位）=====
  // ============================================================

  /// 页头：大标题 28/w700/#000（ink 左缘 21.7）+ 右上「添加联系人」24×24 线稿图标（右边距 26.0）。
  /// 整行与页面同灰底，不占独立白底。
  Widget _header(BuildContext context, double s) {
    return Padding(
      padding: EdgeInsets.only(left: 20.7 * s, right: 26.0 * s, top: 14 * s),
      child: Row(
        children: [
          Text(
            AppLocalizations.of(context).t('contactsTitle'),
            style: TextStyle(
              fontSize: 28 * s,
              fontWeight: FontWeight.w700,
              height: 1.0,
              color: _titleOf(context),
            ),
          ),
          const Spacer(),
          InkWell(
            onTap: _goAddFriend,
            borderRadius: BorderRadius.circular(12 * s),
            child: SizedBox(
              width: 24 * s,
              height: 24 * s,
              child: Icon(Icons.person_add_alt_1,
                  size: 24 * s, color: _inkOf(context)),
            ),
          ),
        ],
      ),
    );
  }

  /// 搜索框：x 20.7 / w 378.7 / h **44（2026-09-15 紧凑：56→44，与消息列表观感对齐）**/
  /// r 22.7（h/2 附近仍呈胶囊）/ 填充 #F7F7F7，**内容左对齐**
  /// （放大镜起 x48.3 → 容器内左内边距 27.7；放大镜 17、间距 16.4；占位 18/w400/#8F8E93）。
  Widget _searchBar(BuildContext context, double s) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 20.7 * s),
      child: Container(
        height: 44 * s,
        padding: EdgeInsets.only(left: 27.7 * s, right: 12 * s),
        decoration: BoxDecoration(
          color: _fillOf(context),
          borderRadius: BorderRadius.circular(22.7 * s),
        ),
        child: Row(
          children: [
            Icon(Icons.search, size: 17 * s, color: _hintOf(context)),
            SizedBox(width: 16.4 * s),
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                onChanged: _filter,
                textAlignVertical: TextAlignVertical.center,
                style: TextStyle(
                  fontSize: 18 * s,
                  height: 1.0,
                  color: _nameOf(context),
                ),
                decoration: InputDecoration.collapsed(
                  hintText:
                      AppLocalizations.of(context).t('contactsSearchHint'),
                  hintStyle: TextStyle(
                    fontSize: 18 * s,
                    fontWeight: FontWeight.w400,
                    height: 1.0,
                    color: _hintOf(context),
                  ),
                ),
              ),
            ),
            // 实时过滤：有输入时给一个清除按钮（保留原有的清除能力）
            if (_searching)
              InkWell(
                onTap: () => setState(() {
                  _searchCtrl.clear();
                  _searching = false;
                  _filteredFriends = [];
                }),
                borderRadius: BorderRadius.circular(10 * s),
                child: Padding(
                  padding: EdgeInsets.all(4 * s),
                  child:
                      Icon(Icons.close, size: 16 * s, color: _hintOf(context)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 三个功能行：满宽白卡（x0 / w420 / 行高 70.0），行间分隔线左缩进 72.0、卡片底边线满宽。
  Widget _funcCard(BuildContext context, double s) {
    final t = AppLocalizations.of(context).t;
    return Container(
      decoration: BoxDecoration(
        color: _cardOf(context),
        border:
            Border(bottom: BorderSide(color: _lineOf(context), width: 0.7 * s)),
      ),
      child: Column(
        children: [
          // 需求8：新朋友 → 申请记录列表（通过/拒绝）
          _funcRow(context, s, Icons.person_add_alt_1, t('contactsNewFriends'),
              count: _requests.length, onTap: () async {
            await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NewFriendsPage()));
            if (mounted) _load();
            // 从新朋友页返回后同步底部 tab 红点
            FriendReqStore.instance.refresh();
          }),
          _insetLine(context, s, 72.0),
          // 需求9：群聊 → 我的群聊列表
          _funcRow(context, s, Icons.group_outlined, t('contactsGroupChats'),
              onTap: () {
            Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => MyGroupsPage(myId: _myId)));
          }),
          // 需求1（2026-09-22 二批）：分隔线随频道入口一起受开关控制
          // 第十三批 #3c：频道 → 我的频道列表（样式同「群聊」入口行；
          // 图标用 podcasts（广播塔），避免与下方小助手的 campaign 重复）
          // 需求1（2026-09-22 二批）：后台关闭「开启频道」→ 通讯录不显示频道入口
          ValueListenableBuilder<bool>(
            valueListenable: FeatureFlags.instance.channelOn,
            builder: (context, on, _) => on
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _insetLine(context, s, 72.0),
                      _funcRow(context, s, Icons.podcasts,
                          t('contactsChannels'), onTap: () {
                        Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => MyChannelsPage(myId: _myId)));
                      }),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
          // 需求2（2026-09-22）：小助手功能开关关闭 → 通讯录不显示官方入口
          // （注册自动添加由服务端 assistant_enabled 短路）
          ValueListenableBuilder<bool>(
            valueListenable: FeatureFlags.instance.assistantOn,
            builder: (context, on, _) => on
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _insetLine(context, s, 72.0),
                      // 需求10：系统公告 → 小助手（带官方标识 + 后台配置头像）
                      _funcRow(context, s, Icons.campaign_outlined,
                          t('contactsAssistant'),
                          official: true,
                          avatarUrl: _assistantAvatar,
                          onTap: _openAssistant),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  /// 功能行：图标 24×24（ink 左缘 24.3）、文字 20/w500（ink 左缘 71.3）、行高 70.0。
  /// 右侧**不放 chevron**（截图里没有）。
  Widget _funcRow(
    BuildContext context,
    double s,
    IconData icon,
    String title, {
    required VoidCallback onTap,
    int count = 0,
    bool official = false,
    String avatarUrl = '',
  }) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 70.0 * s,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 24.3 * s),
          child: Row(
            children: [
              SizedBox(
                width: 24 * s,
                height: 24 * s,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Center(
                        child:
                            Icon(icon, size: 24 * s, color: _inkOf(context))),
                    // 小助手：显示后台配置的头像；加载中 / 失败都回落线稿图标（不空白）
                    if (avatarUrl.isNotEmpty)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6 * s),
                        child: Image.network(
                          avatarUrl,
                          fit: BoxFit.cover,
                          frameBuilder: (ctx, child, frame, wasSync) =>
                              (wasSync || frame != null)
                                  ? child
                                  : const SizedBox.shrink(),
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(width: 23.0 * s),
              Text(title,
                  style: TextStyle(
                      fontSize: 20 * s,
                      fontWeight: FontWeight.w500,
                      height: 1.0,
                      color: _inkOf(context))),
              if (official) ...[
                SizedBox(width: 6 * s),
                const OfficialTag(),
              ],
              const Spacer(),
              // 未处理的申请数（保留原有红点信息，靠右放，不干扰左侧 24.3/71.3 的实测落位）
              // 2026-11-07 修复：原来只有 minWidth/minHeight，又用了 alignment:center，
              // Container 内部的 Align 会把高度撑满 Row 的可用高度（本行 70*s），
              // 结果 18 宽 × 70 高 → 红点被纵向拉长成"竖条"，看起来扭曲。
              // 现在把高度钉死为 18*s、宽度最小 18*s（个位数正好是正圆），
              // 两位以上自动变胶囊、圆角恒为高度的一半 9*s，不会再被拉伸变形。
              if (count > 0)
                Container(
                  // 高度必须钉死：只给 minHeight 时，Container 内部的 Align 会去
                  // 撑满 Row 的可用高度（本行 70*s），红点就被纵向拉长成竖条。
                  height: 18 * s,
                  constraints: BoxConstraints(minWidth: 18 * s),
                  padding: EdgeInsets.symmetric(horizontal: 5 * s),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF4539),
                    // 圆角恒为高度的一半：个位数 = 正圆，两三位数 = 左右半圆的胶囊
                    borderRadius: BorderRadius.circular(9 * s),
                  ),
                  child: Center(
                    widthFactor: 1,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(count > 99 ? '99+' : '$count',
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                              fontSize: 12 * s,
                              fontWeight: FontWeight.w600,
                              height: 1.0,
                              color: Colors.white)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 分隔线：厚 0.7、色 #E5E5E5、**左缩进 [indent]**、右侧通到屏幕右边缘。
  Widget _insetLine(BuildContext context, double s, double indent) {
    return Padding(
      padding: EdgeInsets.only(left: indent * s),
      child: Container(height: 0.7 * s, color: _lineOf(context)),
    );
  }

  /// 联系人行：满宽出血（x0 / w420 / h 86.7）。
  /// 头像圆角方形 r11 / 56×56（左 20.7、行内 +15.3）；
  /// 名字 20/w500/#121826（左 95.7、行内 +19.0）；副标题 18/w400/#6C737D（左 96.0、行内 +50.7）。
  Widget _friendTile(Map<String, dynamic> f) {
    final s = v2Scale(context);
    final id = f['id']?.toString() ?? '';
    final name = _friendName(f);
    // 宽屏双栏：右栏正在显示该好友的资料页 → 行高亮（微信桌面版同款选中态）。
    // 用不透明 Color.lerp 混色（半透明色会透出底下内容，与消息列表卡片同一坑）。
    final selected = Breakpoints.isWide(context) &&
        WideLayoutStore.instance.currentKey == 'friend:$id';
    // 蓝色认证盾：沿用行内已有的 vipShortId 数据（无该字段则不画）
    final vip = f['vipShortId'] == true;
    return InkWell(
      onTap: () async {
        // 需求：通讯录点开好友 = V2 好友资料页（与聊天窗口右上角进的是同一套外观）
        try {
          final convSvc = ConversationService();
          final conv = await convSvc.createDirect(id);
          // createDirect 返回的会话对象不带对方头像，资料页头图会空成首字母
          // （聊天窗口路径会话列表自带 avatar 所以正常）→ 用通讯录行的好友头像兜底
          final av = f['avatar']?.toString() ?? '';
          if (av.isNotEmpty &&
              (conv['avatar'] == null || conv['avatar'].toString().isEmpty)) {
            conv['peerAvatar'] = av;
          }
          // /friend/list 新契约（2026-09-15 be-privacy）：role=账号角色（3=客服，
          // V 盾判定用）、lastLoginAt=最近登录。createDirect 返回的会话对象不带
          // 这两个字段 → 从好友行注入，供 FriendDetailPage.fromConv /
          // conv_settings 头部（peerRole 口径）读取。
          conv['peerRole'] = f['role'];
          conv['lastLoginAt'] = f['lastLoginAt'];
          // 共同群组数（/friend/list 契约，跟 groupVisible 门控：nobody 键不
          // 下发 → 透传 null，资料页整卡不渲染；频道 type=3 不计入）
          conv['commonGroupCount'] = f['commonGroupCount'];
          final online = f['online'] == true;
          final item = ConvItem.fromJson({
            'conversation': conv,
            'conversationName': name,
            'peerId': id,
            'peerShortId': f['shortId']?.toString() ?? '',
            'peerVipShortId': f['vipShortId'] == true,
            'peerRemark': f['remark']?.toString() ?? '',
            'peerOnline': online,
            'peerOnlineDev': f['onlineDevice'] ?? [],
          });
          if (!mounted) return;
          // 宽屏（折叠屏展开/平板）：好友资料在右栏打开，左侧通讯录不动；窄屏 push 整页
          await WideLayoutStore.instance.openDetail(
              context, FriendDetailPage.fromConv(conv: item, myId: _myId),
              paneKey: 'friend:$id');
          if (mounted) _load();
        } catch (_) {
          if (mounted)
            AppDialogs.toast(context,
                AppLocalizations.of(context).t('contactsOpenProfileFailed'));
        }
      },
      child: Container(
        height: 86.7 * s,
        color: selected
            ? Color.lerp(_cardOf(context), AppTheme.primary, 0.10)!
            : _cardOf(context),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(left: 20.7 * s, top: 15.3 * s),
              // Hero 源端：点进好友资料页时头像缩放定位飞行（2026-09-20 动效规范 2）
              child: Hero(
                tag: 'hero-contact-avatar-$id',
                child: _avatarOf(name, id,
                    size: 56 * s, radius: 11 * s, url: f['avatar']?.toString()),
              ),
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(left: 19.0 * s, top: 16.5 * s),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 20 * s,
                                  fontWeight: FontWeight.w500,
                                  height: 1.0,
                                  color: _nameOf(context))),
                        ),
                        // 客服标识：V2SealBadge 与好友资料页统一（二十六批需求）
                        // role 来自 /friend/list（3=客服，判定复用 CertBadge.isKefu）
                        if (CertBadge.isKefu(f['role'])) ...[
                          SizedBox(width: 7 * s),
                          const V2SealBadge(size: 17, color: Color(0xFF4FA4EE)),
                        ],
                        if (vip) ...[
                          SizedBox(width: 8.0 * s),
                          // 靓号皇冠徽（2026-09-15 第十四批：勾保留给客服 CertBadge，
                          // 靓号改金色皇冠）。共享组件，24 图标盒
                          const VipCrownBadge(),
                        ],
                      ],
                    ),
                    SizedBox(height: 12 * s),
                    Padding(
                      // 副标题 ink 左缘 96.0（名字 95.7 + 0.3）
                      padding: EdgeInsets.only(left: 0.3 * s),
                      child: Text(f['account']?.toString() ?? 'ID $id',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 18 * s,
                              fontWeight: FontWeight.w400,
                              height: 1.0,
                              color: _subOf(context))),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 一个分组：分组头（挂 GlobalKey，供索引条跳转定位）+ 组内行。
  /// 组内多人才画左缩进 95.7 的分隔线；跨组不画 —— 靠分组头灰带分隔（与截图一致）。
  List<Widget> _groupWidgets(BuildContext context, double s, String letter,
      List<Map<String, dynamic>> rows) {
    final out = <Widget>[
      KeyedSubtree(
        key: _groupKeys.putIfAbsent(letter, () => GlobalKey()),
        child: _SectionLabel(letter),
      ),
    ];
    for (var i = 0; i < rows.length; i++) {
      out.add(_friendTile(rows[i]));
      if (i != rows.length - 1) out.add(_insetLine(context, s, 95.7));
    }
    return out;
  }

  /// 索引条点击 → 该字母的分组头滚到视口顶部（200ms）。
  ///
  /// 两条路径：
  /// 1) 目标分组头**已渲染**（懒加载已构建）→ `Scrollable.ensureVisible`，最精确；
  /// 2) 目标在屏幕外**未构建** → 拿任一已渲染的分组头当锚点换算：
  ///    分组头 / 行 / 分隔线高度都是定值（38.7 / 86.7 / 0.7），
  ///    锚点与目标在「好友段」内的模型偏移差 Δ 可直接累加，
  ///    目标滚动量 = 当前 offset + 锚点在视口内的 y + Δ。
  ///    （不能只用 ensureVisible：ListView 懒构建，远端分组头没有 context。）
  void _jumpToLetter(String letter) {
    final targetCtx = _groupKeys[letter]?.currentContext;
    if (targetCtx != null) {
      Scrollable.ensureVisible(targetCtx,
          alignment: 0.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut);
      return;
    }
    if (!_listCtrl.hasClients) return;
    final targetModel = _groupOffsets[letter];
    if (targetModel == null) return;
    // 任取一个已渲染的分组头当锚点（用户在看列表时近处那个一定已构建）
    String? anchor;
    for (final l in _groupOffsets.keys) {
      if (_groupKeys[l]?.currentContext != null) {
        anchor = l;
        break;
      }
    }
    if (anchor == null) return;
    final anchorBox = _groupKeys[anchor]!.currentContext!.findRenderObject();
    final viewportBox = _viewportKey.currentContext?.findRenderObject();
    if (anchorBox is! RenderBox ||
        viewportBox is! RenderBox ||
        !anchorBox.attached) {
      return;
    }
    final anchorDy =
        anchorBox.localToGlobal(Offset.zero, ancestor: viewportBox).dy;
    final delta = targetModel - _groupOffsets[anchor]!;
    final next = (_listCtrl.offset + anchorDy + delta)
        .clamp(0.0, _listCtrl.position.maxScrollExtent);
    _listCtrl.animateTo(next,
        duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  /// 右侧字母索引条：x 404.0 / w 8.7 / 13 / w400 / #6F6F6F，**垂直等距 19.5**
  /// （与左侧分组头不对齐）、可视区垂直居中、**可点跳转**（不再是死元素）。
  Widget _indexBar(BuildContext context, double s,
      List<MapEntry<String, List<Map<String, dynamic>>>> groups) {
    if (groups.isEmpty) return const SizedBox.shrink();
    return Positioned(
      top: 0,
      bottom: 0,
      right: 7.3 * s,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 每格高 19.5（= 相邻字母 ink 间距）⇒ 字距不变、点击热区更大；
            // 居中排布后 ink 位置与「13 + 6.5 间隔」完全一致
            for (final g in groups)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _jumpToLetter(g.key),
                child: SizedBox(
                  width: 8.7 * s,
                  height: 19.5 * s,
                  child: Center(
                    child: Text(g.key,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 13 * s,
                            fontWeight: FontWeight.w400,
                            height: 1.0,
                            color: _indexOf(context))),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 56),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 56,
                color: context.cs.onSurfaceVariant.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text(text,
                style: TextStyle(
                    color: context.cs.onSurfaceVariant, fontSize: 14)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return Scaffold(
      backgroundColor: _bgOf(context),
      body: SafeArea(
        // 底部不避让：列表要能延伸到浮动 Tab 胶囊之下（与截图一致）
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(context, s),
            // 2026-09-15 紧凑：搜索框上方 21→14、下方 16→12
            SizedBox(height: 14 * s),
            _searchBar(context, s),
            SizedBox(height: 12 * s),
            Expanded(
              // 选中态跟随右栏：点好友/关右栏时高亮实时刷新
              child: ListenableBuilder(
                listenable: WideLayoutStore.instance,
                builder: (_, __) => _loading
                    ? const SkeletonList(style: SkeletonStyle.contacts)
                    : _loadFailed
                        ? _buildLoadFailed()
                        : _list(context, s),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 列表主体：功能白卡 → 申请区块 → 按拼音首字母分组的好友 / 搜索结果。
  /// 行一律**满宽出血**（左右零内边距），左右留白由各行自己的 padding 提供。
  Widget _list(BuildContext context, double s) {
    final t = AppLocalizations.of(context).t;
    // 底部留白 = 浮动胶囊（30 + 83.7）+ 安全区，保证最后一行能滚出胶囊遮挡
    final bottomPad = 120 * s + MediaQuery.viewPaddingOf(context).bottom;

    // 好友与搜索结果**两条路径都过 _sorted**（否则分组会乱序/重复：C→J→C）
    final groups = _grouped(_sorted(_searching ? _filteredFriends : _friends));

    // 索引条点击跳转用的模型偏移表（单位 = 布局 px，已乘 s；
    // 分组头 38.7 / 行 86.7 / 组内分隔线 0.7 —— 与实际渲染高度一一对应）
    final offsets = <String, double>{};
    final groupWidgets = <Widget>[];
    var acc = 0.0;
    for (final g in groups) {
      offsets[g.key] = acc;
      acc += _kSectionH * s;
      acc += g.value.length * _kRowH * s;
      acc += (g.value.length - 1) * _kRowLineH * s;
      groupWidgets.addAll(_groupWidgets(context, s, g.key, g.value));
    }
    _groupOffsets = offsets;

    return Stack(
      // 视口参照物：索引条跳转时用它换算「锚点分组头在视口内的 y」
      key: _viewportKey,
      children: [
        ListView(
          controller: _listCtrl,
          padding: EdgeInsets.only(bottom: bottomPad),
          children: [
            _funcCard(context, s),
            if (_msg.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_msg,
                    style:
                        const TextStyle(fontSize: 12, color: AppTheme.success)),
              ),
            if (!_searching && _requests.isNotEmpty) ...[
              _SectionLabel(t(
                  'contactsFriendRequests', {'count': '${_requests.length}'})),
              ..._requests.map((r) => _requestTile(r)),
            ],
            // 搜索结果仍保留带条数的标题带（好友列表则完全由拼音分组头分段）
            if (_searching)
              _SectionLabel(t('contactsSearchResults',
                  {'count': '${_filteredFriends.length}'})),
            if (groups.isEmpty)
              _emptyState(_searching ? Icons.search_off : Icons.group_outlined,
                  _searching ? t('contactsNoMatch') : t('contactsEmptyFriends'))
            else
              ...groupWidgets,
          ],
        ),
        _indexBar(context, s, groups),
      ],
    );
  }

  /// 好友列表加载失败：显示"重新加载"，不再误显"暂无好友"
  Widget _buildLoadFailed() {
    final t = AppLocalizations.of(context).t;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined,
              size: 48, color: context.cs.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(t('contactsLoadFailed'),
              style:
                  TextStyle(fontSize: 14, color: context.cs.onSurfaceVariant)),
          const SizedBox(height: 14),
          TextButton(
            onPressed: _retryLoad,
            child: Text(t('contactsRetry'),
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primary)),
          ),
        ],
      ),
    );
  }

  Widget _requestTile(FriendRequest r) {
    final t = AppLocalizations.of(context).t;
    // 优先用后端注入的申请人昵称/账号，兜底到 ID（避免只显示一串数字）
    final name = r.fromUserName.isNotEmpty
        ? r.fromUserName
        : (r.fromUserAccount.isNotEmpty
            ? r.fromUserAccount
            : t('contactsUserWithId', {'id': r.fromUser}));
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 4, 0, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: context.cs.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _avatarOf(name, r.fromUser, size: 42, url: r.fromUserAvatar),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: context.cs.onSurface)),
                if (r.message.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(r.message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: context.cs.onSurfaceVariant)),
                  ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => _handleReq(r.id, true),
            style: TextButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
            ),
            child:
                Text(t('contactsAgree'), style: const TextStyle(fontSize: 13)),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => _handleReq(r.id, false),
            style: TextButton.styleFrom(
              backgroundColor: context.cs.surfaceContainer,
              foregroundColor: context.cs.onSurfaceVariant,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
            ),
            child:
                Text(t('contactsReject'), style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  /// 统一头像：加载中 / 失败 / 无 URL 都走 AppAvatar 的「彩色底 + 首字」占位
  Widget _avatarOf(String name, String seed,
      {double size = 44, double? radius, String? url}) {
    return AppAvatar(
      url: url ?? '',
      name: name,
      size: size,
      radius: radius,
      background: _color(seed),
      emptyText: AppLocalizations.of(context).t('contactsUser'),
    );
  }
}

/// 分组头：高 **32（2026-09-15 紧凑：38.7→32）**、**无独立底色**（与页面同 #F5F5F5，
/// 视觉对比来自与白卡相邻）、字母 #7E7E7E / 17 / w400、左边距 21.3。
class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return Container(
      height: 32 * s,
      alignment: Alignment.centerLeft,
      padding: EdgeInsets.only(left: 21.3 * s),
      child: Text(text,
          style: TextStyle(
              fontSize: 17 * s,
              fontWeight: FontWeight.w400,
              height: 1.0,
              color: _sectionOf(context))),
    );
  }
}
