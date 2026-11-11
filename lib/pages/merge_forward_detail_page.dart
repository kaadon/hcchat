import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../l10n/app_locale.dart';
import '../services/conversation_service.dart';
import '../services/group_file_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_net_image.dart';
import '../widgets/link_card.dart';
import 'file/file_preview_page.dart';
import 'forward_picker_page.dart';
import 'image_viewer_page.dart';

/// 合并转发消息的「聊天记录」详情页。
///
/// content 为 type=12 消息的 JSON 字符串：
/// `{v, count, users, items: [{senderId, senderName, type, content, time}]}`
/// 嵌套合并（items 里还有 type=12）会被拍平成一层逐条展示。
class MergeForwardDetailPage extends StatefulWidget {
  final String content; // 原始合并消息 JSON（整体转发时原样透传）
  final String myId;

  /// 昵称解析兜底（旧合并消息 items 无昵称/含「我」时，用当前会话实时解析）
  final String Function(String senderId)? nameOf;

  /// 头像解析兜底（items 里 senderAvatar 为空时按 senderId 实时取）
  final String Function(String senderId)? avatarOf;

  /// 所属会话（可选）：文件点击走应用内预览（FilePreviewPage）时需要
  final String? convId;
  final String? convName;

  /// 文件元数据反查兜底（旧合并消息 items 缺 file 时，按原消息 msgId 实时查）
  final Future<Map<String, dynamic>?> Function(String msgId)? fileResolver;

  const MergeForwardDetailPage({
    super.key,
    required this.content,
    required this.myId,
    this.nameOf,
    this.avatarOf,
    this.convId,
    this.convName,
    this.fileResolver,
  });

  @override
  State<MergeForwardDetailPage> createState() => _MergeForwardDetailPageState();
}

class _MergeForwardDetailPageState extends State<MergeForwardDetailPage> {
  List<Map<String, dynamic>> _items = [];
  String _users = '';
  bool _parsed = false;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  void _parse() {
    try {
      final data = jsonDecode(widget.content);
      if (data is! Map) return;
      final users = data['users']?.toString() ?? '';
      final flat = <Map<String, dynamic>>[];
      void walk(List items) {
        for (final raw in items) {
          if (raw is! Map) continue;
          final type = (raw['type'] as num?)?.toInt() ?? 1;
          final content = raw['content']?.toString() ?? '';
          if (type == 12) {
            // 嵌套合并 → 拍平（保留内层每条的发送者/时间）
            try {
              final inner = jsonDecode(content);
              if (inner is Map && inner['items'] is List) {
                walk(inner['items'] as List);
                continue;
              }
            } catch (_) {}
          }
          // ⚠️ 必须保留全部扩展字段（file/senderAvatar/msgId）——
          // 此前只复制 5 个基础字段，把 file 元数据丢了，导致详情页
          // 文件永远「暂不支持预览」、头像显示不了（聊天窗口却正常）。
          flat.add({
            'senderId': raw['senderId']?.toString() ?? '',
            'senderName': raw['senderName']?.toString() ?? '',
            'senderAvatar': raw['senderAvatar']?.toString() ?? '',
            'type': type,
            'content': content,
            'time': raw['time']?.toString() ?? '',
            'file': raw['file'] is Map
                ? Map<String, dynamic>.from(raw['file'] as Map)
                : null,
            'msgId': raw['msgId']?.toString() ?? '',
          });
        }
      }

      if (data['items'] is List) walk(data['items'] as List);
      _items = flat;
      _users = users;
      _parsed = true;
    } catch (_) {
      _parsed = false;
    }
  }

  /// 非文本类型在记录里的占位文案（语音通话/红包/转账/名片等显示标签）
  String _itemText(Map<String, dynamic> item) {
    final t = AppLocalizations.of(context).t;
    final type = (item['type'] as num?)?.toInt() ?? 1;
    const map = {
      2: 'svcImage',
      3: 'svcFile',
      4: 'svcVoice',
      5: 'svcVideo',
      7: 'svcCall',
      8: 'svcRedPacket',
      9: 'svcTransfer',
      10: 'svcCard',
      11: 'svcLinkCard',
      12: 'mergeRecordTag',
      14: 'svcLocation',
    };
    final k = map[type];
    if (type == 1) return item['content'] ?? '';
    return k != null ? t(k) : (item['content'] ?? '');
  }

