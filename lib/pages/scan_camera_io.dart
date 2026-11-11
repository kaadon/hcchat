import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../l10n/app_locale.dart';

/// native 摄像头扫码（mobile_scanner 6.x）
/// 核心策略：**显式 start，不依赖 autoStart + errorBuilder 的被动报错**。
/// 6.x 的 start() 会把平台初始化异常吞进 controller.value.error（不外抛），
/// 且平台层启动可能挂死（无回调无异常）——autoStart 模式下这两种情况
/// 都会让页面永远停在「初始化中」。因此：
/// - autoStart: false，挂载后主动 await controller.start() + 8s 超时；
///   超时 = 启动挂死（典型原因：相机被其它应用/通话占用），直接进重试/报错。
/// - start 返回后显式检查 value.error / isRunning，拿到真实错误详情。
/// - 权限 status/request 全程 try/catch（部分 ROM 会抛，抛异常就永久转圈）。
/// - 加载态显示当前步骤（检查权限/释放相机/启动第 N 次），页面内可见排障。
/// - 非 ready 态一律不挂载 MobileScanner widget，重试先卸载旧 widget 再
///   dispose 旧 controller，避免平台级竞态。
class ScanCamera extends StatefulWidget {
  final ValueChanged<String> onScan;
  const ScanCamera({super.key, required this.onScan});

  @override
  State<ScanCamera> createState() => _ScanCameraState();
}

class _ScanCameraState extends State<ScanCamera> {
  MobileScannerController? _controller;
  String _lastError =
      ''; // '', 'permission_denied', 'permanently_denied', 'init_failed'
  String _lastErrorDetail = ''; // 底层异常详情（截断 160 字符）
  bool _checkingPermission = true; // 加载/过渡态（含相机启动中）
  String _step = ''; // 加载态步骤：perm / release / starting / retry
  int _autoRetry = 0; // 自动重试次数（CameraX 瞬时初始化失败很常见）
  bool _disposed = false; // 页面已销毁，所有异步回调 setState 前必须先判断
  bool _starting = false; // _start 并发守卫

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _disposed = true;
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  void _setStep(String s) {
    if (_disposed || !mounted) return;
    setState(() => _step = s);
  }

  Future<void> _start({bool manual = true}) async {
    if (_starting || _disposed) return;
    _starting = true;
    try {
      if (manual) _autoRetry = 0;
      if (!mounted) return;

      // 先摘掉旧 controller：UI 立即离开 ready 态，MobileScanner 随之从树上卸载
      final old = _controller;
      setState(() {
        _checkingPermission = true;
        _lastError = '';
        _lastErrorDetail = '';
        _step = 'release';
        _controller = null;
      });
      // 等一帧确保旧 MobileScanner widget 完成卸载，再做平台级 dispose
      await WidgetsBinding.instance.endOfFrame;
      await old?.dispose();
      if (_disposed || !mounted) return;
      // 释放相机需要时间，给 CameraX 一个缓冲（国产 ROM 上 300ms 经常不够）
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (_disposed || !mounted) return;

      // 1. 检查权限（部分 ROM 的 status/request 会抛异常，必须兜底，
      //    否则 _starting 复位后 UI 永远停在加载态且无任何提示）
      _setStep('perm');
      PermissionStatus status;
      try {
        status = await Permission.camera.status;
      } catch (e) {
        _showInitError('权限状态查询异常: $e');
        return;
      }
      if (_disposed || !mounted) return;
      PermissionStatus effective = status;
      if (!status.isGranted) {
        try {
          effective = await Permission.camera.request();
        } catch (e) {
          _showInitError('权限申请异常: $e');
          return;
        }
        if (_disposed || !mounted) return;
      }
      if (effective.isGranted) {
        await _launchCamera();
      } else if (effective.isPermanentlyDenied) {
        setState(() {
          _lastError = 'permanently_denied';
          _checkingPermission = false;
        });
      } else {
        setState(() {
          _lastError = 'permission_denied';
          _checkingPermission = false;
        });
      }
    } finally {
      _starting = false;
    }
  }

