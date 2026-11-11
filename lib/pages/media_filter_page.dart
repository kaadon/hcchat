import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../l10n/app_locale.dart';
import '../services/conversation_service.dart'; // ApiException
import '../theme/app_theme.dart';
import 'image_viewer_page.dart';

// ============================================================================
// 媒体筛选列表页（2026-09-15 第十二批二轮：好友资料页「照片和视频 / 共享链接 /
// 文件 / 语音消息」行的落地页）。
//
// 契约（API.md :1382）：`GET /api/v1/message/filter?conversationId=&type=
// image|video|voice|file|link&beforeSeq=&limit=`，data 为轻量消息卡
// `{id, seq, type, digest, url(omitempty), createdAt}`，**时间正序**；
// 游标分页传已加载集合中**最小的 seq** 作 beforeSeq 拉更早一页。
// ============================================================================

/// 按类型筛选的消息列表页（单 type；title 由调用方传已翻译文案）。
class MediaFilterPage extends StatefulWidget {
  final String title;
  final String convId;

  /// image | video | voice | file | link（API.md :1382 五种）
  final String type;

  /// 2026-09-29 群「查看媒体」页 Tab 内嵌：true 时不带 Scaffold/AppBar，
  /// 由 GroupMediaPage 的 TabBarView 直接承载本页列表。
  final bool embedded;

  const MediaFilterPage({
    super.key,
    required this.title,
    required this.convId,
    required this.type,
    this.embedded = false,
  });

  @override
  State<MediaFilterPage> createState() => _MediaFilterPageState();
}

class _MediaFilterPageState extends State<MediaFilterPage> {
  final _svc = ConversationService();
  final _scroll = ScrollController();

  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String _error = '';

  static const int _pageSize = 30;

  @override
  void initState() {
    super.initState();
    _loadFirst();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore || _loading) return;
    if (_scroll.position.extentAfter < 240) _loadMore();
  }

  Future<void> _loadFirst() async {
    try {
      final list = await _svc.filterMessages(
          conversationId: widget.convId, type: widget.type, limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
        _hasMore = list.length >= _pageSize;
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

  Future<void> _loadMore() async {
    if (_items.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      // 输出时间正序 → 已加载集合中最早的 seq 在首位
      final minSeq = _items
          .map((e) => (e['seq'] as num?)?.toInt() ?? 0)
          .reduce((a, b) => a < b ? a : b);
      final list = await _svc.filterMessages(
          conversationId: widget.convId,
          type: widget.type,
          limit: _pageSize,
          beforeSeq: minSeq);
      if (!mounted) return;
      setState(() {
        _items.addAll(list);
        _hasMore = list.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  /// createdAt(RFC3339) → yyyy-MM-dd HH:mm（本地时区，失败返回空串）
  static String _fmtTime(dynamic raw) {
    final dt = DateTime.tryParse(raw?.toString() ?? '');
    if (dt == null) return '';
    final l = dt.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')} '
        '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  void _openLink(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // 外跳失败静默（链接卡仅展示也可）
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final body = _loading
        ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
        : _error.isNotEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_error,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 15,
                          color: context.cs.onSurfaceVariant)),
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
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _items.length + (_hasMore ? 1 : 0),
                    separatorBuilder: (_, __) => Divider(
                        height: 1,
                        indent: 76,
                        color: context.cs.onSurfaceVariant
                            .withValues(alpha: 0.12)),
                    itemBuilder: (ctx, i) {
                      if (i >= _items.length) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                              child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))),
                        );
                      }
                      return _row(_items[i]);
                    },
                  );
    // 2026-09-29 embedded：Tab 内嵌模式，外壳由 GroupMediaPage 提供
    if (widget.embedded) return body;
    return Scaffold(
      backgroundColor: context.cs.surface,
      appBar: AppBar(title: Text(widget.title)),
      body: body,
    );
  }

  Widget _row(Map<String, dynamic> m) {
    final digest = m['digest']?.toString() ?? '';
    final rawUrl = m['url']?.toString() ?? '';
    // 图片消息 content 可能是多图 URL 用 | 连接（后端原样下发）——展示/点开取第一张
    final firstRaw = rawUrl.split('|').first.trim();
    // 相对路径 / localhost MinIO 地址统一换 API 同域主机（与聊天页图片气泡一致）
    final url = firstRaw.isEmpty ? '' : AppConfig.assetUrl(firstRaw);
    // digest 就是原始 URL 时不当标题展示，回落类型名
    final title = (digest.isEmpty || digest == rawUrl) ? _fallbackTitle() : digest;
    final time = _fmtTime(m['createdAt']);

    // 点击行为：图片→全屏大图；视频/文件→外部打开；链接→外跳
    final VoidCallback? onTap = switch (widget.type) {
      'image' => url.isEmpty ? null : () {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ImageViewerPage(url: url),
          ));
        },
      'video' || 'file' => url.isEmpty ? null : () => _openLink(url),
      'link' => url.isEmpty ? null : () => _openLink(url),
      _ => null,
    };

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          children: [
            // 缩略图（图片真实渲染，视频图标）或类型图标（链接/文件/语音）
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 56,
                height: 56,
                color: context.cs.onSurfaceVariant.withValues(alpha: 0.08),
                child: widget.type == 'image' && url.isNotEmpty
                    ? Image.network(url,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _typeIcon())
                    : _typeIcon(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15.5,
                        color: context.cs.onSurface,
                        fontWeight: FontWeight.w500),
                  ),
                  if (widget.type == 'link' && url.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12.5, color: AppTheme.primary)),
                  ],
                  if (time.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(time,
                        style: TextStyle(
                            fontSize: 12.5,
                            color: context.cs.onSurfaceVariant)),
                  ],
                ],
              ),
            ),
            if (widget.type == 'link' && url.isNotEmpty)
              Icon(Icons.chevron_right,
                  size: 20, color: context.cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
  Widget _typeIcon() {
    final icon = switch (widget.type) {
      'image' => Icons.image_outlined,
      'video' => Icons.videocam_outlined,
      'voice' => Icons.mic_none,
      'file' => Icons.insert_drive_file_outlined,
      _ => Icons.link_rounded,
    };
    return Icon(icon, size: 24, color: context.cs.onSurfaceVariant);
  }

  String _fallbackTitle() {
    final t = AppLocalizations.of(context).t;
    return switch (widget.type) {
      'image' => t('svcImage'),
      'video' => t('svcVideo'),
      'voice' => t('svcVoice'),
      'file' => t('svcFile'),
      _ => t('svcLink'),
    };
  }
}
