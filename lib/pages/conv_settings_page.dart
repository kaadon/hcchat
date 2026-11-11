import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:image_picker/image_picker.dart';

import '../l10n/app_locale.dart';
import '../config/app_config.dart';
import '../services/api_client.dart';
import '../services/call_service.dart';
import '../services/conversation_service.dart';
import '../services/friend_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/v2_kit.dart';
import '../widgets/v2_seal_badge.dart';
import '../widgets/v2_settings.dart';
import 'chat_page.dart';
import 'friend_detail_page.dart';
import 'group_manage_page.dart';
import 'group_members_page.dart';
import 'group_qr_page.dart';
import 'video_call_page.dart';
import 'voice_call_page.dart';
import 'moments_page.dart';
import 'forward_picker_page.dart';
import 'user_qr_profile_page.dart';
import 'group/group_file_page.dart';
import '../widgets/transitions.dart';

// ============================================================================
// 会话设置（单聊 / 群聊共用）：标题「聊天信息」
//
// ⚠️ **本页没有参考图**，按 `lib/widgets/v2_settings.dart` 的通用规范实现。
//    （曾误判 `clipboard-…-734Z-cc352b24.jpg` / `…-740Z-e83137d6.jpg` 是本页参考图；
//      实测尺寸逐位吻合证明它们分别是 `friend_detail_page.dart`（1260×3863）与
//      `group_manage_page.dart`（1260×5331）的参考图，本页并无对应截图。
//      详见 UI-ref/measure/audit_conv_profile.md。）
//
// 骨架选型：**A 型**（`V2SetScaffold` 不传 bg / headerBg / backSpec）
//   * 页底色 = 头部底色 = `#F6F7F9`（没有 B 型的白色条带）
//   * 返回图标 = `V2SetBackSpec.full`（实心 ←，ink 21.0）
//   * 分组标题走 A 型默认：left 22.0 / 字号 15 / 色 `#6B727D`
//   理由：同为「聊天域」的 `chat_settings_page.dart` 是 A 型；本页原本就是
//   页面底色 + 自绘内容，没有设备/通知/数据那类「顶部三段白条带」结构。
//   间距节奏统一用 `V2SetGap.beforeLabel()(35.4)` / `.afterLabel()(18.4)` /
//   `.betweenCards()(31.3)`；卡片统一 `V2SetCard`（左 20.7 / 宽 378.7 / 圆角 16）。
//
// 业务保留清单（改前有 → 改后仍有；逐项核对见 audit_conv_profile.md）：
//   [单聊] 发消息 / 设备注（真实保存+回显）/ 看朋友圈 / 消息免打扰 / 置顶聊天 /
//          清空聊天记录 / 删除好友 / 投诉（sheet，2026-09-15 第九批由「加入黑名单」
//          行改列；拉黑保留于好友资料页）/ 语音通话 / 视频通话 /
//          复制对方 ID（靓号走徽标）/ 右上「⋯」→ 转发名片 + 设置备注 /
//          顶部新增「个人资料」入口 → V2 `FriendDetailPage`
//   [群聊] 群头像更换（群主）/ 改群名（群主）/ 复制群号 / 置顶消息（多条左右切换 +
//          点击跳转定位）/ 成员预览（隐私模式下截断并提示）/ 邀请 + 移除（有管理权）/
//          群公告查看编辑 / 群二维码 / 群文件 / 顶部新增「群聊资料」入口 →
//          `GroupManagePage` / 消息免打扰 / 置顶聊天 / 清空聊天记录 /
//          退出群聊 / 解散群聊（群主）
// ============================================================================

/// 群文件入口文案。**l10n 缺键（本轮未修）**：`lib/l10n/app_locale.dart` 里没有
/// `群文件` 对应词条，原实现就是硬编码字面量。本轮不改 `app_locale.dart`，
/// 若改成新 key 会在运行时回显 key 名（`t()` 缺键回显），所以维持字面量原样，
/// 只把它记进报告，下一批统一补词条时一并处理（建议 key：`convSetGroupFiles`）。
const String _kGroupFilesLabel = '群文件';

/// 会话设置：单聊 / 群聊统一为「聊天信息」（V2 外观）
class ConvSettingsPage extends StatefulWidget {
  final ConvItem conv;
  const ConvSettingsPage({super.key, required this.conv});

  @override
  State<ConvSettingsPage> createState() => _ConvSettingsPageState();
}

class _ConvSettingsPageState extends State<ConvSettingsPage> {
  final _svc = ConversationService();
  final _friendSvc = FriendService();
  bool _pinned = false;
  bool _mute = false;
  late String _remark;
  List<Map<String, dynamic>> _members = [];
  List<Map<String, dynamic>> _pinnedMsgs = [];
  int _pinIndex = 0;
  String? _myId;
  // 单聊对方靓号信息（从成员接口自取，覆盖所有进入路径的显示一致性）
  String _peerShortId = '';
  bool _peerVip = false;
  // 群聊管理相关
  bool _uploadingAvatar = false;
  bool _privacyOn = false; // 老服务端兼容：成员接口报 4006 时置位
  Map<String, dynamic> _groupSettings = {}; // 群设置（普通成员可读，判断成员隐私）
  String _avatarOverride = ''; // 群主刚上传的头像（本地立即生效，不等列表刷新）
  String _nameOverride = ''; // 群主刚改的群名（本地立即生效）

  bool get isGroup => (widget.conv.conversation['type'] as num?)?.toInt() == 2;

  /// 频道会话（type=3，chat_page.dart:512 同口径）：设置页走频道分支
  bool get isChannel =>
      (widget.conv.conversation['type'] as num?)?.toInt() == 3;

  String get _groupName =>
      _nameOverride.isNotEmpty ? _nameOverride : widget.conv.conversationName;

  String get _avatarUrl =>
      _avatarOverride.isNotEmpty ? _avatarOverride : widget.conv.avatarUrl;

  String get _announcement =>
      widget.conv.conversation['announcementZh']?.toString() ?? '';

  bool get _isOwner {
    if (_myId == null) return false;
    return _members.any((m) {
      final role = m['role'];
      final uid = m['id']?.toString() ?? m['userId']?.toString() ?? '';
      return (role == 1 || role == '1' || role?.toString() == 'owner') &&
          uid == _myId;
    });
  }

  /// 群主或管理员（成员管理操作用）
  bool get _isManager {
    if (_myId == null) return false;
    return _members.any((m) {
      final role = (m['role'] as num?)?.toInt() ?? 3;
      final uid = m['id']?.toString() ?? m['userId']?.toString() ?? '';
      return uid == _myId && (role == 1 || role == 2);
    });
  }

  /// 成员隐私限制，满足任一即受限：
  /// ① 服务端以 4006 明确拦我（老服务端兜底，即我是普通成员）；或
  /// ② 群设置 privacyEnabled 开启且我不是群主/管理员（服务端现行只对
  ///    普通成员把列表截断为 15 条、不报 4006，必须用设置+角色判定）。
  /// 群主/管理员永远在截断白名单前排（排序 role ASC），_isManager 必然命中 → 不受限。
  bool get _privacyLimited {
    if (_privacyOn) return true;
    if (_groupSettings['privacyEnabled'] != true) return false;
    return !_isManager;
  }

