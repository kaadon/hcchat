
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../config/app_config.dart';
import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/app_net_image.dart';
import 'pay_records_page.dart';
import 'pay_ui.dart';

/// 充值页（离线人工审核通道）。
/// 按统一设计稿布局：顶部分段切换（微信/支付宝/银行卡）→ 白卡收款码（居中图 +
/// 「保存二维码」胶囊按钮弹全屏大图 + 收款账户行可复制）→ 充值金额卡 →
/// 转账凭证大虚线上传框 → 底部主按钮 + 灰色到账提示。
/// 单号/备注不再展示，提交时传空（服务端字段可选）。
/// 接口：im-server recharge_withdraw.go。
class RechargePage extends StatefulWidget {
  const RechargePage({super.key});

  @override
  State<RechargePage> createState() => _RechargePageState();
}

class _RechargePageState extends State<RechargePage> {
  final _api = ApiClient.instance;
  final _amountCtrl = TextEditingController();
  final _picker = ImagePicker();

  bool _loading = true;
  bool _submitting = false;
  Map<String, dynamic> _cfg = {};
  int _payMethod = 1; // 1微信 2支付宝 3银行卡
  XFile? _proofFile; // 本地凭证图（提交时上传；H5 需要 XFile 读字节，2026-09-16）
  Uint8List? _proofBytes; // 预览用（Image.memory，兼容 web）

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
    try {
      final r = await _api.get('/api/v1/pay/config');
      if ((r.data['code'] as num?)?.toInt() == 0) {
        cfg = (r.data['data'] as Map<String, dynamic>? ?? {});
      }
    } catch (_) {}
    // 默认选中第一个有收款码的方式
    int method = 1;
    if ((cfg['receiveWechatQrcodeUrl'] ?? '').toString().isEmpty &&
        (cfg['receiveAlipayQrcodeUrl'] ?? '').toString().isNotEmpty) {
      method = 2;
    }
    if (mounted) {
      setState(() {
        _cfg = cfg;
        _payMethod = method;
        _loading = false;
      });
    }
  }

  /// 服务端返回的图片 URL 兜底拼 baseUrl
  String _absUrl(String u) {
    if (u.isEmpty) return u;
    if (u.startsWith('http')) return u;
    return '${AppConfig.instance.apiBase}$u';
  }

  String _qrcodeUrl(int method) {
    switch (method) {
      case 1:
        return (_cfg['receiveWechatQrcodeUrl'] ?? '').toString();
      case 2:
        return (_cfg['receiveAlipayQrcodeUrl'] ?? '').toString();
      case 3:
        return (_cfg['receiveBankQrcodeUrl'] ?? '').toString();
    }
    return '';
  }

  String _methodName(int method) {
    final t = AppLocalizations.of(context).t;
    switch (method) {
      case 1:
        return t('rcPayMethodWechat');
      case 2:
        return t('rcPayMethodAlipay');
      case 3:
        return t('rcPayMethodBank');
    }
    return '';
  }

  Future<void> _pickProof() async {
    try {
      final x = await _picker.pickImage(
          source: ImageSource.gallery,
          maxWidth: 1920,
          maxHeight: 1920,
          imageQuality: 85);
      if (x != null && mounted) {
        // H5 兼容：blob URL 只能现在读字节，预览用 Image.memory（2026-09-16）
        final bytes = await x.readAsBytes();
        setState(() {
          _proofFile = x;
          _proofBytes = bytes;
        });
      }
    } catch (_) {}
  }

  Future<void> _submit() async {
    final t = AppLocalizations.of(context).t;
    final amount = double.tryParse(_amountCtrl.text.trim()) ?? 0;
    if (amount < 0.01) {
      AppDialogs.toast(context, t('rcAmountInvalid'));
      return;
    }
    if (_proofFile == null) {
      AppDialogs.toast(context, t('rcNeedProof'));
      return;
    }
    setState(() => _submitting = true);
    try {
      // 先传凭证图（文档约定目录 pay/proofs）
      final name = 'proof_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final up = await _api.uploadXFile(_proofFile!, name, dir: 'pay/proofs');
      final proofUrl = (up['url'] ?? '').toString();
      // 提交充值订单（单号/备注 UI 已移除，传空）
      final r = await _api.post('/api/v1/wallet/recharge/submit', data: {
        'amount': amount,
        'payMethod': _payMethod,
        'proofImage': proofUrl,
        'payTxNo': '',
        'remark': '',
      });
      final body = r.data as Map<String, dynamic>;
      if ((body['code'] as num?)?.toInt() == 0) {
        if (!mounted) return;
        AppDialogs.toast(context, t('rcSubmitOk'));
        _amountCtrl.clear();
        setState(() {
          _proofFile = null;
          _proofBytes = null;
        });
        _load();
      } else {
        if (!mounted) return;
        AppDialogs.toast(
            context, '${t('rcSubmitFailed')}：${body['message'] ?? ''}');
      }
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('rcSubmitFailed'));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 复制文本到剪贴板并提示
  Future<void> _copy(String text) async {
    final t = AppLocalizations.of(context).t;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) AppDialogs.toast(context, t('rcCopied'));
  }

  /// 全屏大图查看收款码（零依赖：用户自行截图保存）
  void _showQrDialog(String url) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black.withValues(alpha: 0.92),
        child: GestureDetector(
          onTap: () => Navigator.pop(ctx),
          child: Center(
            child: InteractiveViewer(
              maxScale: 4,
              child: AppNetImage(url: url, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(t('rcTitle'))),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final enabled = _cfg['enabled'] == true;
    final tips = (_cfg['rechargeTips'] ?? '').toString();
    final qrUrl = _absUrl(_qrcodeUrl(_payMethod));
    final isDark = scheme.brightness == Brightness.dark;
    return Scaffold(
      // 深色模式回退主题纯黑背景，浅色保持微信灰
      backgroundColor: isDark ? null : const Color(0xFFEDEDED),
      appBar: AppBar(
          title: Text(t('rcTitle'),
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const RechargeRecordsPage())),
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
                  child: Text(t('rcNotEnabled'),
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant))),
            ]))
          else ...[
            // 支付方式分段切换
            PayUI.segmentTabs(
              context: context,
              items: [
                (1, t('rcPayMethodWechat'), Icons.chat_rounded),
                (2, t('rcPayMethodAlipay'), Icons.payment_outlined),
                (3, t('rcPayMethodBank'), Icons.account_balance_outlined),
              ],
              selected: _payMethod,
              onChanged: (v) => setState(() => _payMethod = v),
            ),
            const SizedBox(height: 12),
            // 收款码卡：居中大图 + 保存二维码胶囊 + 银行卡收款账户
            _card(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                  Text(_methodName(_payMethod),
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface)),
                  const SizedBox(height: 12),
                  Container(
                    width: 180,
                    height: 180,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // 底层永远是二维码图标：加载中 / 加载失败都不会白块
                        Center(
                            child: Icon(Icons.qr_code_2,
                                size: 56, color: scheme.onSurfaceVariant)),
                        if (qrUrl.isNotEmpty)
                          Image.network(qrUrl,
                              fit: BoxFit.contain,
                              frameBuilder: (ctx, child, frame, wasSync) =>
                                  (wasSync || frame != null)
                                      ? child
                                      : const SizedBox.shrink(),
                              errorBuilder: (_, __, ___) =>
                                  const SizedBox.shrink()),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 保存二维码（点击弹全屏大图，供用户截图保存）
                  if (qrUrl.isNotEmpty)
                    GestureDetector(
                      onTap: () => _showQrDialog(qrUrl),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: PayUI.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.download_rounded,
                              size: 14, color: PayUI.primary),
                          const SizedBox(width: 4),
                          Text(t('rcSaveQrcode'),
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: PayUI.primary)),
                        ]),
                      ),
                    ),
                  const SizedBox(height: 10),
                  Text(t('rcScanTips'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                  // 银行卡：收款账户信息（每项可复制）
                  if (_payMethod == 3) ...[
                    const SizedBox(height: 12),
                    Divider(height: 1, color: scheme.outlineVariant),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(
                        children: [
                          _copyRow(
                              t('rcBankName'),
                              (_cfg['receiveBankInfo']?['bankName'] ?? '')
                                  .toString()),
                          _copyRow(
                              t('rcCardNo'),
                              (_cfg['receiveBankInfo']?['cardNo'] ?? '')
                                  .toString()),
                          _copyRow(
                              t('rcPayeeName'),
                              (_cfg['receiveBankInfo']?['accountName'] ?? '')
                                  .toString()),
                        ],
                      ),
                    ),
                  ],
                  if (tips.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(tips,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ],
                ])),
            const SizedBox(height: 12),
            // 充值金额：标签在上 + ¥ 大字输入
            _card(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(t('rcAmount'),
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
                        style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface),
                        decoration: InputDecoration(
                          hintText: t('rcAmountHint'),
                          hintStyle: TextStyle(
                              fontSize: 16, color: scheme.outlineVariant),
                          filled: false,
                          border: InputBorder.none,
                          isCollapsed: true,
                        ),
                      ),
                    ),
                  ]),
                ])),
            const SizedBox(height: 12),
            // 转账凭证：大虚线上传框
            _card(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(t('rcProof'),
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 10),
                  PayUI.dashedUploadBox(
                    context: context,
                    height: 170,
                    onTap: _pickProof,
                    child: _proofBytes != null
                        ? SizedBox(
                            width: double.infinity,
                            height: 170,
                            child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: Image.memory(_proofBytes!,
                                    fit: BoxFit.cover)))
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 52,
                                height: 52,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: PayUI.primary.withValues(alpha: 0.12),
                                ),
                                child: const Icon(
                                    Icons.add_photo_alternate_outlined,
                                    size: 26,
                                    color: PayUI.primary),
                              ),
                              const SizedBox(height: 8),
                              Text(t('rcProofPick'),
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: scheme.onSurfaceVariant)),
                            ],
                          ),
                  ),
                ])),
            const SizedBox(height: 24),
            // 提交按钮（全局统一主按钮）
            PayUI.primaryButton(
              label: t('rcSubmit'),
              onPressed: _submitting ? null : _submit,
              loading: _submitting,
            ),
            const SizedBox(height: 10),
            // 到账提示（按钮下方灰色提示行）
            Center(
                child: Text(t('rcArriveHint'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant))),
          ],
        ],
      ),
    );
  }

  /// 收款账户信息行：标签 + 值 + 复制按钮
  Widget _copyRow(String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    final t = AppLocalizations.of(context).t;
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
              width: 76,
              child: Text(label,
                  style:
                      TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface)),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => _copy(value),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.copy_rounded,
                    size: 12, color: scheme.onSurfaceVariant),
                const SizedBox(width: 3),
                Text(t('rcCopy'),
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant)),
              ]),
            ),
          ),
        ],
      ),
    );
  }

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
