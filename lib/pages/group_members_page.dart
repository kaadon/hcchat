import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/conversation_service.dart';
import '../services/friend_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';
import 'user_qr_profile_page.dart';

/// 群成员管理页：
/// - 群主开启"成员隐私"后普通成员只见提示页（列表不可看）
/// - 群主/管理员：邀请新成员；每行卡片旁直接放"禁言/解除禁言"和"移除"按钮
/// - 添加/移除管理员有专门页面（群管理页）
class GroupMembersPage extends StatefulWidget {
  final ConvItem conv;
  const GroupMembersPage({super.key, required this.conv});

  /// 聊天「⋯」等入口：直接弹出邀请选人（不先进成员列表）。
  /// 返回 true 表示成功发出邀请。
  static Future<bool> inviteFriends(BuildContext context, ConvItem conv) async {
    final t = AppLocalizations.of(context).t;
    final svc = ConversationService();
    final friendSvc = FriendService();
    try {
      String myId = '';
      try {
        final p = await friendSvc.profile();
        myId = p['id']?.toString() ?? '';
      } catch (_) {}
      final members = await svc.members(conv.id);
      Map<String, dynamic> settings = {};
      try {
        settings = await svc.groupSettings(conv.id);
      } catch (_) {}
      int myRole = 0;
      for (final m in members) {
        final uid = m['id']?.toString() ?? m['userId']?.toString() ?? '';
        if (uid == myId) {
          myRole = (m['role'] as num?)?.toInt() ?? 3;
          break;
        }
      }
      final canInvite =
          myRole == 1 || myRole == 2 || settings['allowMemberInvite'] == true;
      if (!canInvite) {
        if (context.mounted) {
          AppDialogs.toast(context, t('groupInviteDenied'));
        }
        return false;
      }
      final friends = await friendSvc.list();
      final inGroup = members
          .map((m) => m['id']?.toString() ?? m['userId']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      final candidates = friends
          .where((f) => !inGroup.contains(f['id']?.toString() ?? ''))
          .toList();
      if (!context.mounted) return false;
      if (candidates.isEmpty) {
        AppDialogs.toast(context, t('groupNoFriendsToInvite'));
        return false;
      }
      final selected = <String>{};
      final ok = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => _InvitePicker(
          friends: candidates,
          selected: selected,
          title: t('groupInvitePickTitle'),
          confirmText: t('groupInviteBtn'),
        ),
      );
      if (ok != true || selected.isEmpty) return false;
      await svc.inviteMembers(conv.id, selected.toList());
      if (context.mounted) {
        AppDialogs.toast(context, t('groupInviteSuccess'));
      }
      return true;
    } catch (_) {
      if (context.mounted) {
        AppDialogs.toast(context, t('groupInviteFailed'));
      }
      return false;
    }
  }

  @override
  State<GroupMembersPage> createState() => _GroupMembersPageState();
}

