import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/call_service.dart';
import '../services/e2ee_service.dart';
import '../services/rom_settings.dart';
import '../services/user_cache.dart';
import '../services/wallet_store.dart';
import '../services/ws_service.dart';
import '../theme/app_theme.dart';
import '../utils/web_user_agent.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/v2_kit.dart';
import '../widgets/v2_settings.dart';
import 'login_page.dart';
import 'scan_qr_login_page.dart';

// ============================================================================
// 设备页（V2 复刻，2026-09-14）
//
// 参考截图：`Screenshot_2026_0914_203959.jpg`（物理宽 1260 / DPR 3 ⇒ 逻辑宽 420，
// 与本项目 `v2Scale` 基准宽一致）。逐元素测量报告见
// `UI-ref/measure/measure_device_notify.md`。
//
// 结构（自上而下）：当前设备 / 链接新设备 / 活跃会话 / 加密消息恢复 + 退出登录卡片。
//
// 为什么页面里另起一套 `_k*` 常数而不是直接用 `v2_settings.dart` 的 `kSet*`：
// 本页实测值与共享库有系统性差异（分组标题 16.7 vs 15、主标题 20.4 vs 19.5、
// 灰字 #9A9FA8 vs #6B727D、组间距 48.8/12.7 vs 35.4/18.4 …），且共享文件被另外
// 几个 V2 页面共用，就地改会连带改坏，因此**只在本页覆盖**，共享文件不动。
// ============================================================================

// ---------- 字号（逻辑 px，实测） ----------
const double _kLabelSize = 16.7; // 共享 15；实测「当前设备」逐字步进 17.0 ⇒ em≈16.7
const double _kTitleSize = 20.4; // 共享 19.5；实测「扫描二维码」逐字步进 20.3
const double _kSubSize = 17.7; // 共享 16；实测「登录到其他设备」7 字 ink 123.00 ⇒ 17.72/字
const double _kNoteSize = 16.5; // 页面级说明灰字（实测步进 16.3~17.0）
const double _kNoteLineH = 1.42; // 实测行距 23.4 / 16.5
const double _kSubLineH = 1.47; // 实测副标题两行 ink 顶间距 26.0 ⇒ 26.0 / 17.7 = 1.47
const double _kTitleSubGap = 7.0; // 主标题→副标题块间距（由 ink 中心距 29.0 反推）
const double _kEmptyTextSize = 19.1; // 「暂无其他设备登录」实测步进 19.1
const double _kPillTextSize = 15.3; // 「加载失败」胶囊字号的实测基准 —— 见 UI-ref/DESIGN.md

// ---------- 间距（逻辑 px，实测） ----------
// 注：原 `_kPadTop = 7.8`（头 → 内容区首元素）已删除，改由 `V2SetScaffold.headerExtra`
// 通过 `_kHeaderExtra = 7.7` 承接 —— 那一截在参考截图里是**白色**的（白条带总高 123.0 =
// 状态栏 59.35 + 56 + 7.65），用 `padding.top` 补会画在灰底上，产生真实色差。
// 首个分组标题的 y 位置不变（7.7 与 7.8 是同一个量，差 0.1 在测量噪声内）。
const double _kHeaderExtra = 7.7; // 白条带在 56 高标题区之下的延伸量（见上方说明）
// 2026-09-15 需求：整体紧凑，组间距在实测基础上收一档（约 -25%）。
const double _kGapBeforeLabel = 36.0; // 卡片底 → 分组标题   （原 48.8）
const double _kGapAfterLabel = 10.0; // 分组标题 → 卡片     （原 12.7）
const double _kGapCardNote = 8.0; // 卡片底 → 说明第一行   （原 11.0）
const double _kGapNoteLabel = 36.0; // 说明末行 → 下一个分组标题（原 47.8）
const double _kGapNoteDanger = 32.0; // 说明末行 → 退出登录卡片（原 43.5）
const double _kGapDangerNote = 8.0; // 退出登录卡片 → 卡下灰字（原 11.4）

// ---------- 尺寸（逻辑 px，实测） ----------
const double _kCardX = kSetCardX; // 20.7
const double _kIconBlock = 56.3; // 行首图标块边长
const double _kIconBlockX = 15.3; // 图标块在卡内的左缩进
const double _kIconBlockR = 12.0; // 圆角（最小二乘拟合 r≈11.5~12.3）
const double _kIconTextGap = 16.4; // 图标块右缘 → 文字列（108.7-36.0-56.3）
const double _kTrailInset = 15.3; // 尾部元素右缘距卡右（箭头盒 / 胶囊；开关是 25.3）
const double _kRowHIcon2 = 113.0; // 图标块 + 主标题 + 2 行副标题
const double _kRowHIcon1 = 87.5; // 图标块 + 主标题 + 1 行副标题
const double _kEmptyH = 165.5;
const double _kDangerH = 64.0;