  /// 需求4（2026-09-22）：群未开启「二维码进群」→ 聊天信息页群二维码区块
  /// 对普通成员隐藏（群主/管理员仍可见，便于重新开启）；仅显式 false 才隐藏，
  /// 老服务端缺字段（null）保持显示。
  bool get _qrJoinDisabled => _groupSettings['qrJoinEnabled'] == false;

  @override
  void initState() {
    super.initState();
    _pinned = widget.conv.pinned;
    _mute = widget.conv.mute;
    _remark = widget.conv.peerRemark;
    _loadProfile();
    if (isGroup) {
      _loadMembers();
      _loadPinned();
      _loadGroupSettings();
    }
  }

  /// 群设置（普通成员也可读）：判断成员隐私是否开启
  Future<void> _loadGroupSettings() async {
    try {
      final s = await _svc.groupSettings(widget.conv.id);
      if (mounted) setState(() => _groupSettings = s);
    } catch (_) {}
  }

  Future<void> _loadProfile() async {
    try {
      final p = await _friendSvc.profile();
      if (mounted) {
        setState(() => _myId = p['id']?.toString());
        // 单聊：从成员接口自取对方靓号信息（会话列表/通讯录/新会话等
        // 各入口构造的 ConvItem 不一定带 peerShortId，这里兜底保证显示一致）
        // 频道不走成员接口自取（频道无「对方」概念，ID 从会话数据读）
        if (!isGroup && !isChannel) await _loadDirectPeer();
      }
    } catch (_) {}
  }

  Future<void> _loadDirectPeer() async {
    try {
      final list = await _svc.members(widget.conv.id);
      for (final m in list) {
        final uid = m['id']?.toString() ?? m['userId']?.toString() ?? '';
        if (uid.isNotEmpty && uid != _myId) {
          if (!mounted) return;
          setState(() {
            _peerShortId = m['shortId']?.toString() ?? '';
            _peerVip = m['vipShortId'] == true;
          });
          return;
        }
      }
    } catch (_) {}
  }

  Future<void> _loadMembers() async {
    try {
      final list = await _svc.members(widget.conv.id);
      if (mounted) {
        setState(() {
          _members = list;
          _privacyOn = false;
        });
      }
    } on ApiException catch (e) {
      // 4006：群主开启成员隐私 → 普通成员显示隐私提示而不是报错
      if (e.code == 4006 && mounted) {
        setState(() {
          _members = [];
          _privacyOn = true;
        });
      }
    } catch (_) {}
  }

  /// 加载群置顶消息列表（多条，需求：支持点击切换 + 跳转）
  Future<void> _loadPinned() async {
    try {
      final list = await _svc.pinnedMessages(widget.conv.id);
      if (mounted) {
        setState(() {
          _pinnedMsgs = list;
          _pinIndex = 0;
        });
      }
    } catch (_) {}
  }

  /// 需求2（2026-09-22 二批）：群主在聊天信息页删除当前置顶消息（取消置顶）。
  /// 服务端 PUT /conversation/:id/pin-message，pinned=false 按 msgId 移除。
  Future<void> _unpinCurrent() async {
    if (_pinnedMsgs.isEmpty) return;
    final t = AppLocalizations.of(context).t;
    final p = _pinnedMsgs[_pinIndex];
    final msgId = p['msgId']?.toString() ?? '';
    if (msgId.isEmpty || msgId == '0') return;
    final ok =
        await _svc.setPinMessage(widget.conv.id, msgId, '', pinned: false);
    if (ok && mounted) {
      AppDialogs.toast(context, t('convSetUnpinDone'));
      await _loadPinned();
    }
  }

  Future<void> _togglePin(bool v) async {
    final ok = await _svc.setPin(widget.conv.id, v);
    if (ok && mounted) setState(() => _pinned = v);
  }

  Future<void> _toggleMute(bool v) async {
    final ok = await _svc.setMute(widget.conv.id, v);
    if (ok && mounted) setState(() => _mute = v);
  }

