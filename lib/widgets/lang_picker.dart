import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';

/// 全局语言选择弹窗：四语（简体中文 / English / 日本語 / 繁體中文）。
/// 登录页 / 注册页 / 扫码登录页 / 我的页共用。
///
/// 进入 App 时默认跟随设备语言（见 LocaleProvider 初始化）；
/// 用户在此手动选择后持久化覆盖设备语言。
Future<void> showLangPicker(BuildContext context) {
  final provider = LocaleProvider.of(context);
  final loc = AppLocalizations.of(context).locale;
  final t = AppLocalizations.of(context).t;
  final scheme = Theme.of(context).colorScheme;
  final options = AppLocalizations.supportedLangs
      .map((l) => (l, AppLocalizations.langNativeName(l)))
      .toList();

  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) => Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(t('meChooseLanguage'),
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface)),
            ),
            ...options.map((e) => _LangRow(
                  label: e.$2,
                  scheme: scheme,
                  // 完整匹配语言+地区（简体 zh_CN 与繁体 zh_TW 都是 zh，需区分）
                  checked: loc.languageCode == e.$1.languageCode &&
                      (loc.countryCode ?? '') == (e.$1.countryCode ?? ''),
                  onTap: () {
                    provider?.setLocale(e.$1);
                    Navigator.of(ctx).pop();
                  },
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

class _LangRow extends StatelessWidget {
  final String label;
  final ColorScheme scheme;
  final bool checked;
  final VoidCallback onTap;
  const _LangRow({
    required this.label,
    required this.scheme,
    required this.checked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 16, color: scheme.onSurface)),
            ),
            if (checked) Icon(Icons.check, color: scheme.primary, size: 22),
          ],
        ),
      ),
    );
  }
}