const double _kPillH = 32.3;

// ---------- 色板（实测） ----------
Color _cInk(BuildContext c) =>
    c.v2IsDark ? const Color(0xFFF2F2F7) : const Color(0xFF0B0B0F);
Color _cSub(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF98989F) : const Color(0xFF6C727B);
Color _cMuted(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF8E8E93) : const Color(0xFF9A9FA8);
Color _cGlyph(BuildContext c) =>
    c.v2IsDark ? const Color(0xFFE5E5EA) : const Color(0xFF0C0D12);
Color _cEmptyIcon(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF48484A) : const Color(0xFFB7BCC5);
Color _cPhoneBg(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF2C2C2E) : const Color(0xFFECECEC);
Color _cQrBg(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF2C2C2E) : const Color(0xFFE1E3E2);
Color _cLockBg(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF10344A) : const Color(0xFFE0F1F9);
const Color _kLockFg = Color(0xFF0888C8);

/// 设备页（构造函数无参，方便外层直接 push）
class DevicePage extends StatefulWidget {
  const DevicePage({super.key});

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  final _api = ApiClient.instance;

  /// 本机（当前设备）
  String _name = '';
  String _platform = '';
  String _deviceId = '';

  /// 活跃会话列表：`GET /api/v1/user/devices`（**含本机**，`current` 标记当前设备；
  /// 本机信息同时已在顶部卡片单独展示，此处按契约全量渲染）
  List<_DeviceSession> _sessions = const <_DeviceSession>[];

