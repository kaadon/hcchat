import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../theme/app_theme.dart';
import '../widgets/lang_picker.dart';
import 'home_shell.dart';
import 'login_page.dart';

/// 扫码登录页（设计稿）
/// 流程：H5 显示二维码（内容含 ticket + secret）→ 移动端 App 扫码
///   → 后端状态变更 → H5 端轮询检测到"已确认"→ 写入 token → 跳转主界面
///
/// 后端接口后续接入。当前前端用本地模拟演示状态机：
///   t=0s 等待扫码 / t=3s 已扫码请确认 / t=6s 已确认 → 模拟登录成功
class QrLoginPage extends StatefulWidget {
  const QrLoginPage({super.key});
  @override
  State<QrLoginPage> createState() => _QrLoginPageState();
}

class _QrLoginPageState extends State<QrLoginPage> {
  final _api = ApiClient.instance;
  String _qrPayload = '';
  int _status = 0; // 0 等待扫码 / 1 已扫码请确认 / 2 已确认
  Timer? _pollTimer;
  Timer? _simulateTimer;
  bool _loading = true;
  int _expireIn = 180; // 180s 过期
  Timer? _expireTimer;

  @override
  void initState() {
    super.initState();
    LocaleProvider.of(context)?.toggle; // 触发 LocaleProvider 存在性检查
    _requestTicket();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _simulateTimer?.cancel();
    _expireTimer?.cancel();
    super.dispose();
  }

  /// 向后端申请 ticket：POST /auth/qr/ticket → {ticket, secret, payload}
  Future<void> _requestTicket() async {
    setState(() => _loading = true);
    try {
      final r = await _api.post('/api/v1/auth/qr/ticket');
      final data =
          (r.data as Map<String, dynamic>)['data'] as Map<String, dynamic>? ??
              {};
      final payload = data['payload']?.toString() ?? '';
      if (payload.isEmpty) throw Exception('生成二维码失败');
      if (mounted) {
        setState(() {
          _qrPayload = payload;
          _loading = false;
        });
        _startPolling();
        _startExpire();
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 轮询二维码状态：GET /auth/qr/status?ticket=xxx
  /// pending：等待扫码 → scanned：已扫码 → confirmed：登录成功
  void _startPolling() {
    _pollTimer?.cancel();
    _simulateTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted) return;
      try {
        final r = await _api
            .get('/api/v1/auth/qr/status', query: {'ticket': _ticket});
        final data =
            (r.data as Map<String, dynamic>)['data'] as Map<String, dynamic>? ??
                {};
        final status = data['status']?.toString() ?? '';
        if (status == 'confirmed') {
          _pollTimer?.cancel();
          _expireTimer?.cancel();
          final token = data['accessToken']?.toString() ?? '';
          if (token.isNotEmpty) {
            await _api.saveToken(token);
            await _api.saveRefresh(data['refreshToken']?.toString() ?? '');
            // 多账号切换：记住本账号
            final u = data['user'] as Map<String, dynamic>? ?? {};
            await _api.rememberAccount(
              id: u['id']?.toString() ?? '',
              account: (u['account'] ?? u['username'] ?? '').toString(),
              nickname: (u['nickname'] ?? '').toString(),
              avatar: (u['avatar'] ?? '').toString(),
              accessToken: token,
              refreshToken: data['refreshToken']?.toString() ?? '',
            );
          }
          if (mounted) {
            setState(() => _status = 2);
            await Future.delayed(const Duration(milliseconds: 500));
            if (mounted) {
              Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => const HomeShell()));
            }
          }
        } else if (status == 'expired') {
          _pollTimer?.cancel();
          _requestTicket(); // 自动刷新
        } else {
          setState(() {
            _status = status == 'scanned' ? 1 : 0;
          });
        }
      } catch (_) {}
    });
  }

  String get _ticket {
    final uri = Uri.tryParse(_qrPayload);
    return uri?.queryParameters['ticket'] ?? '';
  }

  void _startExpire() {
    _expireTimer?.cancel();
    _expireTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _expireIn--);
      if (_expireIn <= 0) {
        _expireTimer?.cancel();
        _requestTicket(); // 自动刷新
      }
    });
  }

  String _statusText(String Function(String, [Map<String, String>?]) t) {
    switch (_status) {
      case 1:
        return t('qrLoginScannedConfirm');
      case 2:
        return t('qrLoginSuccess');
      default:
        return t('qrLoginScanHint');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(t('qrLoginTitle')),
        leading: IconButton(
          onPressed: () => Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const LoginPage())),
          icon: const Icon(Icons.arrow_back_ios_new),
        ),
        actions: [
          TextButton(
            onPressed: () => showLangPicker(context),
            // 显示当前语言；点开弹窗可四语切换
            child: Text(
              AppLocalizations.langNativeName(
                  AppLocalizations.of(context).locale),
              style: const TextStyle(color: AppTheme.primary),
            ),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: const BoxDecoration(
                  color: AppTheme.primary,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.send_rounded,
                    color: Colors.white, size: 36),
              ),
              const SizedBox(height: 14),
              Text('ChatPulse',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: context.cs.onSurface)),
              const SizedBox(height: 6),
              Text(t('qrLoginOpenAppHint'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13, color: context.cs.onSurfaceVariant)),
              const SizedBox(height: 24),
              // 二维码卡片
              Container(
                width: 240,
                height: 240,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: context.cs.surface,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        blurRadius: 16,
                        offset: const Offset(0, 4)),
                  ],
                ),
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : QrImageView(
                        data: _qrPayload,
                        version: QrVersions.auto,
                        backgroundColor: Colors.white,
                        eyeStyle: QrEyeStyle(
                            eyeShape: QrEyeShape.square,
                            color: context.cs.onSurface),
                        dataModuleStyle: QrDataModuleStyle(
                            dataModuleShape: QrDataModuleShape.square,
                            color: context.cs.onSurface),
                      ),
              ),
              const SizedBox(height: 16),
              // 状态文字 + 倒计时
              Text(_statusText(t),
                  style: TextStyle(fontSize: 14, color: context.cs.onSurface)),
              const SizedBox(height: 4),
              Text(t('qrLoginRefreshIn', {'seconds': '$_expireIn'}),
                  style: TextStyle(
                      fontSize: 12, color: context.cs.onSurfaceVariant)),
              const SizedBox(height: 24),
              // 底部操作
              Wrap(
                spacing: 24,
                children: [
                  _action(t('qrLoginRefreshQr'), Icons.refresh, _requestTicket),
                  InkWell(
                    onTap: () => Navigator.of(context).pushReplacement(
                        MaterialPageRoute(builder: (_) => const LoginPage())),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.account_circle_outlined,
                            color: AppTheme.primary, size: 18),
                        const SizedBox(width: 4),
                        Text(t('qrLoginSwitchAccount'),
                            style: TextStyle(
                                fontSize: 13,
                                color: AppTheme.primary,
                                fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _action(String label, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppTheme.primary, size: 18),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.primary,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
