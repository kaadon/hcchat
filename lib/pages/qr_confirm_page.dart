import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/user_cache.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';

/// 扫码登录二次确认页（微信式，需求7）：
/// 手机扫 PC 二维码 → 先上报"已扫描"（PC 端显示"已扫码，请在手机上确认"）
/// → 本页展示当前登录账号头像/昵称 + 登录设备 → 用户点「确认登录」才真正下发 token。
class QrConfirmPage extends StatefulWidget {
  final String ticket;
  const QrConfirmPage({super.key, required this.ticket});

  @override
  State<QrConfirmPage> createState() => _QrConfirmPageState();
}

class _QrConfirmPageState extends State<QrConfirmPage> {
  final _api = ApiClient.instance;
  String _nickname = '';
  String _avatar = '';
  bool _confirming = false;
  bool _done = false;

  String _t(String key) => AppLocalizations.of(context).t(key);

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    // 进程内缓存命中直接用（一次登录会话只拉一次 /user/profile）
    Map<String, dynamic>? d = UserCache.myProfileData;
    if (d == null) {
      try {
        final r = await _api.get('/api/v1/user/profile');
        d = (r.data['data'] as Map<String, dynamic>?) ?? {};
        UserCache.setMyProfile(d);
      } catch (_) {
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _nickname = (d?['nickname'] ?? d?['account'] ?? '').toString();
      _avatar = (d?['avatar'] ?? '').toString();
    });
  }

  Future<void> _confirm() async {
    if (_confirming || _done) return;
    setState(() => _confirming = true);
    try {
      final r = await _api
          .post('/api/v1/auth/qr/confirm', data: {'ticket': widget.ticket});
      final code = (r.data as Map<String, dynamic>)['code'];
      if (!mounted) return;
      if (code == 0) {
        setState(() => _done = true);
        AppDialogs.toast(context, _t('qrConfirmDone'));
        await Future.delayed(const Duration(milliseconds: 900));
        if (mounted) Navigator.of(context).pop(true);
      } else {
        AppDialogs.toast(context, _t('qrConfirmFailed'));
        if (mounted) setState(() => _confirming = false);
      }
    } catch (e) {
      if (mounted) {
        AppDialogs.toast(context, _t('qrConfirmFailed'));
        setState(() => _confirming = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(_t('qrConfirmTitle')),
        backgroundColor: cs.surface,
        elevation: 0,
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 32),
            Text(_t('qrConfirmHint'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 40),
            // 当前账号头像
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: AppTheme.primary,
                shape: BoxShape.circle,
              ),
              clipBehavior: Clip.antiAlias,
              alignment: Alignment.center,
              child: AppAvatar(
                url: _avatar,
                name: _nickname,
                size: 84,
                background: AppTheme.primary,
              ),
            ),
            const SizedBox(height: 12),
            Text(_nickname,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 28),
            // 登录设备卡片
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.computer, size: 22, color: cs.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(_t('qrConfirmDevice'),
                        style: TextStyle(
                            fontSize: 14, color: cs.onSurfaceVariant)),
                  ),
                  Text(_t('qrConfirmDeviceName'),
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
            const Spacer(),
            // 底部按钮：取消 / 确认登录（微信式）
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 46,
                      child: OutlinedButton(
                        onPressed: _confirming
                            ? null
                            : () => Navigator.of(context).pop(false),
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        child: Text(_t('qrConfirmCancel')),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: SizedBox(
                      height: 46,
                      child: FilledButton(
                        onPressed: _confirming || _done ? null : _confirm,
                        style: FilledButton.styleFrom(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        child: Text(_done
                            ? _t('qrConfirmDone')
                            : (_confirming
                                ? _t('scanQrLoginConfirming')
                                : _t('qrConfirmOk'))),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
