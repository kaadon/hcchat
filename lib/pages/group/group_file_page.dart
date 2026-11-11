import 'package:flutter/material.dart';

import '../../config/app_config.dart';
import '../../theme/app_theme.dart';
import '../../services/group_file_service.dart';
import '../../widgets/app_net_image.dart';
import '../file/file_preview_page.dart';

/// 群文件列表页（功能 A：群文件云盘）。
///
/// - 顶栏标题「群文件」（无商户维度、无存储配额，故不展示用量胶囊）；
/// - 筛选 Tab：全部 | 图片 | 文档 | 视频；
/// - 搜索框（文件名，客户端实时过滤）；
/// - 排序：时间 / 大小；
/// - 列表项：缩略图 / 文件名 / 大小 / 上传者 / 相对时间；点击进入预览；
/// - 空态「本群还没有文件」。
///
/// 数据来自 [GroupFileService.listFiles]。
class GroupFilePage extends StatefulWidget {
  final String convId;
  final String convName;
  const GroupFilePage({super.key, required this.convId, this.convName = ''});

  @override
  State<GroupFilePage> createState() => _GroupFilePageState();
}

class _GroupFilePageState extends State<GroupFilePage> {
  final _svc = GroupFileService.instance;
  final _search = TextEditingController();

  List<GroupFileItem> _all = [];
  bool _loading = true;
  bool _failed = false;

  String _tab = 'all'; // all | image | doc | video
  String _sort = 'time'; // time | size
  String _kw = '';

  static const List<(String, String)> _tabs = [
    ('all', '全部'),
    ('image', '图片'),
    ('doc', '文档'),
    ('video', '视频'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final list = await _svc.listFiles(widget.convId);
      if (!mounted) return;
      setState(() {
        _all = list.files;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  List<GroupFileItem> get _filtered {
    var items = _all;
    if (_tab != 'all') {
      items = items.where((f) => f.category == _tab).toList();
    }
    if (_kw.isNotEmpty) {
      final kw = _kw.toLowerCase();
      items = items.where((f) => f.name.toLowerCase().contains(kw)).toList();
    }
    items = List<GroupFileItem>.from(items);
    items.sort((a, b) {
      if (_sort == 'size') return b.size.compareTo(a.size);
      // time：uploadedAt 降序
      return b.uploadedAt.compareTo(a.uploadedAt);
    });
    return items;
  }

  static String _formatBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }

  static String _relativeTime(String iso) {
    // 服务端下发 UTC（带 Z），转本地再算差值/取日期字段
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: context.cs.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              size: 26, color: Color(0xFF111111)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('群文件',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: Color(0xFF111111))),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: _searchBox(),
          ),
          _tabBar(),
          const SizedBox(height: 4),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _searchBox() {
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: context.cs.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Icon(Icons.search, size: 18, color: context.cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _kw = v.trim()),
              decoration: InputDecoration(
                hintText: '搜索文件名',
                hintStyle:
                    TextStyle(fontSize: 14, color: context.cs.onSurfaceVariant),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              style: TextStyle(fontSize: 14, color: context.cs.onSurface),
            ),
          ),
          if (_search.text.isNotEmpty)
            InkWell(
              onTap: () {
                _search.clear();
                setState(() => _kw = '');
              },
              child: Icon(Icons.close,
                  size: 16, color: context.cs.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  Widget _tabBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          ..._tabs.map((t) => _tabChip(t.$1, t.$2)),
          const Spacer(),
          // 排序：时间 / 大小
          InkWell(
            onTap: () =>
                setState(() => _sort = _sort == 'time' ? 'size' : 'time'),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: context.cs.surfaceContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _sort == 'time' ? Icons.access_time : Icons.swap_vert,
                    size: 14,
                    color: AppTheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Text(_sort == 'time' ? '时间' : '大小',
                      style: TextStyle(
                          fontSize: 12, color: context.cs.onSurfaceVariant)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabChip(String key, String label) {
    final active = _tab == key;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: () => setState(() => _tab = key),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: active ? AppTheme.primary : context.cs.surfaceContainer,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 13,
                  color: active ? Colors.white : context.cs.onSurfaceVariant)),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('文件列表加载失败',
                style: TextStyle(fontSize: 14, color: Color(0xFF6B7480))),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('重新加载')),
          ],
        ),
      );
    }
    final items = _filtered;
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_outlined,
                size: 56, color: context.cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              _kw.isNotEmpty ? '没有匹配的文件' : '本群还没有文件',
              style:
                  TextStyle(fontSize: 14, color: context.cs.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      color: AppTheme.primary,
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: items.length,
        separatorBuilder: (_, __) =>
            Divider(height: 1, indent: 56, color: context.cs.outlineVariant),
        itemBuilder: (_, i) => _itemRow(items[i]),
      ),
    );
  }

  Widget _itemRow(GroupFileItem f) {
    final thumb = f.thumbnailUrl ?? '';
    final leading = _leading(f, thumb);
    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => FilePreviewPage(
          item: f,
          convId: widget.convId,
          convName: widget.convName,
        ),
      )),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(f.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 15, color: context.cs.onSurface)),
                  const SizedBox(height: 4),
                  Text(
                    [
                      _formatBytes(f.size),
                      if (f.uploaderName.isNotEmpty) f.uploaderName,
                      _relativeTime(f.uploadedAt),
                    ].where((s) => s.isNotEmpty).join('  ·  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12, color: context.cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _leading(GroupFileItem f, String thumb) {
    final size = 44.0;
    if (f.category == 'image' && thumb.isNotEmpty) {
      return AppNetImage(
        url: AppConfig.assetUrl(thumb),
        width: size,
        height: size,
        fit: BoxFit.cover,
        radius: BorderRadius.circular(6),
        iconSize: 24,
      );
    }
    return _fileIcon(f, size);
  }

  Widget _fileIcon(GroupFileItem f, double size) {
    IconData icon;
    Color color;
    if (f.category == 'image') {
      icon = Icons.image_outlined;
      color = AppTheme.primary;
    } else if (f.category == 'video') {
      icon = Icons.play_circle_outline;
      color = AppTheme.danger;
    } else if (f.category == 'doc') {
      icon = Icons.description_outlined;
      color = AppTheme.orange;
    } else {
      icon = Icons.insert_drive_file_outlined;
      color = context.cs.onSurfaceVariant;
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: context.cs.surfaceContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 24, color: color),
    );
  }
}
