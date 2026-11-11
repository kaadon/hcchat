import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../config/app_config.dart';
// ApiException 定义于 conversation_service.dart，无需额外 import
import '../services/call_service.dart';
import '../services/conversation_service.dart';
import '../services/friend_service.dart';
import '../theme/app_theme.dart'; // AppTheme.primary / ctx.cs
import '../widgets/app_avatar.dart';
import '../widgets/v2_kit.dart';
import '../widgets/v2_seal_badge.dart';
import '../widgets/v2_settings.dart'; // V2SetCard / V2SetSwitch / context.setXxx
import '../widgets/v2_tags.dart'; // CertBadge（客服认证勾公共判定）
import 'media_filter_page.dart';
import 'moments_page.dart';
import 'mutual_groups_page.dart';
import '../widgets/app_dialogs.dart';
import 'chat_page.dart';
import 'forward_picker_page.dart';
import 'search_page.dart';
import 'video_call_page.dart';
import 'voice_call_page.dart';

// ============================================================================
// 好友资料页（V2 像素级复刻）
//
// 参考截图：C:/Users/Administrator/Downloads/Screenshot_2026_0914_183605.jpg
//   物理 1260 × 3863 / DPR 3 ⇒ 逻辑 420.0 × 1287.7（与本项目 v2Scale 基准宽一致）
// 逐元素实测值见 UI-ref/measure/measure_friend_group.md。
//
// 页面结构（逻辑 y，均已减去状态栏 44 后落到代码里）：
//   0   – 437  模糊头像背景区：返回箭头 / ⋯ / 头像 107(白环 4.7) / 名字 25.5 + 星形认证徽
//               / 副标题 18.5 / 4 个圆形按钮 ∅56.5（圆心 x=60/160/260/360）
//   437 – 457  留白 20
//   457 – 563.3  卡1「个人简介」+ 签名
//   589.3 – 837.3  卡2 统计 4 行（行高 62）
//   863 – 924.7  卡3「N 个共同群组」
//   950.3 – 1229.3  卡4 免打扰开关行（92.4）+ 清空记录/屏蔽/举报（62.3 × 3）
// 卡片之间留白 26，卡左 20.3 / 宽 379（复用 V2SetCard：左 20.7 / 宽 378.7 / 圆角 16）。
//
// 与参考截图的已知差异（详见测量报告「不确定项」）：
//  1. 顶部模糊背景在参考包里是一张「涂鸦纹样壁纸」的模糊版，assets 里没有该图，
//     这里用**好友头像放大模糊 + 深色蒙版**近似（数据驱动，不编造图片）。
//  2. 卡片圆角实测 ≈12.9，复用 V2SetCard 的 16（差 3.1，肉眼几乎不可见）。
//  3. 行分隔线实测 #E6E6E6，V2SetCard 用 #F3F3F3。
// ============================================================================

/// 顶部模糊背景区高度（**状态栏之下**的部分；整块高度 = 状态栏 + 该值）。
/// 实测参考机状态栏 ≈ 59（状态栏文字 ink 22.0..35.3、返回箭头 ink 中心 87.2
/// ⇒ 顶部条 56 的内容中心在 状态栏 + 28），头部底边实测 y = 436 ⇒ 436 - 59 = 377。
const double _kHeaderBody = 377.0;

/// 头像外径 / 白环宽度（实测白环外径 108.0、中心 209.8）
const double _kAvatarD = 107.0;
const double _kAvatarRing = 4.7;

/// 4 个圆形操作按钮：直径 56.5，圆心 x=60/160/260/360（间距均等 100，
/// 等价于左右留白 31.75 + spaceBetween）
const double _kActionD = 56.5;

/// 卡片之间的留白 / 头部到首卡的留白（实测 25.6 / 21.0）
const double _kCardGap = 25.6;
const double _kHeaderToCard = 21.0;

/// 行布局（相对**卡片左缘**）：图标盒左 21.0、图标盒 30、文字左 73.4、尾部右缩 21.75
/// 实测图标 ink 左 43.7（= 卡左 20.7 + 21.0 + 盒内留白 2.1）、ink 宽 25.7 ⇒ 图标字号 30
const double _kRowIconLeft = 21.0;
const double _kRowIconBox = 30.0;
const double _kRowTextLeft = 73.4;
const double _kRowTailRight = 21.75;

/// 好友详情：资料 / 发消息 / 通话 / 备注 / 删除 / 拉黑
class FriendDetailPage extends StatefulWidget {
  final Map<String, dynamic> friend;
  final String myId;
  const FriendDetailPage({super.key, required this.friend, required this.myId});

