import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_locale.dart';
import '../services/update_service.dart';

/// 版本更新弹窗（App 启动自动检查 / 关于页手动检查 共用）
///
/// UI：顶部主色渐变头图（火箭图标 + 新版本号徽章），
/// 中部滚动更新内容，底部「暂不更新」+「立即更新」。
/// 点立即更新 → 系统外部浏览器打开下载地址。
class UpdateDialog extends StatelessWidget {
  final UpdateInfo info;
  const UpdateDialog({super.key, required this.info});

  /// 有新版本且配置了下载地址时弹出；返回是否已弹出（供调用方决定是否提示"已是最新"）
  static Future<bool> showIfAvailable(
      BuildContext context, UpdateInfo? info) async {
    if (info == null || !info.hasNew || !info.hasUrl) return false;
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => UpdateDialog(info: info),
    );
    return true;
  }

  /// 外部浏览器打开下载地址
  Future<void> _openDownloadUrl(BuildContext context) async {
    final uri = Uri.tryParse(info.downloadUrlForPlatform);
    if (uri == null || !uri.hasScheme) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Container(
          color: scheme.surface,
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── 头部：主色渐变 + 火箭 + 新版本徽章 ──
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(20, 26, 20, 22),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      scheme.primary,
                      scheme.primary.withValues(alpha: 0.72),
                    ],
                  ),
                ),
                child: Column(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.22),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.rocket_launch_outlined,
                          color: Colors.white, size: 30),
                    ),
                    const SizedBox(height: 12),
                    Text(t('meNewVersionFound'),
                        style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                    const SizedBox(height: 6),
                    // 新版本号徽章
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.24),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text('V ${info.latestForPlatform}',
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white)),
                    ),
                  ],
                ),
              ),
              // ── 内容：更新日志（可滚动，限高）──
              Flexible(
                child: Container(
                  constraints: const BoxConstraints(minHeight: 84),
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (info.log.isNotEmpty) ...[
                          Text(t('meWhatsNew'),
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: scheme.onSurface)),
                          const SizedBox(height: 6),
                          Text(info.log,
                              style: TextStyle(
                                  fontSize: 13,
                                  height: 1.6,
                                  color: scheme.onSurfaceVariant)),
                        ] else
                          // 后台没写更新日志时给一行版本过渡，避免弹窗空荡
                          Text(
                              '${UpdateService.currentVersion}  →  ${info.latestForPlatform}',
                              style: TextStyle(
                                  fontSize: 13,
                                  color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ),
              ),
              // ── 底部按钮 ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 44),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          foregroundColor: scheme.onSurfaceVariant,
                        ),
                        child: Text(t('meLater'),
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          Navigator.of(context).pop();
                          _openDownloadUrl(context);
                        },
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 44),
                          backgroundColor: scheme.primary,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        child: Text(t('meDownloadNow'),
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
