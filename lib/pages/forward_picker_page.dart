import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/conversation_service.dart';
import '../services/friend_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';

/// 转发选择器：好友 / 群聊 两个 Tab，单选一行后立即返回结果。
/// pop 返回 Map：{'kind':'friend'|'group','id':String,'nickname':String,'avatar':String?}
class ForwardPickerPage extends StatefulWidget {
  final String myId;
  const ForwardPickerPage({super.key, required this.myId});

  @override
  State<ForwardPickerPage> createState() => _ForwardPickerPageState();
}

class _ForwardPickerPageState extends State<ForwardPickerPage>
    with SingleTickerProviderStateMixin {
  final _friendSvc = FriendService();
  final _convSvc = ConversationService();
  final _searchCtrl = TextEditingController();
  late final TabController _tab = TabController(length: 2, vsync: this);

  List<Map<String, dynamic>> _friends = []; // 好友原始数据
  List<ConvItem> _groups = []; // type==2 的群会话
  bool _loading = true;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _tab.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final friends = await _friendSvc.list();
      final convs = await _convSvc.list();
      if (!mounted) return;
      setState(() {
        _friends = friends;
        _groups = convs.where((c) => c.conversation['type'] == 2).toList();
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
    }
  }

  /// 好友显示名：备注优先
  String _friendName(Map<String, dynamic> u) {
    final r = u['remark']?.toString() ?? '';
    if (r.isNotEmpty) return r;
    return (u['nickname'] ?? u['account'] ?? '').toString();
  }

  void _pickFriend(Map<String, dynamic> u) {
    Navigator.pop(context, {
      'kind': 'friend',
      'id': (u['id'] ?? '').toString(), // 雪花 ID 全程字符串
      'nickname': _friendName(u),
      'avatar': (u['avatar'] ?? '').toString(),
    });
  }

  void _pickGroup(ConvItem c) {
    Navigator.pop(context, {
      'kind': 'group',
      'id': c.id, // 雪花 ID 字符串
      'nickname': c.conversationName,
      'avatar': c.avatarUrl,
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final q = _searchCtrl.text.toLowerCase();
    final friends = q.isEmpty
        ? _friends
        : _friends
            .where((u) =>
                ('${_friendName(u)} ${(u['account'] ?? '')}'.toLowerCase())
                    .contains(q))
            .toList();
    final groups = q.isEmpty
        ? _groups
        : _groups
            .where((c) => c.conversationName.toLowerCase().contains(q))
            .toList();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(t('forwardPickerTitle')),
        bottom: TabBar(
          controller: _tab,
          labelColor: AppTheme.primary,
          unselectedLabelColor: context.cs.onSurfaceVariant,
          indicatorColor: AppTheme.primary,
          tabs: [
            Tab(text: t('forwardTabFriends')),
            Tab(text: t('forwardTabGroups')),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (_) => setState(() {}),
              decoration: AppTheme.authInput(
                  hint: t('newConvSearchHint'), icon: Icons.search),
            ),
          ),
          if (_loading)
            const LinearProgressIndicator(minHeight: 2)
          else if (_loadFailed)
            Expanded(
              child: Center(
                child: Text(t('newConvCreateFailed', {'reason': ''}),
                    style: TextStyle(color: context.cs.onSurfaceVariant)),
              ),
            )
          else
            Expanded(
              child: TabBarView(
                controller: _tab,
                children: [
                  _buildFriendTab(friends),
                  _buildGroupTab(groups),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFriendTab(List<Map<String, dynamic>> friends) {
    final t = AppLocalizations.of(context).t;
    if (friends.isEmpty) {
      return Center(
        child: Text(t('newConvNoContacts'),
            style: TextStyle(color: context.cs.onSurfaceVariant)),
      );
    }
    return ListView.separated(
      itemCount: friends.length,
      separatorBuilder: (_, __) => Divider(
          height: 1,
          indent: 68,
          endIndent: 16,
          color: context.cs.outlineVariant),
      itemBuilder: (_, i) {
        final u = friends[i];
        final name = _friendName(u);
        final avatar = (u['avatar'] ?? '').toString();
        return ListTile(
          onTap: () => _pickFriend(u),
          leading: _Avatar(avatar: avatar, name: name),
          title: Text(name,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
          subtitle: (u['account'] ?? '').toString().isEmpty
              ? null
              : Text((u['account'] ?? '').toString(),
                  style: TextStyle(
                      fontSize: 12, color: context.cs.onSurfaceVariant)),
          trailing: Icon(Icons.chevron_right,
              size: 20, color: context.cs.onSurfaceVariant),
        );
      },
    );
  }

  Widget _buildGroupTab(List<ConvItem> groups) {
    final t = AppLocalizations.of(context).t;
    if (groups.isEmpty) {
      return Center(
        child: Text(t('newConvNoContacts'),
            style: TextStyle(color: context.cs.onSurfaceVariant)),
      );
    }
    return ListView.separated(
      itemCount: groups.length,
      separatorBuilder: (_, __) => Divider(
          height: 1,
          indent: 68,
          endIndent: 16,
          color: context.cs.outlineVariant),
      itemBuilder: (_, i) {
        final c = groups[i];
        return ListTile(
          onTap: () => _pickGroup(c),
          leading: _Avatar(avatar: c.avatarUrl, name: c.conversationName),
          title: Text(c.conversationName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
          subtitle: c.memberCount > 0
              ? Text(t('groupMembersTitle', {'count': '${c.memberCount}'}),
                  style: TextStyle(
                      fontSize: 12, color: context.cs.onSurfaceVariant))
              : null,
          trailing: Icon(Icons.chevron_right,
              size: 20, color: context.cs.onSurfaceVariant),
        );
      },
    );
  }
}

/// 圆形头像：占位为「首字母色块」，加载中/失败/无头像均显示它
class _Avatar extends StatelessWidget {
  final String avatar;
  final String name;
  const _Avatar({required this.avatar, required this.name});

  @override
  Widget build(BuildContext context) {
    return AppAvatar(
      url: avatar,
      name: name,
      size: 42,
      background: AppTheme.primary,
    );
  }
}