  /// 命名工厂：把「单聊会话」（通讯录 / 会话列表点开的好友）适配成本页需要的
  /// `friend` Map，避免每个入口各拼一遍、少一个键就显示空白。
  ///
  /// 本页**实际读取**的键（改这里之前先确认本文件没有新增读取点）：
  /// * `id` —— 雪花 ID，**全程字符串**（createDirect / setRemark / blacklistAdd / delete
  ///   都直接用它）；
  /// * `remark` → `nickname` → `account` —— 依次作为显示名（见 `_name`）；
  /// * `avatar` —— 本页再过一次 [AppConfig.assetUrl]（对绝对 URL 幂等）；
  /// * `signature` —— 卡1 个人简介；**缺键**时页面自动拉 /user/:id 补齐
  ///   （见 `_loadDetail`），存在但为空 → 简介卡不渲染；
  /// * `lastLoginAt` —— 头部副标题「最近上线 xx」。数据源：会话列表单聊项
  ///   （聊天窗口路径实时下发）/ /friend/list（2026-09-15 契约上线，仅好友可见；
  ///   /user/:id、/user/search 不返回该字段——隐私收敛，扫码陌生人路径只占位）；
  /// * `role` —— 对方用户组（3=客服才显示 V 盾）。数据源（2026-09-15 契约上线）：
  ///   /user/:id、/friend/list 的 `PublicUser.role`，会话列表单聊项 `peerRole`
  ///   （小助手虚拟账号恒 0=无盾）。⚠️ 群成员列表的 `role` 是**群内角色**
  ///   （1=群主 2=管理员 3=普通成员），同名不同义，**不得**用于本判定。
  ///
  /// [ConvItem] 带得动全部：`signature` 会话接口不下发，交给 `_loadDetail`
  /// 拉 /user/:id 补；`role` 经 fromConv 从 `peerRole` 注入（contacts 入口
  /// 由 contacts_page 把 /friend/list 的 role 写进 conversation.peerRole）。
  /// 头像走 [ConvItem.avatarUrl]（会话 `avatar` 优先、`peerAvatar` 兜底）。
  factory FriendDetailPage.fromConv({
    required ConvItem conv,
    required String myId,
  }) {
    // 顶层 peerId 优先，回落 conversation.peerId；两者都是字符串，不经过 int
    final peerId = conv.peerId.isNotEmpty
        ? conv.peerId
        : (conv.conversation['peerId']?.toString() ?? '');
    return FriendDetailPage(
      myId: myId,
      friend: <String, dynamic>{
        'id': peerId,
        'remark': conv.peerRemark,
        'nickname': conv.conversationName,
        'account': conv.peerShortId,
        // 短 ID（2026-09-25 需求：昵称下方显示「ID: 10005」）。
        // ConvItem.peerShortId 三个入口都会带上（contacts 注入 / 会话列表下发）
        'shortId': conv.peerShortId,
        'avatar': conv.avatarUrl,
        // 单聊会话列表实时下发的对方最近上线时间（2026-09-15 第十批）
        'lastLoginAt': conv.lastLoginAt,
        // 会话列表 peerRole=账号角色（3=客服亮 V 盾；小助手恒 0 无盾）。
        // 二十七批：后端 peerRole 在 ConvItem 顶层，conversation map 兜底
        'role': conv.peerRoleAny,
        // 共同群组数（contacts 入口经 contacts_page 从 /friend/list 注入；
        // 键不存在（groupVisible=nobody 或聊天窗口路径未拼装）→ 卡不渲染）
        'commonGroupCount': conv.conversation['commonGroupCount'],
      },
    );
  }

  @override
  State<FriendDetailPage> createState() => _FriendDetailPageState();
}

class _FriendDetailPageState extends State<FriendDetailPage> {
  final _svc = FriendService();
  final _convSvc = ConversationService();

  /// 免打扰开关（真实状态：来自会话列表里的 mute；无会话时为 false）
  bool _mute = false;
  String _convId = '';
  bool _muteBusy = false;

  Map<String, dynamic> get f => widget.friend;
  String get _id => f['id']?.toString() ?? '';
  String get _name {
    final r = f['remark']?.toString() ?? '';
    if (r.isNotEmpty) return r;
    return f['nickname']?.toString() ??
        f['account']?.toString() ??
        AppLocalizations.instance.t('friendDetailUser');
  }

  String get _avatarUrl => AppConfig.assetUrl((f['avatar'] ?? '').toString());

  @override
  void initState() {
    super.initState();
    _loadMute();
    _loadDetail();
  }

  /// 从会话列表里找与该好友的单聊，读真实 mute（不主动建会话，避免副作用）
  Future<void> _loadMute() async {
    try {
      final items = await _convSvc.list();
      for (final it in items) {
        if (it.peerId == _id || it.id == _id) {
          if (!mounted) return;
          setState(() {
            _convId = it.id;
            _mute = it.mute;
          });
          return;
        }
      }
    } catch (_) {
      // 读不到就保持默认（关闭），开关点击时再兜底 createDirect
    }
  }

  Future<void> _toggleMute(bool v) async {
    if (_muteBusy) return;
    final t = AppLocalizations.of(context).t;
    setState(() {
      _mute = v;
      _muteBusy = true;
    });
    try {
      var convId = _convId;
      if (convId.isEmpty) {
        final conv = await _convSvc.createDirect(_id);
        convId = conv['id']?.toString() ?? '';
        _convId = convId;
      }
      if (convId.isEmpty) throw Exception('empty conversation id');
      final ok = await _convSvc.setMute(convId, v);
      if (!ok) throw Exception('setMute failed');
    } catch (_) {
      if (mounted) {
        setState(() => _mute = !v); // 失败回滚
        AppDialogs.toast(context, t('convSetStartConvFailed', {'error': ''}));
      }
    } finally {
      if (mounted) setState(() => _muteBusy = false);
    }
  }

