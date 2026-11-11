import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/settings_service.dart';
import '../services/translate_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';

/// AI 翻译设置页（我的 → 设置 → AI 翻译）
///
/// - 自动翻译外来消息（全局开关，默认关）
/// - 翻译语种（跟随我的语言 / zh / zhT / en / ja）
/// - 当日用量（自动/手动分开，来自 GET /translate/usage）
/// - 会话级覆盖：暂未实现，预留（服务端/数据结构已支持扩展）
class AiTranslateSettingsPage extends StatefulWidget {
  const AiTranslateSettingsPage({super.key});

  @override
  State<AiTranslateSettingsPage> createState() =>
      _AiTranslateSettingsPageState();
}

class _AiTranslateSettingsPageState extends State<AiTranslateSettingsPage> {
  Map<String, dynamic>? _usage;

  @override
  void initState() {
    super.initState();
    _loadUsage();
  }

  Future<void> _loadUsage() async {
    try {
      final u = await TranslateService().usage();
      if (!mounted) return;
      setState(() => _usage = u);
    } catch (_) {
      // 用量获取失败静默（页面显示兜底文案）
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    final t = AppLocalizations.of(context).t;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(title: Text(t('aiTitle'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          // ===== 自动翻译 =====
          _group(children: [
            SwitchListTile(
              value: s.aiAutoTranslate,
              onChanged: (v) async {
                await s.setAiAutoTranslate(v);
                if (mounted) setState(() {});
              },
              title: Text(t('aiAutoOn'),
                  style: const TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w500)),
            ),
            _divider(),
            // 语种选择
            InkWell(
              onTap: () => _pickLang(context),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                child: Row(
                  children: [
                    Expanded(
                        child: Text(t('aiLang'),
                            style: const TextStyle(fontSize: 14.5))),
                    Text(
                        s.aiTranslateLang.isEmpty
                            ? t('aiLangFollow')
                            : _langName(s.aiTranslateLang),
                        style: TextStyle(
                            fontSize: 13, color: context.cs.onSurfaceVariant)),
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right,
                        size: 18, color: context.cs.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ]),

          // ===== 用量 =====
          const SizedBox(height: 12),
          _group(children: [
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(
                children: [
                  Expanded(
                      child: Text(t('aiUsageAuto'),
                          style: const TextStyle(fontSize: 14.5))),
                  _usageText(
                      limit: (_usage?['autoLimit'] as num?)?.toInt() ?? 0,
                      used: (_usage?['autoUsed'] as num?)?.toInt() ?? 0),
                ],
              ),
            ),
            _divider(),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(
                children: [
                  Expanded(
                      child: Text(t('aiUsageManual'),
                          style: const TextStyle(fontSize: 14.5))),
                  _usageText(
                      limit: (_usage?['manualLimit'] as num?)?.toInt() ?? 0,
                      used: (_usage?['manualUsed'] as num?)?.toInt() ?? 0),
                ],
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _group({required List<Widget> children}) => Container(
        decoration: BoxDecoration(
          color: context.cs.surface,
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        ),
        child: Column(children: children),
      );

  Widget _divider() => Divider(
      height: 0.5,
      thickness: 0.5,
      indent: 16,
      color: context.cs.onSurfaceVariant.withValues(alpha: 0.15));

  /// 用量文案：limit==0 → 自动「已关闭」/ 手动「不限量」；否则 used/limit
  Widget _usageText({required int limit, required int used}) {
    final t = AppLocalizations.of(context).t;
    String text;
    if (limit == 0) {
      // limit==0 的语义按接口约定区分（auto=关闭 / manual=不限量）
      text = t('aiUnlimitedManual');
    } else {
      text = '$used / $limit';
    }
    return Text(text,
        style: TextStyle(
            fontSize: 13, color: context.cs.onSurfaceVariant));
  }

  String _langName(String code) {
    switch (code) {
      case 'zh':
        return '简体中文';
      case 'zhT':
        return '繁體中文';
      case 'en':
        return 'English';
      case 'ja':
        return '日本語';
    }
    return code;
  }

  Future<void> _pickLang(BuildContext context) async {
    final s = AppSettings.instance;
    final options = [
      ('', AppLocalizations.of(context).t('aiLangFollow')),
      ('zh', '简体中文'),
      ('zhT', '繁體中文'),
      ('en', 'English'),
      ('ja', '日本語'),
    ];
    final picked = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(AppLocalizations.of(context).t('aiLangPick'),
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          ...options.map((o) => ListTile(
                title: Text(o.$2,
                    style: TextStyle(
                        fontSize: 14.5,
                        color: s.aiTranslateLang == o.$2 && o.$1.isEmpty ||
                                s.aiTranslateLang == o.$1
                            ? AppTheme.primary
                            : null,
                        fontWeight: (s.aiTranslateLang.isEmpty && o.$1.isEmpty)
                            ? FontWeight.w600
                            : null)),
                trailing: (s.aiTranslateLang == o.$1)
                    ? const Icon(Icons.check_rounded,
                        size: 18, color: AppTheme.primary)
                    : null,
                onTap: () => Navigator.pop(ctx, o.$1),
              )),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (picked == null) return;
    await s.setAiTranslateLang(picked);
    if (mounted) setState(() {});
    if (mounted) {
      AppDialogs.toast(context, AppLocalizations.of(context).t('aiSaved'));
    }
  }
}
