import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_locale.dart';
import '../services/wallet_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/pay_pwd_input_sheet.dart';
import 'pay_ui.dart';

/// 转账页（美化版 v2：头像层级修复、卡片阴影加重、渐变形背景）
class TransferPage extends StatefulWidget {
  final String peerName;
  final String? peerId;
  const TransferPage({super.key, required this.peerName, this.peerId});

  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage> {
  final _amountCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _focus = FocusNode();

  double get _amount => double.tryParse(_amountCtrl.text.trim()) ?? 0;

  double _balance = 0;
  bool _balanceLoading = true;

  bool get _overBalance => !_balanceLoading && _amount > _balance;
  bool get _canSubmit => _amount > 0 && !_overBalance;

  String _fmt(double v) {
    final s = v.toStringAsFixed(2);
    return s.endsWith('.00') ? v.toStringAsFixed(0) : s;
  }

  @override
  void initState() {
    super.initState();
    _amountCtrl.addListener(() => setState(() {}));
    _loadBalance();
  }

  Future<void> _loadBalance() async {
    await WalletStore.instance.refresh();
    if (!mounted) return;
    setState(() {
      _balance = WalletStore.instance.balance;
      _balanceLoading = false;
    });
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;

    const lightGradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment(0, 0.45),
      colors: [Color(0xFFFFF3E0), Color(0xFFFFFFFF)],
    );

    return Scaffold(
      backgroundColor: isDark ? scheme.surface : Colors.white,
      extendBodyBehindAppBar: false,
      // ===== AppBar 移到 Scaffold.appBar：Scaffold 自动处理状态栏安全区 =====
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: isDark
                  ? [scheme.surface, scheme.surface]
                  : const [Color(0xFFFFF3E0), Color(0xFFFFF8EE)],
            ),
          ),
        ),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        systemOverlayStyle: SystemUiOverlayStyle.dark.copyWith(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new,
              color: scheme.onSurface, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          loc.t('transferTitle'),
          style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface),
        ),
      ),
      // ===== body 外层渐变 + SafeArea(top/bottom:true) 双保险 =====
      body: Container(
        decoration:
            isDark ? null : const BoxDecoration(gradient: lightGradient),
        child: SafeArea(
          top: true,
          bottom: true,
          left: false,
          right: false,
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                  children: [
                    const SizedBox(height: 6),
                    _buildRecipient(loc, scheme, isDark),
                    const SizedBox(height: 24),
                    _buildMainCard(loc, scheme, isDark),
                    const SizedBox(height: 36),
                    PayUI.transferButton(
                      label: loc.t('transferSubmit'),
                      onPressed: _canSubmit ? _submit : null,
                    ),
                    const SizedBox(height: 14),
                    Center(
                      child: Text(
                        loc.t('transferFreezeNotice'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? scheme.onSurfaceVariant
                              : const Color(0xFF888888),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ========= 收款人头像 + 名字（左头像 + 右文字，单行水平布局）=========
  Widget _buildRecipient(
      AppLocalizations loc, ColorScheme scheme, bool isDark) {
    final name = widget.peerName.trim().isEmpty ? '?' : widget.peerName.trim();
    // 取第一个 Unicode 字符（防止中文切半）
    final firstChar = name.characters.first.toUpperCase();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 左侧：头像（发光光环 + ¥ 徽章，整体 72×72）
          SizedBox(
            width: 72,
            height: 72,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 外层发光光环
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const SweepGradient(
                      colors: [
                        Color(0xFFFFE1A8),
                        Color(0xFFFFC072),
                        Color(0xFFF5A623),
                        Color(0xFFFFE1A8),
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.transfer.withValues(alpha: 0.30),
                        blurRadius: 14,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
                // 中间白色圆环
                Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                  ),
                ),
                // 内层实际头像
                ClipOval(
                  child: Container(
                    width: 58,
                    height: 58,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFFFC57E), AppTheme.transfer],
                      ),
                    ),
                    child: Center(
                      child: Text(
                        firstChar,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
                // 右下角 ¥ 金币徽章
                Positioned(
                  right: 0,
                  bottom: 3,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5),
                      gradient: const LinearGradient(
                        colors: [Color(0xFFFFDB74), Color(0xFFFFA927)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 3,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Text(
                        '¥',
                        maxLines: 1,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          // 右侧：「转账给 XXX」
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                RichText(
                  text: TextSpan(
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                      height: 1.3,
                    ),
                    children: [
                      const TextSpan(text: '转账给'),
                      TextSpan(
                        text: ' $name',
                        style: TextStyle(
                          color: AppTheme.transfer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ========= 主卡片 =========
  Widget _buildMainCard(AppLocalizations loc, ColorScheme scheme, bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 16,
            spreadRadius: -2,
            offset: const Offset(0, 6),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            loc.t('transferAmountLabel'),
            style: TextStyle(
              fontSize: 13,
              color: isDark ? scheme.onSurfaceVariant : const Color(0xFF888888),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '¥',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  color: _amount > 0
                      ? AppTheme.transfer
                      : (isDark
                          ? scheme.outlineVariant
                          : const Color(0xFFBBBBBB)),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _amountCtrl,
                  focusNode: _focus,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                        RegExp(r'^\d{0,6}\.?\d{0,2}$')),
                  ],
                  style: TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    color: scheme.onSurface,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    filled: false,
                    isCollapsed: true,
                    hintText: '0.00',
                    hintStyle: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                      color: Color(0xFFD6D6D6),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                _balanceLoading
                    ? loc.t('transferBalanceLoading')
                    : loc.t(
                        'transferAvailableBalance', {'amount': _fmt(_balance)}),
                style: TextStyle(
                  fontSize: 12,
                  color: isDark
                      ? scheme.onSurfaceVariant
                      : const Color(0xFF999999),
                ),
              ),
              const Spacer(),
              if (_overBalance)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E5),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: AppTheme.danger.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    loc.t('transferInsufficient'),
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.danger,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Divider(height: 0.5, thickness: 0.5, color: scheme.outlineVariant),
          const SizedBox(height: 18),
          Text(
            loc.t('transferNoteLabel'),
            style: TextStyle(
              fontSize: 13,
              color: isDark ? scheme.onSurfaceVariant : const Color(0xFF888888),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _noteCtrl,
            maxLength: 10,
            style: TextStyle(fontSize: 14, color: scheme.onSurface),
            decoration: InputDecoration(
              hintText: loc.t('transferNoteHint'),
              hintStyle: TextStyle(
                  fontSize: 14,
                  color:
                      isDark ? scheme.outlineVariant : const Color(0xFFBBBBBB)),
              filled: true,
              fillColor: isDark
                  ? scheme.surfaceContainerHighest
                  : const Color(0xFFF7F8FA),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              counterText: '',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final loc = AppLocalizations.of(context);
    if (_amount <= 0) {
      AppDialogs.toast(context, loc.t('transferInvalidAmount'));
      return;
    }
    if (_balanceLoading) {
      AppDialogs.toast(context, loc.t('transferReadingBalance'));
      return;
    }
    if (_amount > _balance) {
      AppDialogs.toast(context,
          loc.t('transferBalanceInsufficient', {'amount': _fmt(_balance)}));
      return;
    }
    // 在当前窗口（转账页）直接弹支付密码，输入完成后再回会话页发送
    final payPwd = await PayPwdInputSheet.show(
        context, title: loc.t('payPwdInputTitle'));
    if (payPwd == null) return; // 用户取消：停留在转账页
    if (!mounted) return;
    Navigator.pop(context, {
      'amount': _amount,
      'note': _noteCtrl.text.trim(),
      'toUserId': widget.peerId ?? '',
      'toName': widget.peerName,
      'payPassword': payPwd,
    });
  }
}
