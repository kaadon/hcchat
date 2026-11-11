import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/settings_service.dart';
import 'account_security_page.dart';
import 'ai_translate_settings_page.dart';
import 'mass_message_page.dart';

/// 系统设置：账号安全 / AI 翻译 / 群发助手
///
/// 2026-09-17 需求：用户中心「我的收藏」下方新增「系统设置」入口（此前本页
/// 无任何入口）；修改登录密码（含支付密码/绑定手机/注销，都在账号安全页）、
/// AI 翻译等功能收口到这里。
/// 2026-09-17 需求2：删除「开启通知」「深色模式」两个开关——与用户中心
/// 「通知和声音」「外观」行重复。
class SystemSettingsPage extends StatefulWidget {
  const SystemSettingsPage({super.key});

  @override
  State<SystemSettingsPage> createState() => _SystemSettingsPageState();
}

class _SystemSettingsPageState extends State<SystemSettingsPage> {
  final _settings = AppSettings.instance;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(title: Text(t('settingsTitle'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                // 账号安全（2026-09-17 移入）：修改登录密码 / 支付密码 /
                // 绑定手机 / 注销账户 都在 AccountSecurityPage 内
                ListTile(
                  leading: Icon(Icons.lock_outline, color: scheme.primary),
                  title: Text(t('acctSecTitle'),
                      style: TextStyle(fontSize: 15, color: scheme.onSurface)),
                  subtitle: Text(t('acctSecChangePassword'),
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                  trailing: Icon(Icons.chevron_right,
                      size: 20, color: scheme.onSurfaceVariant),
                  onTap: () {
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const AccountSecurityPage()));
                  },
                ),
                Divider(height: 1, indent: 50, color: scheme.outlineVariant),
                // AI 翻译设置（自动开关 / 语种 / 用量）
                ListTile(
                  leading:
                      Icon(Icons.translate, color: scheme.onSurfaceVariant),
                  title: Text(t('aiTitle'),
                      style: TextStyle(fontSize: 15, color: scheme.onSurface)),
                  subtitle: Text(
                      _settings.aiAutoTranslate
                          ? t('aiAutoOn')
                          : t('aiLangFollow'),
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                  trailing: Icon(Icons.chevron_right,
                      size: 20, color: scheme.onSurfaceVariant),
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const AiTranslateSettingsPage()));
                    if (mounted) setState(() {}); // 返回时刷新副标题
                  },
                ),
                Divider(height: 1, indent: 50, color: scheme.outlineVariant),
                // 群发助手（微信式）：选多个好友 → 一条消息逐个发到各自单聊
                ListTile(
                  leading: Icon(Icons.forward_to_inbox,
                      color: scheme.onSurfaceVariant),
                  title: Text(t('massTitle'),
                      style: TextStyle(fontSize: 15, color: scheme.onSurface)),
                  subtitle: Text(t('massDesc'),
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                  trailing: Icon(Icons.chevron_right,
                      size: 20, color: scheme.onSurfaceVariant),
                  onTap: () {
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const MassMessagePage()));
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