  /// 记录内容渲染：文本/图片/文件/视频/链接卡片显示真实内容，
  /// 语音通话/红包/转账/名片/嵌套合并显示标签
  Widget _itemBody(BuildContext context, Map<String, dynamic> item) {
    final cs = Theme.of(context).colorScheme;
    final t = AppLocalizations.of(context).t;
    final type = (item['type'] as num?)?.toInt() ?? 1;
    final content = item['content']?.toString() ?? '';
    switch (type) {
      case 1: // 文本
        return SelectableText(content,
            style: TextStyle(fontSize: 15, height: 1.4, color: cs.onSurface));
      case 2: // 图片：content 为 URL（历史兼容 | 分隔多图）
        final urls =
            content.split('|').where((s) => s.trim().isNotEmpty).toList();
        if (urls.isEmpty) return _labelText(t('svcImage'), cs);
        return _imageList(context, urls);
      case 3: // 文件：content=文件名，file 元数据带 url/size
        return _fileCard(context, item, isVideo: false);
      case 5: // 视频：同样式卡片，点击外部打开
        return _fileCard(context, item, isVideo: true);
      case 11: // 链接卡片 / 网页小程序：复用聊天页 LinkCard 组件
        return LinkCardWidget(content: content, isMine: false);
      default: // 语音通话/红包/转账/名片/嵌套合并 → 标签
        return _labelText(_itemText(item), cs);
    }
  }

  Widget _labelText(String text, ColorScheme cs) {
    return SelectableText(text,
        style:
            TextStyle(fontSize: 15, height: 1.4, color: cs.onSurfaceVariant));
  }