  /// 设备列表加载失败标记（2026-09-15）：以前 fetchDevices 的任何异常被
  /// 静默吞成空列表，页面伪装成「0 台设备 + 离线」，真实错误不可见。
  /// 现在失败时 toast 错误摘要，并在 UI 上明确区分「加载失败」≠「离线/空列表」。
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 1) 本机信息：厂商 / 型号来自原生 MethodChannel（rom_settings.dart）；
    //    Web 平台拿不到原生信息（此前恒空 → 「当前设备」卡恒显示「未知设备」），
    //    改按 UA 显示「手机网页 / 电脑网页」。
    String name = '';
    if (kIsWeb) {
      name = _webDeviceName();
    } else {
      try {
        final rom = await RomSettings.getRomInfo();
        name = [rom['brand'], rom['model']]
            .where((e) => e != null && e.trim().isNotEmpty)
            .map((e) => e!.trim())
            .join(' ');
      } catch (_) {}
    }
    String id = '';
    try {
      id = await _api.getDeviceId();
    } catch (_) {}

    // 2) 活跃会话：`GET /api/v1/user/devices`（服务端按 lastActiveAt 倒序）。
    //    X-Device-ID 已由 fetchDevices 自动携带 → 服务端标记 current。
    //    顶部「当前设备」卡片的在线胶囊直接取本机会话的 online。
    List<Map<String, dynamic>> raw = const [];
    String failDetail = '';
    try {
      raw = await _api.fetchDevices();
    } catch (e) {
      // 不再静默吞错：记录摘要（dio 带 statusCode + 响应体片段）供 toast 与失败态展示
      failDetail = _errDetail(e);
    }

    final sessions =
        raw.map(_DeviceSession.fromJson).toList(growable: false);
    final cur = sessions.where((e) => e.current).toList(growable: false);

    // 2026-09-18 需求 2：活跃会话必然包含本设备。服务端按 X-Device-ID 精确
    // 匹配 isCurrent，本机行缺失（设备表无行/槽位被清）时客户端兜底补一条，
    // 避免「活跃会话里看不到自己」。
    List<_DeviceSession> finalSessions = sessions;
    if (failDetail.isEmpty && cur.isEmpty) {
      finalSessions = [
        ...sessions,
        _DeviceSession(
          deviceId: id,
          deviceType: _platformDeviceType(),
          platform: _platformLabel().toLowerCase(),
          online: true,
          current: true,
          lastIp: '',
          lastActiveAt: DateTime.now(),
        ),
      ];
    }

    if (!mounted) return;
    setState(() {
      _name = name;
      _platform = _platformLabel();
      _deviceId = id;
      _sessions = finalSessions;
      _loadFailed = failDetail.isNotEmpty;
    });
    // 失败 toast 放在 setState 之后：此时页面已完成首帧，overlay 可用
    if (failDetail.isNotEmpty) {
      final t = AppLocalizations.of(context).t;
      AppDialogs.toast(context,
          t('devLoadFailedFmt', {'detail': failDetail}));
    }
  }

  /// 失败诊断摘要（2026-09-15）：DioException 取 statusCode + 类型 + 响应体片段，
  /// 其余异常去掉 `Exception: ` 前缀直接展示。DEBUG 包下一轮截图可直接定位真实错误。
  static String _errDetail(Object e) {
    if (e is DioException) {
      final code = e.response?.statusCode;
      final type = e.type.name;
      var body = e.response?.data?.toString() ?? '';
      if (body.length > 120) body = '${body.substring(0, 120)}…';
      return code != null ? 'HTTP $code/$type $body' : '$type $body';
    }
    return e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
  }

  /// 本机副标题第 1 行：平台名（真实可得；截图的「5.0 · Android 16」＝App/ROM 版本 +
  /// 系统版本，本地拿不到 —— 需要后端在 /user/profile 补 version/osVersion 字段）。
  String _platformLabel() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'Android';
      case TargetPlatform.iOS:
        return 'iOS';
      case TargetPlatform.macOS:
        return 'macOS';
      case TargetPlatform.windows:
        return 'Windows';
      case TargetPlatform.linux:
        return 'Linux';
      case TargetPlatform.fuchsia:
        return 'Fuchsia';
    }
  }

  /// 本机副标题第 2 行：本机设备号前 8 位（真实可得；截图这里是出口 IP）。
  String get _shortId =>
      _deviceId.length >= 8 ? '${_deviceId.substring(0, 8)}…' : _deviceId;

  /// 本机 deviceType 映射（补本机行用，与服务端一致：
  /// 1 Android / 2 iOS / 3 Web / 4 Windows / 5 macOS）
  int _platformDeviceType() {
    if (kIsWeb) return 3;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 1;
      case TargetPlatform.iOS:
        return 2;
      case TargetPlatform.macOS:
        return 5;
      case TargetPlatform.windows:
        return 4;
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return 0;
    }
  }

  /// Web 端本机显示名：移动浏览器「手机网页」/ 桌面浏览器「电脑网页」（UA 判定）。
  static String _webDeviceName() {
    final ua = webUserAgent();
    final mobile = RegExp('Mobile|Android|iPhone|iPad', caseSensitive: false)
        .hasMatch(ua);
    return mobile ? '手机网页' : '电脑网页';
  }

  /// 最后活跃时间格式化：yyyy-MM-dd HH:mm（本地时区）
  /// 服务端下发 UTC（带 Z），必须 toLocal 再取字段，否则差一个时区
  static String _fmtTime(DateTime d) {
    final l = d.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')} '
        '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  /// deviceType → 图标：1 Android / 2 iOS → 手机，3 Web / 4 Windows / 5 macOS → 电脑
  static IconData _deviceIcon(int type) {
    switch (type) {
      case 1:
      case 2:
        return Icons.smartphone;
      case 3:
      case 4:
      case 5:
        return Icons.computer;
      default:
        return Icons.devices_other;
    }
  }

  /// deviceType → 展示名（平台名是专有名词，不进 l10n）；
  /// 3 Web 统一显示「手机网页」（H5 主要在手机浏览器使用，用户口径）；
  /// 其余未知类型回退到服务端 platform 字段，再兜底「未知设备」。
  /// 有客户端上报型号（deviceName）时行标题优先显示型号，见 _sessionRow。
  String _deviceTypeName(_DeviceSession d) {
    switch (d.deviceType) {
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
    }
    if (d.platform.isNotEmpty) return d.platform;
    return AppLocalizations.of(context).t('devUnknownDevice');
  }

  /// 注销某台设备（2026-09-18 需求 3 分流）：
  /// - 本机：等价于「退出登录」，走 _logout（确认弹窗 → 停通话/WS → 清 token → 回登录页）；
  /// - 其他设备：确认弹窗 → DELETE /user/devices/:deviceId 踢下线 → 刷新列表。
  /// 服务端错误（1001/1003 不能注销当前设备/4001 无登录态）以 message 提示。
  Future<void> _confirmLogoutDevice(_DeviceSession d) async {
    if (d.current) {
      await _logout();
      return;
    }
    final t = AppLocalizations.of(context).t;
    final yes = await AppDialogs.confirm(
      context,
      title: t('devSessionLogoutConfirmTitle'),
      message: t('devSessionLogoutConfirmMsg'),
      confirmText: t('acctSecDeleteConfirm'),
      danger: true,
    );
    if (yes != true) return;
    try {
      await _api.logoutDevice(d.deviceId);
      // 注销成功后服务端会给该设备推 forceLogout 并断其 WS；本机刷新列表
      if (mounted) await _load();
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
      AppDialogs.toast(context, msg);
    }
  }

  Future<void> _logout() async {
    final t = AppLocalizations.of(context).t;
    final yes = await AppDialogs.confirm(
      context,
      title: t('meLogoutTitle'),
      message: t('meLogoutMsg'),
      confirmText: t('meLogoutConfirm'),
      danger: true,
    );
    if (yes != true) return;
    // 与「我的」页 _logout 保持一致：先停通话/长连接，再清 token 与本地缓存
    await CallService.instance
        .resetSession()
        .timeout(const Duration(seconds: 3), onTimeout: () {});
    GlobalWs.instance.close();
    try {
      await _api.logout().timeout(const Duration(seconds: 2), onTimeout: () {});
    } catch (_) {}
    UserCache.clear();
    WalletStore.instance.reset();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  void _comingSoon(String label) {
    AppDialogs.toast(
        context, AppLocalizations.of(context).t('meComingSoonSuffix', {'name': label}));
  }

  // ---------- E2EE 跨设备恢复（2026-09-18 接通真实流程） ----------

  bool _recovering = false;

  /// 「申请从旧设备恢复」入口：
  /// 1. 本机私钥已就绪 → 无需恢复，直接提示；
  /// 2. 发起申请（一次性临时密钥对）→ 弹等待窗（10 分钟倒计时，可取消）；
  /// 3. 旧设备（同账号、本机私钥就绪）收到 WS 推送弹审批窗，
  ///    批准后私钥经服务端用临时公钥包裹回传 → 本机落库、立即可解密。
  Future<void> _startRecovery() async {
    if (_recovering) return;
    final t = AppLocalizations.of(context).t;
    if (E2eeService.instance.isReady) {
      AppDialogs.toast(context, t('devRecoverAlreadyReady'));
      return;
    }
    setState(() => _recovering = true);
    try {
      final deviceName = _localDeviceName();
      final requestId = await E2eeService.instance.startRecovery(deviceName);
      if (!mounted) return;
      if (requestId == null) {
        AppDialogs.toast(context, t('devRecoverRequestFail'));
        return;
      }
      final ok = await _showRecoverWaiting(requestId);
      if (!mounted) return;
      AppDialogs.toast(context, ok ? t('devRecoverSuccess') : t('devRecoverFail'));
    } finally {
      if (mounted) setState(() => _recovering = false);
    }
  }

  /// 本机设备名（恢复申请展示给旧设备看）：Web/H5 与原生平台分开取
  String _localDeviceName() {
    if (kIsWeb) return _webDeviceName();
    return const {
      TargetPlatform.android: 'Android',
      TargetPlatform.iOS: 'iOS',
      TargetPlatform.macOS: 'macOS',
      TargetPlatform.windows: 'Windows',
      TargetPlatform.linux: 'Linux',
      TargetPlatform.fuchsia: 'Fuchsia',
    }[defaultTargetPlatform] ?? 'App';
  }

  /// 等待旧设备批准的弹窗：转圈 + 说明 + 取消按钮。
  /// 内部由 E2eeService.waitRecovery 轮询（2s/次）；批准/拒绝/过期都会结束弹窗。
  Future<bool> _showRecoverWaiting(String requestId) async {
    final r = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (c) {
        final t = AppLocalizations.of(context).t;
        bool waiting = true;
        return StatefulBuilder(builder: (c, setSheet) {
          // 后台轮询，结束（成功/失败/过期）即关窗
          unawaited(E2eeService.instance
              .waitRecovery(requestId)
              .then((ok) {
            if (waiting && c.mounted) Navigator.of(c).pop(ok);
          }));
          return AlertDialog(
            title: Text(t('devRecoverWaitingTitle')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 16),
                Text(t('devRecoverWaitingMsg'),
                    style: const TextStyle(fontSize: 14)),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  waiting = false;
                  Navigator.of(c).pop(false);
                },
                child: Text(t('devRecoverCancel')),
              ),
            ],
          );
        });
      },
    );
    return r ?? false;
  }


  /// 活跃会话行：平台图标块 + 平台名 + 「最后活跃 / 出口 IP」两行副标题，
  /// 尾部 = 在线胶囊 +（当前设备？「本机」徽标 : 「注销」按钮）。
  Widget _sessionRow(BuildContext context, _DeviceSession d, double s) {
    final t = AppLocalizations.of(context).t;
    final when = d.lastActiveAt ?? d.createdAt;
    final lines = <String>[
      if (when != null) t('devLastActiveFmt', {'time': _fmtTime(when)}),
      if (d.lastIp.isNotEmpty) d.lastIp,
    ];
    if (lines.isEmpty) lines.add(_shortIdOf(d));
    // 行标题：有客户端上报的真实型号（如 "Xiaomi 2201123G"）优先显示，
    // 没有回落到类型名（Android/iOS/手机网页/…）
    final title =
        d.deviceName.isNotEmpty ? d.deviceName : _deviceTypeName(d);
    return _IconRow(
      bg: _cPhoneBg(context),
      icon: _deviceIcon(d.deviceType),
      iconSize: 30,
      iconColor: _cGlyph(context),
      title: title,
      subtitle: lines.join('\n'),
      height: lines.length >= 2 ? _kRowHIcon2 : _kRowHIcon1,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 2026-09-18 需求：活跃会话不再显示在线/离线胶囊（本机必然在线、
          // 其他设备以登录态为准），右侧只留「注销」；本机行多一个「本机」徽标
          if (d.current) ...[
            _TagBadge(label: t('devThisDevice')),
            SizedBox(width: 10 * s),
          ],
          // 2026-09-18 需求 3：所有行（含本机）右侧都有「注销」——
          // 本机注销 = 退出登录（见 _confirmLogoutDevice 分流）
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _confirmLogoutDevice(d),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 2 * s, vertical: 6 * s),
              child: Text(
                t('acctSecDeleteConfirm'),
                style: TextStyle(
                  fontSize: _kNoteSize * s,
                  height: 1.0,
                  color: context.setDanger,
                ),
              ),
            ),
          ),
        ],
      ),
      onTap: () => _confirmLogoutDevice(d),
    );
  }

  /// 无任何活跃信息可展示时兜底：设备号前 8 位
  static String _shortIdOf(_DeviceSession d) =>
      d.deviceId.length >= 8 ? '${d.deviceId.substring(0, 8)}…' : d.deviceId;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);

    return V2SetScaffold(
      title: t('meRowDevice'),
      // 参考截图（`_probe2`）：顶部是**纯白条带**，y=1 起 #FFFFFF，到 y=123.00 才转 #F3F3F5、
      // y=123.33 起 #F3F2F7（内容区）。故 bg 取内容区灰、headerBg 取白，
      // 56 高标题区之下再补 7.7 白（= 123.0 - 状态栏 - 56）。
      // 深色下不硬套白底：头部标题/图标走 `context.setTitle`（深色是浅色字），
      // 硬编码白底会让字看不见；故深色取「页底 #000 / 头部 #1C1C1E」，
      // 与浅色「页底灰 / 头部比页底更亮」的层次关系一致。
      bg: context.v2IsDark ? kSetPageBgDark : const Color(0xFFF3F2F7),
      headerBg: context.v2IsDark ? kSetCardDark : const Color(0xFFFFFFFF),
      headerExtra: _kHeaderExtra,
      // B 型页返回图标是细雪佛龙 `<`（ink 11.67 × 20.33、ink 左缘 30.00），
      // 不是 A 型的完整 `←`（`_probe3` ASCII 掩码）⇒ 共享库的 V2SetBackSpec.chevron
      backSpec: V2SetBackSpec.chevron,
      // 首个分组标题 ink 顶实测 172.67 ⇒ 标题盒顶 ≈171.8，白条带底 123.0，
      // 故首个标题上方留白 = 171.8 - 123.0 = 48.8，与本页「卡片底→标题」节奏**同一个值**
      // （原实现误置 0，导致整页内容较参考上移 ~49px —— 这是本次重核查出的最大偏差）
      padding: EdgeInsets.only(top: _kGapBeforeLabel * s, bottom: 40),
      children: [
        // ---------- 当前设备 ----------
        _Label(t('devCurrent')),
        const V2SetGap(_kGapAfterLabel),
        V2SetCard(rows: [
          _IconRow(
            bg: _cPhoneBg(context),
            icon: Icons.smartphone,
            // 由 MaterialIcons 字体字形反推：smartphone ink = 0.58203×0.91797 em，
            // 实测块内 ink 18.33×28.67 ⇒ size ≈ 31.36（原 32 偏大 0.6）
            iconSize: 31.4,
            iconColor: _cGlyph(context),
            title: _name.isEmpty ? t('devUnknownDevice') : _name,
            // 2026-09-15 需求：设备名过长收成 1 行省略（原来 maxLines 2 换行），
            // 副标题两行（平台 / 设备号）各自单行
            titleMaxLines: 1,
            // 参考截图此处固定 2 行（第 1 行版本信息 · 第 2 行出口 IP），
            // 故显式分行，避免内容较短时收成 1 行导致行内留白与截图不一致
            subtitle: [_platform, _shortId]
                .where((e) => e.isNotEmpty)
                .join('\n'),
            height: _kRowHIcon2,
            // 2026-09-18 需求：当前设备必然在线，不再显示在线/离线胶囊；
            // 仅加载失败时保留红色「加载失败」胶囊提示。SizedBox.shrink 占位
            // 是为了保住 _IconRow 的右内边距（trailing 非 null 才有 right padding）。
            trailing: _loadFailed
                ? const _FailedPill()
                : const SizedBox.shrink(),
            onTap: () => _comingSoon(t('devCurrent')),
          ),
        ]),

        // ---------- 链接新设备 ----------
        const V2SetGap(_kGapBeforeLabel),
        _Label(t('devLinkNew')),
        const V2SetGap(_kGapAfterLabel),
        V2SetCard(rows: [
          _IconRow(
            bg: _cQrBg(context),
            icon: Icons.qr_code_2,
            // qr_code_2 ink = 0.75×0.75 em，实测块内 ink 23.67×23.67 ⇒ size ≈ 31.56（原 30 偏小 1.6）
            iconSize: 31.6,
            iconColor: _cGlyph(context),
            title: t('devScanQr'),
            subtitle: t('devScanQrSub'),
            height: _kRowHIcon1,
            showChevron: true,
            // 「扫描二维码」直接调起**扫一扫**（`ScanQrLoginPage`，与 chat_list_page.dart:354
            // 的调用方式一致），不是 `QrLoginPage`（那是本机展示二维码给别的设备扫）。
            // 扫一扫成功后可能确认了另一台设备登录 → 回来刷新在线状态 / 活跃会话。
            onTap: () async {
              await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ScanQrLoginPage()));
              if (mounted) await _load();
            },
          ),
        ]),
        const V2SetGap(_kGapCardNote),
        _Note(t('devScanQrNote')),

        // ---------- 活跃会话 ----------
        const V2SetGap(_kGapNoteLabel),
        _Label(
          t('devActiveSessions'),
          // 加载失败时右侧计数显示「加载失败」而不是「0 台设备」
          extra: Text(
            _loadFailed
                ? t('devLoadFailed')
                : t('devDeviceCountFmt', {'n': '${_sessions.length}'}),
            style: TextStyle(
              fontSize: _kLabelSize * s,
              height: 1.0,
              color: _loadFailed ? context.setDanger : _cMuted(context),
            ),
          ),
        ),
        const V2SetGap(_kGapAfterLabel),
        if (_sessions.isEmpty)
          V2SetCard(rows: [
            SizedBox(
              height: _kEmptyH * s,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.devices_other,
                      size: 62 * s, color: _cEmptyIcon(context)),
                  // 实测：图标 ink 底 697.00 → 文字 ink 顶 727.33 = 30.33；
                  // 反推两盒之间的间距 = 30.33 − 图标盒内下留白(0.16602×62=10.3)
                  // − 文字盒内上留白(≈0.75) ≈ 19.3（原 16.6 使图标偏低 ~3px）
                  SizedBox(height: 19.4 * s),
                  Text(
                    // 加载失败时明确区分「加载失败」≠「暂无其他设备登录」
                    _loadFailed
                        ? t('devLoadFailed')
                        : t('devEmptySessions'),
                    style: TextStyle(
                      fontSize: _kEmptyTextSize * s,
                      height: 1.0,
                      color: _loadFailed
                          ? context.setDanger
                          : _cSub(context),
                    ),
                  ),
                ],
              ),
            ),
          ])
        else
          V2SetCard(
            rows: [
              for (final d in _sessions)
                _sessionRow(context, d, s),
            ],
          ),
        const V2SetGap(_kGapCardNote),
        _Note(t('devSessionsNote')),

        // ---------- 加密消息恢复 ----------
        const V2SetGap(_kGapNoteLabel),
        _Label(t('devEncryptedRecovery')),
        const V2SetGap(_kGapAfterLabel),
        V2SetCard(rows: [
          _IconRow(
            bg: _cLockBg(context),
            icon: Icons.enhanced_encryption,
            // enhanced_encryption ink = 0.66797×0.875 em，实测块内 ink 19.00×24.67
            // ⇒ size ≈ 28.31（原 30 偏大 1.7）；字形核心色实测 #0384C4
            iconSize: 28.3,
            iconColor: _kLockFg,
            title: t('devRecoverTitle'),
            subtitle: t('devRecoverSub'),
            height: _kRowHIcon2,
            showChevron: true,
            // 跨设备恢复（2026-09-18 接通）：发起申请 → 旧设备 WS 弹窗批准 →
            // 私钥经服务端用临时公钥包裹回传（明文不落服务端）
            onTap: _startRecovery,
          ),
        ]),
        const V2SetGap(_kGapCardNote),
        _Note(t('devRecoverNote')),

        // ---------- 退出登录 ----------
        const V2SetGap(_kGapNoteDanger),
        _DangerCard(
          label: t('meLogoutTitle'),
          // 参考图标 ink 19.00×19.33（比例 0.983）；`Icons.logout` 的比例是 1.109
          // 明确不符，`Icons.logout_rounded`（0.9893、圆角描边）最接近且按宽/按高
          // 反推的 size 一致（25.61 / 25.77）⇒ 取 25.7
          icon: Icons.logout_rounded,
          height: _kDangerH,
          onTap: _logout,
        ),
        const V2SetGap(_kGapDangerNote),
        _Note(t('devLogoutNote')),
      ],
    );
  }
}

