import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';

/// 扫码进群二次确认页（对齐微信）：展示群头像/群名/成员数，确认后才加入。
/// data 来自 /conversation/:id/preview：{conversation: {...}, memberCount: n}
///
/// [title] / [confirmText] / [countText]：可选文案覆盖（十四批 #7 频道名片
/// 复用本页时传「订阅频道」等；不传走原群聊词条，扫码进群路径零变化）。
class GroupJoinConfirmPage extends StatefulWidget {
  final Map<String, dynamic> data;
  // 成功路径由 onConfirm 自行导航（pushReplacement 进聊天页）；失败时抛异常留在本页
  final Future<void> Function() onConfirm;
  final String? title;
  final String? confirmText;
  final String? countText;
  const GroupJoinConfirmPage(
      {super.key,
      required this.data,
      required this.onConfirm,
      this.title,
      this.confirmText,
      this.countText});

  @override
  State<GroupJoinConfirmPage> createState() => _GroupJoinConfirmPageState();
}

class _GroupJoinConfirmPageState extends State<GroupJoinConfirmPage> {
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final cs = Theme.of(context).colorScheme;
    final conv = ((widget.data['conversation'] ?? const {}) as Map)
        .cast<String, dynamic>();
    final memberCount = (widget.data['memberCount'] as num?)?.toInt() ?? 0;
    final name = (conv['nameZh'] ??
            conv['nameEn'] ??
            conv['name'] ??
            t('groupJoinUnnamed'))
        .toString();
    final avatar = (conv['avatar'] ?? '').toString();

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(widget.title ?? t('groupJoinConfirmTitle'),
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: cs.onSurface)),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            // 群头像
            AppAvatar(url: avatar, name: name, size: 88, radius: 20),
            const SizedBox(height: 16),
            // 群名
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface)),
            ),
            const SizedBox(height: 6),
            // 成员数（频道复用时覆盖为「N 人订阅」）
            Text(widget.countText ??
                t('groupJoinMemberCount', {'n': '$memberCount'}),
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
            const Spacer(flex: 3),
            // 确认按钮（加入中显示 loading，防止重复点击）
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
              child: SizedBox(
                width: double.infinity,
                height: 46,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _loading
                      ? null
                      : () async {
                          setState(() => _loading = true);
                          try {
                            await widget.onConfirm();
                          } catch (_) {
                            // 失败：错误提示由 onConfirm 内 toast，留在确认页可重试
                            if (mounted) setState(() => _loading = false);
                          }
                        },
                  child: _loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : Text(widget.confirmText ?? t('groupJoinConfirmButton'),
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // 取消
            TextButton(
              onPressed: _loading ? null : () => Navigator.of(context).pop(),
              child: Text(t('cancel'),
                  style: TextStyle(fontSize: 15, color: cs.onSurfaceVariant)),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
