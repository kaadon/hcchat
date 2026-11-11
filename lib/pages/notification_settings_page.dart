import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../l10n/app_locale.dart';
import '../services/rom_settings.dart';
import '../services/settings_service.dart';
import '../services/sound_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/v2_kit.dart';
import '../widgets/v2_settings.dart';
import 'keep_alive_guide_page.dart';

// ============================================================================
// 通知和声音页（V2 复刻，2026-09-14）
//
// 参考截图：`Screenshot_2026_0914_203852.jpg`（物理宽 1260 / DPR 3 ⇒ 逻辑宽 420）。
// 逐元素测量报告见 `UI-ref/measure/measure_device_notify.md`。
//
// 9 个分组：系统通知权限 / 安卓后台保护 / 消息保活模式 / 通知总开关 / 通知消息 /
// 通知内容 / 声音和振动 / 应用内通知 / 重置所有通知设置。
//
// 本页实测值与共享库 `v2_settings.dart` 的差异同样用 `_k*` 局部常数覆盖（共享文件不动）：
//   · 分组标题左缘 42.7（设备页是 22.0）、字号 16.7（共享 15）
//   · 主标题 20.4（共享 19.5）、副标题 16.6~17.7（共享 16）
//   · 组间距 34.8 / 13.0（共享 35.4 / 18.4）
//   · 尾部纯文字左对齐在 x=201（不是右对齐）
// ============================================================================

// ---------- 字号 ----------
const double _kLabelSize = 16.7;
const double _kTitleSize = 20.4;
const double _kSubSize = 16.6; // 开关行的副标题（实测步进 16.5）
const double _kSubSizeChevron = 17.7; // 箭头行的副标题（实测步进 17.7）
const double _kTailSize = 17.2; // 「已允许 / 允许后台活动 / 金币」（实测步进 17.0~18.6）
const double _kSubLineH = 1.39; // 实测副标题两行 ink 顶间距 23.0 ⇒ 23.0 / 16.6 = 1.386
const double _kTitleSubGap = 7.0;

// ---------- 间距 ----------
// 注：原 `_kPadTop = 42.6`（= 白条带 7.8 + 标题上方留白 34.8）已删除，拆成两处：
// 白条带那 7.8（实测 7.65）改由 `V2SetScaffold.headerExtra` = `_kHeaderExtra` 承接 ——
// 它在参考截图里是**白色**的，用 `padding.top` 补会画在灰底上，产生真实色差；
// 余下的 34.8 由 `padding.top = _kGapBeforeLabel` 承担。首个分组标题 y 位置不变。
const double _kHeaderExtra = 7.7; // 白条带在 56 高标题区之下的延伸量（见上方说明）
const double _kGapBeforeLabel = 34.8; // 卡片底 → 分组标题
const double _kGapAfterLabel = 13.0; // 分组标题 → 卡片
const double _kGapBetweenCards = 31.3; // 重置卡片与上一组之间

// ---------- 尺寸 ----------
const double _kLabelX = 42.7; // 分组标题左缘（与行主标题 43.0 对齐）
const double _kTitlePadL = kSetTitleX - kSetCardX; // 22.3 ⇒ 绝对 43.0
const double _kTitleColW = 158.0; // 有尾部文字时主标题列宽（43.0 → 201.0）
const double _kSwitchInset = 25.3; // 开关右缘距卡右（共享同值）
const double _kChevronInset = 20.4; // 箭头盒右缘距卡右（实测 ink 右 370.3）

// 行高（实测；开关行 / 箭头行两套节奏，见测量报告 §3）
const double _kHChevron1 = 64.0; // 箭头行：单行标题
const double _kHChevronSub = 91.5; // 箭头行：标题 + 单行副标题
const double _kHSwitch1 = 82.4; // 开关行：单行标题（副标题 0~1 行同高）
const double _kHSwitch2 = 97.5; // 开关行：标题 + 2 行副标题
const double _kHTitle2 = 92.5; // 标题自身折成 2 行
const double _kHDanger = 64.0; // 重置行

// ---------- 色板 ----------
Color _cInk(BuildContext c) =>
    c.v2IsDark ? const Color(0xFFF2F2F7) : const Color(0xFF0B0B0F);

/// 本页的行副标题 / 尾字 / 分组标题**同色**（浅灰 #9A9FA8）——与设备页不同：
/// 设备页副标题是中灰 #6C727B，本页实测 4 处副标题全是 #9B9FA8~#9CA0A9。
Color _cMuted(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF8E8E93) : const Color(0xFF9A9FA8);

