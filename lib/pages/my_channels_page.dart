import 'package:flutter/material.dart';

import '../services/conversation_service.dart';
import '../l10n/app_locale.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import 'chat_page.dart';

/// 我的频道（第十三批 #3c）：显示我加入的所有频道，点击进入聊天。
///
/// 结构与 `my_groups_page.dart`（我的群聊）完全同构，仅两处差异：
/// 1. 过滤条件 type == 3（频道；群聊是 2）；
/// 2. 副标题兜底：频道无消息时显示频道签名 announcementZh/En
///    （与 chat_list_page._convItem 同一取值逻辑：当前语言 zh 用 zh，
///    en 空回退 zh；签名也为空就不显示副标题 —— 不造假数据）。
class MyChannelsPage extends StatefulWidget {
  final String myId;
  const MyChannelsPage({super.key, required this.myId});

  @override
  State<MyChannelsPage> createState() => _MyChannelsPageState();
}

class _MyChannelsPageState extends State<MyChannelsPage> {
  final _svc = ConversationService();
  List<ConvItem> _channels = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _svc.list();
      final channels = list
          .where((c) => (c.conversation['type'] as num?)?.toInt() == 3)
          .toList();
      if (mounted) {
        setState(() {
          _channels = channels;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 频道签名（副标题兜底）：按当前语言取 announcementZh/En（en 空回退 zh）。
  String _signature(ConvItem c) {
    final lc = Localizations.localeOf(context).languageCode;
    final zh = c.conversation['announcementZh']?.toString() ?? '';
    final en = c.conversation['announcementEn']?.toString() ?? '';
    return lc == 'zh' ? zh : (en.isNotEmpty ? en : zh);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(t('myChannelsTitle')),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _channels.isEmpty
              ? Center(
                  child: Text(t('myChannelsEmpty'),
                      style: TextStyle(color: context.cs.onSurfaceVariant)),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _channels.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _tile(_channels[i]),
                ),
    );
  }

  Widget _tile(ConvItem c) {
    final t = AppLocalizations.of(context).t;
    // 副标题与群聊同源（最后一条消息预览）；频道无消息时显示频道签名
    final subtitle =
        c.lastMsgPreview.isNotEmpty ? c.lastMsgPreview : _signature(c);
    return InkWell(
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ChatPage(conv: c, myId: widget.myId)));
        if (mounted) _load();
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.cs.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            // 频道头像：优先显示头像图，无图回落首字
            AppAvatar(
                url: c.avatarUrl,
                name: c.conversationName,
                size: 44,
                radius: 12,
                background: AppTheme.primary,
                emptyText: t('myChannelsInitial')),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.conversationName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: context.cs.onSurface)),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: context.cs.onSurfaceVariant)),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                size: 18, color: context.cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
