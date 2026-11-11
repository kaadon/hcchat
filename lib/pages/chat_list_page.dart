import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/api_client.dart';
import '../services/conv_gap_sync.dart';
import '../services/feature_flags.dart';
import '../services/wide_layout_store.dart';
import '../utils/breakpoints.dart';
import '../services/call_service.dart';
import '../services/conversation_service.dart';
import '../services/local_notify_service.dart';
import '../services/local_store.dart';
import '../services/msg_height_cache.dart';
import '../services/sound_service.dart';
import '../services/unread_store.dart';
import '../services/user_cache.dart';
import '../services/ws_service.dart';
import '../l10n/app_locale.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/app_slidable.dart';
import '../widgets/brand_loading.dart';
import '../widgets/official_tag.dart';
import '../widgets/v2_kit.dart';
import '../widgets/v2_tags.dart';
import '../widgets/v2_seal_badge.dart';
import 'add_friend_page.dart';
import 'chat_page.dart';
import 'create_channel_sheet.dart';
import 'new_conversation_page.dart';
import 'scan_qr_login_page.dart';
import 'search_page.dart';

/// 会话列表页（V2 像素级复刻 2026-09-14；参考截图 1260×2777 / DPR3 ⇒ 逻辑宽 420）
///
/// 页头 = **居中**「聊天」标题 + 右侧 ⊕ 胶囊（左「编辑」胶囊已按需求删除 2026-09-15）
/// → 内容**水平居中**的浅灰搜索框 → 蓝色公告横幅（后台有配置时才显示）
/// → 满宽会话行（分行靠左缩进 60 的分隔线，不是卡片留白）
/// → 浮空白胶囊 Tab 栏（在 `home_shell` 里用 Stack 叠放，本页只负责底部留白）
class ChatListPage extends StatefulWidget {
  const ChatListPage({super.key});

  @override
  State<ChatListPage> createState() => ChatListPageState();
}

class ChatListPageState extends State<ChatListPage> {
  final _svc = ConversationService();
  final _api = ApiClient.instance;
  List<ConvItem> _convs = [];
  List<dynamic> _convRaw = [];
  bool _loading = true;
  bool _loadFailed = false;
  String _myId = '';
  String _announcementText = '';
  String _dismissedAnnouncement = '';
  VoidCallback? _wsCancel;
  VoidCallback? _wsRecallCancel; // onRecall 取消句柄（之前漏存导致页面重建后重复 _load，审查 #4）
  Timer? _convSyncTimer;
  String _openConvId = '';
  void Function(String key)? _corruptSub;
  VoidCallback? _wsReconnectedOff;

  /// ========== 搜索模式（十七批：Telegram 式收纳）==========
  /// 常驻搜索框已删（其原为 SearchPage 入口）；「+」旁搜索按钮进入搜索模式：
  /// 输入框（自动聚焦）本地过滤会话名；键盘「搜索」键跳 SearchPage 全局消息
  /// 搜索（原入口能力保留，带词预填）；「取消」/系统返回键退出搜索模式。
  bool _searchMode = false;
  final TextEditingController _searchCtrl = TextEditingController();

  /// 当前应展示的会话：搜索模式且有关键词时按会话名本地过滤（大小写不敏感）
  List<ConvItem> get _visibleConvs {
    final kw = _searchCtrl.text.trim().toLowerCase();
    if (!_searchMode || kw.isEmpty) return _convs;
    return _convs
        .where((c) => c.conversationName.toLowerCase().contains(kw))
        .toList();
  }

  void _enterSearchMode() {
    setState(() => _searchMode = true);
  }

  void _exitSearchMode() {
    FocusScope.of(context).unfocus();
    setState(() {
      _searchMode = false;
      _searchCtrl.clear();
    });
  }