/// 通知和声音（构造函数无参，方便外层直接 push）
class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  final _set = AppSettings.instance;

  /// 系统通知权限（growable：null = 拿不到，展示「未知」）
  bool? _permGranted;

  /// ROM 厂商名（「后台接收设置引导」右侧尾巴，如 vivo）
  String _brand = '';

  bool _askingPermission = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    Map<String, String> rom = const {};
    try {
      rom = await RomSettings.getRomInfo();
    } catch (_) {}
    if (mounted) {
      setState(() => _brand = (rom['brand'] ?? rom['manufacturer'] ?? '').trim());
    }
    await _refreshPermission();
  }

  Future<void> _refreshPermission() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final p = await FlutterForegroundTask.checkNotificationPermission();
      if (!mounted) return;
      setState(() => _permGranted = p == NotificationPermission.granted);
    } catch (_) {}
  }

  Future<void> _askPermission() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      AppDialogs.toast(
          context, AppLocalizations.of(context).t('nsetAllowSystem'));
      return;
    }
    if (_askingPermission) return;
    _askingPermission = true;
    try {
      await FlutterForegroundTask.requestNotificationPermission();
    } catch (_) {}
    _askingPermission = false;
    await _refreshPermission();
  }

  /// 单个开关：读写 [AppSettings] 的通用通知偏好（一次性 JSON 落本地）
  bool _flag(String key, {bool def = true}) => _set.notifyPref(key, def);
  void _toggle(String key, {bool def = true}) {
    _set.setNotifyPref(key, !_flag(key, def: def));
    setState(() {});
  }

  Future<void> _resetAll() async {
    final t = AppLocalizations.of(context).t;
    final yes = await AppDialogs.confirm(
      context,
      title: t('nsetResetAll'),
      message: t('nsetResetAll'),
      confirmText: t('dialogsConfirm'),
      danger: true,
    );
    if (yes != true) return;
    await _set.resetNotifyPrefs();
    if (mounted) setState(() {});
  }

  // ---------- 提示音选择（2026-09-15） ----------

  /// 当前选中音效的展示名（未知 key 回退「默认」）
  String _toneLabel(String Function(String) t) {
    for (final tone in SoundService.notifyTones) {
      if (tone.key == _set.notifyTone) return t(tone.nameKey);
    }
    return t('nsetToneDefault');
  }

  /// 提示音选择弹层：点一行 = 试听 + 立即选中（弹层不关，方便逐个试），
  /// 选择即时持久化（AppSettings.setNotifyTone）。
  Future<void> _pickTone() async {
    final t = AppLocalizations.of(context).t;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (ctx) {
        var current = _set.notifyTone;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            child: StatefulBuilder(builder: (ctx, setSheetState) {
              final cs = Theme.of(ctx).colorScheme;
              return Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                      child: Text(
                        t('nsetTonePickerTitle'),
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.2,
                          color: cs.onSurface.withOpacity(0.45),
                        ),
                      ),
                    ),
                    for (final tone in SoundService.notifyTones)
                      InkWell(
                        onTap: () {
                          SoundService.instance.previewTone(tone.key);
                          _set.setNotifyTone(tone.key);
                          setSheetState(() => current = tone.key);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 13),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  t(tone.nameKey),
                                  style: TextStyle(
                                    fontSize: 16,
                                    height: 1.2,
                                    color: cs.onSurface,
                                    fontWeight: tone.key == current
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                              if (tone.key == current)
                                Icon(Icons.check,
                                    size: 20, color: AppTheme.primary),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              );
            }),
          ),
        );
      },
    );
    if (mounted) setState(() {}); // 弹层关掉后刷新行尾的音效名
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);

    final permTail = _permGranted == null
        ? t('nsetUnknown')
        : (_permGranted! ? t('nsetAllowed') : t('nsetDenied'));

    return V2SetScaffold(
      title: t('meRowNotify'),
      // 参考截图（`_probe2`）：顶部是**纯白条带**，y=1 起 #FFFFFF，到 y=123.00 才转 #F3F3F5、
      // y=123.33 起 #F3F2F7（内容区）。故 bg 取内容区灰、headerBg 取白，
      // 56 高标题区之下再补 7.7 白（= 123.0 - 状态栏 - 56）。
      // 深色下不硬套白底：头部标题/图标走 `context.setTitle`（深色是浅色字），
      // 硬编码白底会让字看不见；故深色取「页底 #000 / 头部 #1C1C1E」，
      // 与浅色「页底灰 / 头部比页底更亮」的层次关系一致。
      bg: context.v2IsDark ? kSetPageBgDark : const Color(0xFFF3F2F7),
      headerBg: context.v2IsDark ? kSetCardDark : const Color(0xFFFFFFFF),
      headerExtra: _kHeaderExtra,
      // B 型页返回图标是细雪佛龙 `<`（ink 11.33 × 20.33、ink 左缘 30.00），
      // 不是 A 型的完整 `←`（`_probe3` ASCII 掩码）⇒ 共享库的 V2SetBackSpec.chevron
      backSpec: V2SetBackSpec.chevron,
      // 原 top = _kPadTop(42.6) = 白条带 7.8 + 标题上方留白 34.8；
      // 7.8 那截已由 headerExtra 承接，此处只留 34.8
      padding: EdgeInsets.only(top: _kGapBeforeLabel * s, bottom: 40),
      children: [
        // ---------- 系统通知权限 ----------
        _Label(t('nsetSystemPerm')),
        const V2SetGap(_kGapAfterLabel),
        V2SetCard(rows: [
          _NRow(
            title: t('nsetAllowSystem'),
            height: _kHChevron1,
            tail: permTail,
            showChevron: true,
            onTap: _askPermission,
          ),
        ]),

        // ---------- 安卓后台保护 ----------
        const V2SetGap(_kGapBeforeLabel),
        _Label(t('nsetAndroidBg')),
        const V2SetGap(_kGapAfterLabel),
        V2SetCard(rows: [
          _NRow(
            title: t('nsetBgGuide'),
            height: _kHTitle2,
            titleLines: 2,
            tail: _brand.isEmpty ? null : _brand,
            showChevron: true,
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const KeepAliveGuidePage())),
          ),
          _NRow(
            title: t('nsetOpenBattery'),
            subtitle: t('nsetOpenBatterySub'),
            subSize: _kSubSizeChevron,
            height: _kHChevronSub,
            showChevron: true,
            onTap: () async {
              await RomSettings.openBatterySettings();
              await _refreshPermission();
            },
          ),
          _NRow(
            title: t('nsetOpenAutoStart'),
            height: _kHChevron1,
            tail: t('nsetAllowBgActivity'),
            showChevron: true,
            onTap: () async {
              await RomSettings.openAutoStartSettings();
              await _refreshPermission();
            },
          ),
        ]),

        // ---------- 消息保活模式 ----------
        const V2SetGap(_kGapBeforeLabel),
        _Label(t('nsetKeepAliveMode')),
        const V2SetGap(_kGapAfterLabel),
        V2SetCard(rows: [
          _NRow(
            title: t('nsetKeepAliveEnhanced'),
            subtitle: t('nsetKeepAliveSub'),
            height: _kHSwitch2,
            trailing: _Switch(
              value: _flag('keepAliveEnhanced'),
              onChanged: (_) => _toggle('keepAliveEnhanced'),
            ),
          ),
        ]),

        // ---------- 通知总开关 ----------
        const V2SetGap(_kGapBeforeLabel),
        _Label(t('nsetMaster')),
        const V2SetGap(_kGapAfterLabel),
        V2SetCard(rows: [
          _NRow(
            title: t('nsetAllowAppNotify'),
            subtitle: t('nsetAllowAppNotifySub'),
            height: _kHSwitch2,
            trailing: _Switch(
              // 复用全局的通知总开关（sound_service 也读它）
              value: _set.notifications,
              onChanged: (v) async {
                await _set.setNotifications(v);
                if (mounted) setState(() {});
              },
            ),
          ),
        ]),

        // ---------- 通知消息 ----------
        const V2SetGap(_kGapBeforeLabel),
        _Label(t('nsetMessages')),
        const V2SetGap(_kGapAfterLabel),
        V2SetCard(rows: [
          _switchRow('msgPrivate', t('nsetPrivateMsg')),
          _switchRow('msgGroup', t('nsetGroupMsg')),
          _switchRow('msgChannel', t('nsetChannelMsg')),
          _switchRow('msgMoment', t('nsetMomentNotify'),
              sub: t('nsetMomentNotifySub')),
        ]),

        // ---------- 通知内容 ----------
        const V2SetGap(_kGapBeforeLabel),
        _Label(t('nsetContent')),
        const V2SetGap(_kGapAfterLabel),
        V2SetCard(rows: [
          _switchRow('showPreview', t('nsetShowPreview'),
              sub: t('nsetShowPreviewSub'), height: _kHSwitch1),
        ]),

        // ---------- 声音和振动 ----------
        const V2SetGap(_kGapBeforeLabel),
        _Label(t('nsetSoundVibrate')),
        const V2SetGap(_kGapAfterLabel),
        V2SetCard(rows: [
          _switchRow('sound', t('nsetNotifySound')),
          _NRow(
            title: t('nsetTone'),
            height: _kHChevron1,
            tail: _toneLabel(t),
            showChevron: true,
            onTap: _pickTone,
          ),
          _switchRow('momentSound', t('nsetMomentSound'),
              sub: t('nsetMomentSoundSub')),
          _switchRow('vibrate', t('nsetVibrate')),
        ]),

        // ---------- 应用内通知 ----------
        const V2SetGap(_kGapBeforeLabel),
        _Label(t('nsetInApp')),
        const V2SetGap(_kGapAfterLabel),
        V2SetCard(rows: [
          _switchRow('inAppSound', t('nsetInAppSound')),
          _switchRow('inAppVibrate', t('nsetInAppVibrate')),
        ]),

        // ---------- 重置所有通知设置 ----------
        const V2SetGap(_kGapBetweenCards),
        V2SetCard(rows: [
          _NRow(
            title: t('nsetResetAll'),
            height: _kHDanger,
            danger: true,
            onTap: _resetAll,
          ),
        ]),
      ],
    );
  }

  Widget _switchRow(String key, String title, {String? sub, double? height}) {
    return _NRow(
      title: title,
      subtitle: sub,
      height: height ?? _kHSwitch1,
      trailing: _Switch(
        value: _flag(key),
        onChanged: (_) => _toggle(key),
      ),
    );
  }
}

