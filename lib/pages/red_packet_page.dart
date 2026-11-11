import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_locale.dart';
import '../services/wallet_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/pay_pwd_input_sheet.dart';
import 'pay_ui.dart';

/// 发红包页（v3：AppBar 移到 Scaffold.appBar，SafeArea 正常，不顶状态栏/导航栏）
class RedPacketPage extends StatefulWidget {
  final bool isGroup;
  const RedPacketPage({super.key, required this.isGroup});

  @override
  State<RedPacketPage> createState() => _RedPacketPageState();
}

class _RedPacketPageState extends State<RedPacketPage> {
  int _tab = 0;
  String get _mode => _tab == 0 ? 'lucky' : 'normal';
  final _amountCtrl = TextEditingController();
  final _countCtrl = TextEditingController();
  final _noteCtrl = TextEditingController(text: '恭喜发财，大吉大利');

  double get _amount => double.tryParse(_amountCtrl.text.trim()) ?? 0;
  int get _count => int.tryParse(_countCtrl.text.trim()) ?? 1;

  double _balance = 0;
  bool _balanceLoading = true;

  double get _total {
    final a = _amount;
    if (a <= 0) return 0;
    final isLucky = widget.isGroup && _mode == 'lucky';
    if (isLucky) return a;
    final c = widget.isGroup ? _count : 1;
    return a * (c < 1 ? 1 : c);
  }

  bool get _overBalance => !_balanceLoading && _total > _balance;

