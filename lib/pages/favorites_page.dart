import 'dart:convert';

import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/conversation_service.dart';
import '../services/user_cache.dart';
import '../theme/app_theme.dart';
import 'chat_page.dart';

/// 我的收藏：收藏的消息列表
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  final _svc = ConversationService();
  List<Map<String, dynamic>> _favs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _svc.favorites();
      if (mounted) {
        setState(() {
          _favs = list;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Map<String, dynamic>? _asMap(dynamic raw) {
    if (raw == null) return null;
    try {
      final j = raw is String ? jsonDecode(raw) : raw;
      if (j is Map) return Map<String, dynamic>.from(j);
    } catch (_) {}
    return null;
  }

  /// 各消息类型预览：禁止把名片/位置等 JSON 原文甩到列表上。
  String _preview(Map<String, dynamic> m) {
    final t = AppLocalizations.instance.t;
    final type = (m['type'] as num?)?.toInt() ?? 0;
    final content = m['content']?.toString() ?? '';
    final map = _asMap(m['content']);

    switch (type) {
      case 1: // 文本
        return content.replaceAll('\n', ' ').trim();
      case 2:
        return t('favoritesPreviewImage');
      case 3: // 文件：标签 + 文件名
        final name = (map?['name'] ?? map?['fileName'] ?? map?['filename'] ?? '')
            .toString()
            .trim();
        final label = t('favoritesPreviewFile');
        if (name.isNotEmpty) return '$label$name';
        if (content.isNotEmpty && !content.trimLeft().startsWith('{')) {
          return '$label$content';
        }
        return label;
      case 4:
        return t('favoritesPreviewVoice');
      case 5:
        return t('favoritesPreviewVideo');
      case 6:
        return t('svcSystem');
      case 7:
        return t('svcCall');
      case 8:
        final note = (map?['note'] ?? '').toString().trim();
        return note.isEmpty ? t('svcRedPacket') : '${t('svcRedPacket')} $note';
      case 9:
        final note = (map?['note'] ?? '').toString().trim();
        return note.isEmpty ? t('svcTransfer') : '${t('svcTransfer')} $note';
      case 10: // 名片
        final nick = (map?['nickname'] ?? map?['name'] ?? '').toString().trim();
        final label = t('svcCard');
        return nick.isEmpty ? label : '$label $nick';
      case 11: // 链接
        final title = (map?['title'] ?? '').toString().trim();
        final label = t('svcLink');
        return title.isEmpty ? label : '$label $title';
      case 12:
        return t('svcMerge');
      case 13:
        return t('svcE2Text');
      case 14: // 位置
        final name = (map?['name'] ?? map?['address'] ?? '').toString().trim();
        final label = t('svcLocation');
        return name.isEmpty ? label : '$label $name';
      default:
        if (content.trimLeft().startsWith('{')) return t('svcSystem');
        return content.replaceAll('\n', ' ').trim();
    }
  }

  String _time(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _openFav(Map<String, dynamic> m) async {
    final convId = m['conversationId']?.toString() ?? '';
    final msgId = m['msgId']?.toString() ?? '';
    if (convId.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法定位原会话')),
      );
      return;
    }
    try {
      final list = await _svc.list();
      ConvItem? item;
      for (final c in list) {
        if (c.id == convId) {
          item = c;
          break;
        }
      }
      final short = convId.length > 8 ? convId.substring(convId.length - 8) : convId;
      item ??= ConvItem.fromJson({
        'conversation': {'id': convId, 'type': 1},
        'conversationName': '会话 #$short',
      });
      final myId = UserCache.myId ?? '';
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ChatPage(
          conv: item!,
          myId: myId,
          scrollToMsgId: msgId.isEmpty ? null : msgId,
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打开失败: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(title: Text(t('favoritesTitle'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _favs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.star_border,
                          size: 48, color: context.cs.onSurfaceVariant),
                      SizedBox(height: 8),
                      Text(t('favoritesEmpty'),
                          style: TextStyle(color: context.cs.onSurfaceVariant)),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _favs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final m = _favs[i];
                    return Material(
                      color: context.cs.surface,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _openFav(m),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.star,
                                      size: 14, color: Color(0xFFFFB800)),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                        t('favoritesConversation', {
                                          'id': '${m['conversationId']}'
                                        }),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontSize: 12,
                                            color:
                                                context.cs.onSurfaceVariant)),
                                  ),
                                  Text(_time(m['createdAt']?.toString()),
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: context.cs.onSurfaceVariant)),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(_preview(m),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 14,
                                      color: context.cs.onSurface)),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
