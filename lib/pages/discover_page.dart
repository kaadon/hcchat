import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../services/api_client.dart';
import '../services/wide_layout_store.dart';
import '../l10n/app_locale.dart';
import '../theme/app_theme.dart';
import 'moments_page.dart';
import 'scan_qr_login_page.dart';
import 'web_browser_page.dart';

/// 发现：列表展示后台配置的网页小程序，点击打开（H5 新标签页 / native 浏览器）
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  final _dio = ApiClient.instance.dio;
  final _api = ApiClient.instance;
  List<Map<String, dynamic>> _apps = [];
  bool _loading = true;
  bool _loadFailed = false; // 网络失败且无缓存可显示 → 失败视图（有重试按钮）

  static const _icons = [
    Icons.web,
    Icons.help_outline,
    Icons.folder_special_outlined,
    Icons.build_outlined,
    Icons.dashboard_outlined,
    Icons.widgets_outlined,
  ];

  @override
  void initState() {
    super.initState();
    _loadCachedApps();
    _load();
  }

  /// 先渲染本地缓存的小程序列表，避免每次进页都从空白/菊花开始；
  /// 网络回来后覆盖刷新。
  Future<void> _loadCachedApps() async {
    try {
      final raw = await _api.readPref('discoverApps');
      if (raw == null || raw.isEmpty || !mounted || _apps.isNotEmpty) return;
      final list = jsonDecode(raw);
      if (list is List && list.isNotEmpty) {
        setState(() {
          _apps = list.whereType<Map>().map((e) {
            final m = <String, dynamic>{};
            e.forEach((k, v) => m[k.toString()] = v);
            return m;
          }).toList();
          _loading = false;
        });
      }
    } catch (_) {}
  }

  Future<void> _load() async {
    try {
      final r = await _dio.get('/api/v1/app/list',
          options: Options(
              headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
      final data =
          (r.data as Map<String, dynamic>)['data'] as List<dynamic>? ?? [];
      if (mounted) {
        setState(() {
          _apps = data.map((e) => e as Map<String, dynamic>).toList();
          _loading = false;
        });
        unawaited(_api.writePref('discoverApps', jsonEncode(data)));
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          // 没有缓存数据兜底才算失败（有缓存时页面仍可用，静默即可）
          _loadFailed = _apps.isEmpty;
        });
      }
    }
  }

  /// 失败视图：网络不通时不再是一片静默空白，给明确提示 + 重试入口
  Widget _loadFailedView() {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined,
              size: 44, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(t('chatListLoadFailed'),
              style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () {
              setState(() {
                _loading = true;
                _loadFailed = false;
              });
              _load();
            },
            child: Text(t('contactsRetry'),
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primary)),
          ),
        ],
      ),
    );
  }

  String _name(Map<String, dynamic> a) {
    final loc = Localizations.localeOf(context).languageCode;
    return (loc == 'zh' ? a['nameZh']?.toString() : a['nameEn']?.toString()) ??
        a['nameZh']?.toString() ??
        AppLocalizations.of(context).t('discoverMiniApp');
  }

  Future<void> _open(Map<String, dynamic> a) async {
    final url = a['url']?.toString() ?? '';
    if (url.isEmpty) return;
    // 内置浏览器打开（右上角圆形按钮关闭返回发现页）
    // 宽屏（折叠屏展开/平板）：右侧栏打开，左侧发现页不动
    await WideLayoutStore.instance.openDetail(
      context,
      WebBrowserPage(url: url, title: _name(a)),
      paneKey: 'web:$url',
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 顶栏：标题 + 扫一扫入口（扫码登录）
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                    child: Row(
                      children: [
                        Text(t('discover'),
                            style: TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                color: scheme.onSurface)),
                        const Spacer(),
                        IconButton(
                          onPressed: _openQrScanner,
                          icon: Icon(Icons.qr_code_scanner,
                              size: 24, color: scheme.onSurface),
                          splashRadius: 22,
                          tooltip: t('discoverScan'),
                        ),
                      ],
                    ),
                  ),
                  // 快捷入口（扫一扫 / 朋友圈）
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: _quickEntry(
                              scheme,
                              Icons.qr_code_scanner,
                              t('discoverScan'),
                              t('discoverScanSubtitle'),
                              AppTheme.cyan,
                              _openQrScanner),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _quickEntry(
                              scheme,
                              Icons.camera_alt_outlined,
                              t('discoverMoments'),
                              t('discoverMomentsSubtitle'),
                              AppTheme.orange, () {
                            WideLayoutStore.instance.openDetail(
                                context, const MomentsPage(),
                                paneKey: 'moments');
                          }),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _apps.isEmpty && _loadFailed
                        ? _loadFailedView()
                        : _apps.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.apps_outage_outlined,
                                        size: 56,
                                        color: scheme.onSurfaceVariant
                                            .withValues(alpha: 0.5)),
                                    const SizedBox(height: 12),
                                    Text(t('discoverNoApps'),
                                        style: TextStyle(
                                            color: scheme.onSurfaceVariant,
                                            fontSize: 14)),
                                  ],
                                ),
                              )
                            : ListView.separated(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 12, 16, 8),
                                itemCount: _apps.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (_, i) =>
                                    _appTile(scheme, _apps[i], i),
                              ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _quickEntry(ColorScheme scheme, IconData icon, String label,
      String subtitle, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 22, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 扫一扫：手机端扫 PC 端二维码登录
  void _openQrScanner() {
    // 宽屏：右侧栏打开（相机预览在右栏内渲染）；窄屏：push 整页
    WideLayoutStore.instance
        .openDetail(context, const ScanQrLoginPage(), paneKey: 'scan');
  }

  Widget _appTile(ColorScheme scheme, Map<String, dynamic> a, int i) {
    final cat = a['category']?.toString() ?? '';
    // 2026-11-01：后台「上架小程序」的图标可能是协议相对地址（//host/...），
    // Image.network 无法解析会静默失败（露出底层默认图标）。与头像同源问题，
    // 统一走 assetUrl 归一化，补齐协议 / 修正 127.0.0.1 / https 页面降级。
    final icon = AppConfig.assetUrl(a['icon']?.toString() ?? '');
    final tone = AppTheme.avatarColors[i % AppTheme.avatarColors.length];
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: InkWell(
        onTap: () => _open(a),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 底层图标占位：加载中 / 失败都露出它，不再白块
                      Center(child: _appIconBlock(i, tone)),
                      if (icon.isNotEmpty)
                        Image.network(
                          icon,
                          fit: BoxFit.cover,
                          frameBuilder: (ctx, child, frame, wasSync) =>
                              (wasSync || frame != null)
                                  ? child
                                  : const SizedBox.shrink(),
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_name(a),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: scheme.onSurface)),
                    if (cat.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(cat,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12, color: scheme.onSurfaceVariant)),
                      ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  size: 18, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  Widget _appIconBlock(int i, Color tone) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      ),
      alignment: Alignment.center,
      child: Icon(_icons[i % _icons.length], size: 22, color: tone),
    );
  }
}
