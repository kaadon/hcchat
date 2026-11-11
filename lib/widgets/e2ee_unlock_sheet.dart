import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/e2ee_service.dart';
import '../theme/app_theme.dart';
import 'app_dialogs.dart';

/// E2EE 解锁弹窗（§36）：换设备/清存储后本机无私钥，遇到加密消息时
/// 输入登录密码 → 从服务端拉备份密文 → KEK 解出私钥存回本机。
/// 返回 true = 解锁成功（调用方随后 invalidateCache + setState 重绘）。
class E2eeUnlockSheet {
  E2eeUnlockSheet._();

  static Future<bool> show(BuildContext context) async {
    final t = AppLocalizations.of(context).t;
    final ctrl = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.cs.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t('e2UnlockTitle'),
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: context.cs.onSurface)),
            const SizedBox(height: 8),
            Text(t('e2UnlockHint'),
                style: TextStyle(
                    fontSize: 13, color: context.cs.onSurfaceVariant)),
            const SizedBox(height: 14),
            TextField(
              controller: ctrl,
              obscureText: true,
              autofocus: true,
              style: const TextStyle(fontSize: 15),
              decoration: InputDecoration(
                hintText: t('e2UnlockPwdHint'),
                hintStyle: TextStyle(color: context.cs.onSurfaceVariant),
                filled: true,
                fillColor: Theme.of(ctx).scaffoldBackgroundColor,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.primary),
                child: Text(t('e2UnlockBtn')),
              ),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return false;
    final success =
        await E2eeService.instance.unlockWithPassword(ctrl.text);
    if (!success && context.mounted) {
      AppDialogs.toast(context, t('e2UnlockFailed'));
    }
    return success;
  }
}