  /// 创建控制器（autoStart:false）→ 挂载 → 显式 start（8s 超时）→ 检查结果
  Future<void> _launchCamera() async {
    if (_disposed || !mounted) return;
    final ctrl = MobileScannerController(
      autoStart: false,
      facing: CameraFacing.back,
      formats: const [BarcodeFormat.qrCode],
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
    setState(() {
      _controller = ctrl;
      _checkingPermission = false; // 进入 ready 态，MobileScanner 挂载
      _step = 'starting';
    });
    // 等 widget 完成挂载（start 内部等 attach，这里主动等一帧更稳）
    await WidgetsBinding.instance.endOfFrame;
    if (_disposed || !mounted) {
      await ctrl.dispose();
      return;
    }
    try {
      // 平台层挂死时 start 永不返回 → 超时兜底（autoStart 模式下这就是
      // 「一直在初始化」的元凶，现在 8 秒内必定给出结论）
      await ctrl.start().timeout(const Duration(seconds: 8));
    } on TimeoutException {
      _showInitError('启动超时：8 秒无回调（相机可能被其它应用占用，'
          '或上次相机未释放完成）');
      return;
    } catch (e) {
      _showInitError('启动异常: $e');
      return;
    }
    if (_disposed || !mounted) return;
    // 6.x 的 start() 吞掉初始化异常（只写入 value.error），这里显式检查
    final err = ctrl.value.error;
    if (err != null) {
      _showInitError('$err');
    } else if (!ctrl.value.isRunning) {
      _showInitError('启动未完成（isRunning=false，无异常回调）');
    }
  }

  /// 初始化失败统一入口：3 次自动重试（间隔 0.8/1.8/3s），仍失败则报错 + 详情
  void _showInitError(String detail) {
    if (_disposed || !mounted) return;
    debugPrint('[Scan] init error: $detail');
    if (_autoRetry < 3) {
      _autoRetry += 1;
      final delay = _autoRetry == 1 ? 800 : (_autoRetry == 2 ? 1800 : 3000);
      setState(() {
        _checkingPermission = true; // 先卸载相机 widget，再走干净的重试路径
        _step = 'retry';
      });
      Future<void>.delayed(Duration(milliseconds: delay), () {
        if (_disposed || !mounted) return;
        _start(manual: false);
      });
      return;
    }
    setState(() {
      _lastError = 'init_failed';
      _lastErrorDetail = _clipDetail(detail);
      _checkingPermission = false;
    });
  }

  /// errorBuilder 兜底（权限类错误从错误流来的场景）
  void _onCameraError(bool denied, String detail) {
    if (_disposed || !mounted) return;
    debugPrint('[Scan] camera error: $detail');
    if (denied) {
      if (_lastError == 'permission_denied') return;
      setState(() {
        _lastError = 'permission_denied';
        _lastErrorDetail = _clipDetail(detail);
        _checkingPermission = false;
      });
      return;
    }
    // 重试/启动在途（加载态）时交给显式 start 的检查路径，避免重复调度
    if (_checkingPermission) return;
    _showInitError(detail);
  }

  String _clipDetail(String text) {
    if (text.length <= 160) return text;
    return text.substring(0, 160);
  }

  /// 相机被占用类错误的友好提示（详情文本特征匹配）
  bool get _detailBusy {
    final d = _lastErrorDetail.toLowerCase();
    return d.contains('in use') ||
        d.contains('inuse') ||
        d.contains('busy') ||
        d.contains('占用');
  }

  String get _stepText {
    switch (_step) {
      case 'perm':
        return '正在检查相机权限…';
      case 'release':
        return '正在释放相机…';
      case 'starting':
        return _autoRetry > 0 ? '正在启动摄像头（自动重试 $_autoRetry/3）…' : '正在启动摄像头…';
      case 'retry':
        return '启动失败，正在自动重试（$_autoRetry/3）…';
    }
    return '正在初始化…';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    if (_checkingPermission) {
      // 加载态：显示当前步骤，让用户/截图能看出卡在哪一步
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.white54),
            const SizedBox(height: 14),
            Text(_stepText,
                style: const TextStyle(color: Colors.white38, fontSize: 12)),
          ],
        ),
      );
    }

    if (_lastError.isNotEmpty) {
      return _buildError(_lastError == 'permanently_denied');
    }

    final controller = _controller;
    if (controller == null) {
      return _buildError(false, customMessage: t('scanCamNotReady'));
    }

    // 只有 ready 态才挂载 MobileScanner
    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: controller,
          onDetect: _onDetect,
          errorBuilder: (context, error, child) {
            final detail = error.toString();
            final denied = _isPermissionError(detail);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _onCameraError(denied, detail);
            });
            return _buildError(denied);
          },
        ),
        // 扫描框
        IgnorePointer(
          child: Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white38, width: 1.5),
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _onDetect(BarcodeCapture capture) {
    final raw =
        capture.barcodes.isEmpty ? '' : (capture.barcodes.first.rawValue ?? '');
    if (raw.isNotEmpty) widget.onScan(raw);
  }

  /// 权限类错误判定：mobile_scanner 的 genericError 文案不含 permission/denied，
  /// 只有 permissionDenied / 系统拒绝类错误才会被识别为权限问题
  bool _isPermissionError(String message) {
    final msg = message.toLowerCase();
    return msg.contains('permission') || msg.contains('denied');
  }

  Widget _buildError(bool permissionDenied, {String? customMessage}) {
    final t = AppLocalizations.of(context).t;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.photo_camera_outlined,
                size: 64, color: Colors.white38),
            const SizedBox(height: 16),
            Text(
              permissionDenied
                  ? t('scanCamPermissionDenied')
                  : (customMessage ?? t('scanCamInitFailed')),
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              permissionDenied
                  ? t('scanCamPermissionHint')
                  : t('scanCamInitHint'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white38, fontSize: 13, height: 1.5),
            ),
            // 相机被占用：追加友好提示（通话/TRTC 刚结束的场景最常见）
            if (!permissionDenied && customMessage == null && _detailBusy) ...[
              const SizedBox(height: 8),
              const Text(
                '相机可能被其它功能占用（如通话刚结束），请完全退出相关页面后重试',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
            // 排障辅助：显示底层真实错误（不进 i18n 词典，仅 init_failed 时出现）
            if (!permissionDenied &&
                customMessage == null &&
                _lastErrorDetail.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '错误详情：$_lastErrorDetail',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white24, fontSize: 11, height: 1.4),
              ),
            ],
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: permissionDenied ? _openSettings : _start,
              icon: Icon(permissionDenied ? Icons.settings : Icons.refresh,
                  size: 18),
              label: Text(permissionDenied
                  ? t('scanCamOpenSettings')
                  : t('scanCamRetry')),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                minimumSize: const Size(180, 46),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openSettings() => openAppSettings();
}
