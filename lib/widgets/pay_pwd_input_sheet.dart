import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../theme/app_theme.dart';
import '../widgets/pay_pwd_field.dart';

/// 发红包 / 转账时的「输入支付密码」底部弹窗。
///
/// 用法：`final pwd = await PayPwdInputSheet.show(context, title: ...);`
/// 满 6 位自动提交并 pop 返回密码；用户主动下滑关闭返回 null。
/// [error] 用于密码错误后重新弹出时展示错误提示（如「支付密码错误，请重试」）。
class PayPwdInputSheet {
  static Future<String?> show(BuildContext context,
      {required String title, String? error}) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _PayPwdInputSheetBody(title: title, error: error),
    );
  }
}

class _PayPwdInputSheetBody extends StatelessWidget {
  final String title;
  final String? error;

  const _PayPwdInputSheetBody({required this.title, this.error});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, 20, 24, MediaQuery.of(context).viewInsets.bottom + 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 拖拽条
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: scheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Text(title,
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface)),
          const SizedBox(height: 6),
          Text(t('payPwdInputDesc'),
              style: TextStyle(
                  fontSize: 12, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 22),
          PayPwdField(
            onCompleted: (pwd) {
              // 满 6 位自动提交（微信式）
              Navigator.of(context).pop(pwd);
            },
          ),
          const SizedBox(height: 16),
          if (error != null && error!.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.danger.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: AppTheme.danger.withValues(alpha: 0.35)),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline_rounded,
                      size: 18, color: AppTheme.danger),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(error!,
                        style: TextStyle(
                            fontSize: 13,
                            color: AppTheme.danger,
                            fontWeight: FontWeight.w500)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 10),
          // 忘记密码 / 去设置 的兜底入口（极少数未设置却被放行时）
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: Text(t('payPwdCancel'),
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}