// ============================================================================
// 本页私有组件（含共享库中没有的形态：行首图标块、在线胶囊、空状态、居中红卡）
// ============================================================================

/// `GET /api/v1/user/devices` 的 DeviceSession（契约见 im-server/doc/API.md）
class _DeviceSession {
  const _DeviceSession({
    required this.deviceId,
    required this.deviceType,
    required this.platform,
    required this.online,
    required this.current,
    required this.lastIp,
    this.deviceName = '',
    this.lastActiveAt,
    this.createdAt,
  });

  final String deviceId; // 客户端持久化设备号
  final int deviceType; // 1 Android 2 iOS 3 Web 4 Windows 5 macOS
  final String deviceName; // 客户端上报的设备型号（2026-09-21 起登录时上报）
  final String platform; // android/ios/web/windows/macos
  final bool online; // WS 在线（onlinedev 90s 内有心跳）
  final bool current; // 是否当前设备（与 X-Device-ID 匹配）
  final String lastIp; // 最后活跃出口 IP
  final DateTime? lastActiveAt; // 最后活跃（WS 建连/心跳、登录/刷新时更新）
  final DateTime? createdAt; // 首次登录时间

  factory _DeviceSession.fromJson(Map<String, dynamic> j) {
    return _DeviceSession(
      deviceId: j['deviceId']?.toString() ?? '',
      deviceType: (j['deviceType'] as num?)?.toInt() ?? 0,
      deviceName: j['deviceName']?.toString() ?? '',
      platform: j['platform']?.toString() ?? '',
      online: j['online'] == true,
      // 后端 isCurrent/current 双字段下发（2026-09-15），任一为 true 即当前设备
      current: j['isCurrent'] == true || j['current'] == true,
      lastIp: j['lastIp']?.toString() ?? '',
      lastActiveAt: DateTime.tryParse(j['lastActiveAt']?.toString() ?? ''),
      createdAt: DateTime.tryParse(j['createdAt']?.toString() ?? ''),
    );
  }
}

