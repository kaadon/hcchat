
import 'dart:typed_data'; // Uint8List（收款码预览 Image.memory，兼容 web）

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../config/app_config.dart';
import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/app_net_image.dart';
import 'pay_ui.dart';

/// 提现收款方式绑定页（一人只能绑定一种，账号唯一）。
/// 按统一设计稿布局：顶部分段切换（支付宝/微信/银行卡）→ 白卡表单（标签在上、
/// 描边输入框）→ 收款码大虚线上传框 → 底部主按钮 + 灰色提示。
/// 接口：GET/PUT /api/v1/wallet/withdraw-account（服务端按 accountType 校验必填）。
class WithdrawAccountPage extends StatefulWidget {
  const WithdrawAccountPage({super.key});

  @override
  State<WithdrawAccountPage> createState() => _WithdrawAccountPageState();
}

class _WithdrawAccountPageState extends State<WithdrawAccountPage> {
  final _api = ApiClient.instance;
  final _picker = ImagePicker();

  // 微信
  final _wechatNameCtrl = TextEditingController();
  // 支付宝
  final _alipayAccountCtrl = TextEditingController();
  final _alipayNameCtrl = TextEditingController();
  // 银行卡
  final _bankCardCtrl = TextEditingController();
  final _bankNameCtrl = TextEditingController();
  final _bankAccNameCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  int _type = 1; // 1微信 2支付宝 3银行卡
  String _wechatQrUrl = ''; // 已绑定的微信收款码（服务端 URL）
  String _alipayQrUrl = ''; // 已绑定的支付宝收款码
  XFile? _wechatQrFile; // 本地新选的收款码（提交时上传替换；H5 需要 XFile 读字节）
  XFile? _alipayQrFile;
  Uint8List? _wechatQrBytes; // 预览用（Image.memory，兼容 web）
  Uint8List? _alipayQrBytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _wechatNameCtrl.dispose();
    _alipayAccountCtrl.dispose();
    _alipayNameCtrl.dispose();
    _bankCardCtrl.dispose();
    _bankNameCtrl.dispose();
    _bankAccNameCtrl.dispose();
    super.dispose();
  }

  String _absUrl(String u) {
    if (u.isEmpty) return u;
    if (u.startsWith('http')) return u;
    return '${AppConfig.instance.apiBase}$u';
  }

  Future<void> _load() async {
    Map<String, dynamic> wa = {};
    try {
      final r = await _api.get('/api/v1/wallet/withdraw-account');
      if ((r.data['code'] as num?)?.toInt() == 0) {
        wa = (r.data['data'] as Map<String, dynamic>? ?? {});
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _type = (wa['accountType'] as num?)?.toInt() ?? 1;
        _wechatNameCtrl.text = (wa['wechatName'] ?? '').toString();
        _wechatQrUrl = (wa['wechatQrcodeUrl'] ?? '').toString();
        _alipayAccountCtrl.text = (wa['alipayAccount'] ?? '').toString();
        _alipayNameCtrl.text = (wa['alipayName'] ?? '').toString();
        _alipayQrUrl = (wa['alipayQrcodeUrl'] ?? '').toString();
        _bankCardCtrl.text = (wa['bankCardNo'] ?? '').toString();
        _bankNameCtrl.text = (wa['bankName'] ?? '').toString();
        _bankAccNameCtrl.text = (wa['bankAccountName'] ?? '').toString();
        _loading = false;
      });
    }
  }

  Future<void> _pickQr(bool isWechat) async {
    try {
      final x = await _picker.pickImage(
          source: ImageSource.gallery,
          maxWidth: 1600,
          maxHeight: 1600,
          imageQuality: 90);
      if (x != null && mounted) {
        // H5 兼容：blob URL 只能现在读字节，预览用 Image.memory（2026-09-16）
        final bytes = await x.readAsBytes();
        setState(() {
          if (isWechat) {
            _wechatQrFile = x;
            _wechatQrBytes = bytes;
          } else {
            _alipayQrFile = x;
            _alipayQrBytes = bytes;
          }
        });
      }
    } catch (_) {}
  }

  /// 上传收款码图（有新选图才传），返回最终 URL（文档约定目录 pay/qrcodes）
  Future<String> _uploadQrIfNeeded(XFile? f, String oldUrl) async {
    if (f == null) return oldUrl;
    final name = 'qrcode_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final up = await _api.uploadXFile(f, name, dir: 'pay/qrcodes');
    return (up['url'] ?? '').toString();
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context).t;
    // 前端先按类型校验必填（与服务端对齐：收款码为建议上传，非必填）
    switch (_type) {
      case 1:
        if (_wechatNameCtrl.text.trim().isEmpty) {
          AppDialogs.toast(context, t('wdNeedWechat'));
          return;
        }
        break;
      case 2:
        if (_alipayAccountCtrl.text.trim().isEmpty ||
            _alipayNameCtrl.text.trim().isEmpty) {
          AppDialogs.toast(context, t('wdNeedAlipay'));
          return;
        }
        break;
      case 3:
        if (_bankCardCtrl.text.trim().isEmpty ||
            _bankNameCtrl.text.trim().isEmpty ||
            _bankAccNameCtrl.text.trim().isEmpty) {
          AppDialogs.toast(context, t('wdNeedBank'));
          return;
        }
        break;
    }
    setState(() => _saving = true);
    try {
      final wechatQr = await _uploadQrIfNeeded(_wechatQrFile, _wechatQrUrl);
      final alipayQr = await _uploadQrIfNeeded(_alipayQrFile, _alipayQrUrl);
      // 未选中类型的字段传空，服务端会清理
      final r = await _api.put('/api/v1/wallet/withdraw-account', data: {
        'accountType': _type,
        'wechatQrcodeUrl': _type == 1 ? wechatQr : '',
        'wechatName': _type == 1 ? _wechatNameCtrl.text.trim() : '',
        'alipayQrcodeUrl': _type == 2 ? alipayQr : '',
        'alipayAccount': _type == 2 ? _alipayAccountCtrl.text.trim() : '',
        'alipayName': _type == 2 ? _alipayNameCtrl.text.trim() : '',
        'bankCardNo': _type == 3 ? _bankCardCtrl.text.trim() : '',
        'bankName': _type == 3 ? _bankNameCtrl.text.trim() : '',
        'bankAccountName': _type == 3 ? _bankAccNameCtrl.text.trim() : '',
      });
      final body = r.data as Map<String, dynamic>;
      if ((body['code'] as num?)?.toInt() == 0) {
        if (!mounted) return;
        AppDialogs.toast(context, t('wdSaveOk'));
        Navigator.of(context).pop();
      } else {
        if (!mounted) return;
        AppDialogs.toast(
            context, '${t('wdSaveFailed')}：${body['message'] ?? ''}');
      }
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('wdSaveFailed'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(t('wdBindTitle'))),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      // 深色模式回退主题纯黑背景，浅色保持微信灰
      backgroundColor:
          scheme.brightness == Brightness.dark ? null : const Color(0xFFEDEDED),
      appBar: AppBar(
          title: Text(t('wdBindTitle'),
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          // 绑定类型分段切换
          PayUI.segmentTabs(
            context: context,
            items: [
              (2, t('wdMethodAlipay'), Icons.payment_outlined),
              (1, t('wdMethodWechat'), Icons.chat_rounded),
              (3, t('wdMethodBank'), Icons.account_balance_outlined),
            ],
            selected: _type,
            onChanged: (v) => setState(() => _type = v),
          ),
          const SizedBox(height: 12),
          // 按类型渲染表单
          if (_type == 3) ...[
            _card(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  _outlinedField(t('wdRealName'), _bankAccNameCtrl),
                  const SizedBox(height: 4),
                  _tip(t('wdRealNameTip')),
                  const SizedBox(height: 14),
                  _outlinedField(t('wdBankCardNo'), _bankCardCtrl,
                      keyboard: TextInputType.number),
                  const SizedBox(height: 14),
                  _outlinedField(t('wdBankName'), _bankNameCtrl),
                ])),
          ],
          if (_type == 1) ...[
            _card(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  _outlinedField(t('wdWechatName'), _wechatNameCtrl),
                  const SizedBox(height: 4),
                  _tip(t('wdRealNameTip')),
                  const SizedBox(height: 14),
                  Text(t('wdWechatQrcode'),
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  _qrBox(),
                ])),
          ],
          if (_type == 2) ...[
            _card(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  _outlinedField(t('wdAlipayName'), _alipayNameCtrl),
                  const SizedBox(height: 4),
                  _tip(t('wdRealNameTip')),
                  const SizedBox(height: 14),
                  _outlinedField(t('wdAlipayAccount'), _alipayAccountCtrl,
                      keyboard: TextInputType.emailAddress),
                  const SizedBox(height: 14),
                  Text(t('wdAlipayQrcode'),
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  _qrBox(),
                ])),
          ],
          const SizedBox(height: 24),
          // 保存按钮（全局统一主按钮）
          PayUI.primaryButton(
            label: t('wdBindNow'),
            onPressed: _saving ? null : _save,
            loading: _saving,
          ),
          const SizedBox(height: 10),
          Center(
              child: Text(t('wdHint'),
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant))),
        ],
      ),
    );
  }

  /// 收款码大虚线上传框（空态=圆形浅蓝图标+提示文字，有图=整框预览，点击换图）
  Widget _qrBox() {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    final isWechat = _type == 1;
    final localBytes = isWechat ? _wechatQrBytes : _alipayQrBytes;
    final serverUrl = isWechat ? _wechatQrUrl : _alipayQrUrl;
    Widget? preview;
    if (localBytes != null) {
      preview = Image.memory(localBytes, fit: BoxFit.cover);
    } else if (serverUrl.isNotEmpty) {
      preview = AppNetImage(url: _absUrl(serverUrl), fit: BoxFit.cover);
    }
    return PayUI.dashedUploadBox(
      context: context,
      height: 170,
      onTap: () => _pickQr(isWechat),
      child: preview != null
          ? SizedBox(
              width: double.infinity,
              height: 170,
              child: ClipRRect(
                  borderRadius: BorderRadius.circular(10), child: preview),
            )
          : Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: PayUI.primary.withValues(alpha: 0.12),
                ),
                child: const Icon(Icons.add_photo_alternate_outlined,
                    size: 26, color: PayUI.primary),
              ),
              const SizedBox(height: 8),
              Text(t('wdPickQrcode'),
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ]),
    );
  }

  /// 标签在上 + 描边输入框（圆角 8，聚焦变主蓝）
  Widget _outlinedField(String label, TextEditingController ctrl,
      {TextInputType? keyboard}) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
      const SizedBox(height: 8),
      TextField(
        controller: ctrl,
        keyboardType: keyboard,
        style: TextStyle(fontSize: 15, color: scheme.onSurface),
        decoration: InputDecoration(
          filled: false,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: scheme.outlineVariant)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: scheme.outlineVariant)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: PayUI.primary, width: 1.5)),
        ),
      ),
    ]);
  }

  /// 灰色小字提示
  Widget _tip(String text) => Text(text,
      style: TextStyle(
          fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant));

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
