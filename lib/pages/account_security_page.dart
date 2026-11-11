import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:dio/dio.dart';

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/e2ee_service.dart'; // E2EE 开关 + 改密 re-wrap（§36）
import '../services/wide_layout_store.dart';
import '../services/user_cache.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';
import 'login_page.dart';
import 'pay_pwd_setup_page.dart';

/// 账号安全：修改登录密码 / 注销账户
class AccountSecurityPage extends StatefulWidget {
  const AccountSecurityPage({super.key});

  @override
  State<AccountSecurityPage> createState() => _AccountSecurityPageState();
}

class _AccountSecurityPageState extends State<AccountSecurityPage> {
  final _api = ApiClient.instance;
  Map<String, dynamic>? _profile;
  // E2EE（§36）：后台模式为 e2ee 且已建钥时显示用户级开关
  bool _e2eeVisible = false;
  bool _e2eeOn = true;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _loadE2ee();
  }

  Future<void> _loadE2ee() async {
    await E2eeService.instance.ensureLoaded();
    final me = await E2eeService.instance.meInfo();
    if (!mounted) return;
    setState(() {
      _e2eeVisible = me != null && me['mode'] == 'e2ee' && me['hasKeys'] == true;
      _e2eeOn = me?['e2eeOn'] != false;
    });
  }

  /// 拉取资料以显示当前已绑定的手机号
  Future<void> _loadProfile() async {
    try {
      final r = await _api.get('/api/v1/user/profile');
      final d = (r.data as Map<String, dynamic>)['data'];
      if (d is Map<String, dynamic> && mounted) {
        setState(() => _profile = d);
      }
    } catch (_) {}
  }

  Future<void> _bindPhone() async {
    final current =
        (_profile?['phone']?.toString() ?? '').trim();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.cs.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => _BindPhoneSheet(currentPhone: current),
    );
    if (ok == true && mounted) {
      await _loadProfile();
    }
  }

  bool _validPwd(String p) {
    final n = p.runes.length; // 按字符数计，与后端 len([]rune(p)) 一致
    return n >= 6 && n <= 20;
  }

  Widget _field(TextEditingController c, String hint) => TextField(
        controller: c,
        obscureText: true,
        style: const TextStyle(fontSize: 15),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: context.cs.onSurfaceVariant),
          filled: true,
          fillColor: Theme.of(context).scaffoldBackgroundColor,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none),
        ),
      );

  Future<void> _changePassword() async {
    final t = AppLocalizations.of(context).t;
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.cs.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
              16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t('acctSecChangePassword'),
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: context.cs.onSurface)),
              const SizedBox(height: 16),
              _field(oldCtrl, t('acctSecOldPwdHint')),
              const SizedBox(height: 12),
              _field(newCtrl, t('acctSecNewPwdHint')),
              const SizedBox(height: 12),
              _field(confirmCtrl, t('acctSecConfirmPwdHint')),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style:
                      FilledButton.styleFrom(backgroundColor: AppTheme.primary),
                  child: Text(t('acctSecConfirmChange')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    final oldP = oldCtrl.text;
    final newP = newCtrl.text;
    final confirmP = confirmCtrl.text;
    if (newP != confirmP) {
      AppDialogs.toast(context, t('acctSecPwdMismatch'));
      return;
    }
    if (!_validPwd(newP)) {
      AppDialogs.toast(context, t('acctSecPwdInvalid'));
      return;
    }
    // E2EE（§36）：已有私钥备份 → 先用旧密码解私钥、新密码 re-wrap，
    // 新密文随改密请求同事务落库；本地解不开（旧密码错）直接终止。
    String? encPriv;
    try {
      encPriv = await E2eeService.instance
          .rewrapForPasswordChange(oldPassword: oldP, newPassword: newP);
    } catch (_) {
      AppDialogs.toast(context, t('e2UnlockFailed'));
      return;
    }
    try {
      final token = await _api.readToken();
      final r = await _api.dio.put('/api/v1/user/password',
          data: {
            'oldPassword': oldP,
            'newPassword': newP,
            if (encPriv != null) 'encPriv': encPriv,
          },
          options: Options(headers: {'Authorization': 'Bearer $token'}));
      final code = (r.data as Map)['code'];
      if (code == 0) {
        AppDialogs.toast(context, t('acctSecPwdChanged'));
        // 宽屏右栏打开时不能直接 pop（会弹掉根路由黑屏）→ closeDetail
        if (mounted) closeDetail(context);
      } else if (code == 4401) {
        AppDialogs.toast(context, t('e2BackupRequired'));
      } else {
        AppDialogs.toast(
            context,
            ((r.data as Map)['message'] ??
                    AppLocalizations.of(context).t('acctSecChangeFailed'))
                .toString());
      }
    } catch (_) {
      AppDialogs.toast(context, t('acctSecChangeFailedRetry'));
    }
  }

  Future<void> _deleteAccount() async {
    final t = AppLocalizations.of(context).t;
    final yes = await AppDialogs.confirm(
      context,
      title: t('acctSecDeleteAccount'),
      message: t('acctSecDeleteAccountMsg'),
      confirmText: t('acctSecDeleteConfirm'),
      danger: true,
    );
    if (yes != true) return;
    try {
      final token = await _api.readToken();
      final r = await _api.dio.delete('/api/v1/user',
          options: Options(headers: {'Authorization': 'Bearer $token'}));
      final code = (r.data as Map)['code'];
      if (code == 0) {
        await _api.logout();
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const LoginPage()),
            (route) => false,
          );
        }
        return;
      }
      AppDialogs.toast(
          context,
          ((r.data as Map)['message'] ??
                  AppLocalizations.of(context).t('acctSecDeleteFailed'))
              .toString());
    } catch (_) {
      AppDialogs.toast(context, t('acctSecDeleteFailedRetry'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(title: Text(t('acctSecTitle'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            decoration: BoxDecoration(
              color: context.cs.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.phone_android_outlined,
                      color: AppTheme.purple),
                  title: Text(t('acctSecBindPhone'),
                      style: const TextStyle(fontSize: 15)),
                  subtitle: _profile != null &&
                          (_profile!['phone']?.toString() ?? '').isNotEmpty
                      ? Text(_profile!['phone'].toString(),
                          style: TextStyle(
                              fontSize: 12, color: context.cs.onSurfaceVariant))
                      : null,
                  trailing: Icon(Icons.chevron_right,
                      size: 18, color: context.cs.onSurfaceVariant),
                  onTap: _bindPhone,
                ),
                const Divider(height: 1, indent: 50),
                ListTile(
                  leading:
                      const Icon(Icons.lock_outline, color: AppTheme.purple),
                  title: Text(t('acctSecChangePassword'),
                      style: const TextStyle(fontSize: 15)),
                  trailing: Icon(Icons.chevron_right,
                      size: 18, color: context.cs.onSurfaceVariant),
                  onTap: _changePassword,
                ),
                // E2EE 用户级开关（§36 拍板③：默认开、可关）；
                // 仅后台加密方式为「端到端」且已建钥时显示
                if (_e2eeVisible) ...[
                  const Divider(height: 1, indent: 50),
                  ListTile(
                    leading: const Icon(Icons.enhanced_encryption,
                        color: AppTheme.purple),
                    title: Text(t('e2ToggleTitle'),
                        style: const TextStyle(fontSize: 15)),
                    subtitle: Text(t('e2ToggleSub'),
                        style: TextStyle(
                            fontSize: 12,
                            color: context.cs.onSurfaceVariant)),
                    trailing: Switch(
                      value: _e2eeOn,
                      activeColor: AppTheme.primary,
                      onChanged: (v) async {
                        final ok = await E2eeService.instance.setToggle(v);
                        if (!mounted) return;
                        if (ok) {
                          setState(() => _e2eeOn = v);
                        } else {
                          AppDialogs.toast(
                              context, t('e2UnlockFailed'));
                        }
                      },
                    ),
                  ),
                ],
                const Divider(height: 1, indent: 50),
                ListTile(
                  leading:
                      const Icon(Icons.lock_outline, color: AppTheme.purple),
                  title: Text(t('payPwdSetEntry'),
                      style: const TextStyle(fontSize: 15)),
                  subtitle: UserCache.myProfileData?['payPwdSet'] == true
                      ? Text(t('payPwdSetDone'),
                          style: TextStyle(
                              fontSize: 12, color: context.cs.onSurfaceVariant))
                      : null,
                  trailing: Icon(Icons.chevron_right,
                      size: 18, color: context.cs.onSurfaceVariant),
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const PayPwdSetupPage()));
                    if (mounted) setState(() {}); // 返回时刷新「已设置」状态
                  },
                ),
                const Divider(height: 1, indent: 50),
                ListTile(
                  leading: const Icon(Icons.delete_forever_outlined,
                      color: AppTheme.danger),
                  title: Text(t('acctSecDeleteAccount'),
                      style: const TextStyle(
                          fontSize: 15, color: AppTheme.danger)),
                  trailing: Icon(Icons.chevron_right,
                      size: 18, color: context.cs.onSurfaceVariant),
                  onTap: _deleteAccount,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 绑定手机号底部弹窗：显示当前手机号（若有）→ 输入新手机号 → 图形验证码 → 短信验证码 → 确认绑定
class _BindPhoneSheet extends StatefulWidget {
  const _BindPhoneSheet({this.currentPhone = ''});
  final String currentPhone;
  @override
  State<_BindPhoneSheet> createState() => _BindPhoneSheetState();
}

class _BindPhoneSheetState extends State<_BindPhoneSheet> {
  final _svc = AuthService();
  final _phone = TextEditingController();
  final _captchaCode = TextEditingController();
  final _smsCode = TextEditingController();
  Captcha? _captcha;
  Uint8List? _captchaBytes; // 图形验证码解码一次，避免每秒重建闪烁
  int _left = 0;
  Timer? _timer;
  bool _loading = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _loadCaptcha();
  }

  Future<void> _loadCaptcha() async {
    try {
      final c = await _svc.getCaptcha();
      if (!mounted) return;
      final bytes = base64Decode(c.imageBase64);
      setState(() {
        _captcha = c;
        _captchaBytes = bytes;
      });
    } catch (_) {}
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_left <= 1) {
        t.cancel();
        setState(() => _left = 0);
      } else {
        setState(() => _left--);
      }
    });
  }

  Future<void> _send() async {
    final t = AppLocalizations.of(context).t;
    final phone = _phone.text.trim();
    if (phone.isEmpty) {
      setState(() => _error = '请填写手机号');
      return;
    }
    if (_captcha == null) {
      setState(() => _error = '图形验证码加载中，请稍候');
      return;
    }
    if (_captchaCode.text.trim().isEmpty) {
      setState(() => _error = '请先填写图形验证码');
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      await _svc.sendBindPhoneCode(
          phone, '+86', _captcha!.captchaId, _captchaCode.text.trim());
      if (!mounted) return;
      setState(() => _left = 60);
      _start();
      AppDialogs.toast(context, t('codeSent'));
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    final t = AppLocalizations.of(context).t;
    final phone = _phone.text.trim();
    if (_smsCode.text.trim().isEmpty) {
      setState(() => _error = '请填写短信验证码');
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      await _svc.bindPhone(phone, '+86', _smsCode.text.trim());
      if (!mounted) return;
      AppDialogs.toast(context, t('acctSecBindSuccess'));
      Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _phone.dispose();
    _captchaCode.dispose();
    _smsCode.dispose();
    super.dispose();
  }

  Widget _field(TextEditingController c, String hint, {TextInputType? kt}) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return TextField(
      controller: c,
      keyboardType: kt,
      style: TextStyle(fontSize: 15, color: scheme.onSurface),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
            fontSize: 15,
            color: isDark ? scheme.outlineVariant : const Color(0xFFAAAAAA)),
        filled: true,
        fillColor:
            isDark ? scheme.surfaceContainerHighest : const Color(0xFFF7F8FA),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = AppTheme.primary;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t('acctSecBindPhone'),
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface)),
          const SizedBox(height: 12),
          if (widget.currentPhone.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark
                    ? scheme.surfaceContainerHighest
                    : const Color(0xFFF7F8FA),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                  '${t('acctSecCurrentPhone')}：${widget.currentPhone}',
                  style: TextStyle(
                      fontSize: 13, color: scheme.onSurfaceVariant)),
            ),
          if (widget.currentPhone.isNotEmpty) const SizedBox(height: 12),
          _field(_phone, t('acctSecPhoneHint'), kt: TextInputType.phone),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _field(_captchaCode, t('graphicCaptcha')),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: _loadCaptcha,
                child: Container(
                  width: 112,
                  height: 44,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: isDark
                            ? scheme.outlineVariant
                            : const Color(0xFFE2E5EA)),
                    color: isDark
                        ? scheme.surfaceContainerHighest
                        : const Color(0xFFF7F8FA),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: _captchaBytes == null
                        ? const Center(
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2),
                            ),
                          )
                        : Image.memory(
                            _captchaBytes!,
                            fit: BoxFit.fill,
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.refresh),
                          ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child:
                    _field(_smsCode, t('smsCode'), kt: TextInputType.number),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 44,
                child: ElevatedButton(
                  onPressed: (_left > 0 || _loading) ? null : _send,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primary,
                    foregroundColor: Colors.white,
                    disabledForegroundColor: scheme.onSurfaceVariant,
                    disabledBackgroundColor: isDark
                        ? scheme.surfaceContainerHighest
                        : const Color(0xFFEDEFF2),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  child: Text(
                    _left > 0 ? '$_left s' : t('sendCode'),
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFDEAEA),
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
                    child: Text(
                      _error,
                      style: TextStyle(
                          fontSize: 13,
                          color: AppTheme.danger,
                          fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: FilledButton(
              onPressed: _loading ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: primary,
              ),
              child: Text(t('acctSecBindConfirm')),
            ),
          ),
        ],
      ),
    );
  }
}
