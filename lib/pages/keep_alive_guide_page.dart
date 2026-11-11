import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../l10n/app_locale.dart';
import '../services/rom_settings.dart';
import '../theme/app_theme.dart';

/// 消息保活设置引导页（仅 Android 有完整功能）
///
/// 内容：
///   1. 电池优化白名单状态 + 一键去开启（flutter_foreground_task 内置 API）
///   2. 按设备厂商展示「自启动 / 后台权限」步骤，并直接跳转对应设置页
///      （未命中厂商组件时退回应用详情页，用户手动找）
///   3. 兜底说明：进程被杀走极光离线推送，不影响收消息
class KeepAliveGuidePage extends StatefulWidget {
  const KeepAliveGuidePage({super.key});

  @override
  State<KeepAliveGuidePage> createState() => _KeepAliveGuidePageState();
}

class _KeepAliveGuidePageState extends State<KeepAliveGuidePage>
    with WidgetsBindingObserver {
  bool _batteryOk = false;
  String _manufacturer = ''; // 原始厂商名（展示用）
  String _romKey = 'other'; // 厂商分类 key（决定步骤文案）
  bool _needRefreshOnResume = false; // 跳设置页后返回时刷新白名单状态

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 跳系统设置后返回：自动重查电池优化白名单状态
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_needRefreshOnResume) return;
    _needRefreshOnResume = false;
    _refreshBatteryState();
  }

  Future<void> _refreshBatteryState() async {
    try {
      final ok = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      if (mounted) setState(() => _batteryOk = ok);
    } catch (_) {}
  }

  Future<void> _load() async {
    final isAndroid =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    String manufacturer = '';
    String romKey = 'other';
    bool batteryOk = false;
    if (isAndroid) {
      try {
        final info = await RomSettings.getRomInfo();
        manufacturer =
            (info['manufacturer'] ?? info['brand'] ?? '').toUpperCase();
        romKey = _detectRom(manufacturer);
      } catch (_) {}
      try {
        batteryOk = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _manufacturer = manufacturer;
        _romKey = romKey;
        _batteryOk = batteryOk;
      });
    }
  }

  /// 厂商分类（与 MainActivity.kt 的跳转组件清单保持一致）
  String _detectRom(String m) {
    if (['XIAOMI', 'REDMI', 'POCO'].any(m.contains)) return 'xiaomi';
    if (m.contains('HONOR')) return 'honor';
    if (m.contains('HUAWEI')) return 'huawei';
    if (['OPPO', 'REALME', 'ONEPLUS'].any(m.contains)) return 'oppo';
    if (m.contains('IQOO')) return 'vivo';
    if (m.contains('VIVO')) return 'vivo';
    if (m.contains('SAMSUNG')) return 'samsung';
    return 'other';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    final isAndroid =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final stepKey = const {
          'xiaomi': 'kaStepsXiaomi',
          'huawei': 'kaStepsHuawei',
          'honor': 'kaStepsHonor',
          'oppo': 'kaStepsOppo',
          'vivo': 'kaStepsVivo',
          'samsung': 'kaStepsSamsung',
        }[_romKey] ??
        'kaStepsOther';
    final steps = t(stepKey).split('|');
    return Scaffold(
      appBar: AppBar(title: Text(t('kaTitle'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ===== 状态卡：电池优化白名单 =====
          if (isAndroid) ...[
            _card(context,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(
                        _batteryOk
                            ? Icons.check_circle
                            : Icons.warning_amber_rounded,
                        size: 20,
                        color: _batteryOk ? AppTheme.green : AppTheme.danger,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _batteryOk ? t('kaBatteryOk') : t('kaBatteryTip'),
                          style: TextStyle(
                              fontSize: 14,
                              height: 1.4,
                              color: scheme.onSurface),
                        ),
                      ),
                    ]),
                    if (!_batteryOk) ...[
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        height: 42,
                        child: FilledButton(
                          onPressed: _goBattery,
                          style: FilledButton.styleFrom(
                              backgroundColor: AppTheme.primary,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                      AppTheme.radiusMd))),
                          child: Text(t('kaBatteryAction'),
                              style: const TextStyle(fontSize: 14)),
                        ),
                      ),
                    ],
                  ],
                )),
            const SizedBox(height: 12),
          ],
          // ===== 厂商自启动引导卡 =====
          if (isAndroid)
            _card(
              context,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t('kaAutoStartTitle'),
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                  if (_manufacturer.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(t('kaAutoStartDevice', {'device': _manufacturer}),
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ],
                  const SizedBox(height: 10),
                  Text(t('kaAutoStartTip'),
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 10),
                  for (var i = 0; i < steps.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 18,
                            height: 18,
                            alignment: Alignment.center,
                            margin: const EdgeInsets.only(top: 1, right: 8),
                            decoration: BoxDecoration(
                              color: AppTheme.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Text('${i + 1}',
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.primary)),
                          ),
                          Expanded(
                            child: Text(steps[i].trim(),
                                style: TextStyle(
                                    fontSize: 13,
                                    height: 1.4,
                                    color: scheme.onSurface)),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    height: 42,
                    child: OutlinedButton(
                      onPressed: _goAutoStart,
                      style: OutlinedButton.styleFrom(
                          side: BorderSide(
                              color: AppTheme.primary.withValues(alpha: 0.5)),
                          shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(AppTheme.radiusMd))),
                      child: Text(t('kaAutoStartAction'),
                          style:
                              TextStyle(fontSize: 14, color: AppTheme.primary)),
                    ),
                  ),
                ],
              ),
            ),
          if (isAndroid) const SizedBox(height: 12),
          // ===== 兜底说明卡 =====
          _card(
            context,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline,
                    size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(t('kaGeneralTip'),
                      style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: scheme.onSurfaceVariant)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, {required Widget child}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(
            color: scheme.onSurface.withValues(alpha: 0.08), width: 0.5),
      ),
      child: child,
    );
  }

  /// 电池优化白名单：原生三级 fallback（直接授权弹窗 → 电池优化列表页 → 应用详情），
  /// 从设置返回后自动刷新状态
  Future<void> _goBattery() async {
    final t = AppLocalizations.of(context).t;
    final level = await RomSettings.openBatterySettings();
    if (!mounted) return;
    // 打开的是列表页/详情页：提示用户手动操作路径，返回后刷新状态
    if (level >= 2) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(t('kaBatteryListTip')),
          duration: const Duration(seconds: 4)));
    }
    _needRefreshOnResume = true;
  }

  /// 跳厂商自启动设置页（未命中组件时原生侧已退回应用详情页）
  Future<void> _goAutoStart() async {
    final t = AppLocalizations.of(context).t;
    final ok = await RomSettings.openAutoStartSettings();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(t('kaFallback')),
          duration: const Duration(seconds: 3)));
    }
  }
}