// ============================================================================
// 本页私有组件
// ============================================================================

/// 分组小标题：左 42.7 / 字号 16.7 / #9A9FA8。
class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return Padding(
      padding: EdgeInsets.only(left: _kLabelX * s, right: kSetCardX * s),
      child: Text(
        text,
        style: TextStyle(
          fontSize: _kLabelSize * s,
          height: 1.0,
          color: _cMuted(context),
        ),
      ),
    );
  }
}

/// 设置行：主标题 + 可选副标题 + 可选尾部纯文字（**左对齐在固定列**）+ 开关/箭头。
///
/// 截图里尾部文字（「已允许」「允许后台活动」「金币」）都从 x=201 开始，
/// 不是右对齐到箭头，所以这里用固定宽度主标题列把尾巴钉在 201。
class _NRow extends StatelessWidget {
  const _NRow({
    required this.title,
    this.subtitle,
    required this.height,
    this.trailing,
    this.tail,
    this.showChevron = false,
    this.onTap,
    this.danger = false,
    this.subSize = _kSubSize,
    this.titleLines = 1,
  });

  final String title;
  final String? subtitle;
  final double height;
  final Widget? trailing;
  final String? tail;
  final bool showChevron;
  final VoidCallback? onTap;
  final bool danger;
  final double subSize;
  final int titleLines;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final ink = danger ? context.setDanger : _cInk(context);
    // 实测本页行副标题是**浅灰 #9A9FA8**，不是设备页那种中灰 #6C727B：
    // 「检测到后台限制，请处理」#9CA0A9、「后台连接更积极…」#9CA0A8、
    // 「锁屏和通知中心…」#9CA0A8、「动态声音…」#9B9FA8（4 处一致）
    final subC = danger ? context.setDanger : _cMuted(context);