class _GroupMembersPageState extends State<GroupMembersPage> {
  final _svc = ConversationService();
  final _friendSvc = FriendService();
  List<Map<String, dynamic>> _members = [];
  Map<String, dynamic> _settings = {};
  String _myId = '';
  bool _loading = true;
  bool _privacyOn = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // 先取我的 id，再加载成员/设置，最后判定隐私（普通成员受限）
      try {
        final p = await _friendSvc.profile();
        _myId = p['id']?.toString() ?? '';
      } catch (_) {}
      final list = await _svc.members(widget.conv.id);
      Map<String, dynamic> settings = {};
      try {
        settings = await _svc.groupSettings(widget.conv.id);
      } catch (_) {}
      // 关键：从刚拉到的 list 里取我的角色。
      // 不能调 _roleById（它读 this._members，此刻还未赋值、恒为空 → 角色恒 0，
      // 会导致群主/管理员也被当成普通成员拦在隐私提示页）。
      int myRole = 0;
      for (final m in list) {
        if (_uidOf(m) == _myId) {
          myRole = _roleOf(m);
          break;
        }
      }
      // 仅普通成员(role=3)受限；角色未知(0)时放行——
      // 服务端本就会对普通成员把列表截断为前 15 条，这里只是 UX 层的整页提示。
      final limited = settings['privacyEnabled'] == true && myRole == 3;
      if (mounted) {
        setState(() {
          _members = list;
          _settings = settings;
          _privacyOn = limited;
          _loading = false;
        });
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _privacyOn = e.code == 4006; // 老服务端兜底
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  int _roleOf(Map<String, dynamic> m) => (m['role'] as num?)?.toInt() ?? 3;

  String _uidOf(Map<String, dynamic> m) =>
      m['id']?.toString() ?? m['userId']?.toString() ?? '';

  bool get _isManager {
    final r = _roleById(_myId);
    return r == 1 || r == 2;
  }

  int _roleById(String uid) {
    for (final m in _members) {
      if (_uidOf(m) == uid) return _roleOf(m);
    }
    return 0;
  }

  bool _isMuted(Map<String, dynamic> m) {
    final until = (m['speakMutedUntil'] as num?)?.toInt() ?? 0;
    return until > DateTime.now().millisecondsSinceEpoch ~/ 1000;
  }

  bool get _canInvite => _isManager || (_settings['allowMemberInvite'] == true);

  String _memberName(Map<String, dynamic> m) {
    final remark = m['remark']?.toString() ?? '';
    if (remark.isNotEmpty) return remark;
    return m['nickname']?.toString() ??
        m['account']?.toString() ??
        AppLocalizations.of(context).t('contactsUser');
  }

  // ==================== 操作 ====================

  /// 邀请新成员：多选好友（排除已在群内的）→ 确认邀请
  Future<void> _invite() async {
    final ok = await GroupMembersPage.inviteFriends(context, widget.conv);
    if (ok && mounted) _load();
  }


  Future<void> _remove(Map<String, dynamic> m) async {
    final t = AppLocalizations.of(context).t;
    final name = _memberName(m);
    final confirmed = await AppDialogs.confirm(
      context,
      title: t('groupRemoveConfirmTitle'),
      message: t('groupRemoveConfirmMsg', {'name': name}),
      confirmText: t('groupRemoveConfirmBtn'),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _svc.removeMember(widget.conv.id, _uidOf(m));
      if (mounted) {
        AppDialogs.toast(context, t('groupRemoveSuccess'));
        _load();
      }
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('groupRemoveFailed'));
    }
  }

  /// 禁言：选时长（10分钟/1小时/8小时/1天/7天）
  Future<void> _mute(Map<String, dynamic> m) async {
    final t = AppLocalizations.of(context).t;
    final options = <(int, String)>[
      (10, t('groupMute10m')),
      (60, t('groupMute1h')),
      (480, t('groupMute8h')),
      (1440, t('groupMute1d')),
      (10080, t('groupMute7d')),
    ];
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                    color: ctx.cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(t('groupMutePickTitle'),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            ...options.map((e) => ListTile(
                  title: Text(e.$2, textAlign: TextAlign.center),
                  onTap: () => Navigator.of(ctx).pop(e.$1),
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    try {
      await _svc.muteMember(widget.conv.id, _uidOf(m), true, minutes: picked);
      if (mounted) {
        AppDialogs.toast(context, t('groupMuteSuccess'));
        _load();
      }
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('groupMuteFailed'));
    }
  }

  Future<void> _unmute(Map<String, dynamic> m) async {
    final t = AppLocalizations.of(context).t;
    try {
      await _svc.muteMember(widget.conv.id, _uidOf(m), false);
      if (mounted) {
        AppDialogs.toast(context, t('groupUnmuteSuccess'));
        _load();
      }
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('groupMuteFailed'));
    }
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(t('groupMembersTitle',
            {'count': _members.isEmpty ? '' : _members.length.toString()})),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _privacyOn
              ? _buildPrivacy()
              : _buildList(),
    );
  }