  Future<void> _exit() async {
    final ok = await _svc.quit(widget.conv.id);
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  Future<void> _disband() async {
    final ok = await _svc.disband(widget.conv.id);
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  /// 单聊对方用户 id（members 里非自己的成员）
  Future<String> _peerId() async {
    try {
      final list = await _svc.members(widget.conv.id);
      for (final m in list) {
        final uid = m['id']?.toString() ?? m['userId']?.toString() ?? '';
        if (uid.isNotEmpty && uid != _myId) return uid;
      }
    } catch (_) {}
    return '';
  }

  /// 设置备注（需求：真实保存 + 回显）
  Future<void> _setRemark() async {
    final t = AppLocalizations.of(context).t;
    final result = await AppDialogs.input(
      context,
      title: t('convSetRemarkTitle'),
      hint: t('convSetRemarkName'),
      maxLines: 1,
      maxLength: 20,
      initialValue: _remark.isEmpty ? null : _remark,
    );
    if (result == null || result.isEmpty) return;
    final pid = await _peerId();
    if (pid.isEmpty) {
      if (mounted) AppDialogs.toast(context, t('convSetGetPeerFailed'));
      return;
    }
    final ok = await _friendSvc.setRemark(pid, result);
    if (ok && mounted) {
      setState(() => _remark = result);
      AppDialogs.toast(context, t('convSetRemarkSaved'));
    }
  }

  // ===== AppBar「...」菜单：转发名片 / 设置备注（十六批起群聊也提供转发名片） =====

  String _uuid() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(99999)}';

  void _showMoreSheet() {
    final t = AppLocalizations.of(context).t;
    // 群/频道：只有转发名片（备注/朋友圈是单聊概念，不展示）。
    // 频道（十七批）也走本页「…」菜单，「转发名片」支持频道名片。
    AppDialogs.actionSheet(
      context,
      actions: [
        DialogAction(
          label: t('forwardCardTitle'),
          icon: Icons.share_outlined,
          onTap: _forwardCard,
        ),
        // 需求4（2026-09-22）：群聊在转发名片旁增加「群管理」入口（仅群主可见），
        // 直达群管理设置页（二维码进群/成员隐私/全员禁言/允许邀请/显示成员开关/管理员）
        if (isGroup && _isOwner)
          DialogAction(
            label: t('convSetGroupAdmin'),
            icon: Icons.manage_accounts_outlined,
            onTap: _openGroupAdmin,
          ),
        if (!isGroup && !isChannel)
          DialogAction(
            label: t('friendDetailSetRemark'),
            icon: Icons.edit_outlined,
            onTap: _setRemark,
          ),
      ],
    );
  }

  /// 需求4（2026-09-22）：跳转群管理设置页（openGroupSettingsPage 为
  /// group_manage_page.dart 提供的公开导航函数，_GroupSettingsPage 私有）。
  /// 返回后刷新群设置/成员（显示成员开关可能被改动）
  Future<void> _openGroupAdmin() async {
    await openGroupSettingsPage(context, widget.conv);
    if (mounted) {
      _loadMembers();
      _loadGroupSettings();
    }
  }

  /// 转发名片：选会话 → 发 type=10 名片消息。
  /// * 单聊：content=JSON {"userId","nickname","avatar"}（旧用户名片格式，不动）；
  /// * 群/频道（2026-09-15 十六批修复）：此前群会话无分享入口、频道误走
  ///   用户名片，接收方点击按 user 路径查 /user/:id → 「用户不存在」。
  ///   现按 be-channel 名片契约构造 {"kind":"group"|"channel","id","name","avatar"}，
  ///   解析侧 chat_page._cardKindOf/_openCardProfile 已认该格式。
  Future<void> _forwardCard() async {
    final t = AppLocalizations.of(context).t;
    final convType = (widget.conv.conversation['type'] as num?)?.toInt() ?? 1;
    final myId = _myId ?? '';
    if (myId.isEmpty) return;
    final picked = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => ForwardPickerPage(myId: myId)),
    );
    if (picked == null || !mounted) return;
    final targetId = picked['id']?.toString() ?? '';
    if (targetId.isEmpty) return;
    try {
      // 好友 → 先 createDirect 拿会话 id（字符串）；群/频道 → 直接用会话 id
      String convId;
      if (picked['kind'] == 'group') {
        convId = targetId;
      } else {
        final conv = await _svc.createDirect(targetId);
        convId = conv['id']?.toString() ?? '';
      }
      if (convId.isEmpty) throw Exception('empty conversation id');
      final String content;
      if (convType == 2 || convType == 3) {
        // 群/频道名片：雪花 ID 全程字符串
        content = jsonEncode({
          'kind': convType == 3 ? 'channel' : 'group',
          'id': widget.conv.id,
          'name': _groupName,
          'avatar': _avatarUrl,
        });
      } else {
        final pid = await _peerId();
        if (pid.isEmpty) throw Exception('empty peer id');
        content = jsonEncode({
          'userId': pid,
          'nickname':
              _remark.isNotEmpty ? _remark : widget.conv.conversationName,
          'avatar': _avatarUrl,
        });
      }
      await _svc.sendRaw(convId, 10, content,
          clientMsgId: _uuid()); // code!=0 内部抛错
      if (!mounted) return;
      AppDialogs.toast(context, t('forwardCardDone'));
    } catch (e) {
      if (mounted) {
        AppDialogs.toast(context, t('convSetStartConvFailed', {'error': '$e'}));
      }
    }
  }

  /// 朋友圈入口：查看该好友的全部朋友圈（F-03）
  Future<void> _openMoments() async {
    final t = AppLocalizations.of(context).t;
    final pid = await _peerId();
    if (pid.isEmpty) {
      if (mounted) AppDialogs.toast(context, t('convSetGetPeerFailed'));
      return;
    }
    if (!mounted) return;
    final name = _remark.isNotEmpty ? _remark : widget.conv.conversationName;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => MomentsPage(userId: pid, userName: name)));
  }

  /// 发消息：进入与对方的聊天
  Future<void> _sendMsg() async {
    final t = AppLocalizations.of(context).t;
    final pid = await _peerId();
    if (pid.isEmpty) return;
    try {
      final conv = await _svc.createDirect(pid);
      if (!mounted) return;
      final item = ConvItem.fromJson({
        'conversation': conv,
        'conversationName':
            _remark.isNotEmpty ? _remark : widget.conv.conversationName,
      });
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ChatPage(conv: item, myId: _myId ?? '')));
    } catch (e) {
      if (mounted) {
        AppDialogs.toast(
            context, t('convSetStartConvFailed', {'error': e.toString()}));
      }
    }
  }

  /// 顶部「个人资料」入口 → V2 好友资料页（`FriendDetailPage`）
  ///
  /// `myId` 是资料页建会话/发消息的必需参数，尚未加载出来时（`_loadProfile` 未回）
  /// 先提示而不是开一个发不出消息的空页。
  void _openFriendDetail() {
    final myId = _myId ?? '';
    if (myId.isEmpty) {
      AppDialogs.toast(
          context, AppLocalizations.of(context).t('convSetGetPeerFailed'));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            FriendDetailPage.fromConv(conv: widget.conv, myId: myId)));
  }

  /// 「投诉」底部弹层（2026-09-15 第九批：危险区原「拉黑用户」行改为「投诉」；
  /// 拉黑功能本身保留在好友资料页 `_confirmBlock`，本页不再提供）。
  ///
  /// 结构：投诉类型单选（5 项）+ 可选补充说明 + 提交。
  /// ⚠️ 后端投诉端点未上线 —— 见 `ConversationService.reportConversation`
  /// 的 TODO 契约；提交后以「已收到你的投诉」toast 收尾（前端占位，
  /// 不假装已上送）。
  Future<void> _openReportSheet() async {
    final t = AppLocalizations.of(context).t;
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
                        child: Text(t('convSetReport'),
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
      await _svc.reportConversation(
        convId: widget.conv.id,
        peerId: await _peerId(),
        category: selected,
        note: noteCtrl.text.trim(),
      );
      if (!mounted) return;
      AppDialogs.toast(context, t('convSetReportDone'));
    } on ApiException catch (e) {
      if (!mounted) return;
      AppDialogs.toast(context, e.message);
    }
  }

  /// 单聊对方的 shortId：优先会话数据，缺失时用成员接口自取值兜底
  String get _resolvedPeerShortId => widget.conv.peerShortId.isNotEmpty
      ? widget.conv.peerShortId
      : _peerShortId;

  void _copyId() {
    final v = isGroup ? widget.conv.id : _resolvedPeerShortId;
    if (v.isEmpty) return;
    Clipboard.setData(ClipboardData(text: v));
    final t = AppLocalizations.of(context).t;
    AppDialogs.toast(
        context, isGroup ? t('convSetGroupIdCopied') : t('convSetIdCopied'));
  }

  void _startCall(String type) async {
    final t = AppLocalizations.of(context).t;
    final busy = CallService.instance.state.value != null;
    if (busy) {
      AppDialogs.toast(context, t('convSetCallBusy'));
      return;
    }
    await CallService.instance.startCall(
      convId: widget.conv.id,
      callType: type,
      peerName: widget.conv.conversationName,
      peerAvatar: widget.conv.avatarUrl,
    );
    if (!mounted) return;
    final page = type == 'video'
        ? VideoCallPage(
            peerName: widget.conv.conversationName,
            peerAvatar: widget.conv.avatarUrl,
            convId: widget.conv.id,
          )
        : VoiceCallPage(
            peerName: widget.conv.conversationName,
            peerAvatar: widget.conv.avatarUrl,
            convId: widget.conv.id,
          );
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  void _editAnnouncement() async {
    final t = AppLocalizations.of(context).t;
    final text = await AppDialogs.input(context,
        title: t('convSetAnnouncementTitle'),
        hint: t('convSetAnnouncementHint'),
        initialValue: _announcement,
        maxLines: 4,
        maxLength: 200,
        confirmText: t('convSetSave'));
    if (text == null || !mounted) return;
    final ok = await _svc.updateAnnouncement(widget.conv.id, text, '');
    if (ok && mounted) {
      AppDialogs.toast(context, t('convSetAnnouncementSaved'));
      Navigator.of(context).pop(true);
    }
  }

  /// 查看全部成员 → 群成员页（管理：邀请/移除/禁言/设管理员）
  Future<void> _showMembers() async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => GroupMembersPage(conv: widget.conv)));
    if (mounted) _loadMembers();
  }

  /// 群聊管理页（群主：二维码进群/成员隐私/全员禁言/允许邀请/管理员）
  Future<void> _openGroupManage() async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => GroupManagePage(conv: widget.conv)));
    if (mounted) _loadMembers();
  }

  /// 群主上传群头像：相册选图 → 上传 → 更新会话
  Future<void> _changeGroupAvatar() async {
    if (_uploadingAvatar) return;
    final t = AppLocalizations.of(context).t;
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return;
    setState(() => _uploadingAvatar = true);
    try {
      final up = await ApiClient.instance.uploadXFile(
        picked,
        picked.name.isEmpty ? 'group_avatar.jpg' : picked.name,
        dir: 'avatar/',
      );
      final url = (up['url'] ?? '').toString();
      if (url.isEmpty) throw Exception('upload failed');
      await _svc.updateGroupInfo(widget.conv.id, avatar: url);
      // 回写会话对象：返回会话列表/聊天页立即可见
      widget.conv.conversation['avatar'] = url;
      if (mounted) {
        setState(() => _avatarOverride = url);
        AppDialogs.toast(context, t('groupAvatarUpdated'));
      }
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('groupAvatarUpdateFailed'));
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  /// 群主修改群名（双语同值，App 内单语言展示）
  Future<void> _editGroupName() async {
    final t = AppLocalizations.of(context).t;
    final result = await AppDialogs.input(
      context,
      title: t('groupRenameTitle'),
      hint: t('groupRenameHint'),
      maxLines: 1,
      maxLength: 32,
      initialValue: _nameOverride.isNotEmpty
          ? _nameOverride
          : widget.conv.conversationName,
    );
    if (result == null || result.trim().isEmpty) return;
    final name = result.trim();
    try {
      await _svc.updateGroupInfo(widget.conv.id, name: name);
      widget.conv.conversation['nameZh'] = name;
      widget.conv.conversation['nameEn'] = name;
      if (mounted) {
        setState(() => _nameOverride = name);
        AppDialogs.toast(context, t('groupRenameSaved'));
      }
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('groupRenameFailed'));
    }
  }

  void _clearHistory() async {
    final t = AppLocalizations.of(context).t;
    // 单聊（2026-09-18）：接真「删除聊天记录」——底部弹层选范围
    // （仅为我清空 / 为双方清空），服务端软删位点（消息本体保留），本机同步清缓存。
    if (!isGroup) {
      final scope = await AppDialogs.clearHistorySheet(
        context,
        title: t('clearSheetTitleFmt', {'name': widget.conv.conversationName}),
      );
      if (scope == null || (scope != 'self' && scope != 'both')) return;
      try {
        await _svc.clearHistory(widget.conv.id, scope: scope);
        ConversationService.historyCacheClearConv(widget.conv.id);
        if (mounted) {
          AppDialogs.toast(context, t('convSetHistoryCleared'));
        }
      } catch (e) {
        if (!mounted) return;
        final msg = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
        AppDialogs.toast(context, msg);
      }
      return;
    }
    // 群聊/频道：保留原确认框（服务端暂无按会话清空）
    final ok = await AppDialogs.confirm(context,
        title: t('convSetClearHistoryTitle'),
        message: t('convSetClearHistoryMsg'),
        confirmText: t('convSetClearHistoryConfirm'),
        danger: true);
    if (ok == true && mounted) {
      AppDialogs.toast(context, t('convSetHistoryCleared'));
    }
  }

  Future<void> _deleteFriendOrExit() async {
    final t = AppLocalizations.of(context).t;
    final title = isGroup
        ? (_isOwner
            ? t('convSetDisbandGroupTitle')
            : t('convSetExitGroupTitle'))
        : t('convSetDeleteFriendTitle');
    final msg = isGroup
        ? (_isOwner ? t('convSetDisbandGroupMsg') : t('convSetExitGroupMsg'))
        : t('convSetDeleteFriendMsg');
    final ok = await AppDialogs.confirm(context,
        title: title,
        message: msg,
        confirmText: isGroup
            ? (_isOwner ? t('convSetDisbandConfirm') : t('convSetExitConfirm'))
            : t('convSetDeleteConfirm'),
        danger: true);
    if (ok != true) return;
    if (isGroup) {
      _isOwner ? _disband() : _exit();
    } else {
      // 单聊：先删好友再退出会话（V2.0 完整实现前仅删除会话）
      _exit();
    }
  }

  // ==================== 页面骨架（A 型 V2） ====================

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final t = AppLocalizations.of(context).t;
    return V2SetScaffold(
      title: t('convSetChatInfo'),
      // 首屏是一个卡片（头像/资料入口），没有分组标题，所以顶部留白不用
      // `V2SetGap.beforeLabel()` 的 35.4，取 24 让卡片不贴死头部。
      padding: EdgeInsets.only(top: 24 * s, bottom: 40 * s),
      // 十六批：群聊也显示「...」（转发名片入口；频道会话不经本页，
      // chat_page 侧直接分享），单聊菜单多一项设置备注。
      // 频道分支（十七批）：菜单（转发名片/备注）是单聊/群语义，频道不显示
      actions: isChannel
          ? null
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _showMoreSheet,
              child: SizedBox(
                width: 44 * s,
                height: 44 * s,
                child: Icon(Icons.more_horiz,
                    size: 24 * s, color: context.setTitle),
              )),
      children: isGroup
          ? _groupChildren()
          : isChannel
              ? _channelChildren()
              : _directChildren(),
    );
  }

  // ==================== 单聊：聊天信息 ====================

  List<Widget> _directChildren() {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    return [
      // ---- 头部：头像背景 + 昵称 + 在线/最近上线 + ID（沿用原视觉，数据驱动） ----
      _directHeader(),
      const V2SetGap.betweenCards(),
      // ---- 语音 / 视频通话 ----
      _callButtons(),
      const V2SetGap.betweenCards(),
      // ---- 个人资料入口 → V2 FriendDetailPage ----
      V2SetCard(rows: [
        V2SetRow(
          title: t('convSetPersonalProfile'),
          leading:
              Icon(Icons.badge_outlined, size: 22 * s, color: context.setTitle),
          showChevron: true,
          onTap: _openFriendDetail,
        ),
      ]),
      const V2SetGap.betweenCards(),
      // ---- 常用 ----
      V2SetCard(rows: [
        V2SetRow(
          title: t('convSetSendMessage'),
          leading: Icon(Icons.chat_bubble_outline,
              size: 22 * s, color: context.setTitle),
          showChevron: true,
          onTap: _sendMsg,
        ),
        V2SetRow(
          title: t('convSetRemarkName'),
          leading:
              Icon(Icons.edit_outlined, size: 22 * s, color: context.setTitle),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            V2SetTailText(_remark.isEmpty ? t('convSetNotSet') : _remark),
            SizedBox(width: 12 * s),
            const V2SetChevron(),
          ]),
          onTap: _setRemark,
        ),
        V2SetRow(
          title: t('convSetMoments'),
          leading: Icon(Icons.photo_album_outlined,
              size: 22 * s, color: context.setTitle),
          showChevron: true,
          onTap: _openMoments,
        ),
      ]),
      const V2SetGap.betweenCards(),
      // ---- 会话开关 ----
      V2SetCard(rows: [
        _switchRow(t('convSetMute'), _mute, _toggleMute),
        _switchRow(t('convSetPinChat'), _pinned, _togglePin),
      ]),
      const V2SetGap.betweenCards(),
      // ---- 清空聊天记录 ----
      V2SetCard(rows: [
        V2SetRow(
          title: t('convSetClearHistoryTitle'),
          showChevron: true,
          onTap: _clearHistory,
        ),
      ]),
      const V2SetGap.betweenCards(),
      // ---- 危险操作（白卡内居中红字，与钱包页「退出登录」同款） ----
      V2SetCard(rows: [
        V2SetDangerButton(
          label: t('convSetDeleteFriendTitle'),
          onTap: _deleteFriendOrExit,
          filled: false,
        ),
        V2SetDangerButton(
          label: t('convSetReport'),
          onTap: _openReportSheet,
          filled: false,
        ),
      ]),
    ];
  }

  Widget _directHeader() {
    final t = AppLocalizations.of(context).t;
    final url = AppConfig.assetUrl(widget.conv.avatarUrl);
    final name = widget.conv.conversationName;
    final initial = name.isEmpty ? '?' : name.characters.first;
    // 对方是否靓号（服务端预留池校验，随会话/成员数据下发）
    final shortId = _resolvedPeerShortId;
    final isVipPeer =
        (widget.conv.peerVipShortId || _peerVip) && shortId.isNotEmpty;
    // 在线显示在线+设备；离线且有最近上线记录 → 显示"最近上线 xx"
    final onlineText = widget.conv.peerOnline
        ? (widget.conv.peerOnlineZh.isNotEmpty
            ? widget.conv.peerOnlineZh
            : t('convSetOnline'))
        : _lastSeenText();
    final onlineColor = widget.conv.peerOnline
        ? AppTheme.onlineDot
        : context.cs.onSurfaceVariant;

    // 高度从 1:1 正方形改为 2:1，避免占据过多屏幕，留出更多操作空间
    // （2026-09-15 第十批：整块可点 → V2 FriendDetailPage；昵称右侧客服 V 盾。
    //   「与新好友资料页头部一致」采用最小增强方案：保留本页既有的大图头部与
    //   复制 ID 交互，补齐「昵称+V 盾+上线时间+点按进完整资料页」要素。）
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _openFriendDetail,
      child: AspectRatio(
        aspectRatio: 2.0,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 正方形头像背景：占位常驻底层，加载中/失败都不再白块
            Stack(
              fit: StackFit.expand,
              children: [
                _directAvatarFallback(initial),
                if (url.isNotEmpty)
                  Image.network(
                    url,
                    fit: BoxFit.cover,
                    frameBuilder: (ctx, child, frame, wasSync) =>
                        (wasSync || frame != null)
                            ? child
                            : const SizedBox.shrink(),
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
              ],
            ),
            // 底部渐变遮罩，保证白色文字可读
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.05),
                    Colors.black.withValues(alpha: 0.40),
                  ],
                  stops: const [0.55, 1.0],
                ),
              ),
            ),
            // 昵称（+客服 V 盾） / 在线状态 / ID
            Positioned(
              left: 20,
              right: 20,
              bottom: 24,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            shadows: [
                              Shadow(
                                color: Colors.black54,
                                blurRadius: 6,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // V 盾仅客服显示（与好友资料页同一判定口径）。
                      // 契约已上线（2026-09-15）：会话列表单聊项 peerRole=账号角色
                      // （3=客服；小助手虚拟账号恒 0=无盾），此处直接生效。
                      // ⚠️ 群成员列表的 role 是群内角色，同名不同义，勿用。
                      if (_isPeerKefu) ...[
                        const SizedBox(width: 8),
                        const V2SealBadge(size: 26, color: Color(0xFF4FA4EE)),
                      ],
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: onlineColor,
                          shape: BoxShape.circle,
                          boxShadow: const [
                            BoxShadow(
                              color: Colors.black45,
                              blurRadius: 4,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        onlineText,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.white,
                          shadows: [
                            Shadow(
                              color: Colors.black54,
                              blurRadius: 4,
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 14),
                      Flexible(
                        child: InkWell(
                          onTap: _copyId,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                // 靓号好友只显示「靓ID：xxx」徽标，不再重复显示普通 ID
                                child: isVipPeer
                                    ? Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 1.5),
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                              color: const Color(0xFFE5484D),
                                              width: 1),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          t('vipIdBadge', {'id': shortId}),
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.white,
                                          ),
                                        ),
                                      )
                                    : Text(
                                        'ID: ${shortId.isEmpty ? t('convSetUnknown') : shortId}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          color: Colors.white70,
                                          shadows: [
                                            Shadow(
                                              color: Colors.black54,
                                              blurRadius: 4,
                                              offset: Offset(0, 1),
                                            ),
                                          ],
                                        ),
                                      ),
                              ),
                              if (shortId.isNotEmpty) ...[
                                const SizedBox(width: 4),
                                const Icon(Icons.copy,
                                    size: 14, color: Colors.white70),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 对方是否客服（V 盾显示条件，与 `friend_detail_page._isKefu` 同口径）。
  /// 契约已上线（2026-09-15）：会话列表单聊项 peerRole（3=客服，小助手恒 0）；
  /// contacts 入口由 contacts_page 把 /friend/list 的 role 写进 conversation.peerRole。
  bool get _isPeerKefu {
    // 二十七批：后端 peerRole 在 ConvItem 顶层，conversation map 兜底
    final r = widget.conv.peerRoleAny;
    return r == 3 || r?.toString() == '3';
  }

  Widget _directAvatarFallback(String initial) {
    return Container(
      color: AppTheme.primary.withValues(alpha: 0.12),
      alignment: Alignment.center,
      child: Text(initial,
          style: TextStyle(
              fontSize: 40,
              fontWeight: FontWeight.w600,
              color: AppTheme.primary.withValues(alpha: 0.7))),
    );
  }

  /// 离线状态文案：有最近上线记录显示"最近上线 xx"，否则回退"离线"
  String _lastSeenText() {
    final t = AppLocalizations.of(context).t;
    final dt = DateTime.tryParse(widget.conv.lastLoginAt);
    if (dt == null) return t('convSetOffline');
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

  Widget _callButtons() {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    // 一张 V2 白卡承载两个圆形操作，视觉成组、不散
    return V2SetCard(rows: [
      Padding(
        padding: EdgeInsets.symmetric(vertical: 18 * s),
        child: Row(
          children: [
            Expanded(
              child: _callButton(Icons.phone_outlined, t('convSetVoiceCall'),
                  () => _startCall('voice')),
            ),
            Expanded(
              child: _callButton(Icons.videocam_outlined, t('convSetVideoCall'),
                  () => _startCall('video')),
            ),
          ],
        ),
      ),
    ]);
  }

  Widget _callButton(IconData icon, String label, VoidCallback onTap) {
    // 圆形浅色底图标 + 下方小字（与「我的」页大按钮同款语言），替代色块/描边按钮
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 24, color: AppTheme.primary),
          ),
          const SizedBox(height: 8),
          Text(label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: context.cs.onSurface)),
        ],
      ),
    );
  }

  // ==================== 群聊：聊天信息 ====================

  List<Widget> _groupChildren() {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    return [
      // ---- 群头部（2026-09-15 第十二批：换成与 V2 群资料页一致的头部风格
      //      —— 满宽白底头块 + 居中头像/群名/成员数；群主换头像/改名、群号
      //      复制交互保留；字号间距对齐 group_manage_page 头部规格） ----
      _groupHeadBlock(),
      const V2SetGap.betweenCards(),
      // 需求2（2026-09-22 三批补充）：删除顶部「群管理」入口卡片（用户要求）。
      // 群管理入口仍保留在「…」菜单（仅群主可见），功能不受影响。
      // ---- 置顶消息：多消息支持 + 左右切换 + 点击跳转 ----
      if (_pinnedMsgs.isNotEmpty) ...[
        const V2SetGap.beforeLabel(),
        _sectionHeader(t('convSetPinnedMessages'),
            trailing: _pinnedMsgs.length > 1
                ? '${_pinIndex + 1}/${_pinnedMsgs.length}'
                : null),
        const V2SetGap.afterLabel(),
        V2SetCard(rows: [_pinnedCard()]),
      ],
      // ---- 成员区：隐私开启时普通成员最多 2 排预览（多余不显示、不可查看全部） ----
      // 需求5（2026-09-22）：群级开关 showMembers（仅群主可切换，群管理页）
      // 关闭 → 整个成员卡片区块不渲染；老服务端无该字段（null != false）保持显示
      // 需求3（2026-09-22 二批）：群隐私开启 → 普通成员整个成员卡片不渲染
      // （_privacyLimited 对群主/管理员恒 false，群主仍可见）；老服务端 4006 同样命中
      // 需求3（2026-09-22 三批）：群设置未拉回先不渲染，防止隐私群闪现成员卡片
      if (_groupSettings.isNotEmpty &&
          _groupSettings['showMembers'] != false &&
          !_privacyLimited) ...[
        const V2SetGap.beforeLabel(),
        _membersSection(),
      ],
      // ---- 群公告 ----
      const V2SetGap.beforeLabel(),
      _sectionHeader(t('convSetGroupAnnouncement')),
      const V2SetGap.afterLabel(),
      V2SetCard(rows: [
        V2SetRow(
          title: _announcement.isNotEmpty
              ? _announcement
              : t('convSetNoAnnouncement'),
          subtitle:
              _announcement.isNotEmpty ? t('convSetAnnouncementTime') : null,
          showChevron: true,
          onTap: _editAnnouncement,
        ),
      ]),
      // ---- 群二维码（分享扫码进群） ----
      // 需求4（2026-09-22）：群未开启「二维码进群」→ 普通成员不显示本区块，
      // 群主/管理员仍可见（_qrJoinDisabled 仅在设置显式关闭时为 true）
      if (!_qrJoinDisabled || _isManager) ...[
        const V2SetGap.beforeLabel(),
        _sectionHeader(t('groupQrSection')),
        const V2SetGap.afterLabel(),
        V2SetCard(rows: [
          V2SetRow(
            title: t('groupQrRow'),
            leading:
                Icon(Icons.qr_code_2, size: 22 * s, color: context.setTitle),
            showChevron: true,
            onTap: () => Navigator.of(context).push(
                fadeScaleRoute(GroupQrPage(conv: widget.conv), scale: true)),
          ),
        ]),
      ],
      // ---- 群文件云盘（功能 A）：所有群成员可见 ----
      const V2SetGap.beforeLabel(),
      _sectionHeader(_kGroupFilesLabel),
      const V2SetGap.afterLabel(),
      V2SetCard(rows: [
        V2SetRow(
          title: _kGroupFilesLabel,
          leading: Icon(Icons.folder_outlined,
              size: 22 * s, color: context.setTitle),
          showChevron: true,
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => GroupFilePage(
                  convId: widget.conv.id,
                  convName: widget.conv.conversationName))),
        ),
      ]),
      // ---- 会话开关 ----
      const V2SetGap.betweenCards(),
      V2SetCard(rows: [
        _switchRow(t('convSetMute'), _mute, _toggleMute),
        _switchRow(t('convSetPinChat'), _pinned, _togglePin),
      ]),
      // ---- 清空聊天记录 ----
      const V2SetGap.betweenCards(),
      V2SetCard(rows: [
        V2SetRow(
          title: t('convSetClearHistoryTitle'),
          showChevron: true,
          onTap: _clearHistory,
        ),
      ]),
      // ---- 退出群聊 / 解散群聊（群主） ----
      const V2SetGap.betweenCards(),
      V2SetCard(rows: [
        V2SetDangerButton(
          label: _isOwner
              ? t('convSetDisbandGroupTitle')
              : t('convSetExitGroupTitle'),
          onTap: _deleteFriendOrExit,
          filled: false,
        ),
      ]),
    ];
  }

  // ==================== 频道：频道资料（十七批） ====================

  List<Widget> _channelChildren() {
    final t = AppLocalizations.of(context).t;
    return [
      // ---- 头部：头像 + 频道名 + 订阅数 + 频道 ID（可复制） ----
      _channelHeadBlock(),
      const V2SetGap.betweenCards(),
      // ---- 清空聊天记录（与群/单聊共用） ----
      V2SetCard(rows: [
        V2SetRow(
          title: t('convSetClearHistoryTitle'),
          showChevron: true,
          onTap: _clearHistory,
        ),
      ]),
      const V2SetGap.betweenCards(),
      // ---- 退出频道 ----
      V2SetCard(rows: [
        V2SetDangerButton(
          label: t('convSetExitChannelTitle'),
          onTap: _exitChannel,
          filled: false,
        ),
      ]),
    ];
  }

  /// 频道头部：视觉规格与 `_groupHeadBlock` 同源（头像 128 圆角方 r=31 /
  /// 频道名 30.6 w600 / 订阅数 19.3 / ID 行 13），但无群主编辑affordance。
  /// ID 行（任务#4）：shortId 非空显示「频道 ID：xxx（自定义）」，
  /// 为空回退雪花 ID；点击/长按复制显示值（自定义 ID 可直接用于搜索与
  /// GET /channel/:id，比雪花更实用），交互与群号复制同款。
  Widget _channelHeadBlock() {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    final shortId = widget.conv.conversation['shortId']?.toString() ?? '';
    final idText = shortId.isNotEmpty ? shortId : widget.conv.id;
    return Container(
      color: context.setCard,
      padding: EdgeInsets.fromLTRB(20.7 * s, 8.3 * s, 20.7 * s, 22 * s),
      child: Column(
        children: [
          _groupAvatar(), // _isOwner 为 false 时是纯展示（无角标/不可点）
          SizedBox(height: 21.55 * s),
          Text(widget.conv.conversationName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 30.6 * s,
                  fontWeight: FontWeight.w600,
                  height: 1.0,
                  color: context.setTitle)),
          SizedBox(height: 16.4 * s),
          // 订阅数（成员数=订阅数，chat_page 顶栏同口径）
          Text(t('chatSubSubscribers', {'count': '${widget.conv.memberCount}'}),
              style: TextStyle(
                  fontSize: 19.3 * s, height: 1.0, color: context.setSub)),
          SizedBox(height: 10 * s),
          // 频道 ID（可复制，与群号复制同款交互）
          InkWell(
            onLongPress: _copyChannelId,
            onTap: _copyChannelId,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                      t(
                          shortId.isNotEmpty
                              ? 'convSetChannelIdCustom'
                              : 'convSetChannelId',
                          {'id': idText}),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 13 * s, color: context.setSub)),
                ),
                SizedBox(width: 4 * s),
                Icon(Icons.copy, size: 14 * s, color: context.setSub),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 复制频道 ID（显示值：自定义 ID 优先，回退雪花）
  void _copyChannelId() {
    final shortId = widget.conv.conversation['shortId']?.toString() ?? '';
    final v = shortId.isNotEmpty ? shortId : widget.conv.id;
    if (v.isEmpty) return;
    Clipboard.setData(ClipboardData(text: v));
    AppDialogs.toast(
        context, AppLocalizations.of(context).t('convSetChannelIdCopied'));
  }

  /// 退出频道：确认后走会话退出接口（type=3 会话同 /conversation 退出链路）
  Future<void> _exitChannel() async {
    final t = AppLocalizations.of(context).t;
    final ok = await AppDialogs.confirm(context,
        title: t('convSetExitChannelTitle'),
        message: t('convSetExitChannelMsg'),
        confirmText: t('convSetExitChannelConfirm'),
        danger: true);
    if (ok == true) _exit();
  }

  /// 群头部（2026-09-15 第十二批）：满宽白底头块（下接圆角卡列表），
  /// 居中排布，字号间距对齐 `group_manage_page._profileHead` 的实测规格
  /// （头像 128 圆角方 r=31 / 群名 30.6 w600 / 成员数 19.3）。
  /// 群主换头像、改群名、群号复制的既有交互全部保留。
  Widget _groupHeadBlock() {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    return Container(
      color: context.setCard,
      padding: EdgeInsets.fromLTRB(20.7 * s, 8.3 * s, 20.7 * s, 22 * s),
      child: Column(
        children: [
          // 群头像：群主可点击更换（相册选图上传）
          _groupAvatar(),
          SizedBox(height: 21.55 * s),
          // 群名：群主可点击修改
          InkWell(
            onTap: _isOwner ? _editGroupName : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(_groupName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 30.6 * s,
                          fontWeight: FontWeight.w600,
                          height: 1.0,
                          color: context.setTitle)),
                ),
                if (_isOwner) ...[
                  SizedBox(width: 7.7 * s),
                  Icon(Icons.edit_outlined,
                      size: 17 * s, color: context.setSub),
                ],
              ],
            ),
          ),
          // 成员数（与群资料页同款「{count} 位成员」）
          // 需求3（2026-09-22 三批）：showMembers 开关关闭或群隐私开启
          // （普通成员，_privacyLimited）→ 该行不显示，群名与群号之间只留间距；
          // 群设置未拉回（空 map）先不渲染，防止隐私群「先闪后藏」
          if (_groupSettings.isNotEmpty &&
              _groupSettings['showMembers'] != false &&
              !_privacyLimited) ...[
            SizedBox(height: 16.4 * s),
            Text(t('gmpMemberCount', {'count': '${widget.conv.memberCount}'}),
                style: TextStyle(
                    fontSize: 19.3 * s, height: 1.0, color: context.setSub)),
            SizedBox(height: 10 * s),
          ] else
            SizedBox(height: 16.4 * s),
          // 群号（可复制）
          InkWell(
            onTap: _copyId,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(t('convSetGroupId', {'id': widget.conv.id}),
                    style: TextStyle(fontSize: 13 * s, color: context.setSub)),
                SizedBox(width: 4 * s),
                Icon(Icons.copy, size: 14 * s, color: context.setSub),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _groupAvatar() {
    final s = v2Scale(context);
    final url = AppConfig.assetUrl(_avatarUrl);
    final name = _groupName;
    final initial = name.isEmpty ? '?' : name.characters.first;
    return InkWell(
      onTap: _isOwner ? _changeGroupAvatar : null,
      borderRadius: BorderRadius.circular(31 * s),
      child: Stack(
        children: [
          Container(
            width: 128 * s,
            height: 128 * s,
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(31 * s),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _groupAvatarFallback(initial),
                if (url.isNotEmpty)
                  Image.network(url,
                      fit: BoxFit.cover,
                      frameBuilder: (ctx, child, frame, wasSync) =>
                          (wasSync || frame != null)
                              ? child
                              : const SizedBox.shrink(),
                      errorBuilder: (_, __, ___) => const SizedBox.shrink()),
              ],
            ),
          ),
          // 群主可换头像：右下角相机角标（上传中转菊花）
          if (_isOwner)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: context.cs.surface.withValues(alpha: 0.9),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: _uploadingAvatar
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.photo_camera_outlined,
                        size: 19, color: context.cs.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  Widget _groupAvatarFallback(String initial) {
    return Container(
      color: AppTheme.primary.withValues(alpha: 0.12),
      alignment: Alignment.center,
      child: Icon(Icons.group,
          size: 36, color: AppTheme.primary.withValues(alpha: 0.7)),
    );
  }

  // ==================== 公共组件（全部走 V2 共享件） ====================

  /// 分组标题：A 型默认几何（left 22.0 / 15 / #6B727D），右端可挂一个可点尾标
  /// （如「查看全部 N 名成员 >」）。
  Widget _sectionHeader(String title, {String? trailing, VoidCallback? onTap}) {
    final s = v2Scale(context);
    return V2SetSectionLabel(
      title,
      extra: trailing == null
          ? null
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: Text(
                trailing,
                style: TextStyle(
                    fontSize: 14.5 * s, height: 1.0, color: context.setSub),
              ),
            ),
    );
  }

  /// 置顶消息卡：多条切换（左右箭头）+ 点击跳转 ChatPage 定位
  Widget _pinnedCard() {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    if (_pinnedMsgs.isEmpty) return const SizedBox.shrink();
    final p = _pinnedMsgs[_pinIndex];
    final content = (p['content']?.toString() ?? '').trim();
    final sender = (p['senderName']?.toString() ?? '').trim();
    final hasMulti = _pinnedMsgs.length > 1;
    void switchPin(int delta) {
      setState(() {
        _pinIndex =
            (_pinIndex + delta + _pinnedMsgs.length) % _pinnedMsgs.length;
      });
    }

    return InkWell(
      onTap: () {
        final msgId = p['msgId']?.toString() ?? '';
        if (msgId.isEmpty) return;
        final c = ConvItem.fromJson({
          'conversation': widget.conv.conversation,
          'conversationName': widget.conv.conversationName,
        });
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) =>
              ChatPage(conv: c, myId: _myId ?? '', scrollToMsgId: msgId),
        ));
      },
      borderRadius: BorderRadius.circular(kSetCardR * s),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            if (hasMulti)
              IconButton(
                onPressed: () => switchPin(-1),
                icon: Icon(Icons.chevron_left,
                    color: context.cs.onSurfaceVariant),
                visualDensity: VisualDensity.compact,
                tooltip: t('convSetPrevPinned'),
              ),
            const Icon(Icons.push_pin, size: 16, color: AppTheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (sender.isNotEmpty)
                    Text(sender,
                        style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.primary,
                            fontWeight: FontWeight.w500)),
                  Text(content.isEmpty ? t('convSetEmptyMessage') : content,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 14, color: context.cs.onSurface)),
                ],
              ),
            ),
            if (hasMulti)
              IconButton(
                onPressed: () => switchPin(1),
                icon: Icon(Icons.chevron_right,
                    color: context.cs.onSurfaceVariant),
                visualDensity: VisualDensity.compact,
                tooltip: t('convSetNextPinned'),
              ),
            // 需求2（2026-09-22 二批）：置顶消息旁的「删除」（取消置顶，仅群主）
            if (_isOwner)
              IconButton(
                onPressed: _unpinCurrent,
                icon: Icon(Icons.close,
                    size: 18, color: context.cs.onSurfaceVariant),
                visualDensity: VisualDensity.compact,
                tooltip: t('convSetUnpin'),
              ),
          ],
        ),
      ),
    );
  }

  /// 成员区：隐私开启时普通成员最多 2 排预览（无查看全部入口）。
  /// 自带分组标题 + 标题下留白，调用处只需在它前面放 `V2SetGap.beforeLabel()`。
  Widget _membersSection() {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    final limited = _privacyLimited;
    // 老服务端兼容：隐私模式下成员接口报 4006 → 列表为空，显示提示卡片
    if (limited && _members.isEmpty) {
      return Column(
        children: [
          _sectionHeader(t('convSetGroupMembers')),
          const V2SetGap.afterLabel(),
          V2SetCard(rows: [
            Padding(
              padding: EdgeInsets.symmetric(vertical: 22 * s),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_outline, size: 18 * s, color: context.setSub),
                  SizedBox(width: 8 * s),
                  Text(t('groupPrivacyHint'),
                      style:
                          TextStyle(fontSize: 14 * s, color: context.setSub)),
                ],
              ),
            ),
          ]),
        ],
      );
    }
    return Column(
      children: [
        limited
            ? _sectionHeader(t('convSetGroupMembers'))
            : _sectionHeader(t('convSetGroupMembers'),
                trailing: t('convSetViewAllMembers',
                    {'count': _members.length.toString()}),
                onTap: _showMembers),
        const V2SetGap.afterLabel(),
        V2SetCard(rows: [
          Padding(
            padding: EdgeInsets.fromLTRB(16 * s, 16 * s, 16 * s, 16 * s),
            child: _memberGrid(),
          ),
        ]),
      ],
    );
  }

  Widget _memberGrid() {
    final t = AppLocalizations.of(context).t;
    final limited = _privacyLimited;
    return LayoutBuilder(builder: (context, constraints) {
      const spacing = 12.0;
      final width = constraints.maxWidth;
      // 每格 52 宽 + 12 间距：按卡片实际宽度动态算列数，让每排铺满卡片（不留斜边）
      final cols = ((width + spacing) / (52 + spacing)).floor().clamp(1, 20);
      final cellW = (width - spacing * (cols - 1)) / cols;
      // 资料页固定最多 2 排预览（隐私模式多余不显示；普通模式点"查看全部"进成员页）
      final maxShow = cols * 2;
      // 邀请/移除格子也占位，成员格子数 = 2排总格数 - 功能格数，保证总数不超 2 排
      final actionCount = (!limited ? 1 : 0) + (!limited && _isManager ? 1 : 0);
      final memberMax = (maxShow - actionCount).clamp(0, _members.length);
      final cells = <Widget>[];
      var shown = 0;
      for (final m in _members) {
        if (shown >= memberMax) break;
        cells.add(_memberCell(m, cellW));
        shown++;
      }
      if (!limited) {
        cells.add(_actionCell(Icons.add, t('convSetInvite'), _showMembers,
            width: cellW));
        if (_isManager) {
          cells.add(_actionCell(Icons.remove, t('convSetRemove'), _showMembers,
              width: cellW));
        }
      }
      return Wrap(
        spacing: spacing,
        runSpacing: 16,
        children: cells,
      );
    });
  }

  Widget _memberCell(Map<String, dynamic> m, double width) {
    final t = AppLocalizations.of(context).t;
    final name = m['nickname']?.toString() ?? m['account']?.toString() ?? '';
    final initial = name.isEmpty ? '?' : name.characters.first;
    final url = m['avatar']?.toString() ?? '';
    final role = (m['role'] as num?)?.toInt() ?? 3;
    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              GestureDetector(
                onTap: () {
                  final uid =
                      m['id']?.toString() ?? m['userId']?.toString() ?? '';
                  if (uid.isEmpty) return;
                  if (_privacyLimited) {
                    AppDialogs.toast(context, t('groupPrivacyProfileBlocked'));
                    return;
                  }
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => UserQrProfilePage(uid: uid)));
                },
                child: CircleAvatar(
                  radius: 22,
                  backgroundColor: AppTheme
                      .avatarColors[name.length % AppTheme.avatarColors.length],
                  backgroundImage: url.isNotEmpty ? NetworkImage(url) : null,
                  child: url.isEmpty
                      ? Text(initial,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600))
                      : null,
                ),
              ),
              // 群主标识：头像右上角小角标
              if (role == 1)
                Positioned(
                  top: -3,
                  right: -6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: AppTheme.orange,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: Theme.of(context).colorScheme.surface,
                          width: 1),
                    ),
                    child: Text(t('groupRoleOwner'),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 8,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _actionCell(IconData icon, String label, VoidCallback onTap,
      {double width = 52}) {
    return SizedBox(
      // 与成员格同宽（cellW），保证同排内头像圆心/文字中心像素级对齐
      width: width,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: context.cs.surfaceContainer,
                shape: BoxShape.circle,
                border: Border.all(color: context.cs.outlineVariant),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 20, color: context.cs.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12, color: context.cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  /// V2 开关行：行高按共享件实测值 92.7，尾部用 [V2SetSwitch]（67.0 × 41.3）。
  Widget _switchRow(String label, bool value, ValueChanged<bool> onChanged) {
    return V2SetRow(
      title: label,
      height: 92.7,
      trailing: V2SetSwitch(value: value, onChanged: onChanged),
    );
  }
}