  /// 键盘「搜索」键：跳全局消息搜索（原常驻搜索框的去向），带词预填自动搜
  void _pushGlobalSearch(String kw) {
    final word = kw.trim();
    FocusScope.of(context).unfocus();
    if (word.isEmpty) return;
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SearchPage(initialKeyword: word)));
  }

  /// 非当前会话的补拉器（修 R-20）；用全局单例，与 GlobalWs 的常驻补拉共享状态
  final ConvGapSync _gapSync = ConvGapSync.instance;

  /// ========== 侧滑菜单显式关闭 ==========
  /// 每个会话一个 GlobalKey：侧滑状态跟随会话身份移动（列表重排不会错配到别的行），
  /// 置顶/免打扰等操作完成后经 currentState?.close() 显式收起菜单。
  final Map<String, GlobalKey<AppSlidableState>> _slideKeys = {};

  @override
  void initState() {
    super.initState();
    _loadCached();
    _load();
    // 功能开关（2026-09-22 需求2）：频道关闭时隐藏「新建频道」入口
    unawaited(FeatureFlags.instance.load());
    _corruptSub = (key) {
      if (key == 'conv_list' && mounted) _load();
    };
    LocalStore.addCorruptListener(_corruptSub!);
    _loadMyId();
    _loadAnnouncement();
    _loadDismissedAnnouncement();
    _wsCancel = GlobalWs.instance.onMessage((m) {
      _applyIncomingMessage(m);
      final type = (m['type'] as num?)?.toInt();
      final senderId = m['senderId']?.toString() ?? '';
      if (type == 1 &&
          senderId.isNotEmpty &&
          senderId != _myId &&
          CallService.instance.state.value == null) {
        SoundService.instance.playNewMessage();
      }
      _maybeLocalNotify(m);
    });
    _wsRecallCancel = GlobalWs.instance.onRecall((_) => _load());
    // 【修 R-20】重连后给**非当前会话**补拉。
    // 以前只有 chat_page 注册 onReconnected，于是其它会话的消息全靠
    // 「进会话时拉 80 条历史」——离线较久时 >80 条的缺口就永久漏掉了。
    _wsReconnectedOff = GlobalWs.instance.onReconnected(() {
      _gapSync.syncAll(_convs, excludeConvId: _openConvId).then((n) {
        if (n > 0 && mounted) _load(); // 补到新消息 → 刷新列表预览与未读
      });
    });
    // P0：全局补拉 / 周期对账补到新消息后，刷新会话列表预览与未读红点
    // （用户停在列表页时，列表页之外的会话也能即时看到新消息提示）。
    ConvGapSync.instance.onAfterSync = () {
      if (mounted) _load();
    };
    GlobalWs.instance.ensureConnected();
  }

  /// 回前台（由 HomeShell 的生命周期回调转调）：
  /// 切后台期间 WS 可能已死、事件通道可能丢事件，这里补一次。
  void onAppResumed() {
    if (_convs.isEmpty) return;
    _gapSync.syncAll(_convs, excludeConvId: _openConvId).then((n) {
      if (n > 0 && mounted) _load();
    });
  }

  @override
  void dispose() {
    _wsCancel?.call();
    _wsRecallCancel?.call();
    _wsReconnectedOff?.call();
    ConvGapSync.instance.onAfterSync = null;
    _convSyncTimer?.cancel();
    if (_corruptSub != null) LocalStore.removeCorruptListener(_corruptSub!);
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAnnouncement() async {
    try {
      final cached = await _api.readPref('announcement');
      if (cached != null && cached.isNotEmpty && mounted) {
        setState(() => _announcementText = cached);
      }
    } catch (_) {}
    try {
      final r = await _api.get('/api/v1/auth/config');
      final data = (r.data as Map<String, dynamic>)['data'];
      final text = (data is Map && data['announcement'] != null)
          ? data['announcement'].toString()
          : '';
      if (mounted) setState(() => _announcementText = text);
      unawaited(_api.writePref('announcement', text));
    } catch (_) {}
  }

  Future<void> _loadDismissedAnnouncement() async {
    try {
      final v = await _api.readPref('dismissed_announcement') ?? '';
      if (mounted) setState(() => _dismissedAnnouncement = v);
    } catch (_) {}
  }

  Future<void> _loadMyId() async {
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

  Future<void> _loadCached() async {
    try {
      if (!mounted || _convs.isNotEmpty) return;
      var data = await LocalStore.loadConvList();
      if (data == null || data.isEmpty) {
        final raw = await _api.readPref('convList');
        if (raw == null || raw.isEmpty) return;
        if (!mounted) return;
        try {
          final decoded = jsonDecode(raw);
          data = decoded is List ? decoded : null;
        } catch (_) {
          data = null;
        }
      }
      if (data == null || data.isEmpty || !mounted) return;
      _applyRawList(data);
    } catch (_) {}
  }

  void _applyRawList(List<dynamic> data) {
    setState(() {
      _convRaw = List<dynamic>.from(data);
      _convs = _convRaw
          .whereType<Map>()
          .map((e) => ConvItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      _loading = false;
    });
  }

  // 2026-09-28 性能修复：合并并发 _load()。从聊天页返回时 .then、WS 回调、
  // 补拉回调可能在同一秒内各触发一次 _load()，每次都带 setState 全列表重建 +
  // jsonEncode 落盘 + 预热循环，与 pop 转场动画抢主线程 → 返回列表页卡顿。
  // 在飞标志 + 尾随补跑：飞行中的触发不再各自执行，只记一笔，结束后补跑一次。
  bool _loadInFlight = false;
  bool _loadQueued = false;

  Future<void> _load() async {
    if (_loadInFlight) {
      _loadQueued = true;
      return;
    }
    _loadInFlight = true;
    try {
      await _loadOnce();
    } finally {
      _loadInFlight = false;
      if (_loadQueued) {
        _loadQueued = false;
        if (mounted) unawaited(_load());
      }
    }
  }

  Future<void> _loadOnce() async {
    try {
      final list = await _svc.list();
      UnreadStore.instance
          .update(list.fold<int>(0, (sum, c) => sum + (c.mute ? 0 : c.unread)));
      if (mounted) {
        setState(() {
          _convs = list;
          _convRaw = List<dynamic>.from(_svc.lastConvRaw);
          // ✅ 移除了 _listRev++：不再强制重建所有行
          // 置顶/免打扰操作已改为局部更新，不需要全局 key 变化
          _loading = false;
        });
      }
      unawaited(LocalStore.saveConvList(_convRaw));
      // 会话历史预热：进聊天页免转圈。取列表前 10 个、内存还没有缓存的会话，
      // 顺序（不并发、间隔 100ms 防限流）后台预拉最近一页历史写进
      // ConversationService 的内存缓存，之后打开聊天页直接缓存直出，
      // 不再显示「正在载入消息」。全程后台静默，失败不影响任何 UI。
      unawaited(_preheatHistory(list));
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = _convs.isEmpty;
        });
      }
    }
  }

  /// 会话历史预热（后台顺序执行，不并发）：已有内存缓存的会话跳过，
  /// 最多预热 10 个；退出登录不清理也无碍，下次登录 hydrate 会覆盖。
  Future<void> _preheatHistory(List<ConvItem> list) async {
    var warmed = 0;
    for (final c in list) {
      if (warmed >= 10) return;
      if (ConversationService.historyCached(c.id) != null) continue;
      warmed++;
      await Future.delayed(const Duration(milliseconds: 100));
      try {
        await _svc.history(c.id);
      } catch (_) {
        // 预热失败静默：进聊天页时走正常首拉兜底
      }
    }
  }

  /// P0-3：WS 新消息增量更新会话列表。
  void _applyIncomingMessage(Map<String, dynamic> m) {
    if (!mounted || _convs.isEmpty || _convRaw.isEmpty) {
      _load();
      return;
    }
    final convId = m['conversationId']?.toString() ?? '';
    if (convId.isEmpty) {
      _load();
      return;
    }
    if (convId == _openConvId) return;
    final type = (m['type'] as num?)?.toInt() ?? 1;
    if (type == 6 || type == 7) {
      _load();
      return;
    }
    final idx = _convs.indexWhere((c) => c.id == convId);
    if (idx < 0 || idx >= _convRaw.length) {
      _load();
      return;
    }
    final raw = Map<String, dynamic>.from(_convRaw[idx] as Map);
    final senderId = m['senderId']?.toString() ?? '';
    final mine = senderId.isNotEmpty && senderId == _myId;
    raw['lastMessage'] = m;
    if (!mine) {
      final old = (raw['unread'] as num?)?.toInt() ?? 0;
      raw['unread'] = old + 1;
    }
    final item = ConvItem.fromJson(raw);

    final list = List<ConvItem>.from(_convs);
    final raws = List<dynamic>.from(_convRaw);
    list.removeAt(idx);
    raws.removeAt(idx);
    var target = 0;
    if (!item.pinned) {
      while (target < list.length && list[target].pinned) {
        target++;
      }
    }
    list.insert(target, item);
    raws.insert(target, raw);

    setState(() {
      _convs = list;
      _convRaw = raws;
    });
    UnreadStore.instance
        .update(list.fold<int>(0, (sum, c) => sum + (c.mute ? 0 : c.unread)));
    _convSyncTimer?.cancel();
    _convSyncTimer = Timer(const Duration(seconds: 10), () {
      if (mounted) _load();
    });
  }

  void _maybeLocalNotify(Map<String, dynamic> m) {
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == AppLifecycleState.resumed) return;
    final type = (m['type'] as num?)?.toInt();
    final senderId = m['senderId']?.toString() ?? '';
    if (type != 1 || senderId.isEmpty || senderId == _myId) return;
    if (CallService.instance.state.value != null) return;
    final convId = m['conversationId']?.toString() ?? '';
    ConvItem? conv;
    for (final c in _convs) {
      if (c.id == convId) {
        conv = c;
        break;
      }
    }
    if (conv != null && conv.mute) return;
    final title = (conv?.conversationName ?? '').isNotEmpty
        ? conv!.conversationName
        : '新消息';
    final body = (conv?.lastMsgPreview ?? '').isNotEmpty
        ? conv!.lastMsgPreview
        : '你收到一条新消息';
    LocalNotifyService.instance.showMessage(title: title, body: body);
  }

  void _showPlusMenu() {
    final t = AppLocalizations.of(context).t;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      // 参考图实测遮罩 = Flutter 默认 black54（255×(1−0.541)=117 命中 #757575，
      // measure_channel.md §0）—— 旧值 0x80000000 会把白页压成 127，差一档
      barrierColor: Colors.black54,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(12, 18, 12, 18),
                decoration: BoxDecoration(
                  color: context.cs.surface,
                  borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _menuGridItem(
                      icon: Icons.person_add_alt_1,
                      color: AppTheme.primary,
                      title: t('chatListAddFriend'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        Navigator.of(context)
                            .push(MaterialPageRoute(
                                builder: (_) => const AddFriendPage()))
                            .then((_) => _load());
                      },
                    ),
                    _menuGridItem(
                      icon: Icons.group_add_outlined,
                      color: AppTheme.green,
                      title: t('chatListCreateGroup'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        Navigator.of(context)
                            .push(MaterialPageRoute(
                                builder: (_) =>
                                    NewConversationPage(myId: _myId)))
                            .then((_) => _load());
                      },
                    ),
                    _menuGridItem(
                      icon: Icons.qr_code_scanner,
                      color: AppTheme.orange,
                      title: t('chatListScan'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => const ScanQrLoginPage()));
                      },
                    ),
                    // 第四项「新建频道」：sheet 由 home_shell 的 Stack 分层挂载
                    // （导航胶囊须画在 sheet 之上，见 create_channel_sheet.dart）。
                    // 参考图没有第四宫格配色，中性灰 #8E8E93 为派生值（非实测）。
                    // 需求2（2026-09-22）：频道功能开关关闭 → 隐藏「新建频道」入口
                    if (FeatureFlags.instance.channelOn.value)
                      _menuGridItem(
                        icon: Icons.campaign,
                        color: const Color(0xFF8E8E93),
                        title: t('chcTitle'),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          CreateChannelSheetController.show();
                        },
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: context.cs.surface,
                  borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                ),
                width: double.infinity,
                child: InkWell(
                  onTap: () => Navigator.of(ctx).pop(),
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: Text(t('chatListCancel'),
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: context.cs.onSurface)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _menuGridItem({
    required IconData icon,
    required Color color,
    required String title,
    required VoidCallback onTap,
  }) {
    // Expanded 等分可用宽度：原固定 width 86 是按 3 项布局定的，
    // 加到 4 项后 4×86 = 344 > Row 可用宽（360 逻辑宽 − 外层 12×2 − 菜单容器 12×2 = 312）
    // → RIGHT OVERFLOWED BY 32 PIXELS（344 − 312 = 32）。
    // 等分后每项 = (屏宽 − 48) / 4，任意屏宽都不溢出（360 真机 = 78，420 基准 = 93）。
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 26, color: color),
              ),
              const SizedBox(height: 8),
              Text(title,
                  style: TextStyle(
                      fontSize: 13,
                      color: context.cs.onSurface,
                      fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }

  /// WSS 联通状态条：
  /// - connected：整条隐藏（SizedBox.shrink，零占位）
  /// - connecting：灰条「正在连接…」（自动重连中，不可点）
  /// - disconnected：红条「连接已断开」+ 「重试」——整条可点，立即手动重连
  ///   （不等指数退避下一轮，manualReconnect 整体重建连接、retry 归零）
  Widget _wsStatusBar() {
    return ListenableBuilder(
      listenable: GlobalWs.instance.connState,
      builder: (_, __) {
        final st = GlobalWs.instance.connState.value;
        if (st == WsConnState.connected) return const SizedBox.shrink();
        final t = AppLocalizations.of(context).t;
        final bad = st == WsConnState.disconnected;
        final dark = context.v2IsDark;
        final fg = bad
            ? (dark ? const Color(0xFFEF9A9A) : const Color(0xFFD32F2F))
            : (dark ? const Color(0xFF9AA5A8) : const Color(0xFF70797C));
        return Material(
          // 低透明度主题色铺底：白底/黑底都能透出可辨识的浅色带
          color: bad
              ? fg.withValues(alpha: 0.12)
              : fg.withValues(alpha: 0.08),
          child: InkWell(
            onTap: bad ? () => GlobalWs.instance.manualReconnect() : null,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  Icon(bad ? Icons.cloud_off : Icons.cloud_outlined,
                      size: 14, color: fg),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(bad ? t('wsDisconnected') : t('wsConnecting'),
                        style: TextStyle(
                            fontSize: 12, height: 1.2, color: fg)),
                  ),
                  if (bad)
                    Text(t('wsRetry'),
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: fg)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    return Scaffold(
      // 截图实测：会话列表页背景是**纯白 #FFFFFF**（不是全局浅灰 #F5F6F8）。
      // 「⊕」胶囊与搜索框的浅灰 #F1F1F1 正是在白底上才能看出边界。
      backgroundColor:
          context.v2IsDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF),
      body: SafeArea(
        child: PopScope(
          // 搜索模式下系统返回键先退搜索模式（不退出页面）；非搜索模式放行
          //（嵌套 PopScope：本层 canPop=true 时交给 home_shell 外层的宽屏处理）
          canPop: !_searchMode,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _exitSearchMode();
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 搜索模式：顶栏整行换成「输入框 + 取消」（Telegram 同构）
              _searchMode ? _searchModeBar() : _header(),
              _announcement(),
              // WSS 联通状态条（2026-09-25）：断开时红条 + 「重试」手动重连
              _wsStatusBar(),
              Expanded(
                // 宽屏右栏选中态跟随：点会话/关右栏时高亮实时刷新
                child: ListenableBuilder(
                  listenable: WideLayoutStore.instance,
                  builder: (_, __) => _loading
                      ? _buildLoadingView()
                      : _visibleConvs.isNotEmpty
                          ? ListView.builder(
                              // 下拉刷新已删（2026-09-19 用户要求）：列表数据
                              // 由 WS 增量 + 进页/重连自动 _load 维护，不再
                              // 需要手动全量刷新入口。physics 回默认，
                              // 不足一屏不再强制可滚动（原 AlwaysScrollable
                              // 是为撑出下拉手势用的）。
                              // 常驻搜索框已删（十七批）：原「搜索框底→行 1 顶」
                              // 的 12 间距直接沿用为「头栏底→行 1 顶」，无空洞
                              padding:
                                  EdgeInsets.fromLTRB(0, 12 * s, 0, 120 * s),
                              itemCount: _visibleConvs.length,
                              itemBuilder: (_, i) =>
                                  _convItem(_visibleConvs[i]),
                            )
                          : _loadFailed && !_searchMode
                              ? _loadFailedView()
                              : Center(
                                  child: Text(t('chatListEmpty'),
                                      style: TextStyle(
                                          color: context.cs.onSurfaceVariant))),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _loadFailedView() {
    final t = AppLocalizations.of(context).t;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined,
              size: 44, color: context.cs.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(t('chatListLoadFailed'),
              style:
                  TextStyle(fontSize: 14, color: context.cs.onSurfaceVariant)),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () {
              setState(() {
                _loading = true;
                _loadFailed = false;
              });
              _load();
            },
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

  /// 顶部标题栏（V2 复刻 2026-09-14；2026-09-15 按需求删除左侧「编辑」胶囊）。
  /// 截图实测（逻辑 px，基准宽 420）：
  /// 「聊天」标题 22/w700 且**居中于屏幕**（中心 209.7 ≈ 210）、
  /// 右侧 ⊕ 按钮 59.0×48.7（**不是正圆，宽 > 高**，是胶囊），中线 y92.2（距顶 68.0）。
  ///
  /// 标题为什么用 Stack 绝对居中、而不是 Row + Expanded：
  /// 左胶囊删除前左右宽度不等（97.3 / 59.0），Expanded 居中会偏 19px；
  /// 现在标题仍走绝对居中，右侧 ⊕ 用 Spacer 靠右，互不影响。
  Widget _header() {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    final dark = context.v2IsDark;
    final fg = context.cs.onSurface;
    // 「聊天」实测 #131927（带蓝调的深色）
    final titleColor = dark ? Colors.white : const Color(0xFF131927);
    // 顶栏底部分隔线（二十批：Telegram 同款灰色边框；深浅色各自适配）
    final borderColor =
        dark ? const Color(0xFF232326) : const Color(0xFFE9EBEE);

    // 二十批：右侧两按钮去掉灰椭圆胶囊底（Telegram 同款纯图标），
    // 顶栏整行加 1px 灰色底边框与列表分隔。
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: borderColor, width: 1)),
      ),
      padding: EdgeInsets.fromLTRB(20.7 * s, 24 * s, 20.7 * s, 10 * s),
      child: SizedBox(
        height: 48.7 * s,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Text(
              t('chatListTitle'),
              style: TextStyle(
                fontSize: 22 * s,
                fontWeight: FontWeight.w700,
                height: 1.0,
                color: titleColor,
              ),
            ),
            Row(
              children: [
                const Spacer(),
                // 搜索按钮（十七批入口，二十批去胶囊底）：点击进入搜索模式
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _enterSearchMode,
                  child: SizedBox(
                    width: 44 * s,
                    height: 48.7 * s,
                    child: Icon(Icons.search, size: 29 * s, color: fg),
                  ),
                ),
                SizedBox(width: 10 * s),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _showPlusMenu,
                  child: SizedBox(
                    width: 44 * s,
                    height: 48.7 * s,
                    // 实测墨迹：圆环外径 24.7 + 环笔画 2.5 + 内嵌加号（臂长 12.3）
                    // ⇒ 用 add_circle_outline（环+加号），size 按「glyph 约占盒子 20/24」放大
                    child:
                        Icon(Icons.add_circle_outline, size: 29 * s, color: fg),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 搜索模式行（十七批）：「输入框（自动聚焦）+ 取消」整行替换顶栏，
  /// 视觉沿用原常驻搜索框（v2Fill 填充）与头栏（48.7 高、20.7 左右出血）。
  /// 输入即本地过滤会话（_visibleConvs）；键盘「搜索」键 → SearchPage 全局
  /// 消息搜索（原搜索框去向，带词预填）；「取消」→ _exitSearchMode。
  /// 返回键由 body 的 PopScope 拦截，同样走 _exitSearchMode。
  Widget _searchModeBar() {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    final dark = context.v2IsDark;
    return Padding(
      padding: EdgeInsets.fromLTRB(20.7 * s, 24 * s, 20.7 * s, 0),
      child: SizedBox(
        height: 48.7 * s,
        child: Row(
          children: [
            Expanded(
              child: Container(
                height: 48.7 * s,
                decoration: BoxDecoration(
                  color: context.v2Fill,
                  borderRadius: BorderRadius.circular(24.3 * s),
                ),
                alignment: Alignment.centerLeft,
                padding: EdgeInsets.only(left: 16 * s),
                child: TextField(
                  controller: _searchCtrl,
                  autofocus: true, // 进入搜索模式即弹键盘
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: _pushGlobalSearch,
                  style: TextStyle(
                      fontSize: 17 * s,
                      height: 1.0,
                      color: dark ? Colors.white : const Color(0xFF131927)),
                  cursorColor: AppTheme.primary,
                  decoration: InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    icon: Icon(Icons.search,
                        size: 20 * s, color: context.v2HintColor),
                    hintText: t('chatListSearch'), // placeholder 沿用原词条
                    hintStyle: TextStyle(
                        fontSize: 17 * s,
                        height: 1.0,
                        color: context.v2HintColor),
                  ),
                ),
              ),
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _exitSearchMode,
              child: Padding(
                padding: EdgeInsets.only(left: 14 * s),
                child: Text(
                  t('chatListCancel'), // 复用现有「取消」词条
                  style: TextStyle(
                      fontSize: 17 * s,
                      fontWeight: FontWeight.w500,
                      height: 1.0,
                      color: AppTheme.primary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _announcement() {
    final text = _announcementText;
    if (text.isEmpty) return const SizedBox.shrink();
    if (_dismissedAnnouncement == text) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      height: 44,
      padding: const EdgeInsets.only(left: 14),
      decoration: BoxDecoration(
        color: context.cs.primaryContainer,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Row(
        children: [
          const Icon(Icons.campaign_outlined,
              size: 18, color: AppTheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: _Marquee(
                text: text,
                style: TextStyle(fontSize: 13, color: context.cs.onSurface)),
          ),
          IconButton(
            onPressed: _dismissAnnouncement,
            icon:
                Icon(Icons.close, size: 18, color: context.cs.onSurfaceVariant),
            splashRadius: 18,
          ),
        ],
      ),
    );
  }

  Future<void> _dismissAnnouncement() async {
    setState(() => _dismissedAnnouncement = _announcementText);
    try {
      await _api.writePref('dismissed_announcement', _announcementText);
    } catch (_) {}
  }

  // ===== 会话项 =====
  Widget _convItem(ConvItem c) {
    final t = AppLocalizations.of(context).t;
    final isGroup = (c.conversation['type'] as num?)?.toInt() == 2;
    // 宽屏双栏：右栏正在显示的会话 → 卡片高亮（微信桌面版同款选中态）。
    // 高亮必须用不透明色（Color.lerp）——侧滑按钮层常驻绘制在卡片底下，
    // 半透明卡片（withValues(alpha)）会把 置顶/免打扰/删除 按钮透出来，
    // 视觉上像侧滑菜单没关（与 _convCardBg 置顶底色同一坑，见其注释）。
    final selected = Breakpoints.isWide(context) &&
        WideLayoutStore.instance.currentKey == 'chat:${c.id}';
    final cardBg = selected
        ? Color.lerp(_convCardBg(c.pinned), AppTheme.primary, 0.10)!
        : _convCardBg(c.pinned);
    final s = v2Scale(context);
    final dark = context.v2IsDark;
    // 会话类型：2 = 群聊、3 = 频道。
    // ⚠️ 频道是**预留分支**：服务端目前只有 1 单聊 / 2 群聊，没有 type=3。
    // 参考截图里第 2 条是「频道」（浅蓝标签），这里按截图实现好，
    // 等后端支持频道会话后自动生效，不改 UI。详见 UI-ref/DESIGN.md。
    final isChannel = (c.conversation['type'] as num?)?.toInt() == 3;
    // 频道签名（副标题兜底）：/conversation/list 随 Conversation 对象下发
    // announcementZh/En（频道简介/公告），按当前语言取值（en 空回退 zh），
    // 与 chat_page 群公告同一取值逻辑。签名也为空就留空 —— 不造假数据。
    String channelSig = '';
    if (isChannel) {
      final lc = Localizations.localeOf(context).languageCode;
      final zh = c.conversation['announcementZh']?.toString() ?? '';
      final en = c.conversation['announcementEn']?.toString() ?? '';
      channelSig = lc == 'zh' ? zh : (en.isNotEmpty ? en : zh);
    }
    // 副标题与群聊同一来源（最后一条消息预览）；频道无消息时显示频道签名
    final subtitleText =
        c.lastMsgPreview.isNotEmpty ? c.lastMsgPreview : channelSig;
    // 行高原实测 101.3（含 1px 分隔线）。2026-09-15 第十三批按用户需求压缩一档
    // → **88**（-13.3，约 -13%）：头像 66.7→60 后上下留白 17.3→14，两行文字间距 8→6。
    // 行是**满宽出血**的：没有左右卡片边距、没有圆角，
    // 分行靠「左缩进 60 的分隔线」——与旧版「12/4 卡片 + 圆角」完全不同。
    final rowH = 88 * s;
    final dividerColor =
        dark ? context.cs.outlineVariant : const Color(0xFFEBEBEB);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppSlidable(
          convId: c.id,
          // GlobalKey：侧滑状态跟随会话身份移动（列表重排不错配到别的行）；
          // 置顶/免打扰等操作完成后由 _closeSlider 经它显式收起菜单。
          key:
              _slideKeys.putIfAbsent(c.id, () => GlobalKey<AppSlidableState>()),
          cardColor: cardBg,
          actions: [
            SlidableAction(
              icon: Icons.push_pin,
              label: c.pinned ? t('chatListUnpin') : t('chatListPin'),
              color: AppTheme.primary.withValues(alpha: 0.14),
              foregroundColor: AppTheme.primary,
              onTap: () => _togglePin(c),
            ),
            SlidableAction(
              icon:
                  c.mute ? Icons.notifications_active : Icons.notifications_off,
              label: c.mute ? t('chatListUnmute') : t('chatListMute'),
              color: context.cs.outlineVariant,
              foregroundColor: context.cs.onSurface,
              onTap: () => _toggleMute(c),
            ),
            SlidableAction(
              icon: Icons.delete_outline,
              label: t('chatListDelete'),
              color: AppTheme.danger,
              onTap: () => _deleteConv(c),
            ),
          ],
          child: Container(
            color: cardBg,
            child: InkWell(
              onTap: () async {
                // 进入聊天前收起所有侧滑菜单：滑开后点行，行内 InkWell 赢得点按
                // 仲裁，AppSlidable 自己的收起回调不执行 → 菜单残留展开态
                for (final k in _slideKeys.values) {
                  k.currentState?.close();
                }
                setState(() => _openConvId = c.id);
                // 宽屏（折叠屏展开/平板）：不 push，更新右栏（WideChatPane）
                if (Breakpoints.isWide(context)) {
                  WideLayoutStore.instance.openConversation(context, c, _myId);
                  // 等价于窄屏 push 返回后的 _load()：刷新未读角标
                  Future.delayed(const Duration(milliseconds: 600), () {
                    if (mounted) _load();
                  });
                  return;
                }
                // 第十三批问题 2：push 前先预热本地缓存（LazyBox 读一条 JSON，
                // 几毫秒），ChatPage 拿 initialMessages 首帧同步直出消息列表 ——
                // 消掉转场中途「白色气泡/占位卡弹入」的闪现
                final warmed = await ConversationService.hydrateFromDisk(c.id);
                // 残余跳修复：预热实测高度内存层（毫秒级），ChatPage 首帧
                // initialScrollOffset 才能用真实高度（异步加载赶不上首帧）
                await MsgHeightCache.ensureLoaded();
                if (!mounted) return;
                Navigator.of(context)
                    .push(MaterialPageRoute(
                        builder: (_) => ChatPage(
                            conv: c,
                            myId: _myId,
                            initialMessages: warmed
                                ? ConversationService.historyCached(c.id)
                                : null)))
                    .then((_) {
                  // 2026-09-28 性能修复：push 的 Future 在 pop() 调用瞬间即完成
                  // （转场动画还没播完），立刻 setState 全列表重建 + _load()
                  // 会和 pop 动画抢主线程 → 返回列表页卡顿。延迟到转场结束后
                  // 再刷新（宽屏分支 600ms 延迟同款先例）。
                  Future.delayed(const Duration(milliseconds: 350), () {
                    if (!mounted) return;
                    setState(() => _openConvId = '');
                    _load();
                  });
                });
              },
              child: SizedBox(
                // 行高 88、头像 60 垂直居中（上下各留 14）
                height: rowH,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20.7 * s),
                  child: Row(
                    children: [
                      // 群/频道不显示在线小圆点（截图里两条都没有）
                      _avatar(c, showOnline: !isGroup && !isChannel),
                      SizedBox(width: 15.9 * s),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // ---- 第一行：类型标签 / 名称 / 蓝V / 频道标签 …… 时间 ----
                            SizedBox(
                              height: 24.4 * s,
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Row(
                                      children: [
                                        // 「群聊」红色圆底图标徽章在名称**之前**
                                        // （十七批：文字标签 → Telegram 风格圆徽章）
                                        if (isGroup) ...[
                                          const V2ConversationTag(),
                                          SizedBox(width: 6 * s),
                                        ],
                                        // 「频道」蓝色圆底图标徽章同样在名称**之前**
                                        // （间距与群聊徽章一致）
                                        if (isChannel) ...[
                                          const V2ConversationTag(
                                              kind: V2ConversationTagKind
                                                  .channel),
                                          SizedBox(width: 6 * s),
                                        ],
                                        Flexible(
                                          child: Text(c.conversationName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                  fontSize: 20.3 * s,
                                                  fontWeight: FontWeight.w700,
                                                  height: 1.0,
                                                  // 实测：群聊名是**红色** #DC4E52
                                                  // （第十三批按用户需求：频道名改**蓝色**
                                                  // 与群聊名红形成对照；单聊仍近黑 #131927）
                                                  color: isGroup
                                                      ? (dark
                                                          ? const Color(
                                                              0xFFFF7A7E)
                                                          : const Color(
                                                              0xFFDC4E52))
                                                      : isChannel
                                                          ? (dark
                                                              ? const Color(
                                                                  0xFF409CFF)
                                                              : AppTheme
                                                                  .primary)
                                                          : (dark
                                                              ? Colors.white
                                                              : const Color(
                                                                  0xFF131927)))),
                                        ),
                                        // 官方/客服标识（二十六批修正）：
                                        // 小助手（uid=-1）=「官方」文字标签（官方账号
                                        // 不是客服，不亮勾）；客服账号（peerRole=3）=
                                        // 蓝盾勾（与好友资料页同款 V2SealBadge）
                                        if (c.isAssistant) ...[
                                          SizedBox(width: 7 * s),
                                          const OfficialTag(),
                                        ] else if (CertBadge.isKefu(
                                            c.peerRoleAny)) ...[
                                          SizedBox(width: 7 * s),
                                          const V2SealBadge(
                                              size: 18,
                                              color: Color(0xFF4FA4EE)),
                                        ],
                                      ],
                                    ),
                                  ),
                                  if (c.timeText.isNotEmpty)
                                    Padding(
                                      padding: EdgeInsets.only(left: 8 * s),
                                      child: Text(c.timeText,
                                          style: TextStyle(
                                              fontSize: 15.7 * s,
                                              height: 1.0,
                                              color: dark
                                                  ? context.cs.onSurfaceVariant
                                                  : const Color(0xFF9FA2AD))),
                                    ),
                                ],
                              ),
                            ),
                            SizedBox(height: 6 * s),
                            // ---- 第二行：免打扰/置顶标记 / 预览文字 …… 未读红点 ----
                            SizedBox(
                              height: 21.6 * s,
                              child: Row(
                                children: [
                                  if (c.mute && c.unread == 0)
                                    Padding(
                                      padding: EdgeInsets.only(right: 4 * s),
                                      child: Icon(
                                          Icons.notifications_off_outlined,
                                          size: 20 * s,
                                          color: context.cs.onSurfaceVariant),
                                    )
                                  else if (c.pinned)
                                    Padding(
                                      padding: EdgeInsets.only(right: 4 * s),
                                      child: Icon(Icons.push_pin,
                                          size: 20 * s,
                                          color: context.cs.onSurfaceVariant),
                                    ),
                                  Expanded(
                                    child: Text(subtitleText,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontSize: 18 * s,
                                            height: 1.0,
                                            fontWeight: FontWeight.w400,
                                            // 实测：有消息 #6A6F79；空会话的
                                            // 「快来发送第一条消息吧～」是更浅的 #A5A7AD
                                            color: dark
                                                ? context.cs.onSurfaceVariant
                                                : (c.lastMessage == null
                                                    ? const Color(0xFFA5A7AD)
                                                    : const Color(
                                                        0xFF6A6F79)))),
                                  ),
                                  if (c.unread > 0)
                                    Container(
                                      margin: EdgeInsets.only(left: 8 * s),
                                      // 实测为正圆 ∅26（逐行宽剖面 12→78→22 严格对称）
                                      constraints: BoxConstraints(
                                          minWidth: 26 * s, minHeight: 26 * s),
                                      padding: EdgeInsets.symmetric(
                                          horizontal: 5 * s),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFF3B2F),
                                        borderRadius:
                                            BorderRadius.circular(13 * s),
                                      ),
                                      alignment: Alignment.center,
                                      child: Text(
                                          c.unread > 99 ? '99+' : '${c.unread}',
                                          style: TextStyle(
                                              fontSize: 15 * s,
                                              fontWeight: FontWeight.w600,
                                              height: 1.0,
                                              color: Colors.white)),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        // 分隔线：实测 #EBEBEB、厚 1.0、**左缩进 60**（与头像右缘对齐）、
        // 右侧通到屏幕右边缘；最后一行之后也有一条（截图 y=419.8 那条）。
        Padding(
          padding: EdgeInsets.only(left: 60 * s),
          child: Container(height: 1, color: dividerColor),
        ),
      ],
    );
  }

  // ============================================================
  //  ✅ 核心修复：置顶/免打扰改为「本地更新」，不再调 _load()
  // ============================================================

  /// 置顶/取消置顶
  ///
  /// 原逻辑：调 _load() → _listRev++ → 全量重建 → 菜单状态错乱
  /// 新逻辑：本地直接更新数据 + setState → key 变化 → AppSlidable 重建 → 菜单自动收起
  Future<void> _togglePin(ConvItem c) async {
    final newPinned = !c.pinned;
    final t = AppLocalizations.of(context).t;

    // 1）先本地更新（立即反映 UI，不触发全量刷新）
    final idx = _convs.indexWhere((x) => x.id == c.id);
    if (idx >= 0 && idx < _convRaw.length) {
      final raw = Map<String, dynamic>.from(_convRaw[idx] as Map);
      raw['pinned'] = newPinned;
      final updated = ConvItem.fromJson(raw);

      setState(() {
        _convs.removeAt(idx);
        _convRaw.removeAt(idx);
        // 置顶的移到最前，取消置顶的插到"置顶块"之后
        var target = 0;
        if (!newPinned) {
          while (target < _convs.length && _convs[target].pinned) {
            target++;
          }
        }
        _convs.insert(target, updated);
        _convRaw.insert(target, raw);
      });
    }

    // 2）显式关闭该行侧滑菜单（按钮 onTap 时 AppSlidable 已自收起一次，这里再兜底）
    _closeSlider(c.id);

    // 3）后台同步到服务端（不需要 await，不阻塞 UI）
    try {
      final ok = await ConversationService().setPin(c.id, newPinned);
      if (!ok) {
        _toast(t('chatListOpFailed'));
        _load(); // 失败回滚：重新拉取正确数据
        return;
      }
      _toast(newPinned ? t('chatListPinned') : t('chatListUnpinned'));
    } catch (e) {
      _toast(t('chatListOpFailed'));
      // 失败回滚：重新拉取正确数据
      _load();
    }
  }

  /// 免打扰/取消免打扰 —— 同理
  Future<void> _toggleMute(ConvItem c) async {
    final newMute = !c.mute;
    final t = AppLocalizations.of(context).t;

    // 1）本地更新单条
    final idx = _convs.indexWhere((x) => x.id == c.id);
    if (idx >= 0 && idx < _convRaw.length) {
      final raw = Map<String, dynamic>.from(_convRaw[idx] as Map);
      raw['mute'] = newMute;
      final updated = ConvItem.fromJson(raw);

      setState(() {
        _convs[idx] = updated;
        _convRaw[idx] = raw;
      });
    }

    // 2）显式关闭该行侧滑菜单（同置顶，操作后兜底收起）
    _closeSlider(c.id);

    // 3）后台同步
    try {
      final ok = await ConversationService().setMute(c.id, newMute);
      if (!ok) {
        _toast(t('chatListOpFailed'));
        _load();
        return;
      }
      _toast(newMute ? t('chatListMuteOn') : t('chatListNotifyOn'));
    } catch (e) {
      _toast(t('chatListOpFailed'));
      _load();
    }
  }

  Future<void> _deleteConv(ConvItem c) async {
    // 1）本地乐观移除（立即反映 UI，不涉及全量刷新）
    //    AppSlidable 被移除 → 菜单自然不存在了；顺手清掉它的 GlobalKey
    final idx = _convs.indexWhere((x) => x.id == c.id);
    _slideKeys.remove(c.id);
    setState(() {
      _convs.removeWhere((x) => x.id == c.id);
      if (idx >= 0 && idx < _convRaw.length) _convRaw.removeAt(idx);
    });
    // 先落本地缓存：避免杀进程重开瞬间从缓存把已删会话闪回
    // （最终以服务端 hidden=1 为准；失败回滚时 _load() 会重写缓存）
    unawaited(LocalStore.saveConvList(_convRaw));
    _toast(AppLocalizations.of(context).t('chatListDeleted'));

    // 2）同步服务端（conversation_member.hidden=1）。
    //    此前只做内存移除、从不调服务端 → 杀进程重开时 /conversation/list 仍下发该会话，
    //    会话「复活」。现在删服务端后，重拉列表过滤 hidden=0，会话不再出现。
    try {
      final ok = await ConversationService().deleteConversation(c.id);
      if (!ok) {
        _toast(AppLocalizations.of(context).t('chatListOpFailed'));
        _load(); // 服务端未删除 → 重新拉取回滚
      }
    } catch (e) {
      _toast(AppLocalizations.of(context).t('chatListOpFailed'));
      _load(); // 网络失败 → 重新拉取回滚
    }
  }

  /// 显式关闭某行的侧滑菜单（置顶/免打扰等操作完成后调用）。
  /// 延后到帧末执行：确保 GlobalKey 对应的 State 已完成重排后的重新挂载。
  void _closeSlider(String id) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _slideKeys[id]?.currentState?.close();
    });
  }

  /// 首次载入态：主色调线性进度条 + 文案（替代原来的灰色转圈）
  Widget _buildLoadingView() {
    // 骨架屏（2026-09-06）：替代线性进度条 + 文案，等待感知更低
    return const SkeletonList(style: SkeletonStyle.chat);
  }

  /// 会话卡背景色。置顶 = surface 向主色调抬 6% 的【不透明】色。
  /// 铁律：不能用半透明色（primary.withValues(alpha:0.06)）——
  /// 侧滑按钮层常驻绘制在卡片底下，半透明卡片会把
  /// 「取消置顶/免打扰/删除」三个按钮直接透出来（视觉上像菜单没关）。
  Color _convCardBg(bool pinned) {
    final surface = context.cs.surface;
    if (!pinned) return surface;
    return Color.lerp(surface, AppTheme.primary, 0.06)!;
  }

  void _toast(String msg) {
    AppDialogs.toast(context, msg);
  }

  /// 会话头像（V2 复刻）。原实测：**66.7×66.7、圆角方形 r≈15**（≈边长的 22.5%），
  /// 单聊为整圆（r = 半边长）。
  /// 2026-09-15 第十三批按用户需求缩小一档 → **60×60**（-10.1%），
  /// 圆角 15→13.5 同步维持 22.5% 比例；单聊仍为整圆。
  /// 旧版挂在头像右下角的「群聊」斜角标**已删** ——
  /// 参考截图里「群聊」是名称**之前**的独立蓝色胶囊标签，见 `_convItem` 第一行。
  Widget _avatar(ConvItem c, {bool showOnline = true}) {
    final s = v2Scale(context);
    final side = 60 * s;
    final color = AppTheme
        .avatarColors[c.id.hashCode.abs() % AppTheme.avatarColors.length];
    final isGroup = (c.conversation['type'] as num?)?.toInt() == 2;
    final radius = isGroup ? 13.5 * s : side / 2;
    final avatar = SizedBox(
      width: side,
      height: side,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: AppAvatar(
                url: c.avatarUrl,
                name: c.conversationName,
                size: side,
                radius: radius,
                background: color,
                emptyText:
                    AppLocalizations.of(context).t('chatListGroupInitial'),
              ),
            ),
          ),
          if (showOnline && c.peerOnline)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 16 * s,
                height: 16 * s,
                decoration: BoxDecoration(
                  color: AppTheme.onlineDot,
                  shape: BoxShape.circle,
                  border: Border.all(color: context.cs.surface, width: 2.6 * s),
                ),
              ),
            ),
        ],
      ),
    );
    return avatar;
  }
}

/// 跑马灯：文字水平循环滚动（公告横幅用）
class _Marquee extends StatefulWidget {
  final String text;
  final TextStyle style;
  const _Marquee({required this.text, required this.style});

  @override
  State<_Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<_Marquee>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final ScrollController _scroll;
  double _textWidth = 0;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(vsync: this, duration: const Duration(seconds: 12))
          ..addListener(() {
            if (_scroll.hasClients) {
              _scroll.jumpTo(_controller.value * _textWidth);
            }
          });
    _scroll = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _measure() {
    if (!mounted || _started) return;
    final tp = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    _textWidth = tp.width;
    _started = true;
    if (_textWidth > 200) _controller.repeat();
    setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: SizedBox(
        height: 24,
        child: ListView(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 40),
              child: Text(widget.text,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.visible,
                  style: widget.style),
            ),
          ],
        ),
      ),
    );
  }
}
