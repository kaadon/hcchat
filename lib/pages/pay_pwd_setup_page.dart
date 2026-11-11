import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/auth_service.dart';
import '../services/friend_service.dart';
import '../services/user_cache.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/pay_pwd_field.dart';

/// 设置 / 修改支付密码。
///
/// 已设置过（UserCache.payPwdSet）→ 修改流程：原密码 → 新密码 → 确认。
/// 未设置过 → 首次设置：新密码 → 确认。
/// 后端 `POST /user/paypwd/set` 按是否已设置自动分流（无需客户端判断走哪个接口）。
class PayPwdSetupPage extends StatefulWidget {
  const PayPwdSetupPage({super.key});

  @override
  State<PayPwdSetupPage> createState() => _PayPwdSetupPageState();
}

class _PayPwdSetupPageState extends State<PayPwdSetupPage> {
  final _auth = AuthService();
  bool _isSet = false; // 是否为「修改」（已设置过）
  int _step = 0; // 0=原密码(仅修改) / 0或1=新密码 / 末步=确认
  bool _loading = false;
  String? _error;
  String _old = '';
  String _new = '';
  String _confirm = '';
  int _fieldNonce = 0; // 强制 PayPwdField 重挂载（切步 / 输错时清空内部输入）

  @override
  void initState() {
    super.initState();
    _init();
  }

  /// 读取是否已设置（必要时刷新 profile，避免旧缓存误判）
  Future<void> _init() async {
    bool set = UserCache.myProfileData?['payPwdSet'] == true;
    if (!set) {
      try {
        final p = await FriendService().profile();
        UserCache.setMyProfile(p);
        set = p['payPwdSet'] == true;
      } catch (_) {}
    }
    if (mounted) setState(() => _isSet = set);
  }

  String _stepTitle() {
    final t = AppLocalizations.of(context).t;
    if (_isSet) {
      switch (_step) {
        case 0:
          return t('payPwdOldHint');
        case 1:
          return t('payPwdNewHint');
        default:
          return t('payPwdConfirmHint');
      }
    } else {
      return _step == 0 ? t('payPwdNewHint') : t('payPwdConfirmHint');
    }
  }

  int get _totalSteps => _isSet ? 3 : 2;

  void _onCompleted(String pwd) {
    setState(() => _error = null);
    if (_isSet) {
      if (_step == 0) {
        _old = pwd;
        setState(() => _step = 1);
        return;
      }
      if (_step == 1) {
        _new = pwd;
        setState(() => _step = 2);
        return;
      }
      _confirm = pwd;
      _submit();
      return;
    } else {
      if (_step == 0) {
        _new = pwd;
        setState(() => _step = 1);
        return;
      }
      _confirm = pwd;
      _submit();
    }
  }

  Future<void> _submit() async {
    final t = AppLocalizations.of(context).t;
    if (_new != _confirm) {
      setState(() {
        _error = t('payPwdMismatch');
        _confirm = '';
        _fieldNonce++; // 强制重挂载，清空输入框
      });
      return;
    }
    if (_new.length != 6) {
      setState(() => _error = t('payPwdFormatTip'));
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _auth.setPayPwd(
          oldPassword: _isSet ? _old : null, newPassword: _new);
      // 更新本地缓存标记，使「发红包/转账」入口立即放行
      final mp = UserCache.myProfileData;
      if (mp != null) mp['payPwdSet'] = true;
      if (!mounted) return;
      AppDialogs.toast(context,
          _isSet ? t('payPwdChangedSuccess') : t('payPwdSetSuccess'));
      Navigator.of(context).pop(true);
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      if (!mounted) return;
      // 原密码错误 / 格式错误：回到对应步骤重输
      setState(() {
        _error = msg;
        _loading = false;
        if (_isSet && msg.contains('原支付密码')) {
          _old = '';
          _new = '';
          _confirm = '';
          _step = 0;
        } else {
          _new = '';
          _confirm = '';
          _step = _isSet ? 1 : 0;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    final title =
        _isSet ? t('payPwdChangeTitle') : t('payPwdSetTitle');
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(title: Text(title)),
      body: GestureDetector(
        // 点击空白处收起键盘（隐藏输入框仍可点）
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 12),
            Text(_stepTitle(),
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface)),
            const SizedBox(height: 20),
            PayPwdField(
              key: ValueKey<int>(_step * 1000 + _fieldNonce),
              onChanged: (_) => setState(() => _error = null),
              onCompleted: _onCompleted,
            ),
            const SizedBox(height: 18),
            if (_error != null && _error!.isNotEmpty)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .error
                      .withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: Theme.of(context)
                          .colorScheme
                          .error
                          .withValues(alpha: 0.35)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline_rounded,
                        size: 18,
                        color: Theme.of(context).colorScheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_error!,
                          style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context).colorScheme.error,
                              fontWeight: FontWeight.w500)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 14),
            Text(t('payPwdRuleTip'),
                style: TextStyle(
                    fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 24),
            // 步骤指示
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_totalSteps, (i) {
                return Container(
                  width: 24,
                  height: 4,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: i <= _step
                        ? scheme.primary
                        : scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                );
              }),
            ),
            if (_loading) ...[
              const SizedBox(height: 20),
              const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ],
        ),
      ),
    );
  }
}
