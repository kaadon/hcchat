import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/push_service.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/update_dialog.dart';
import 'policy_page.dart';

/// 关于页：版本号 + 更新内容 + 下载地址（数据来自后台 /auth/config）
///
/// 2026-09-14 从 `me_page.dart` 抽出来独立成文件：钱包页的「关于钱包」行需要
/// 跳到这里，而 `wallet_page.dart` ← `me_page.dart` 已存在反向依赖，
/// 再把 `me_page.dart` 引回来会形成循环 import。抽成独立文件后
/// `me_page.dart` 与 `wallet_page.dart` 都单向依赖本文件，环被打断。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});
  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  final _api = ApiClient.instance;
  // 本地版本基准：统一走 UpdateService（由 apply_config 自动同步，勿手改）
  String get _currentVersion => UpdateService.currentVersion;

  /// 后台配置的软件名（无配置回落默认名）——政策文案/简介统一替换
  String get _appName => _brandName.isNotEmpty ? _brandName : 'ChatPulse';

  String _version = '';
  String _updateLog = '';
  String _androidUrl = '';
  String _iosUrl = '';
  String _brandName = '';
  String _brandLogo = ''; // 后台配置的品牌 logo（appLogo/brandLogo）

  @override
  void initState() {
    super.initState();
    _loadCached(); // 缓存直出：品牌/版本信息首帧即显，不空屏等待
    _load();
  }

  /// 先渲染本地缓存的品牌与版本配置，网络回来后覆盖刷新
  Future<void> _loadCached() async {
    try {
      final raw = await _api.readPref('authConfig');
      if (raw == null || raw.isEmpty || !mounted) return;
      final d = jsonDecode(raw);
      if (d is Map) _applyConfig(Map<String, dynamic>.from(d));
    } catch (_) {}
  }

  void _applyConfig(Map<String, dynamic> d) {
    setState(() {
      _version = _platformLatest(d);
      _updateLog = d['updateLog']?.toString() ?? '';
      _androidUrl = d['androidUrl']?.toString() ?? '';
      _iosUrl = d['iosUrl']?.toString() ?? '';
      _brandName = (d['brandName'] ?? d['appName'] ?? '').toString();
      _brandLogo = (d['brandLogo'] ?? d['appLogo'] ?? '').toString();
    });
  }

  /// 三端独立检测：取当前平台的后台最新版本号；
  /// android_version / ios_version 未配置时回退旧键 appVersion（与后端一致）；H5 返回空
  String _platformLatest(Map<String, dynamic> d) {
    final legacy = (d['appVersion'] ?? '').toString();
    if (kIsWeb) return '';
    if (Platform.isIOS) {
      final v = (d['iosVersion'] ?? '').toString();
      return v.isNotEmpty ? v : legacy;
    }
    final v = (d['androidVersion'] ?? '').toString();
    return v.isNotEmpty ? v : legacy;
  }

  Future<void> _load() async {
    try {
      // 品牌信息（名称/logo）与版本配置同接口，这里一次拉全
      final r = await _api.get('/api/v1/auth/config');
      final d =
          (r.data as Map<String, dynamic>)['data'] as Map<String, dynamic>? ??
              {};
      if (mounted && d.isNotEmpty) {
        _applyConfig(d);
        // 配置类内容"请求一次缓存即可"：落盘，下次进页直出
        unawaited(_api.writePref('authConfig', jsonEncode(d)));
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(title: Text(t('meAboutUs'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 品牌 logo：读取后台配置，无配置回落默认品牌头像
          Center(
            child: _brandLogo.isNotEmpty
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: SizedBox(
                      width: 72,
                      height: 72,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          AppTheme.brandAvatar(size: 72),
                          Image.network(
                            _brandLogo,
                            fit: BoxFit.cover,
                            frameBuilder: (ctx, child, frame, wasSync) =>
                                (wasSync || frame != null)
                                    ? child
                                    : const SizedBox.shrink(),
                            errorBuilder: (_, __, ___) =>
                                const SizedBox.shrink(),
                          ),
                        ],
                      ),
                    ),
                  )
                : AppTheme.brandAvatar(size: 72),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(_brandName.isEmpty ? t('meAbout') : _brandName,
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface)),
          ),
          if (_version.isNotEmpty)
            Center(
              child: Text(t('meVersion', {'version': _version}),
                  style:
                      TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            ),
          const SizedBox(height: 24),
          if (_updateLog.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t('meWhatsNew'),
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface)),
                  const SizedBox(height: 8),
                  Text(_updateLog,
                      style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant,
                          height: 1.6)),
                ],
              ),
            ),
          const SizedBox(height: 16),
          // 更多信息
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('meAboutUs'),
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface)),
                const SizedBox(height: 8),
                Text(
                  t('meAboutDesc').replaceAll('ChatPulse', _appName),
                  style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                      height: 1.6),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                _infoRow(Icons.system_update_outlined, t('meCheckUpdate'),
                    _checkUpdate,
                    trailing: _version.isEmpty
                        ? null
                        : (_version == _currentVersion
                            ? t('meUpToDate')
                            : t('meNewVersion'))),
                Divider(height: 1, indent: 50, color: scheme.outlineVariant),
                _infoRow(Icons.policy_outlined, t('mePrivacyPolicy'), () {
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => PolicyPage(
                          title: t('mePrivacyPolicy'),
                          content: kPrivacyPolicy,
                          appName: _appName)));
                }),
                Divider(height: 1, indent: 50, color: scheme.outlineVariant),
                _infoRow(Icons.gavel_outlined, t('meTermsOfService'), () {
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => PolicyPage(
                          title: t('meTermsOfService'),
                          content: kTermsOfService,
                          appName: _appName)));
                }),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // 推送诊断：极光 RegistrationID + alias 绑定状态（排障用，点击复制）
          if (!kIsWeb) _pushDiagCard(),
          const SizedBox(height: 24),
          Center(
            child: Text(
                'Copyright © ${_brandName.isEmpty ? 'ChatPulse' : _brandName}',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
          const SizedBox(height: 16),
          if (_androidUrl.isNotEmpty)
            _linkRow(Icons.android, t('meAndroidDownload'), _androidUrl),
          if (_iosUrl.isNotEmpty)
            _linkRow(Icons.apple, t('meIosDownload'), _iosUrl),
        ],
      ),
    );
  }

  /// 检测更新：拉后台配置，有新版本弹新版更新弹窗（外部浏览器下载）。
  /// H5 不检测更新——网页刷新即最新，直接提示已最新。
  Future<void> _checkUpdate() async {
    if (kIsWeb) {
      if (!mounted) return;
      AppDialogs.toast(
          context,
          AppLocalizations.of(context)
              .t('meAlreadyLatestVersion', {'version': _currentVersion}));
      return;
    }
    // 重新拉一次保证拿到最新后台配置
    final info = await UpdateService.fetch();
    if (!mounted) return;
    final t = AppLocalizations.of(context).t;
    if (info == null || info.latestForPlatform.isEmpty) {
      AppDialogs.toast(context, t('meGetVersionFailed'));
      return;
    }
    final shown = await UpdateDialog.showIfAvailable(context, info);
    if (!shown && mounted) {
      AppDialogs.toast(
          context, t('meAlreadyLatestVersion', {'version': _currentVersion}));
    }
  }

  /// 推送诊断卡片：展示极光 RegistrationID 与 alias 绑定状态，
  /// 点击复制诊断文本（发给开发定位离线推送问题）。
  /// RegistrationID 为空 = SDK 没注册到极光服务器（先查 entitlements/证书环境）；
  /// ID 有值但服务端按 alias 查不到设备 = setAlias 没生效（看绑定状态文案）。
  Widget _pushDiagCard() {
    final push = PushService.instance;
    final t = AppLocalizations.of(context).t;
    return ValueListenableBuilder<String>(
      valueListenable: push.diag,
      builder: (context, diag, _) => ValueListenableBuilder<String>(
        valueListenable: push.regId,
        builder: (context, rid, __) {
          final scheme = Theme.of(context).colorScheme;
          return InkWell(
            onTap: () {
              Clipboard.setData(ClipboardData(
                  text:
                      'regId=$rid\ndiag=$diag\nversion=$_currentVersion\nplatform=${Platform.operatingSystem}'));
              AppDialogs.toast(context, t('meCopied'));
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.notifications_outlined,
                          size: 18, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(t('pushDiagTitle'),
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurface)),
                      ),
                      Icon(Icons.content_copy,
                          size: 14, color: scheme.onSurfaceVariant),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${t('pushDiagRegId')}: ${rid.isEmpty ? t('pushDiagRegEmpty') : rid}',
                    style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                        height: 1.5),
                  ),
                  Text(
                    '${t('pushDiagStatus')}: $diag',
                    style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                        height: 1.5),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, VoidCallback onTap,
      {String? trailing}) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Icon(icon, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 15, color: scheme.onSurface)),
            ),
            if (trailing != null && trailing.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(trailing,
                    style: TextStyle(
                        fontSize: 13, color: scheme.onSurfaceVariant)),
              ),
            Icon(Icons.chevron_right, color: scheme.onSurfaceVariant, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _linkRow(IconData icon, String label, String url) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () async {
        // 直接调系统外部浏览器打开下载地址
        final uri = Uri.tryParse(url);
        if (uri == null || !uri.hasScheme) return;
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {}
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
                child: Text(label,
                    style: TextStyle(fontSize: 14, color: scheme.onSurface))),
            Icon(Icons.open_in_new, size: 16, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