  /// 拿到（必要时创建）单聊会话 id。
  /// 在途 Future 复用：连点「发消息」时两个请求共享同一次 createDirect——
  /// 服务端虽有 uk_direct_key 唯一键兜底（并发创建返回同一条会话），这里
  /// 再挡一层，避免双开聊天页。
  Future<String>? _ensureConvFuture;
  Future<String> _ensureConv() {
    if (_convId.isNotEmpty) return Future.value(_convId);
    return _ensureConvFuture ??= _doEnsureConv();
  }

  Future<String> _doEnsureConv() async {
    try {
      final conv = await _convSvc.createDirect(_id);
      _convId = conv['id']?.toString() ?? '';
      return _convId;
    } finally {
      _ensureConvFuture = null;
    }
  }

  Future<void> _sendMsg() async {
    try {
      final convId = await _ensureConv();
      if (!mounted) return;
      final item = ConvItem.fromJson({
        'conversation': {
          'id': convId,
          // peerRole 注入（3=客服）：聊天顶栏的客服勾靠它判定——否则从
          // 好友资料发消息进聊天，顶栏永远没勾（会话列表入口才有）。
          'peerRole': f['role'],
        },
        'conversationName': _name,
        // peerId 必带：peerRole 拿不到时聊天页 _loadPeerRole 靠它拉 /user/:id 兜底
        'peerId': _id,
      });
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ChatPage(conv: item, myId: widget.myId)));
    } catch (e) {
      if (mounted) {
        AppDialogs.toast(
            context,
            AppLocalizations.of(context)
                .t('friendDetailStartConvFailed', {'error': '$e'}));
      }
    }
  }

  /// 语音/视频通话（沿用会话设置页的既有流程：先拿到会话 id 再进通话页）
  ///
  /// 2026-09-17 修复：通话页（VoiceCallPage/VideoCallPage）自身**不发邀请**，
  /// 只监听 CallService 事件等对方接听——邀请必须由 [CallService.startCall]
  /// 在进页前发出。旧实现直接推通话页没调 startCall → 邀请根本没发出去，
  /// 本地永远「等待对方接听」、对方收不到任何弹窗。现对齐会话设置页口径：
  /// 忙线检查 → startCall 发邀请 → 再进通话页。
  Future<void> _call(bool video) async {
    final t = AppLocalizations.of(context).t;
    try {
      if (CallService.instance.state.value != null) {
        AppDialogs.toast(context, t('convSetCallBusy'));
        return;
      }
      final convId = await _ensureConv();
      if (!mounted) return;
      await CallService.instance.startCall(
        convId: convId,
        callType: video ? 'video' : 'voice',
        peerName: _name,
        peerAvatar: _avatarUrl,
      );
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => video
            ? VideoCallPage(
                peerName: _name, peerAvatar: _avatarUrl, convId: convId)
            : VoiceCallPage(
                peerName: _name, peerAvatar: _avatarUrl, convId: convId),
      ));
    } catch (e) {
      if (mounted) {
        AppDialogs.toast(
            context,
            AppLocalizations.of(context)
                .t('friendDetailStartConvFailed', {'error': '$e'}));
      }
    }
  }

  String _uuid() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(99999)}';

  /// AppBar「...」菜单：转发名片 / 设置备注
  void _showMoreSheet() {
    final t = AppLocalizations.of(context).t;
    AppDialogs.actionSheet(
      context,
      actions: [
        DialogAction(
          label: t('forwardCardTitle'),
          icon: Icons.share_outlined,
          onTap: _forwardCard,
        ),
        DialogAction(
          label: t('friendDetailSetRemark'),
          icon: Icons.edit_outlined,
          onTap: _setRemark,
        ),
        DialogAction(
          label: t('friendDetailMoments'),
          icon: Icons.photo_album_outlined,
          onTap: _openMoments,
        ),
        // 参考截图的卡片里没有「删除好友」，但原页面有该功能，
        // 迁到「⋯」菜单里保留（不顺手删功能）。
        DialogAction(
          label: t('friendDetailDeleteFriend'),
          icon: Icons.person_remove_outlined,
          danger: true,
          onTap: _confirmDelete,
        ),
      ],
    );
  }

  void _openMoments() {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => MomentsPage(userId: _id, userName: _name)));
  }

  /// 转发名片：选会话 → 发 type=10 名片消息
  /// content=JSON {"userId","nickname","avatar"}，雪花 ID 全程字符串
  Future<void> _forwardCard() async {
    final t = AppLocalizations.of(context).t;
    final picked = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => ForwardPickerPage(myId: widget.myId)),
    );
    if (picked == null) return;
    final targetId = picked['id']?.toString() ?? '';
    if (targetId.isEmpty) return;
    try {
      // 好友 → 先 createDirect 拿会话 id（字符串）；群 → 直接用群 id
      String convId;
      if (picked['kind'] == 'group') {
        convId = targetId;
      } else {
        final conv = await _convSvc.createDirect(targetId);
        convId = conv['id']?.toString() ?? '';
      }
      if (convId.isEmpty) throw Exception('empty conversation id');
      final content = jsonEncode({
        'userId': _id,
        'nickname': _name, // 备注优先于昵称（_name 已处理）
        'avatar': f['avatar']?.toString() ?? '',
      });
      final ok = await _svc.sendRaw(convId, 10, content, clientMsgId: _uuid());
      if (!ok) throw Exception('send failed');
      if (!mounted) return;
      AppDialogs.toast(context, t('forwardCardDone'));
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        AppDialogs.toast(
            context, t('friendDetailStartConvFailed', {'error': '$e'}));
      }
    }
  }

  Future<void> _setRemark() async {
    final t = AppLocalizations.of(context).t;
    final result = await AppDialogs.input(
      context,
      title: t('friendDetailSetRemark'),
      hint: t('friendDetailRemarkHint'),
      maxLines: 1,
      maxLength: 20,
    );
    if (result != null && result.isNotEmpty) {
      final ok = await _svc.setRemark(_id, result);
      if (ok && mounted) {
        AppDialogs.toast(
            context, AppLocalizations.of(context).t('friendDetailRemarkSaved'));
      }
    }
  }

  /// 删除聊天记录（2026-09-18 接真）：底部弹层选范围——
  /// 「仅为我清空」（scope=self，只推进自己位点，重启/重拉网络也不再显示）
  /// /「为双方清空」（scope=both，双方位点推进，对端在线实时清空）。
  /// 服务端软删：消息本体保留（后台可查原文）。成功后本机立即清掉
  /// 本地缓存（内存 + Hive），不用等进会话再对账。
  Future<void> _confirmClearHistory() async {
    final t = AppLocalizations.of(context).t;
    final scope = await AppDialogs.clearHistorySheet(
      context,
      title: t('clearSheetTitleFmt', {'name': _name}),
    );
    if (scope == null || (scope != 'self' && scope != 'both')) return;
    try {
      final convId = await _ensureConv();
      if (convId.isEmpty) throw Exception('empty conversation id');
      await _convSvc.clearHistory(convId, scope: scope);
      ConversationService.historyCacheClearConv(convId);
      if (mounted) AppDialogs.toast(context, t('convSetHistoryCleared'));
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
      AppDialogs.toast(context, msg);
    }
  }

  Future<void> _confirmBlock() async {
    final t = AppLocalizations.of(context).t;
    final yes = await AppDialogs.confirm(
      context,
      title: t('friendDetailBlockTitle'),
      message: t('friendDetailBlockMsg'),
      confirmText: t('friendDetailBlock'),
      danger: true,
    );
    if (yes != true) return;
    final ok = await _svc.blacklistAdd(_id);
    if (ok && mounted) {
      AppDialogs.toast(
          context, AppLocalizations.of(context).t('friendDetailBlocked'));
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _confirmDelete() async {
    final t = AppLocalizations.of(context).t;
    final yes = await AppDialogs.confirm(
      context,
      title: t('friendDetailDeleteFriend'),
      message: t('friendDetailDeleteMsg'),
      confirmText: t('friendDetailDelete'),
      danger: true,
    );
    if (yes != true) return;
    final ok = await _svc.delete(_id);
    if (ok && mounted) {
      AppDialogs.toast(
          context, AppLocalizations.of(context).t('friendDetailFriendDeleted'));
      Navigator.of(context).pop(true);
    }
  }

  /// 「举报用户」（2026-09-15 第十二批接真请求）：投诉 sheet（类型 + 可选
  /// 说明 + 提交，与 conv_settings_page 的投诉 sheet 同款交互与词条）。
  /// 走 `ConversationService.reportConversation` 真 POST（/api/v1/conversation/
  /// report，code!=0 抛 ApiException → toast 其 message）；成功 toast
  /// 「举报已提交」。会话不存在时先 createDirect（与免打扰开关同一兜底）。
  Future<void> _report() async {
    final t = AppLocalizations.of(context).t;
    if (widget.myId.isEmpty) {
      AppDialogs.toast(context, t('convSetGetPeerFailed'));
      return;
    }
    final categories = <String>[
      'convSetReportSpam',
      'convSetReportFraud',
      'convSetReportHarass',
      'convSetReportImpersonate',
      'convSetReportOther',
    ];
    var selected = categories.first;
    final noteCtrl = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x80000000),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: SafeArea(
          child: StatefulBuilder(
            builder: (ctx, setSheet) => Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              child: Container(
                decoration: BoxDecoration(
                  color: ctx.cs.surface,
                  borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                        child: Text(t('fdpReport'),
                            style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                                color: ctx.cs.onSurface)),
                      ),
                      RadioGroup<String>(
                        groupValue: selected,
                        onChanged: (v) =>
                            setSheet(() => selected = v ?? selected),
                        child: Column(
                          children: categories
                              .map((key) => RadioListTile<String>(
                                    value: key,
                                    dense: true,
                                    title: Text(t(key),
                                        style: TextStyle(
                                            fontSize: 16,
                                            color: ctx.cs.onSurface)),
                                  ))
                              .toList(),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                        child: TextField(
                          controller: noteCtrl,
                          minLines: 1,
                          maxLines: 3,
                          maxLength: 200,
                          style:
                              TextStyle(fontSize: 15, color: ctx.cs.onSurface),
                          decoration: InputDecoration(
                            hintText: t('convSetReportNoteHint'),
                            hintStyle: TextStyle(
                                fontSize: 15, color: ctx.cs.onSurfaceVariant),
                            counterText: '',
                            isDense: true,
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppTheme.primary,
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(46),
                          ),
                          onPressed: () => Navigator.of(ctx).pop(true),
                          child: Text(t('convSetReportSubmit'),
                              style: const TextStyle(fontSize: 16)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (ok != true) return;
    try {
      final convId = await _ensureConv();
      if (!mounted) return;
      await _convSvc.reportConversation(
        convId: convId,
        peerId: _id,
        category: selected,
        note: noteCtrl.text.trim(),
      );
      if (!mounted) return;
      AppDialogs.toast(context, t('fdpReportDone'));
    } on ApiException catch (e) {
      if (!mounted) return;
      AppDialogs.toast(context, e.message);
    } catch (_) {
      if (!mounted) return;
      AppDialogs.toast(context, t('convSetGetPeerFailed'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return Scaffold(
      backgroundColor: context.setPageBg,
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          _header(),
          SizedBox(height: _kHeaderToCard * s),
          // ---- 卡1：个人简介（签名为空 → 整卡不渲染，2026-09-15 第十批；
          //      原「这个人很懒…」兜底已按需求删除，不伪造文案） ----
          if (_signature().isNotEmpty) ...[
            V2SetCard(rows: [_introCardBody()]),
            SizedBox(height: _kCardGap * s),
          ],
          // ---- 卡2：媒体统计 4 行 ----
          V2SetCard(rows: [
            _statRow(Icons.image_outlined, 'fdpPhotos', 61.6),
            _statRow(Icons.link_rounded, 'fdpLinks', 61.6),
            _statRow(Icons.insert_drive_file_outlined, 'fdpFiles', 61.6),
            _statRow(Icons.mic_none, 'fdpVoice', 61.6),
          ]),
          SizedBox(height: _kCardGap * s),
          // ---- 卡3：共同群组 + TA 的朋友圈（2026-09-15 第十三批：两张卡合并
          //      为一张卡内的两行，行间细分隔线由 V2SetCard 自动插入；
          //      commonGroupCount 键不存在（groupVisible=nobody 或聊天窗口路径
          //      未拼装）时只渲染朋友圈一行，整卡不消失） ----
          V2SetCard(rows: [
            if (f['commonGroupCount'] != null) _commonGroupRow(),
            _momentsRow(),
          ]),
          SizedBox(height: _kCardGap * s),
          // ---- 卡4：免打扰 + 清空记录 / 屏蔽 / 举报 ----
          V2SetCard(rows: [
            _muteRow(),
            _dangerRow(
              icon: Icons.delete_sweep,
              labelKey: 'fdpClearHistory',
              color: const Color(0xFFFF9500),
              onTap: _confirmClearHistory,
              chevron: true,
            ),
            _dangerRow(
              icon: Icons.block,
              labelKey: 'fdpBlock',
              color: context.setDanger,
              onTap: _confirmBlock,
            ),
            _dangerRow(
              icon: Icons.report_outlined,
              labelKey: 'fdpReport',
              color: context.setDanger,
              onTap: _report,
            ),
          ]),
          SizedBox(height: 40 * s + MediaQuery.paddingOf(context).bottom),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------
  // 顶部（模糊背景 + 头像 + 名字 + 4 个圆形按钮）
  // --------------------------------------------------------------------------

  Widget _header() {
    final s = v2Scale(context);
    final top = MediaQuery.paddingOf(context).top;
    // 自适应定高（溢出根因修复，2026-09-15 第八批）：
    // 内部各实测子项之和 = 74.3+107+15+26(徽标)+13.3+18.5+28.45+82.7(按钮列)
    //   +12.75 = 378.0，而参考头部体高 377.0 —— 差值来自逐项 ink 测量的累积
    //   取整误差；再叠加文本行高按物理像素取整的 ε（用户设备实测
    //   BOTTOM OVERFLOWED BY 0.743px，widget test 复现 0.700px）。
    // 固定 377 容器装 378 内容必然溢出。这里改为 Stack 由内容 Column 自撑
    // 高度、`_kHeaderBody` 只作为最小高度下限（ConstrainedBox.minHeight），
    // 参考间距一个不动，任何字体/文本缩放下都不会再溢出。
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: top + _kHeaderBody * s),
      child: Stack(
        children: [
          Positioned.fill(child: _headerBackdrop()),
          // 返回箭头（实测 ink 12.7 × 21.0、ink 左缘 23.0、ink 中心 y 87.2）
          Positioned(
            left: 13.0 * s,
            top: top + 12.7 * s,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).maybePop(),
              child: SizedBox(
                width: 31 * s,
                height: 31 * s,
                child: Icon(Icons.arrow_back_ios_new,
                    size: 31 * s, color: Colors.white),
              ),
            ),
          ),
          // 「⋯」（实测 ink 20.7 × 5.3、右缘 399.7、ink 中心 y 87.3）
          Positioned(
            right: 16.0 * s,
            top: top + 14.3 * s,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _showMoreSheet,
              child: SizedBox(
                width: 30 * s,
                height: 30 * s,
                child:
                    Icon(Icons.more_horiz, size: 30 * s, color: Colors.white),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.only(top: top),
            child: Column(
              children: [
                // 实测：头像顶 133.3 = 状态栏 59 + 74.3；底部 240.3
                SizedBox(height: 74.3 * s),
                // 头像：外径 107 白环 4.7
                // Hero 目标端：与通讯录好友行头像同 tag，push 时缩放定位飞行
                // （2026-09-20 动效规范 2：列表头像圆 → 资料页大头像圆，位置连续）
                Hero(
                  tag: 'hero-contact-avatar-${widget.friend['id'] ?? ''}',
                  child: Container(
                    width: _kAvatarD * s,
                    height: _kAvatarD * s,
                    padding: EdgeInsets.all(_kAvatarRing * s),
                    decoration: const BoxDecoration(
                        shape: BoxShape.circle, color: Colors.white),
                    child: AppAvatar(
                      url: _avatarUrl,
                      name: _name,
                      size: (_kAvatarD - _kAvatarRing * 2) * s,
                    ),
                  ),
                ),
                SizedBox(height: 15.0 * s),
                // 名字 + 星形认证徽（两人整体居中）
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        _name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 25.0 * s,
                          fontWeight: FontWeight.w600,
                          height: 1.0,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    // V 盾仅对方用户组=客服（role=3）才显示（2026-09-15 第十批；
                    // 契约已上线：/user/:id、/friend/list 的 PublicUser.role 与
                    // 会话列表 peerRole，由 fromConv / contacts 注入 friend['role']）。
                    // ⚠️ 群成员列表的 role 是群内角色，同名不同义，勿用。
                    if (_isKefu) ...[
                      SizedBox(width: 7.7 * s),
                      const V2SealBadge(size: 26, color: Color(0xFF4FA4EE)),
                    ],
                  ],
                ),
                // 短 ID 行（2026-09-25 需求）：昵称下方「ID: 10005」。
                // shortId 缺失（极端：直构 map 且 /user/:id 还没回来）整行不占位
                if (_shortId.isNotEmpty) ...[
                  SizedBox(height: 6.7 * s),
                  Text('ID: $_shortId',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 15.0 * s,
                        height: 1.0,
                        color: Colors.white.withValues(alpha: 0.75),
                      )),
                ],
                SizedBox(height: 13.3 * s),
                // 副标题：最近上线时间（2026-09-15 第十批：原 signature 占位
                // 「加载中...」改为需求要求的 lastLoginAt；相对时间文案与
                // conv_settings 顶部一致）。数据源：会话列表单聊项
                // conversation.lastLoginAt（friend/list 入口暂无该字段 → 只占位）。
                SizedBox(
                  height: 18.5 * s,
                  child: _lastSeenText().isEmpty
                      ? null
                      : Text(
                          _lastSeenText(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 18.5 * s,
                            height: 1.0,
                            color: Colors.white.withValues(alpha: 0.82),
                          ),
                        ),
                ),
                SizedBox(height: 28.45 * s),
                _actionRow(),
                // 标签 ink 底 422.3 → 头部底边 436 的留白
                SizedBox(height: 12.75 * s),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 签名（后端 user.signature 字段，好友列表接口直接下发）
  String _signature() => (f['signature'] ?? '').toString().trim();

  /// 对方短 ID（头部「ID: 」行用）：fromConv 注入 ConvItem.peerShortId；
  /// 扫码陌生人等直构 map 缺失时由 _loadDetail 拉 /user/:id 补。
  String get _shortId => (f['shortId'] ?? '').toString().trim();

  /// 对方用户组是否客服（RoleKefu=3，im-server/internal/model/user.go:19）。
  /// 契约已上线（2026-09-15）：PublicUser.role（/user/:id、/friend/list）与
  /// 会话列表 peerRole（fromConv 注入）。判定收口到 CertBadge.isKefu
  /// （2026-09-15 第十三批，与消息列表 / 聊天窗口共用同一处）。
  bool get _isKefu => CertBadge.isKefu(f['role']);

  /// 最近上线时间文案（头部副标题）。与 `conv_settings_page._lastSeenText`
  /// 的相对时间规则保持一致（刚刚 / n 分钟前 / n 小时前 / n 天前 / yyyy-MM-dd）；
  /// 复用既有词条，不新增 key。无 lastLoginAt 数据（如 /friend/list 入口）
  /// 返回空串 → 头部只保留占位高度。
  String _lastSeenText() {
    final t = AppLocalizations.of(context).t;
    final dt = DateTime.tryParse((f['lastLoginAt'] ?? '').toString());
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt);
    final time = diff.inMinutes < 1
        ? t('timeJustNow')
        : diff.inMinutes < 60
            ? t('timeMinAgo', {'n': '${diff.inMinutes}'})
            : diff.inHours < 24
                ? t('timeHourAgo', {'n': '${diff.inHours}'})
                : diff.inDays < 7
                    ? t('timeDayAgo', {'n': '${diff.inDays}'})
                    : '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    return t('convSetLastSeen', {'time': time});
  }

  /// 聊天/名片等入口经 [FriendDetailPage.fromConv] 进来时 friend map 没有
  /// signature 键（会话接口不下发用户签名）——这里拉一次 GET /user/:id
  /// （PublicUser 含 signature 与 role；24h 进程内缓存）补齐，让简介卡能
  /// 显示真数据。注意 /user/:id **不返回 lastLoginAt**（隐私收敛，仅
  /// /friend/list 与会话列表下发），故此处不覆盖该字段。
  /// 好友列表入口（contacts/扫码好友）的 map 自带 signature 键 → 不重复请求。
  /// 二十六批：**role 缺失也要拉**——聊天窗口「…查看资料」路径（fromConv）
  /// 的会话快照不带 peerRole，以前这里直接 return，客服勾永远出不来。
  Future<void> _loadDetail() async {
    if (_id.isEmpty) return;
    // signature 缺失（简介卡要真数据）、role 缺失（客服勾判定）或 shortId
    // 缺失（头部「ID: 」行，2026-09-25）才需要拉
    final needSig = !f.containsKey('signature');
    final needRole = f['role'] == null;
    final needShortId =
        (f['shortId'] ?? '').toString().trim().isEmpty;
    if (!needSig && !needRole && !needShortId) return;
    try {
      final d = await _svc.userDetail(_id);
      if (!mounted) return;
      setState(() {
        final sig = d['signature']?.toString();
        if (sig != null) f['signature'] = sig;
        // role 顺带补齐（扫码陌生人→ /user/:id 也有 role；lastLoginAt 不覆盖）
        final r = d['role'];
        if (r != null) f['role'] = r;
        // 短 ID 补齐（头部「ID: 」行）：/user/:id 的 PublicUser.shortId
        final sid = d['shortId']?.toString();
        if (sid != null && sid.isNotEmpty) f['shortId'] = sid;
      });
    } catch (_) {
      // 拉不到就保持现状（简介卡不渲染），不打断页面
    }
  }

  /// 模糊头像背景。参考包里是一张涂鸦壁纸的模糊版，assets 里没有该图，
  /// 这里用好友头像放大模糊 + 深色蒙版近似（纯数据驱动，不引入编造素材）。
  Widget _headerBackdrop() {
    final url = _avatarUrl;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF6D717A), Color(0xFF8A8E97), Color(0xFF696D73)],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (url.isNotEmpty)
            ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 40, sigmaY: 40),
              child: Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          // 花纹线稿（2026-09-15 第十二批：背景 = 纯色 + 花纹，参照
          // me_page 头部写法：assets/me_header_doodle.png 白色线稿透明 PNG，
          // cover 满铺，资产加载失败退化为纯渐变）。
          IgnorePointer(
            child: Image.asset(
              'assets/me_header_doodle.png',
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
          // 深色蒙版：实测圆形按钮底色为「黑 @33%」叠在模糊背景上，
          // 整块背景也需要压暗才能让白色文字达到实测对比度。
          Container(color: Colors.black.withValues(alpha: 0.34)),
        ],
      ),
    );
  }

  Widget _actionRow() {
    final s = v2Scale(context);
    final items = <List<String>>[
      ['fdpMessages', 'msg'],
      ['fdpCall', 'voice'],
      ['fdpVideo', 'video'],
      ['fdpSearch', 'search'],
    ];
    final icons = <IconData>[
      Icons.chat_bubble_outline_rounded,
      Icons.phone_outlined,
      Icons.videocam_outlined,
      Icons.search_rounded,
    ];
    final children = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      final key = items[i][0];
      final kind = items[i][1];
      children.add(SizedBox(
        width: _kActionD * s,
        child: Column(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                switch (kind) {
                  case 'msg':
                    _sendMsg();
                  case 'voice':
                    _call(false);
                  case 'video':
                    _call(true);
                  case 'search':
                    Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const SearchPage()));
                }
              },
              child: Container(
                width: _kActionD * s,
                height: _kActionD * s,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0x54000000), // 黑 33%（实测圆形底色）
                ),
                child: Icon(icons[i], size: 26 * s, color: Colors.white),
              ),
            ),
            SizedBox(height: 10.9 * s),
            Text(
              AppLocalizations.of(context).t(key),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15.3 * s,
                height: 1.0,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ));
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 31.75 * s),
      child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: children),
    );
  }

  // --------------------------------------------------------------------------
  // 卡片内容
  // --------------------------------------------------------------------------

  /// 卡1：个人简介 + 签名
  Widget _introCardBody() {
    final s = v2Scale(context);
    final body = _signature();
    return Padding(
      padding: EdgeInsets.fromLTRB(26.6 * s, 26 * s, 26.6 * s, 27.5 * s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocalizations.of(context).t('fdpIntro'),
            style: TextStyle(
              fontSize: 16.6 * s,
              height: 1.0,
              color: context.setLabel,
            ),
          ),
          SizedBox(height: 14.3 * s),
          Text(
            // 参考截图默认文案「这个人很懒，什么都没留下」由后端 signature 下发；
            // 为空时不留文案（不硬编假的默认值）。
            body,
            style: TextStyle(
              fontSize: 21.3 * s,
              height: 1.0,
              color: context.setTitle,
            ),
          ),
        ],
      ),
    );
  }

  /// 统计行：左图标 + 标题 +（有数据时）右侧数字 + 箭头。
  /// 点击 → 媒体筛选列表页（2026-09-15 第十二批二轮接真：
  /// GET /message/filter，key→type 映射见 [mediaTypeOf]）。
  Widget _statRow(IconData icon, String key, double height) {
    final s = v2Scale(context);
    return _rowShell(
      height: height,
      onTap: () {
        if (_convId.isEmpty) {
          // 无会话数据（如通讯录直进）→ 先拿会话 id 再进筛选页
          _ensureConv().then((convId) {
            if (!mounted) return;
            if (convId.isEmpty) {
              AppDialogs.toast(context,
                  AppLocalizations.of(context).t('convSetGetPeerFailed'));
              return;
            }
            _pushMediaFilter(key, convId);
          });
          return;
        }
        _pushMediaFilter(key, _convId);
      },
      children: [
        Icon(icon, size: 30 * s, color: context.setTitle),
        Expanded(
          child: Text(
            AppLocalizations.of(context).t(key),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 21.1 * s, height: 1.0, color: context.setTitle),
          ),
        ),
        // ⚠️ 参考截图这里各有一个「0」。后端没有好友维度的媒体计数接口
        //（无 photosCount / linksCount / filesCount / voiceCount 字段），
        // 按「不要伪造数据」的要求这里**不显示数字**（宁缺勿假）。
        _chevron(),
      ],
    );
  }

  /// 词条 key → message/filter 的 type（API.md :1382 五种之一）
  String mediaTypeOf(String key) => switch (key) {
        'fdpPhotos' => 'image',
        'fdpLinks' => 'link',
        'fdpFiles' => 'file',
        'fdpVoice' => 'voice',
        _ => 'image',
      };

  void _pushMediaFilter(String key, String convId) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => MediaFilterPage(
            title: AppLocalizations.of(context).t(key),
            convId: convId,
            type: mediaTypeOf(key))));
  }

  /// 共同群组行（点击 → 共同群组列表页，2026-09-15 第十二批二轮接真：
  /// GET /user/:id/mutual-groups，群卡点击进群聊会话）
  Widget _commonGroupRow() {
    final s = v2Scale(context);
    final raw = f['commonGroupCount'];
    // 容错解析：契约是数字，但万一以字符串下发也不至于让整页崩掉；
    // 0 是合法值（键存在=可见，「0 个共同群组」照常渲染）
    final count = int.tryParse(raw.toString()) ?? 0;
    return _rowShell(
      height: 61.7,
      onTap: _id.isEmpty
          ? null
          : () {
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      MutualGroupsPage(userId: _id, myId: widget.myId)));
            },
      children: [
        Icon(Icons.people_alt, size: 30 * s, color: const Color(0xFF4CAF50)),
        Expanded(
          child: Text(
            AppLocalizations.of(context)
                .t('fdpCommonGroups', {'count': '$count'}),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 21.1 * s, height: 1.0, color: context.setTitle),
          ),
        ),
        _chevron(),
      ],
    );
  }

  /// TA 的朋友圈（2026-09-15 第十三批：点击直接进对方（[_id]）的朋友圈页；
  /// MomentsPage 支持 userId 参数，数据层走 MomentService.listByUser 查他人动态）
  Widget _momentsRow() {
    final s = v2Scale(context);
    return _rowShell(
      height: 61.6,
      onTap: _id.isEmpty ? null : _openMoments,
      children: [
        Icon(Icons.photo_album_outlined,
            size: 30 * s, color: const Color(0xFFF59913)),
        Expanded(
          child: Text(
            AppLocalizations.of(context).t('fdpMomentsTitle'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 21.1 * s, height: 1.0, color: context.setTitle),
          ),
        ),
        _chevron(),
      ],
    );
  }

  /// 消息免打扰行（实测行高 92.7，开关右缘距卡右 25.3）
  Widget _muteRow() {
    final s = v2Scale(context);
    return SizedBox(
      height: 92.7 * s,
      child: Row(
        children: [
          SizedBox(width: _kRowIconLeft * s),
          SizedBox(
            width: _kRowIconBox * s,
            child: Icon(Icons.notifications_active_outlined,
                size: 30 * s, color: context.setTitle),
          ),
          SizedBox(width: (_kRowTextLeft - _kRowIconLeft - _kRowIconBox) * s),
          Expanded(
            child: Text(
              AppLocalizations.of(context).t('convSetMute'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 21.1 * s, height: 1.0, color: context.setTitle),
            ),
          ),
          V2SetSwitch(value: _mute, onChanged: _toggleMute),
          SizedBox(width: 25.3 * s),
        ],
      ),
    );
  }

  /// 彩色行（清空聊天记录 / 屏蔽用户 / 举报）
  Widget _dangerRow({
    required IconData icon,
    required String labelKey,
    required Color color,
    required VoidCallback onTap,
    bool chevron = false,
  }) {
    final s = v2Scale(context);
    return _rowShell(
      height: 61.6,
      onTap: onTap,
      children: [
        Icon(icon, size: 30 * s, color: color),
        Expanded(
          child: Text(
            AppLocalizations.of(context).t(labelKey),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 21.3 * s, height: 1.0, color: color),
          ),
        ),
        if (chevron) _chevron(),
      ],
    );
  }

  Widget _chevron() {
    final s = v2Scale(context);
    return Padding(
      padding: EdgeInsets.only(right: _kRowTailRight * s),
      child: Icon(Icons.chevron_right, size: 24 * s, color: context.setChevron),
    );
  }

  /// 行外壳：统一「图标盒 + 文字」的左基线，供上面几种行复用
  Widget _rowShell({
    required double height,
    required List<Widget> children,
    VoidCallback? onTap,
  }) {
    final s = v2Scale(context);
    final body = SizedBox(
      height: height * s,
      child: Row(
        children: [
          SizedBox(width: _kRowIconLeft * s),
          SizedBox(width: _kRowIconBox * s, child: children.first),
          SizedBox(width: (_kRowTextLeft - _kRowIconLeft - _kRowIconBox) * s),
          ...children.sublist(1),
        ],
      ),
    );
    if (onTap == null) return body;
    return Material(
        color: Colors.transparent, child: InkWell(onTap: onTap, child: body));
  }
}
