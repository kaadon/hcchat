import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/conversation_service.dart'; // ApiException
import '../services/friend_service.dart';
import '../theme/app_theme.dart';
import 'chat_page.dart';

// ============================================================================
// 共同群组列表页（2026-09-15 第十二批二轮：好友资料页「共同群组」行落地页）。
//
// 契约（API.md :837）：`GET /api/v1/user/:id/mutual-groups` → 轻量群卡
// `[{id(群会话ID雪花字符串), name, nameEn, avatar, memberCount}]`，按成员数降序；
// 仅统计 type=2 且未解散的群。
// ============================================================================

/// 共同群组列表：群卡（头像 + 群名 + 成员数），点击进群聊会话。
class MutualGroupsPage extends StatefulWidget {
  final String userId;
  final String myId;
  const MutualGroupsPage(
      {super.key, required this.userId, required this.myId});

  @override
  State<MutualGroupsPage> createState() => _MutualGroupsPageState();
}

class _MutualGroupsPageState extends State<MutualGroupsPage> {
  final _svc = FriendService();

  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _svc.mutualGroups(widget.userId);
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// 群卡 → 进群聊会话：按轻量群卡构造最小 ConvItem（会话页自行拉成员/设置）。
  void _openGroup(Map<String, dynamic> g) {
    final gid = g['id']?.toString() ?? '';
    if (gid.isEmpty) return;
    final name = g['name']?.toString() ?? '';
    final item = ConvItem.fromJson({
      'conversation': {
        'id': gid,
        'type': 2,
        'avatar': g['avatar']?.toString() ?? '',
        'nameZh': name,
      },
      'conversationName': name,
      'memberCount': (g['memberCount'] as num?)?.toInt() ?? 0,
    });
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ChatPage(conv: item, myId: widget.myId)));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      backgroundColor: context.cs.surface,
      appBar: AppBar(title: Text(t('fdpCommonGroupsTitle'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _error.isNotEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 15, color: context.cs.onSurfaceVariant)),
                  ),
                )
              : _items.isEmpty
                  ? Center(
                      child: Text(t('mfEmpty'),
                          style: TextStyle(
                              fontSize: 15,
                              color: context.cs.onSurfaceVariant)),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _items.length,
                      separatorBuilder: (_, __) => Divider(
                          height: 1,
                          indent: 76,
                          color: context.cs.onSurfaceVariant
                              .withValues(alpha: 0.12)),
                      itemBuilder: (ctx, i) => _groupRow(_items[i]),
                    ),
    );
  }

  Widget _groupRow(Map<String, dynamic> g) {
    final t = AppLocalizations.of(context).t;
    final name = g['name']?.toString() ?? '';
    final avatar = g['avatar']?.toString() ?? '';
    final count = (g['memberCount'] as num?)?.toInt() ?? 0;
    final initial = name.isEmpty ? '?' : name.characters.first;
    return InkWell(
      onTap: () => _openGroup(g),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: 48,
                height: 48,
                color: AppTheme.primary.withValues(alpha: 0.12),
                child: avatar.isNotEmpty
                    ? Image.network(avatar,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            Center(child: Text(initial,
                                style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.primary
                                        .withValues(alpha: 0.7)))))
                    : Center(child: Text(initial,
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.primary.withValues(alpha: 0.7)))),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w500,
                      color: context.cs.onSurface)),
            ),
            const SizedBox(width: 8),
            Text(t('gmpMemberCount', {'count': '$count'}),
                style: TextStyle(
                    fontSize: 13, color: context.cs.onSurfaceVariant)),
            Icon(Icons.chevron_right,
                size: 20, color: context.cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