  @override
  void initState() {
    super.initState();
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
    _countCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  String _fmt(double v) => v.toStringAsFixed(v.truncateToDouble() == v ? 0 : 2);

  Future<void> _submit() async {
    final loc = AppLocalizations.of(context);
    if (_balanceLoading) return;
    // 按钮始终高亮可点，点击后在这里校验并提示（对齐微信：红包按钮永远醒目）
    if (_total <= 0) {
      AppDialogs.toast(context, loc.t('redPacketInvalidAmount'));
      return;
    }
    if (_overBalance) {
      AppDialogs.toast(context, loc.t('redPacketInsufficient'));
      return;
    }
    final count = widget.isGroup ? _count : 1;
    // 在当前窗口（红包页）直接弹支付密码，输入完成后再回会话页发送
    // （不再回到聊天窗口才弹密码框）
    final payPwd = await PayPwdInputSheet.show(
        context, title: loc.t('payPwdInputTitle'));
    if (payPwd == null) return; // 用户取消：停留在红包页
    if (!mounted) return;
    // 带上 payload + 支付密码 回 chat_page：由会话页真正调发送接口并插入消息气泡
    Navigator.pop(context, <String, dynamic>{
      'amount': _amount,
      'note': _noteCtrl.text.trim(),
      'mode': _mode,
      'count': count,
      'payPassword': payPwd,
    });
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;

    const lightGradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment(0, 0.55),
      colors: [Color(0xFFFA5151), Color(0xFFFDEAEA)],
    );

    return Scaffold(
      backgroundColor: isDark ? scheme.surface : const Color(0xFFFDEAEA),
      extendBodyBehindAppBar: false,
      // ===== AppBar 放这里：Scaffold 自动处理状态栏安全区，不会被盖住 =====
      appBar: AppBar(
        // flexibleSpace 让红包红渐变延伸进 AppBar 背景（更像微信红包）
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFFFA5151), Color(0xFFFB6A6A)],
            ),
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        systemOverlayStyle: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              color: Colors.white, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          widget.isGroup
              ? loc.t('redPacketTitleGroup')
              : loc.t('redPacketTitle'),
          style: const TextStyle(
              fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white),
        ),
      ),
      // ===== body 外层渐变 + SafeArea(top:true 默认，bottom:true 防系统导航栏) =====
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
                    if (widget.isGroup) ...[
                      _buildSegmentTabs(loc),
                      const SizedBox(height: 20),
                    ],
                    _buildFormCard(loc, scheme),
                    const SizedBox(height: 28),
                    _buildSummary(isDark),
                    const SizedBox(height: 4),
                    _buildBalanceTip(loc, scheme, isDark),
                    const SizedBox(height: 24),
                    PayUI.redPacketButton(
                      label: loc.t('redPacketSendButton'),
                      icon: Icons.redeem_rounded,
                      // 始终可点：按钮保持高亮红包红，校验交给 _submit 提示
                      onPressed: _submit,
                    ),
                    const SizedBox(height: 14),
                    Center(
                      child: Text(
                        loc.t(
                            'redPacketFreezeNotice', {'amount': _fmt(_total)}),
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

  // ========= 分段切换 =========
  Widget _buildSegmentTabs(AppLocalizations loc) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          for (final id in const [0, 1])
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _tab = id),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _tab == id ? AppTheme.redPacket : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: _tab == id
                        ? [
                            BoxShadow(
                              color: AppTheme.redPacket.withValues(alpha: 0.3),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    id == 0
                        ? loc.t('redPacketLucky')
                        : loc.t('redPacketNormal'),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight:
                          _tab == id ? FontWeight.w600 : FontWeight.w400,
                      color:
                          _tab == id ? Colors.white : const Color(0xFFFFE8E8),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ========= 表单大卡片（行前置分隔线模式） =========
  Widget _buildFormCard(AppLocalizations loc, ColorScheme scheme) {
    final rows = <Widget>[
      // 第1行：金额（无前置分隔线）
      _iconRow(
        icon: Icons.redeem_rounded,
        iconBg: const Color(0xFFFFE8E8),
        iconColor: AppTheme.redPacket,
        label: widget.isGroup && _mode == 'lucky'
            ? loc.t('redPacketTotalAmount')
            : loc.t('redPacketSingleAmount'),
        suffix: loc.t('rpUnitYuan'),
        child: TextField(
          controller: _amountCtrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'^\d{0,6}\.?\d{0,2}$')),
          ],
          textAlign: TextAlign.right,
          style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface),
          decoration: const InputDecoration(
            border: InputBorder.none,
            filled: false,
            isCollapsed: true,
            contentPadding: EdgeInsets.symmetric(vertical: 20),
            hintText: '0.00',
            hintStyle: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Color(0xFFCCCCCC)),
          ),
          onChanged: (_) => setState(() {}),
        ),
      ),
    ];

    // 第2行：个数（仅群聊，前置分隔线）
    if (widget.isGroup) {
      rows.add(_hairlineDivider());
      rows.add(_iconRow(
        icon: Icons.people_alt_rounded,
        iconBg: const Color(0xFFFFF0DB),
        iconColor: AppTheme.transfer,
        label: loc.t('redPacketCountLabel'),
        suffix: loc.t('rpUnitCount'),
        child: TextField(
          controller: _countCtrl,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          textAlign: TextAlign.right,
          style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface),
          decoration: const InputDecoration(
            border: InputBorder.none,
            filled: false,
            isCollapsed: true,
            contentPadding: EdgeInsets.symmetric(vertical: 20),
            hintText: '0',
            hintStyle: TextStyle(fontSize: 17, color: Color(0xFFCCCCCC)),
          ),
          onChanged: (_) => setState(() {}),
        ),
      ));
    }

    // 第3行：留言（前置分隔线 + 红包色系图标，修正截图里的蓝色图标）
    rows.add(_hairlineDivider());
    rows.add(_iconRow(
      icon: Icons.chat_bubble_outline_rounded,
      iconBg: const Color(0xFFFFE8E8),
      iconColor: AppTheme.redPacket,
      label: loc.t('redPacketNoteLabel'),
      child: TextField(
        controller: _noteCtrl,
        maxLength: 25,
        textAlign: TextAlign.right,
        style: TextStyle(fontSize: 15, color: scheme.onSurface),
        decoration: InputDecoration(
          border: InputBorder.none,
          filled: false,
          isCollapsed: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 20),
          hintText: loc.t('redPacketNoteHint'),
          hintStyle: const TextStyle(fontSize: 15, color: Color(0xFFBBBBBB)),
          counterText: '',
        ),
      ),
    ));

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(22),
        // 明显一点的卡片阴影：让白色卡片从红包背景"浮"出来
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.14),
            blurRadius: 22,
            spreadRadius: -3,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 6,
            spreadRadius: 0,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
      child: Column(children: rows),
    );
  }

  // ========= 图标行 =========
  Widget _iconRow({
    required IconData icon,
    required Color iconBg,
    required Color iconColor,
    required String label,
    required Widget child,
    String? suffix,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 20, color: iconColor),
          ),
          const SizedBox(width: 14),
          SizedBox(
            width: 80,
            // label 变化时（拼手气 ↔ 普通红包）淡入淡出，避免文字瞬切闪烁
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: Text(
                label,
                key: ValueKey(label),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
            ),
          ),
          Expanded(child: child),
          if (suffix != null) ...[
            const SizedBox(width: 8),
            Text(
              suffix,
              style: TextStyle(
                fontSize: 15,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ========= 发丝分隔线 =========
  Widget _hairlineDivider() {
    return Padding(
      padding: const EdgeInsets.only(left: 50),
      child: Divider(
        height: 0.5,
        thickness: 0.5,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
    );
  }

  // ========= 合计预览 =========
  Widget _buildSummary(bool isDark) {
    final totalText = _fmt(_total);
    final hasAmount = _total > 0;
    final color = hasAmount
        ? AppTheme.redPacket
        : (isDark ? const Color(0xFF888888) : const Color(0xFFBBBBBB));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            '合计',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: isDark ? const Color(0xFFCCCCCC) : const Color(0xFF555555),
            ),
          ),
          const SizedBox(width: 10),
          Text('¥',
              style: TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w700, color: color)),
          // 合计金额变化时淡入淡出，避免瞬切闪烁
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: Text(
              totalText,
              key: ValueKey(totalText),
              style: TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ========= 余额 + 超额警告 =========
  Widget _buildBalanceTip(
      AppLocalizations loc, ColorScheme scheme, bool isDark) {
    final balanceColor =
        isDark ? scheme.onSurfaceVariant : const Color(0xFF777777);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(
            _balanceLoading
                ? loc.t('redPacketBalanceLoading')
                : loc
                    .t('redPacketAvailableBalance', {'amount': _fmt(_balance)}),
            style: TextStyle(fontSize: 12, color: balanceColor),
          ),
          if (_overBalance) ...[
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.danger.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                loc.t('redPacketInsufficient'),
                style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.danger,
                    fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