/// 分组小标题：左 22.0 / 字号 16.7 / #9A9FA8；`extra` 放右侧「0 台设备」。
class _Label extends StatelessWidget {
  const _Label(this.text, {this.extra});

  final String text;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return Padding(
      padding: EdgeInsets.only(left: 22.0 * s, right: _kCardX * s),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: _kLabelSize * s,
                height: 1.0,
                color: _cMuted(context),
              ),
            ),
          ),
          if (extra != null) extra!,
        ],
      ),
    );
  }
}

/// 页面级说明灰字（多行，左 22.0，右到卡右）。
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return Padding(
      padding: EdgeInsets.only(left: 22.0 * s, right: _kCardX * s),
      child: Text(
        text,
        style: TextStyle(
          fontSize: _kNoteSize * s,
          height: _kNoteLineH,
          color: _cMuted(context),
        ),
      ),
    );
  }
}

/// 带行首图标块的设置行。
///
/// 几何（实测，卡内坐标）：图标块左 15.3、边长 56.3、圆角 12；
/// 文字列左 88.0（= 15.3 + 56.3 + 16.4）；尾部元素右缘距卡右 15.3。
class _IconRow extends StatelessWidget {
  const _IconRow({
    required this.bg,
    required this.icon,
    required this.title,
    this.iconSize = 30,
    this.iconColor,
    this.subtitle,
    this.titleMaxLines = 2,
    this.height = _kRowHIcon1,
    this.trailing,
    this.showChevron = false,
    this.onTap,
  });

