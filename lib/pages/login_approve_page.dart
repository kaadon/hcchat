import 'package:flutter/material.dart';

import '../app_navigator.dart';
import '../l10n/app_locale.dart';
import '../services/auth_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/v2_kit.dart';

/// 账户安全验证·审批方页面（全屏，非弹窗）。
/// 本设备作为「可信设备」收到新设备的登录审批请求（WS `login.approve`），
/// 在此页面确认允许/拒绝，调用 /auth/verify/approve（服务端校验 X-Device-ID 命中审批设备）。
/// 视觉对齐「扫码登录确认页」：居中图标 + 设备信息卡 + 底部允许/拒绝。
class LoginApprovePage extends StatefulWidget {
  final Map<String, dynamic> data;
  const LoginApprovePage({super.key, required this.data});

  @override
  State<LoginApprovePage> createState() => _LoginApprovePageState();
}

class _LoginApprovePageState extends State<LoginApprovePage> {
  late final String _ticket;
  late final String _deviceName;
  late final int _deviceType;
  late final String _ip;
  late final String _time;
  bool _handling = false;
  String? _result; // 'allowed' | 'rejected' | null

  @override
  void initState() {
    super.initState();
    final d = widget.data;
    _ticket = (d['verifyTicket'] ?? '').toString();
    _deviceName = (d['deviceName'] ?? '').toString();
    _deviceType =
        d['deviceType'] is int ? d['deviceType'] : int.tryParse(d['deviceType']?.toString() ?? '') ?? 0;
    _ip = (d['ip'] ?? '').toString();
    _time = (d['time'] ?? '').toString();
  }

  IconData get _deviceIcon {
    switch (_deviceType) {
      case 1:
      case 2:
        return Icons.smartphone_rounded;
      case 3:
      case 4:
      case 5:
        return Icons.computer_rounded;
      default:
        return Icons.devices_other_rounded;
    }
  }

  String get _deviceTypeLabel {
    switch (_deviceType) {
      case 1:
        return 'Android';
      case 2:
        return 'iOS';
      case 3:
        return '手机网页';
      case 4:
        return 'Windows';
      case 5:
        return 'macOS';
      default:
        return AppLocalizations.of(context).t('devUnknownDevice');
    }
  }

  Future<void> _act(bool allow) async {
    if (_handling || _result != null || !mounted) return;
    setState(() => _handling = true);
    final t = AppLocalizations.of(context).t;
    try {
      await AuthService().verifyApprove(_ticket, allow ? 'allow' : 'reject');
      if (!mounted) return;
      setState(() => _result = allow ? 'allowed' : 'rejected');
      // 1.2s 后自动返回原页面
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (mounted) appNavigatorKey.currentState?.pop();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _handling = false);
      AppDialogs.toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final bg = context.v2Bg;
    final fg = context.v2ActionBg;
    final muted = context.v2MutedColor;

    if (_result != null) {
      final ok = _result == 'allowed';
      return Scaffold(
        backgroundColor: bg,
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (ok ? Colors.green : AppTheme.danger).withOpacity(0.12),
                  ),
                  child: Icon(
                    ok ? Icons.check_rounded : Icons.close_rounded,
                    size: 46,
                    color: ok ? Colors.green : AppTheme.danger,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  ok ? t('verifyApproveDoneAllow') : t('verifyApproveDoneReject'),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => appNavigatorKey.currentState?.pop(),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            children: [
              const SizedBox(height: 24),
              // 顶部设备图标（呼吸光环，呼应「等待批准」语义）
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: fg.withOpacity(0.1),
                ),
                child: Icon(_deviceIcon, size: 48, color: fg),
              ),
              const SizedBox(height: 24),
              Text(t('verifyApprovePageTitle'),
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(t('verifyApprovePageSubtitle'),
                  style: TextStyle(fontSize: 14, color: muted),
                  textAlign: TextAlign.center),
              const SizedBox(height: 28),
              // 设备信息卡
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: context.v2Fill,
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: const EdgeInsets.all(18),
                child: Column(
                  children: [
                    _InfoRow(
                      label: t('verifyApproveDevice'),
                      value: _deviceName.isEmpty
                          ? _deviceTypeLabel
                          : '$_deviceName · $_deviceTypeLabel',
                    ),
                    const SizedBox(height: 14),
                    _InfoRow(label: t('verifyApproveIp'), value: _ip),
                    const SizedBox(height: 14),
                    _InfoRow(label: t('verifyApproveTime'), value: _time),
                  ],
                ),
              ),
              const Spacer(),
              // 底部操作：允许（主按钮）+ 拒绝（危险描边）
              V2PrimaryButton(
                label: _handling ? t('verifyApproveProcessing') : t('verifyApproveAllow'),
                loading: _handling,
                onPressed: () => _act(true),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: AppTheme.v2PrimaryBtnHeight,
                child: OutlinedButton(
                  onPressed: _handling ? null : () => _act(false),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: AppTheme.danger.withOpacity(0.5)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.v2Radius),
                    ),
                  ),
                  child: Text(t('verifyApproveReject'),
                      style: TextStyle(color: AppTheme.danger, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label, style: TextStyle(fontSize: 14, color: context.v2MutedColor)),
        const Spacer(),
        Expanded(
          flex: 2,
          child: Text(value,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}
