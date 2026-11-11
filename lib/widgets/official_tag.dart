import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../theme/app_theme.dart';

/// 「官方」小标签：小助手（虚拟 uid -1）专用
/// 消息列表会话项 / 通讯录功能行共用，保证两处样式一致
class OfficialTag extends StatelessWidget {
  const OfficialTag({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.12),
        border: Border.all(
            color: AppTheme.primary.withValues(alpha: 0.55), width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(AppLocalizations.of(context).t('officialTag'),
          style: const TextStyle(
              fontSize: 10,
              height: 1.3,
              fontWeight: FontWeight.w600,
              color: AppTheme.primary)),
    );
  }
}