  /// 图片列表：单图满宽（自适应高，点击看大图）；多图两列网格
  Widget _imageList(BuildContext context, List<String> urls) {
    if (urls.length == 1) {
      return GestureDetector(
        onTap: () => _openViewer(context, urls.first),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: AppNetImage(
              url: AppConfig.assetUrl(urls.first),
              width: 200,
              cacheWidth: 600,
            ),
          ),
        ),
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final u in urls.take(9))
          GestureDetector(
            onTap: () => _openViewer(context, u),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: AppNetImage(
                url: AppConfig.assetUrl(u),
                width: 96,
                height: 96,
                cacheWidth: 300,
              ),
            ),
          ),
      ],
    );
  }

  void _openViewer(BuildContext context, String url) {
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => ImageViewerPage(url: AppConfig.assetUrl(url))),
    );
  }

  /// 文件 / 视频卡片（图标 + 名称 + 大小）
  /// 点击：有 fileId → 应用内 FilePreviewPage（doc/PDF 可预览，与聊天页一致）；
  /// 无 fileId 有 url → 外部打开；都没有（旧合并消息没存 file）→ toast 提示
  Widget _fileCard(BuildContext context, Map<String, dynamic> item,
      {required bool isVideo}) {
    final cs = Theme.of(context).colorScheme;
    final name = item['content']?.toString() ?? '';
    final file = (item['file'] as Map?)?.cast<String, dynamic>();
    final size = (file?['size'] as num?)?.toInt() ?? 0;
    return InkWell(
      onTap: () => _openFile(context, item),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: cs.onSurfaceVariant.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
                isVideo
                    ? Icons.movie_outlined
                    : Icons.insert_drive_file_outlined,
                size: 26,
                color: AppTheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name.isEmpty ? (isVideo ? 'video' : 'file') : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14, height: 1.3, color: cs.onSurface)),
                  if (size > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(_fmtSize(size),
                          style: TextStyle(
                              fontSize: 11, color: cs.onSurfaceVariant)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 文件/视频点击（与聊天页 _openFileBubble 同款降级链）
  Future<void> _openFile(
      BuildContext context, Map<String, dynamic> item) async {
    final t = AppLocalizations.of(context).t;
    var file = (item['file'] as Map?)?.cast<String, dynamic>();
    // 旧合并消息 items 里没存 file → 按原消息 msgId 从当前会话消息反查兜底
    if (file == null) {
      final mid = (item['msgId'] ?? '').toString();
      if (mid.isNotEmpty && widget.fileResolver != null) {
        try {
          file = await widget.fileResolver!(mid);
        } catch (_) {}
      }
    }
    final fileId = (file?['fileId'] ?? '').toString();
    final url = (file?['url'] ?? '').toString();

    // 1) 有 fileId → 应用内预览（doc/PDF/图片走 FilePreviewPage 分支）
    if (fileId.isNotEmpty && (widget.convId ?? '').isNotEmpty) {
      final mime = (file?['mimeType'] ?? '').toString();
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => FilePreviewPage(
          item: GroupFileItem(
            fileId: fileId,
            name: (file?['name'] ?? item['content'] ?? '').toString(),
            size: (file?['size'] as num?)?.toInt() ?? 0,
            uploaderName: item['senderName']?.toString() ?? '',
            category: _categoryOfMime(mime),
            url: url,
          ),
          convId: widget.convId!,
          convName: widget.convName ?? '',
        ),
      ));
      return;
    }

    // 2) 无 fileId 有 url → 外部打开
    if (url.isNotEmpty) {
      final uri = Uri.tryParse(AppConfig.assetUrl(url));
      if (uri != null) {
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          return;
        } catch (_) {
          // 打开失败继续走 toast
        }
      }
    }

    // 3) 反查也拿不到（跨会话的旧合并消息，数据里确实没存文件信息）
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(t('mergeFileMissing')),
        duration: const Duration(seconds: 2)));
  }

  /// MIME → 群文件分类（与聊天页 _categoryOfMime 口径一致）
  static String _categoryOfMime(String mime) {
    final m = mime.toLowerCase();
    if (m.startsWith('image/')) return 'image';
    if (m.startsWith('video/')) return 'video';
    if (m.startsWith('audio/')) return 'audio';
    if (m.isEmpty) return 'other';
    return 'doc';
  }

  String _fmtSize(int bytes) {
    if (bytes >= 1024 * 1024)
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  /// 整体转发：把这条合并消息原样（嵌套保留）发到目标会话
  Future<void> _forwardAgain() async {
    final picked = await Navigator.push<Map>(
      context,
      MaterialPageRoute(builder: (_) => ForwardPickerPage(myId: widget.myId)),
    );
    if (picked == null || !mounted) return;
    final targetId = picked['id']?.toString() ?? '';
    if (targetId.isEmpty) return;
    final t = AppLocalizations.of(context).t;
    try {
      String convId;
      if (picked['kind'] == 'group') {
        convId = targetId;
      } else {
        final conv = await ConversationService().createDirect(targetId);
        convId = conv['id']?.toString() ?? '';
      }
      if (convId.isEmpty) throw Exception(t('forwardNotAllowed'));
      await ConversationService().sendRaw(convId, 12, widget.content);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(t('forwardSent')),
          duration: const Duration(seconds: 1)));
      Navigator.pop(context);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(t('forwardNotAllowed')),
          duration: const Duration(seconds: 1)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(t('mergeDetailTitle')),
        actions: [
          TextButton(
            onPressed: _forwardAgain,
            child: Text(t('chatActionForward')),
          ),
        ],
      ),
      body: !_parsed || _items.isEmpty
          ? Center(
              child: Text(t('mergeEmpty'),
                  style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)))
          : ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              itemCount: _items.length + 1,
              separatorBuilder: (_, __) => const SizedBox(height: 14),
              itemBuilder: (context, i) => i == 0
                  ? _header(context)
                  : _recordRow(context, _items[i - 1]),
            ),
    );
  }

  /// 参与者 + 条数汇总头
  Widget _header(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = AppLocalizations.of(context).t;
    return Center(
      child: Text(
        _users.isEmpty
            ? t('mergeCountMsg', {'n': '${_items.length}'})
            : '$_users · ${t('mergeCountMsg', {'n': '${_items.length}'})}',
        textAlign: TextAlign.center,
        style: TextStyle(
            fontSize: 12, color: cs.onSurfaceVariant.withValues(alpha: 0.7)),
      ),
    );
  }

  Widget _recordRow(BuildContext context, Map<String, dynamic> item) {
    final cs = Theme.of(context).colorScheme;
    final senderId = item['senderId']?.toString() ?? '';
    // 昵称：items 自带 → 回调实时解析兜底（旧消息里存的是「我」/ID 尾号时纠正）
    var name = item['senderName']?.toString() ?? '';
    final resolved = widget.nameOf?.call(senderId) ?? '';
    if (resolved.isNotEmpty) name = resolved;
    // 头像：items 自带 senderAvatar → 回调实时解析兜底；都没有显示文字圈
    var avatarUrl = item['senderAvatar']?.toString() ?? '';
    if (avatarUrl.isEmpty) avatarUrl = widget.avatarOf?.call(senderId) ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 发送者行：头像 + 昵称 + 时间
        Row(
          children: [
            _avatar(context, avatarUrl, name),
            const SizedBox(width: 8),
            Expanded(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ),
            Text(item['time']?.toString() ?? '',
                style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.7))),
          ],
        ),
        const SizedBox(height: 6),
        // 内容气泡：白色圆角卡片（与消息列表卡片风格一致）
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(4),
              topRight: Radius.circular(12),
              bottomLeft: Radius.circular(12),
              bottomRight: Radius.circular(12),
            ),
          ),
          child: _itemBody(context, item),
        ),
      ],
    );
  }

  /// 圆形头像：占位为「色块 + 昵称尾字」，加载中/失败/无 URL 均显示它
  Widget _avatar(BuildContext context, String url, String name) {
    return AppAvatar(
      url: url,
      name: name,
      size: 28,
      background: AppTheme.primary.withValues(alpha: 0.15),
    );
  }
}