    final titleWidget = Text(
      title,
      maxLines: titleLines,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: _kTitleSize * s, height: 1.0, color: ink),
    );

    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        titleWidget,
        if (subtitle != null && subtitle!.isNotEmpty) ...[
          SizedBox(height: _kTitleSubGap * s),
          Text(
            subtitle!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: subSize * s,
              height: _kSubLineH,
              color: subC,
            ),
          ),
        ],
      ],
    );

    final rightInset = showChevron ? _kChevronInset : _kSwitchInset;
    final body = Padding(
      padding: EdgeInsets.only(left: _kTitlePadL * s, right: rightInset * s),
      child: SizedBox(
        height: height * s,
        child: Row(
          children: [
            if (tail != null)
              SizedBox(width: _kTitleColW * s, child: column)
            else
              Expanded(child: column),
            if (tail != null)
              Expanded(
                child: Text(
                  tail!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: _kTailSize * s,
                    height: 1.0,
                    color: danger ? context.setDanger : _cMuted(context),
                  ),
                ),
              ),
            if (trailing != null) trailing!,
            if (showChevron)
              SizedBox(
                width: 24 * s,
                height: 24 * s,
                child: V2SetChevron(color: context.setChevron),
              ),
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

/// 开关（复用共享库的自绘开关：67.0 × 41.3，两态形状不同）。
class _Switch extends StatelessWidget {
  const _Switch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) =>
      V2SetSwitch(value: value, onChanged: onChanged);
}
