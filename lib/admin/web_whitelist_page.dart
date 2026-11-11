import 'package:flutter/material.dart';

import '../services/group_file_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';

/// 网页小程序白名单管理页（后台 / 管理员）。
///
/// 功能：
/// - 列表展示 domain / 展示名 / 启用开关 / JS 桥开关 / 操作（编辑、删除）；
/// - 按 domain 实时搜索；
/// - 新增 / 编辑弹窗（domain、displayName、enabled、nativeBridge）；
/// - 数据来自 [GroupFileService] 的 `/api/v1/admin/web-whitelist` 系列接口。
///
/// 说明：当前 App 无独立「管理后台」入口，本页已实现但未挂接入点；
/// 待后台/管理员模块接入时直接 `Navigator.push` 到此页即可（见 PRD 备注）。
class WebWhitelistPage extends StatefulWidget {
  const WebWhitelistPage({super.key});

  @override
  State<WebWhitelistPage> createState() => _WebWhitelistPageState();
}

class _WebWhitelistPageState extends State<WebWhitelistPage> {
  final _svc = GroupFileService.instance;
  final _search = TextEditingController();

  List<WhitelistItem> _all = [];
  bool _loading = true;
  bool _failed = false;
  String _kw = '';

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
      final list = await _svc.listWhitelist();
      if (!mounted) return;
      setState(() {
        _all = list;
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

  List<WhitelistItem> get _filtered {
    if (_kw.isEmpty) return _all;
    final kw = _kw.toLowerCase();
    return _all.where((e) => e.domain.toLowerCase().contains(kw)).toList();
  }

  Future<void> _toggleEnabled(WhitelistItem item, bool v) async {
    final next = item.copyWith(enabled: v);
    setState(() {
      _all = _all.map((e) => e.id == item.id ? next : e).toList();
    });
    try {
      await _svc.updateWhitelist(next);
    } catch (e) {
      if (!mounted) return;
      AppDialogs.toast(context, '更新失败：${e.toString()}');
      _load();
    }
  }

  Future<void> _toggleBridge(WhitelistItem item, bool v) async {
    final next = item.copyWith(nativeBridge: v);
    setState(() {
      _all = _all.map((e) => e.id == item.id ? next : e).toList();
    });
    try {
      await _svc.updateWhitelist(next);
    } catch (e) {
      if (!mounted) return;
      AppDialogs.toast(context, '更新失败：${e.toString()}');
      _load();
    }
  }

  Future<void> _delete(WhitelistItem item) async {
    final ok = await AppDialogs.confirm(
      context,
      title: '删除白名单',
      message: '确定删除「${item.domain}」吗？',
      confirmText: '删除',
    );
    if (ok != true) return;
    setState(() {
      _all = _all.where((e) => e.id != item.id).toList();
    });
    try {
      await _svc.deleteWhitelist(item.id);
    } catch (e) {
      if (!mounted) return;
      AppDialogs.toast(context, '删除失败：${e.toString()}');
      _load();
    }
  }

  /// 新增 / 编辑弹窗。
  Future<void> _showEditor({WhitelistItem? existing}) async {
    final domainCtrl = TextEditingController(text: existing?.domain ?? '');
    final nameCtrl = TextEditingController(text: existing?.displayName ?? '');
    var enabled = existing?.enabled ?? true;
    var bridge = existing?.nativeBridge ?? false;

    final result = await showDialog<WhitelistItem>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(existing == null ? '新增白名单' : '编辑白名单'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _field('域名（domain）', domainCtrl, hint: 'example.com'),
                const SizedBox(height: 12),
                _field('展示名', nameCtrl, hint: '示例小程序'),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用'),
                  value: enabled,
                  onChanged: (v) => setSt(() => enabled = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('注入 JS 桥'),
                  subtitle: const Text('开启后原生 WebView 注入 window.IM_BRIDGE'),
                  value: bridge,
                  onChanged: (v) => setSt(() => bridge = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final domain = domainCtrl.text.trim();
                if (domain.isEmpty) {
                  AppDialogs.toast(ctx, '请填写域名');
                  return;
                }
                Navigator.of(ctx).pop(WhitelistItem(
                  id: existing?.id ?? '',
                  domain: domain,
                  displayName: nameCtrl.text.trim(),
                  enabled: enabled,
                  nativeBridge: bridge,
                ));
              },
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
              ),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    if (result == null) return;

    try {
      if (existing == null) {
        await _svc.createWhitelist(result);
      } else {
        await _svc.updateWhitelist(result.copyWith(id: existing.id));
      }
      if (!mounted) return;
      AppDialogs.toast(context, '已保存');
      _load();
    } catch (e) {
      if (!mounted) return;
      AppDialogs.toast(context, '保存失败：${e.toString()}');
    }
  }

  Widget _field(String label, TextEditingController c, {String hint = ''}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 13, color: Color(0xFF6B7480))),
        const SizedBox(height: 6),
        TextField(
          controller: c,
          decoration: InputDecoration(
            hintText: hint.isEmpty ? null : hint,
            hintStyle: const TextStyle(fontSize: 14, color: Color(0xFF9AA3AE)),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: context.cs.outlineVariant),
            ),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: context.cs.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.chevron_left, size: 28, color: Color(0xFF111111)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('网页白名单',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: Color(0xFF111111))),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.add, size: 24, color: Color(0xFF111111)),
            onPressed: () => _showEditor(),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Container(
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
                        hintText: '搜索域名',
                        hintStyle: TextStyle(
                            fontSize: 14, color: context.cs.onSurfaceVariant),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
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
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AppTheme.primary));
    }
    if (_failed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('加载失败',
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
            Icon(Icons.shield_outlined, size: 56, color: context.cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              _kw.isNotEmpty ? '没有匹配的域名' : '还没有白名单',
              style: TextStyle(fontSize: 14, color: context.cs.onSurfaceVariant),
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
            Divider(height: 1, color: context.cs.outlineVariant),
        itemBuilder: (_, i) => _row(items[i]),
      ),
    );
  }

  Widget _row(WhitelistItem item) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.domain,
                        style: TextStyle(
                            fontSize: 15, color: context.cs.onSurface)),
                    if (item.displayName.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(item.displayName,
                            style: TextStyle(
                                fontSize: 12,
                                color: context.cs.onSurfaceVariant)),
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.edit_outlined,
                    size: 20, color: context.cs.onSurfaceVariant),
                onPressed: () => _showEditor(existing: item),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline,
                    size: 20, color: AppTheme.danger),
                onPressed: () => _delete(item),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _switchCell('启用', item.enabled, (v) => _toggleEnabled(item, v)),
              const SizedBox(width: 16),
              _switchCell('JS 桥', item.nativeBridge, (v) => _toggleBridge(item, v)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _switchCell(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: TextStyle(fontSize: 13, color: context.cs.onSurfaceVariant)),
        const SizedBox(width: 6),
        Switch(
          value: value,
          onChanged: onChanged,
          activeColor: AppTheme.primary,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
  }
}