  /// 群主开启成员隐私：普通成员的提示页
  Widget _buildPrivacy() {
    final t = AppLocalizations.of(context).t;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline,
              size: 48, color: context.cs.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(t('groupPrivacyHint'),
              style:
                  TextStyle(fontSize: 14, color: context.cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _buildList() {
    final t = AppLocalizations.of(context).t;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_canInvite)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: context.cs.surface,
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            ),
            child: ListTile(
              leading: CircleAvatar(
                radius: 18,
                backgroundColor: AppTheme.primary.withValues(alpha: 0.12),
                child: Icon(Icons.person_add_alt_1,
                    size: 20, color: AppTheme.primary),
              ),
              title: Text(t('groupInviteBtn'),
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: context.cs.onSurface)),
              trailing: Icon(Icons.chevron_right,
                  size: 18, color: context.cs.onSurfaceVariant),
              onTap: _invite,
            ),
          ),
        ..._members.map(_memberRow),
      ],
    );
  }

  Widget _memberRow(Map<String, dynamic> m) {
    final t = AppLocalizations.of(context).t;
    final uid = _uidOf(m);
    final name = _memberName(m);
    final role = _roleOf(m);
    final muted = _isMuted(m);
    final isSelf = uid == _myId;
    final url = m['avatar']?.toString() ?? '';

    // 行内按钮（禁言/移除直接放卡片旁，不收进菜单）：
    // 仅群主/管理员可操作他人；不能动群主；管理员不能动管理员；不能操作自己
    final myRole = _roleById(_myId);
    final canManage = !isSelf &&
        (myRole == 1 || myRole == 2) &&
        role != 1 &&
        !(myRole == 2 && role == 2);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: context.cs.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              // 隐私模式下整页已是提示页，这里仅兜底；正常情况点头像看资料/加好友
              if (_privacyOn) {
                AppDialogs.toast(context, t('groupPrivacyProfileBlocked'));
                return;
              }
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => UserQrProfilePage(uid: uid)));
            },
            child: _avatar(name, url, uid),
          ),
          const SizedBox(width: 12),
          Expanded(
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
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: context.cs.onSurface)),
                    ),
                    if (isSelf) ...[
                      const SizedBox(width: 6),
                      Text(t('groupMe'),
                          style: TextStyle(
                              fontSize: 12,
                              color: context.cs.onSurfaceVariant)),
                    ],
                  ],
                ),
                if (role != 3 || muted) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (role == 1)
                        _roleTag(t('groupRoleOwner'), AppTheme.primary),
                      if (role == 2)
                        _roleTag(t('groupRoleAdmin'), AppTheme.orange),
                      if (muted) ...[
                        const SizedBox(width: 6),
                        _roleTag(t('groupMutedTag'), AppTheme.danger),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (canManage) ...[
            TextButton(
              onPressed: () => muted ? _unmute(m) : _mute(m),
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.primary,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(muted ? t('groupUnmute') : t('groupMute'),
                  style: const TextStyle(fontSize: 13)),
            ),
            const SizedBox(width: 4),
            TextButton(
              onPressed: () => _remove(m),
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.danger,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(t('groupRemoveMember'),
                  style: const TextStyle(fontSize: 13)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _roleTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: color)),
    );
  }

  Widget _avatar(String name, String url, String seed) {
    final color = AppTheme
        .avatarColors[seed.hashCode.abs() % AppTheme.avatarColors.length];
    return AppAvatar(url: url, name: name, size: 40, background: color);
  }
}

/// 邀请好友多选 bottom sheet
class _InvitePicker extends StatefulWidget {
  final List<Map<String, dynamic>> friends;
  final Set<String> selected;
  final String title;
  final String confirmText;
  const _InvitePicker({
    required this.friends,
    required this.selected,
    required this.title,
    required this.confirmText,
  });

  @override
  State<_InvitePicker> createState() => _InvitePickerState();
}

class _InvitePickerState extends State<_InvitePicker> {
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                  color: context.cs.outlineVariant,
                  borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(widget.title,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.45,
            child: ListView.builder(
              itemCount: widget.friends.length,
              itemBuilder: (_, i) {
                final f = widget.friends[i];
                final uid = f['id']?.toString() ?? '';
                final name = (f['remark']?.toString() ?? '').isNotEmpty
                    ? f['remark'].toString()
                    : (f['nickname']?.toString() ?? '');
                final checked = widget.selected.contains(uid);
                return ListTile(
                  leading: CircleAvatar(
                    radius: 18,
                    backgroundColor: AppTheme.avatarColors[
                        uid.hashCode.abs() % AppTheme.avatarColors.length],
                    child: Text(name.isEmpty ? '?' : name.characters.first,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600)),
                  ),
                  title:
                      Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Checkbox(
                    value: checked,
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        widget.selected.add(uid);
                      } else {
                        widget.selected.remove(uid);
                      }
                    }),
                  ),
                  onTap: () => setState(() {
                    if (checked) {
                      widget.selected.remove(uid);
                    } else {
                      widget.selected.add(uid);
                    }
                  }),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              height: 44,
              child: FilledButton(
                onPressed: widget.selected.isEmpty
                    ? null
                    : () => Navigator.of(context).pop(true),
                child: Text('${widget.confirmText}(${widget.selected.length})',
                    style: const TextStyle(fontSize: 15)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
