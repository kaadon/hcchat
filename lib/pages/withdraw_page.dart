import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/wallet_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';
import 'pay_records_page.dart';
import 'pay_ui.dart';
import 'withdraw_account_page.dart';

/// 提现页（离线人工审核通道）。
/// 按统一设计稿布局：顶部蓝渐变余额卡（账户余额白字 + 大数字 + 规则提示）→
/// 白卡提现金额（标签在上 + ¥ 大字输入 + 全部按钮 + 手续费/实际到账 + 到账提示）→
/// 白卡提现方式（标题 + 三行单选 + 修改收款信息入口）→ 底部主按钮。
/// 服务端冻结余额并生成 withdraw_order，后台审核打款后结算。
class WithdrawPage extends StatefulWidget {
  const WithdrawPage({super.key});

  @override
  State<WithdrawPage> createState() => _WithdrawPageState();
}

class _WithdrawPageState extends State<WithdrawPage> {
  final _api = ApiClient.instance;
  final _amountCtrl = TextEditingController();

  bool _loading = true;
  bool _submitting = false;
  Map<String, dynamic> _cfg = {}; // pay/config
  Map<String, dynamic> _wa = {}; // withdraw-account
  int _withdrawType = 0; // 当前选中的提现方式（1微信 2支付宝 3银行卡）

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    Map<String, dynamic> cfg = {};
    Map<String, dynamic> wa = {};
    // 余额与配置**并发**拉取：本页"全部提现"会用余额直接填充金额，
    // 必须是服务端最新值——用落盘快照（可能过期）会填出一个提现失败的金额。
    final walletFuture = WalletStore.instance.refresh();
    try {
      final r = await _api.get('/api/v1/pay/config');
      if ((r.data['code'] as num?)?.toInt() == 0) {
        cfg = (r.data['data'] as Map<String, dynamic>? ?? {});
      }
    } catch (_) {}
    try {
      final r = await _api.get('/api/v1/wallet/withdraw-account');
      if ((r.data['code'] as num?)?.toInt() == 0) {
        wa = (r.data['data'] as Map<String, dynamic>? ?? {});
      }
    } catch (_) {}
    await walletFuture; // 页面要展示余额，必须等它回来再 setState
    // 默认选中已绑定的方式
    final boundType = (wa['accountType'] as num?)?.toInt() ?? 0;
    if (mounted) {
      setState(() {
        _cfg = cfg;
        _wa = wa;
        _withdrawType = boundType;
        _loading = false;
      });
      // 进页即检测：未绑定任何收款方式 → 弹窗强制引导去绑定
      if (boundType == 0) _showBindGuide();
    }
  }

  /// 未绑定收款方式：弹窗引导（微信风格：居中标题/内容 + 发丝线分隔双文字按钮）
  Future<void> _showBindGuide() async {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    final go = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
            child: Text(t('wdBindTitle'),
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
            child: Text(t('wdBindFirst'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant)),
          ),
          Divider(height: 1, thickness: 0.5, color: scheme.outlineVariant),
          SizedBox(
            height: 48,
            child: Row(children: [
              Expanded(
                child: InkWell(
                  onTap: () => Navigator.pop(ctx, false),
                  child: Center(
                    child: Text(t('wdBindCancel'),
                        style: TextStyle(
                            fontSize: 16, color: scheme.onSurfaceVariant)),
                  ),
                ),
              ),
              VerticalDivider(
                  width: 1, thickness: 0.5, color: scheme.outlineVariant),
              Expanded(
                child: InkWell(
                  onTap: () => Navigator.pop(ctx, true),
                  child: Center(
                    child: Text(t('wdBind'),
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: PayUI.primary)),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
    if (!mounted) return;
    if (go != true) {
      // 暂不绑定：退出提现页
      Navigator.of(context).pop();
      return;
    }
    // 去绑定：绑定页返回后重新检测（绑好继续提现，没绑再弹）
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const WithdrawAccountPage()));
    if (!mounted) return;
    await _load();
  }

  double get _balance => WalletStore.instance.balance;
  double get _amount => double.tryParse(_amountCtrl.text.trim()) ?? 0;

  /// 服务端规则：fee = max(amount*feeRate, feeMin)
  double get _fee {
    final rate = (_cfg['withdrawFeeRate'] as num?)?.toDouble() ?? 0;
    final feeMin = (_cfg['withdrawFeeMin'] as num?)?.toDouble() ?? 0;
    var f = _amount * rate;
    if (f < feeMin) f = feeMin;
    return f;
  }

  bool _isBound(int type) => (_wa['accountType'] as num?)?.toInt() == type;

  /// 各类型绑定是否完整（与服务端校验对齐）
  bool _isBoundComplete(int type) {
    if (!_isBound(type)) return false;
    switch (type) {
      case 1:
        return (_wa['wechatName'] ?? '').toString().isNotEmpty;
      case 2:
        return (_wa['alipayAccount'] ?? '').toString().isNotEmpty &&
            (_wa['alipayName'] ?? '').toString().isNotEmpty;
      case 3:
        return (_wa['bankCardNo'] ?? '').toString().isNotEmpty &&
            (_wa['bankName'] ?? '').toString().isNotEmpty &&
            (_wa['bankAccountName'] ?? '').toString().isNotEmpty;
    }
    return false;
  }

  String _boundSummary(int type) {
    switch (type) {
      case 1:
        return (_wa['wechatName'] ?? '').toString();
      case 2:
        return '${(_wa['alipayName'] ?? '').toString()}'
            ' ${(_wa['alipayAccount'] ?? '').toString()}';
      case 3:
        return '${(_wa['bankName'] ?? '').toString()}'
            ' ${(_wa['bankCardNo'] ?? '').toString()}';
    }
    return '';
  }

  Future<void> _submit() async {
    final t = AppLocalizations.of(context).t;
    final min = (_cfg['withdrawMin'] as num?)?.toDouble() ?? 0;
    final max = (_cfg['withdrawMax'] as num?)?.toDouble() ?? 0;
    if (_amount < min || _amount > max) {
      AppDialogs.toast(
          context,
          t('wdRange',
              {'min': min.toStringAsFixed(0), 'max': max.toStringAsFixed(0)}));
      return;
    }
    if (!_isBoundComplete(_withdrawType)) {
      AppDialogs.toast(context, t('wdNeedBind'));
      return;
    }
    setState(() => _submitting = true);
    try {
      final r = await _api.post('/api/v1/wallet/withdraw/submit', data: {
        'amount': _amount,
        'withdrawType': _withdrawType,
      });
      final body = r.data as Map<String, dynamic>;
      if ((body['code'] as num?)?.toInt() == 0) {
        if (!mounted) return;
        AppDialogs.toast(context, t('wdSubmitOk'));
        _amountCtrl.clear();
        // 提交后余额转入冻结，立即刷新余额缓存
        WalletStore.instance.refresh();
        _load();
      } else {
        if (!mounted) return;
        AppDialogs.toast(
            context, '${t('wdSubmitFailed')}：${body['message'] ?? ''}');
      }
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('wdSubmitFailed'));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(t('wdTitle'))),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final enabled = _cfg['withdrawEnabled'] == true;
    final min = (_cfg['withdrawMin'] as num?)?.toDouble() ?? 0;
    final max = (_cfg['withdrawMax'] as num?)?.toDouble() ?? 0;
    final feeRate = (_cfg['withdrawFeeRate'] as num?)?.toDouble() ?? 0;
    final feeMin = (_cfg['withdrawFeeMin'] as num?)?.toDouble() ?? 0;
    final actual = (_amount - _fee) > 0 ? _amount - _fee : 0.0;
    final isDark = scheme.brightness == Brightness.dark;
    return Scaffold(
      // 深色模式回退主题纯黑背景，浅色保持微信灰
      backgroundColor: isDark ? null : const Color(0xFFEDEDED),
      appBar: AppBar(
          title: Text(t('wdTitle'),
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const WithdrawRecordsPage())),
              child: Text(t('payRecords'),
                  style: TextStyle(fontSize: 15, color: scheme.onSurface)),
            ),
          ]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          if (!enabled)
            _card(
                child: Row(children: [
              Icon(Icons.info_outline,
                  size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(t('wdNotEnabled'),
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant))),
            ]))
          else ...[
            // 蓝渐变余额卡
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: PayUI.balanceGradient,
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t('wdBalance'),
                        style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.85))),
                    const SizedBox(height: 6),
                    Text('¥ ${_balance.toStringAsFixed(2)}',
                        style: const TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                    const SizedBox(height: 8),
                    Text(
                        t('wdRule', {
                          'min': min.toStringAsFixed(0),
                          'max': max.toStringAsFixed(0),
                          'rate': (feeRate * 100).toStringAsFixed(
                              feeRate * 100 == feeRate * 100.truncateToDouble()
                                  ? 0
                                  : 1),
                          'feeMin': feeMin.toStringAsFixed(0),
                        }),
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.white.withValues(alpha: 0.75))),
                  ]),
            ),
            const SizedBox(height: 12),
            // 提现金额：标签在上 + ¥ 大字输入 + 全部按钮 + 手续费/到账
            _card(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(t('wdAmount'),
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                    Text('¥',
                        style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextField(
                        controller: _amountCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        onChanged: (_) => setState(() {}),
                        style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface),
                        decoration: InputDecoration(
                          hintText: t('wdAmountHint'),
                          hintStyle: TextStyle(
                              fontSize: 16, color: scheme.outlineVariant),
                          filled: false,
                          border: InputBorder.none,
                          isCollapsed: true,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        _amountCtrl.text = _balance.toStringAsFixed(2);
                        setState(() {});
                      },
                      style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                      child: Text(t('wdAll'),
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: PayUI.primary)),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Divider(height: 1, color: scheme.outlineVariant),
                  const SizedBox(height: 10),
                  _kv(t('wdFee'),
                      '¥${_amount <= 0 ? '0.00' : _fee.toStringAsFixed(2)}'),
                  const SizedBox(height: 6),
                  _kv(t('wdActual'), '¥${actual.toStringAsFixed(2)}',
                      bold: true),
                  const SizedBox(height: 8),
                  Text(t('wdArriveHint'),
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant)),
                ])),
            const SizedBox(height: 12),
            // 提现方式：标题 + 三行单选 + 修改收款信息入口
            _card(
                padding: EdgeInsets.zero,
                child: Column(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
                    child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(t('wdMethodTitle'),
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurface))),
                  ),
                  _methodRow(1, Icons.chat_rounded, t('wdMethodWechat')),
                  Divider(height: 1, indent: 14, color: scheme.outlineVariant),
                  _methodRow(2, Icons.payment_outlined, t('wdMethodAlipay')),
                  Divider(height: 1, indent: 14, color: scheme.outlineVariant),
                  _methodRow(
                      3, Icons.account_balance_outlined, t('wdMethodBank')),
                  Divider(height: 1, indent: 14, color: scheme.outlineVariant),
                  InkWell(
                    onTap: _goBind,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 13),
                      child: Row(
                        children: [
                          Icon(Icons.credit_card,
                              size: 20, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(t('wdEditAccount'),
                                style: TextStyle(
                                    fontSize: 14,
                                    color: scheme.onSurfaceVariant)),
                          ),
                          Icon(Icons.chevron_right,
                              size: 18, color: scheme.onSurfaceVariant),
                        ],
                      ),
                    ),
                  ),
                ])),
            const SizedBox(height: 24),
            // 提交按钮（全局统一主按钮）
            PayUI.primaryButton(
              label: t('wdSubmit'),
              onPressed: _submitting ? null : _submit,
              loading: _submitting,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _goBind() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const WithdrawAccountPage()));
    _load(); // 绑定页返回后刷新状态
  }

  Widget _kv(String k, String v, {bool bold = false}) => Row(
        children: [
          Expanded(
              child: Text(k,
                  style: TextStyle(
                      fontSize: 13, color: context.cs.onSurfaceVariant))),
          Text(v,
              style: TextStyle(
                  fontSize: bold ? 16 : 14,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                  color: context.cs.onSurface)),
        ],
      );

  /// 收款方式单选行：左图标 + 名称 + 绑定摘要/未绑定 + 右圆形单选
  Widget _methodRow(int type, IconData icon, String label) {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    final selected = _withdrawType == type;
    final complete = _isBoundComplete(type);
    final sub = complete
        ? _boundSummary(type)
        : (_isBound(type) ? t('wdNotBound') : '');
    return InkWell(
      onTap: () => setState(() => _withdrawType = type),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Icon(icon,
                size: 22,
                color: selected ? PayUI.primary : scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                          color: scheme.onSurface)),
                  if (sub.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            color: complete
                                ? AppTheme.green
                                : scheme.onSurfaceVariant)),
                  ],
                ],
              ),
            ),
            _radio(selected),
          ],
        ),
      ),
    );
  }

  /// 圆形单选指示器
  Widget _radio(bool selected) => PayUI.radio(context, selected);

  Widget _card({required Widget child, EdgeInsetsGeometry? padding}) =>
      Container(
        width: double.infinity,
        padding: padding ?? const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.cs.surface,
          borderRadius: BorderRadius.circular(10),
        ),
        child: child,
      );
}