  final Color bg;
  final IconData icon;
  final String title;
  final double iconSize;
  final Color? iconColor;
  final String? subtitle;

  /// 主标题最大行数（当前设备卡的设备名过长时收成 1 行省略，2026-09-15）
  final int titleMaxLines;
  final double height;
  final Widget? trailing;
  final bool showChevron;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final body = Padding(
      padding: EdgeInsets.only(
          left: _kIconBlockX * s, right: (showChevron || trailing != null) ? _kTrailInset * s : 0),
      child: SizedBox(
        height: height * s,
        child: Row(
          children: [
            Container(
              width: _kIconBlock * s,
              height: _kIconBlock * s,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(_kIconBlockR * s),
              ),
              child: Icon(icon, size: iconSize * s, color: iconColor),
            ),
            SizedBox(width: _kIconTextGap * s),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: titleMaxLines,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: _kTitleSize * s,
                      // 实测本页行主标题是**中黑**（w500）：「扫描二维码」墨迹覆盖率 0.376、
                      // 「申请从旧设备恢复」0.395，而同字号的通知页标题只有 0.328~0.368
                      // ⇒ 本页主标题比通知页粗一档（裁图目视也明显：本页笔画更厚）
                      fontWeight: FontWeight.w500,
                      height: 1.0,
                      color: _cInk(context),
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    SizedBox(height: _kTitleSubGap * s),
                    // 2026-09-15 需求：三行信息（名称/系统/设备号）各自单行省略——
                    // 按 \n 拆成独立 Text，每行 maxLines:1 + ellipsis；
                    // 每行 height 仍取 _kSubLineH，总高与原单 Text 多行完全一致。
                    for (final line in subtitle!.split('\n'))
                      Text(
                        line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: _kSubSize * s,
                          height: _kSubLineH,
                          color: _cSub(context),
                        ),
                      ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              SizedBox(width: 10 * s),
              trailing!,
            ],
            if (showChevron) ...[
              SizedBox(width: 10 * s),
              SizedBox(
                width: 24 * s,
                height: 24 * s,
                child: V2SetChevron(color: context.setChevron),
              ),
            ],
          ],
        ),
      ),
    );
    if (onTap == null) return body;
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, child: body),
    );
  }
}

/// 「加载失败」胶囊（2026-09-15 新增）：设备列表请求失败时在当前设备卡上提示，
/// 浅红底 + 红字，明确区分「加载失败」≠「在线/离线」
/// （2026-09-18 起在线/离线胶囊已整体移除——当前设备必然在线）。
class _FailedPill extends StatelessWidget {
  const _FailedPill();

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12 * s),
      height: _kPillH * s,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: context.v2IsDark
            ? const Color(0xFF3A2024)
            : const Color(0xFFFBEBEB),
        borderRadius: BorderRadius.circular(_kPillH / 2 * s),
      ),
      child: Text(
        t('devLoadFailed'),
        style: TextStyle(
          fontSize: _kPillTextSize * s,
          height: 1.0,
          color: context.setDanger,
        ),
      ),
    );
  }
}

/// 小标签徽标（2026-09-15 新增）：活跃会话里当前设备的「本机」标记。
/// 浅灰底圆角小胶囊 + 灰字，视觉上弱于在线胶囊（状态才是主信息）。
class _TagBadge extends StatelessWidget {
  const _TagBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 9 * s, vertical: 5 * s),
      decoration: BoxDecoration(
        color: context.v2Fill,
        borderRadius: BorderRadius.circular(7 * s),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13.5 * s,
          height: 1.0,
          color: _cSub(context),
        ),
      ),
    );
  }
}

/// 底部「退出登录」：白卡 + 居中红字（图标在文字左侧 14.3）。
class _DangerCard extends StatelessWidget {
  const _DangerCard({
    required this.label,
    required this.icon,
    required this.height,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: _kCardX * s),
      child: Container(
        width: kSetCardW * s,
        decoration: BoxDecoration(
          color: context.setCard,
          borderRadius: BorderRadius.circular(kSetCardR * s),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: height * s,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 25.7 * s, color: context.setDanger),
                    // 实测图标 ink 右缘 173.33 → 红字 ink 左缘 188.33 = 15.00 ink 间距；
                    // 图标盒内右留白 0.125×25.7 = 3.2、文字盒内左留白 ≈0.6
                    // ⇒ 盒间距 = 15.00 − 3.2 − 0.6 = 11.2（原 14.3 使图标偏左 ~2.4）
                    SizedBox(width: 11.2 * s),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: _kTitleSize * s,
                        fontWeight: FontWeight.w500,
                        height: 1.0,
                        color: context.setDanger,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
