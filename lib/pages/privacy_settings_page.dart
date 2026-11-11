import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/v2_kit.dart';
import '../widgets/v2_settings.dart';

// ============================================================================
// 隐私设置页（V2 像素级复刻，2026-09-14）
//
// 参考截图：`Screenshot_2026_0914_203813.jpg`（物理 1260×2750 / DPR 3 ⇒ **逻辑 420×916.7**）。
// 逐元素实测见 `UI-ref/measure/audit_me_shell.md` §1（原始探针输出 `_me_privacy_out*.txt`）。
//
// 页面族 = **B 型**（与设备 / 数据和存储 / 通知和声音同族）：
//   页底 #F3F2F7、顶部**纯白条带到 y=123.0**、返回是**细雪佛龙 `<`**（不是 A 型的完整 `←`）。
//
// 本页实测值与共享库 `v2_settings.dart` 的差异，一律用 `_k*` 局部常数覆盖（共享文件不动）：
//   · 组标题左缘 42.0（共享 A 型是 22.0）、字号 16.4（共享 15）
//   · 主标题 19.8（共享 19.5）、副标题 / 尾字 / 页脚 16.4（共享 16.0）
//   · 行高 65.5 / 89.5 / 98.7（共享 64.0 / 93.0）
//   · 组间距 34.8（标题上）/ 12.9（标题下）（共享 35.4 / 18.4）
//   · **尾部纯文字是「左对齐固定位 x≈200.7」，不是「右对齐贴箭头」**
//     （本页 3 个尾值都是 3 字、左右对齐无法区分，故用同族「通知和声音」页交叉验证：
//      该页 3 字尾值 ink 202.0~252.3、7 字尾值 ink 201.0~305.3 ⇒ 左缘恒定、右缘随字数变）
//   · 文字灰一律 #9A9FA8（共享副标题 token #6C727B 是 A 型的值；本页与通知页实测一致）
//
// ⚠️ **未复用 `V2SetRow`**（共享库不动，仅本页绕开），原因是它的横向内边距与本页实测差 20+ px：
//   · 文字左缘：它叠了 `Padding(left: 22.3)` **和** `textLeft = kSetTitleX − kSetCardX = 22.3`
//     ⇒ 距卡左 44.6、落到屏幕 x=65.3；本页实测 **42.3**（距卡左 21.6）。
//   · 尾部右缘：它取 `right: kSetTailInset − kSetCardX = 4.6` ⇒ 落到卡右 −4.6 = 394.7；
//     本页实测开关右缘 **374.0**（距卡右 25.3）。
//   ⇒ 行内自绘 `_PrivRow`，与 `device_page.dart` / `notification_settings_page.dart` 的做法一致
//     （那两页同样没用 `V2SetRow`，目前全仓只有 `group_manage_page.dart` 在用）。
// ============================================================================

// ---------- 字号（实测逻辑 px） ----------
const double _kLabelSize = 16.4; // 组标题（供对照：ink 宽 30.7「隐私」2 字）
const double _kTitleSize = 19.8; // 行主标题（实测样本行 ink 180.7 ÷ 9 = 20.08）
const double _kBodySize = 16.4; // 副标题 / 尾字 / 页脚（296.0 ÷ 18 = 16.44）
const double _kSubLineH = 1.385; // 副标题行距 = 22.7 ÷ 16.4（实测两行 ink 顶间距 22.7）
const double _kTitleSubGap = 7.8; // 主标题行盒底 → 副标题行盒顶（实测 ink 间距 11.0~11.3）

// ---------- 间距 ----------
const double _kHeaderExtra = 7.7; // 白条带在 56 高标题区之下的延伸（123.0 − 59.35 − 56）
const double _kGapBeforeLabel = 34.8; // 头部底(123.0) → 组标题行盒顶(157.8)
const double _kGapAfterLabel = 12.9; // 组标题行盒底(174.1) → 卡顶(187.0)
const double _kGapBeforeFooter = 14.5; // 卡底(867.3) → 页脚行盒顶(881.8)
const double _kPageBottomPad = 40.0;

// ---------- 横向 ----------
/// 文字 ink 左缘距屏幕左（实测行标题 42.0~42.7 / 副标题 42.0 / 页脚 41.7）。
const double _kTextX = 42.0;

/// 尾部纯文字 ink 左缘（实测 200.7）⇒ 主标题列固定宽 = 200.0 − 42.0。
const double _kTailX = 200.0;
const double _kTitleColW = _kTailX - _kTextX; // 158.0

/// 开关行主标题列宽：把副标题卡在**同一折行点**再交给文字自动折行。
///
/// 参考图 4 条副标题的第 1 行都恰好 15 字（ink 宽 246.7，42.0→288.7），第 16 字必落到第 2 行
/// ⇒ 可用宽度 ∈ [246.7, 246.7 + 2×16.4=279.5) 的反推收窄为 [246.7, 263.0)（16 字 = 262.4 必须放不下）。
/// 取中位 **252.0**（距开关左缘 307.0 还有 13 的非文字区）。
const double _kSwitchColW = 252.0;

/// 开关右缘距卡右（实测 374.0，卡右 399.3）。
const double _kSwitchInset = 25.3;

/// 箭头盒右缘距卡右：实测箭头 ink 362.7~370.3，`Icons.chevron_right` ink 左偏 8.59/24
/// ⇒ 盒右 = 362.7 − 8.59 + 24 = 378.1 ⇒ 内缩 21.2，取 21.0（ink 左 362.9）。
/// 行 1（主标题列用 `Expanded`）的可用宽度 = 378.6 − 21.3 − 21.0 − 24 = **312.3**
/// ≥ 其 18 字副标题实测所需的 296.0 ⇒ 不会被折行。
const double _kChevronInset = 21.0;

// ---------- 行高（实测） ----------
const double _kRowH1 = 65.5; // 单行主标题（在线状态 / 手机号 / 群组）
const double _kRowH3 = 98.7; // 主标题 + 2 行副标题 + 开关（允许手机号搜索 等 4 行）

// ---------- 色板 ----------
/// 行主标题：B 型页实测 **纯黑**（darkest-3% = #000000），不是 A 型的 #121824。
Color _cInk(BuildContext c) =>
    c.v2IsDark ? const Color(0xFFF2F2F7) : const Color(0xFF000000);

/// 本页的组标题 / 副标题 / 尾字 / 页脚**同色**（实测 4 处全是 #9A9EA7~#9A9FA8）。
/// 与「通知和声音」页选值一致（`_cMuted` = #9A9FA8），够同一族的证据。
Color _cMuted(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF8E8E93) : const Color(0xFF9A9FA8);

/// 隐私设置：在线状态 / 手机号可见范围（三档）+ 回执两个开关 + 「添加我的方式」分组
/// （手机号 / 短 ID 被搜索开关）。群组可见范围已按产品决策撤销，不再展示。
///
/// [onBack] 供外层容器（宽屏右栏）接管返回；不传时 `V2SetHeader` 走 `maybePop`。
class PrivacySettingsPage extends StatefulWidget {
  const PrivacySettingsPage({super.key, this.onBack});

  final VoidCallback? onBack;

  @override
  State<PrivacySettingsPage> createState() => _PrivacySettingsPageState();
}

class _PrivacySettingsPageState extends State<PrivacySettingsPage> {
  // ---------- 三档可见范围（服务端枚举，见 im-server/doc/API.md 隐私设置节） ----------
  static const String _scopeAll = 'all'; // 所有人
  static const String _scopeContacts = 'contacts'; // 仅联系人
  static const String _scopeNobody = 'nobody'; // 不公开

  // 三档可见范围。预置为服务端默认值（API.md：onlineVisible 默认 all、
  // phoneVisible 默认 nobody），initState 拉 GET /user/privacy 后回显覆盖。
  // 「群组」可见范围已按产品决策撤销（用户：不要群组隐私设置），页面不再展示。
  String _onlineVisible = _scopeAll;
  String _phoneVisible = _scopeNobody;

  // 4 个布尔开关（服务端字段 phoneSearchable/shortIdSearchable/readReceiptEnabled/typingEnabled，
  // 默认全 true——与 API.md 默认值及参考图初值一致）。
  bool _searchByPhone = true; // 允许手机号搜索
  bool _searchByShortId = true; // 允许平台短号搜索
  bool _readReceipt = true; // 发送已读回执
  bool _typingStatus = true; // 显示输入状态

  @override
  void initState() {
    super.initState();
    _loadPrivacy();
  }

  /// 回显：GET /user/privacy（信封 code!=0 抛错，见 ApiClient.fetchPrivacy）。
  /// 拉取失败保持服务端默认值，页面仍可用——后续改动 PUT 时会再得到明确报错。
  Future<void> _loadPrivacy() async {
    try {
      final m = await ApiClient.instance.fetchPrivacy();
      if (!mounted) return;
      setState(() {
        _phoneVisible = (m['phoneVisible'] as String?) ?? _phoneVisible;
        _onlineVisible = (m['onlineVisible'] as String?) ?? _onlineVisible;
        _searchByPhone = (m['phoneSearchable'] as bool?) ?? _searchByPhone;
        _searchByShortId =
            (m['shortIdSearchable'] as bool?) ?? _searchByShortId;
        _readReceipt = (m['readReceiptEnabled'] as bool?) ?? _readReceipt;
        _typingStatus = (m['typingEnabled'] as bool?) ?? _typingStatus;
      });
    } catch (_) {
      // 静默：默认值兜底，不打断浏览
    }
  }

  // ---------- 落库 ----------
  /// 开关改动：乐观更新本地 → PUT 只发改动字段 → 失败回滚 + toast 服务端 message。
  Future<void> _putBool(
      String field, bool v, bool Function() get, ValueChanged<bool> set) async {
    final old = get();
    if (old == v) return;
    set(v);
    try {
      await ApiClient.instance.updatePrivacy({field: v});
    } catch (e) {
      if (!mounted) return;
      set(old);
      AppDialogs.toast(context, _errText(e));
    }
  }

  /// 三档选择改动：乐观更新本地 → PUT 只发改动字段 → 失败回滚 + toast 服务端 message。
  Future<void> _putScope(String field, String v, String Function() get,
      ValueChanged<String> set) async {
    final old = get();
    if (old == v) return;
    set(v);
    try {
      await ApiClient.instance.updatePrivacy({field: v});
    } catch (e) {
      if (!mounted) return;
      set(old);
      AppDialogs.toast(context, _errText(e));
    }
  }

  /// toast 文案：网络层错误取 l10n 友好文案（404=服务端过旧 / 其余=网络错误），
  /// 服务端业务拒绝显示其 message —— **不再把 DioException 原文弹给用户**。
  String _errText(Object e) {
    if (e is PrivacyNetException) {
      final t = AppLocalizations.of(context).t;
      return t(e.type == PrivacyNetErrorType.unsupported
          ? 'netErrUnsupported'
          : 'netErrRetry');
    }
    return e.toString().replaceFirst('Exception: ', '');
  }

  /// 三档选择面板：底部弹出（与我的页外观面板同款交互），当前档打勾。
  Future<void> _pickScope({
    required String title,
    required String field,
    required String current,
    required ValueChanged<String> setLocal,
  }) async {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 6),
            Text(title,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface)),
            const SizedBox(height: 6),
            for (final v in const [_scopeAll, _scopeContacts, _scopeNobody])
              SizedBox(
                height: 56,
                child: InkWell(
                  onTap: () => Navigator.of(ctx).pop(v),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(_scopeLabel(t, v),
                              style: TextStyle(
                                  fontSize: 16, color: scheme.onSurface)),
                        ),
                        if (v == current)
                          const Icon(Icons.check,
                              size: 22, color: AppTheme.primary),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (picked == null || picked == current) return;
    await _putScope(field, picked, () => current, setLocal);
  }

  String _scopeLabel(String Function(String) t, String v) {
    switch (v) {
      case _scopeContacts:
        return t('mePrivContacts');
      case _scopeNobody:
        return t('mePrivNobody');
      default:
        return t('mePrivEveryone');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    final dark = context.v2IsDark;

    return V2SetScaffold(
      title: t('meRowPrivacy'),
      onBack: widget.onBack,
      // B 型页：内容区 #F3F2F7、顶部纯白条带到 123.0（见文件头与审计报告 §1.1）。
      // 深色下不硬套白底（硬编码白会让 `context.setTitle` 的浅色字看不见），
      // 取「页底 #000 / 头部 #1C1C1E」，与浅色「页底灰 / 头部更亮」的层次关系一致。
      bg: dark ? kSetPageBgDark : const Color(0xFFF3F2F7),
      headerBg: dark ? kSetCardDark : const Color(0xFFFFFFFF),
      headerExtra: _kHeaderExtra,
      // 返回为细雪佛龙 `<`（逐物理行 ASCII 掩码：每行单游程、无横杠；ink 30.3×19.0）
      backSpec: V2SetBackSpec.chevron,
      padding: const EdgeInsets.only(top: _kGapBeforeLabel, bottom: _kPageBottomPad),
      children: [
        // ---------- 分组标题「隐私」（与页面标题同词，参考图即如此） ----------
        V2SetSectionLabel(
          t('meRowPrivacy'),
          left: _kTextX,
          fontSize: _kLabelSize,
          color: _cMuted(context),
        ),
        const V2SetGap(_kGapAfterLabel),

        // ---------- 卡 1：可见范围 + 回执开关（行 1-5） ----------
        V2SetCard(rows: [
          // 行 2-3：可见范围三档（点按弹面板，改动即 PUT 只发改动字段）
          _PrivRow(
            height: _kRowH1,
            title: t('mePrivOnlineStatus'),
            tail: _scopeLabel(t, _onlineVisible),
            titleColW: _kTitleColW,
            trailing: _chevron(s),
            onTap: () => _pickScope(
              title: t('mePrivOnlineStatus'),
              field: 'onlineVisible',
              current: _onlineVisible,
              setLocal: (v) => setState(() => _onlineVisible = v),
            ),
          ),
          _PrivRow(
            height: _kRowH1,
            title: t('mePrivPhone'),
            tail: _scopeLabel(t, _phoneVisible),
            titleColW: _kTitleColW,
            trailing: _chevron(s),
            onTap: () => _pickScope(
              title: t('mePrivPhone'),
              field: 'phoneVisible',
              current: _phoneVisible,
              setLocal: (v) => setState(() => _phoneVisible = v),
            ),
          ),
          // 行 4-5：主标题 + 2 行副标题 + 开关（高 98.7），改动即 PUT 只发改动字段
          _PrivRow(
            height: _kRowH3,
            title: t('mePrivReadReceipt'),
            subtitle: t('mePrivReadReceiptSub'),
            titleColW: _kSwitchColW,
            trailing: _switch(
                _readReceipt,
                (v) => _putBool('readReceiptEnabled', v, () => _readReceipt,
                    (x) => setState(() => _readReceipt = x)),
                s),
          ),
          _PrivRow(
            height: _kRowH3,
            title: t('mePrivTypingStatus'),
            subtitle: t('mePrivTypingStatusSub'),
            titleColW: _kSwitchColW,
            trailing: _switch(
                _typingStatus,
                (v) => _putBool('typingEnabled', v, () => _typingStatus,
                    (x) => setState(() => _typingStatus = x)),
                s),
          ),
        ]),

        // ---------- 分组标题「添加我的方式」+ 卡 2：被搜索开关 ----------
        const V2SetGap(_kGapBeforeLabel),
        V2SetSectionLabel(
          t('mePrivAddWays'),
          left: _kTextX,
          fontSize: _kLabelSize,
          color: _cMuted(context),
        ),
        const V2SetGap(_kGapAfterLabel),
        V2SetCard(rows: [
          _PrivRow(
            height: _kRowH3,
            title: t('mePrivSearchPhone'),
            subtitle: t('mePrivSearchPhoneSub'),
            titleColW: _kSwitchColW,
            trailing: _switch(
                _searchByPhone,
                (v) => _putBool('phoneSearchable', v, () => _searchByPhone,
                    (x) => setState(() => _searchByPhone = x)),
                s),
          ),
          _PrivRow(
            height: _kRowH3,
            title: t('mePrivSearchShortId'),
            subtitle: t('mePrivSearchShortIdSub'),
            titleColW: _kSwitchColW,
            trailing: _switch(
                _searchByShortId,
                (v) => _putBool('shortIdSearchable', v, () => _searchByShortId,
                    (x) => setState(() => _searchByShortId = x)),
                s),
          ),
        ]),

        // ---------- 页脚灰字 ----------
        const V2SetGap(_kGapBeforeFooter),
        Padding(
          padding: EdgeInsets.only(left: _kTextX * s, right: kSetCardX * s),
          child: Text(
            t('mePrivFooter'),
            style: TextStyle(
              fontSize: _kBodySize * s,
              fontWeight: FontWeight.w400,
              height: 1.0,
              color: _cMuted(context),
            ),
          ),
        ),
      ],
    );
  }

  /// 右侧箭头：盒右缘距卡右 21.0（实测 ink 362.7~370.3）。
  Widget _chevron(double s) => Padding(
        padding: EdgeInsets.only(right: _kChevronInset * s),
        child: const V2SetChevron(size: 24),
      );

  /// 开关：整体 67.0×41.3，右缘距卡右 25.3（实测开关 x 307.0..374.0，卡右 399.3）。
  Widget _switch(bool value, ValueChanged<bool> onChanged, double s) => Padding(
        padding: EdgeInsets.only(right: _kSwitchInset * s),
        child: V2SetSwitch(value: value, onChanged: onChanged),
      );
}

/// 隐私页的单行（自绘，见文件头「未复用 V2SetRow」的原因）。
///
/// 纵向：整行固定高，文字块 `Column` **垂直居中**；实测行 2-4 的文字块中心与行中心只差 0.4。
/// 横向：文字 ink 左缘固定 42.0（= 卡左 20.7 + 本行内边距 21.3）。
class _PrivRow extends StatelessWidget {
  const _PrivRow({
    required this.height,
    required this.title,
    this.subtitle,
    this.tail,
    this.trailing,
    this.titleColW,
    this.onTap,
  });

  final double height;
  final String title;
  final String? subtitle;

  /// 尾部纯文字（左对齐在固定位 [_kTailX]）。
  final String? tail;
  final Widget? trailing;

  /// 主标题列固定宽；null ⇒ 用 `Expanded` 撑满剩余（给不带尾字的行）。
  final double? titleColW;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final hasSub = subtitle != null;
    final lineCount = _wrapLineCount;

    final titleColor = _cInk(context);
    final muted = _cMuted(context);

    final col = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: _kTitleSize * s,
            fontWeight: FontWeight.w400,
            height: 1.0,
            color: titleColor,
          ),
        ),
        if (hasSub) ...[
          SizedBox(height: _kTitleSubGap * s),
          Text(
            subtitle!,
            // 行 1 是 1 行、4 个开关行是 2 行（见 `_wrapLineCount`）。行高是实测固定值，
            // 故这里按估算行数硬截断：中文参考文案刚好铺满，译文过长则省略号收尾，
            // 不会撑破固定行高（像素级复刻优先）。
            maxLines: lineCount,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: _kBodySize * s,
              fontWeight: FontWeight.w400,
              height: _kSubLineH,
              leadingDistribution: TextLeadingDistribution.even,
              color: muted,
            ),
          ),
        ],
      ],
    );

    final children = <Widget>[];
    if (titleColW != null) {
      children.add(SizedBox(width: titleColW! * s, child: col));
    } else {
      children.add(Expanded(child: col));
    }
    if (tail != null) {
      children.add(Text(
        tail!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: _kBodySize * s,
          fontWeight: FontWeight.w400,
          height: 1.0,
          color: muted,
        ),
      ));
    }
    if (trailing != null) {
      // 只有「主标题列宽度固定」时才需要 Spacer 把尾部元素顶到最右；
      // 行 1 的主标题列是 `Expanded`，它已经吃掉全部剩余宽度 —— 若再加 Spacer，
      // 两者会各分一半（flex 相等），行 1 的 18 字副标题就会被折行。
      if (titleColW != null) children.add(const Spacer());
      children.add(trailing!);
    }

    Widget body = Center(
      child: Row(
        children: children,
      ),
    );

    // 本行内边距：卡左 20.7 → 文字 42.0（= +21.3）；右缘由尾部元素各自内缩
    body = Padding(
      padding: EdgeInsets.only(left: (kSetTitleX - kSetCardX) * s, top: 0),
      child: SizedBox(height: height * s, child: body),
    );

    if (onTap == null) return body;
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, child: body),
    );
  }

  /// 副标题在**本行给定列宽**下会折成几行 —— 决定行高与尾部对齐量。
  ///
  /// 实测：行 1 的副标题 18 字一行放得下（296.0 ≤ 可用 304.3）；4 个开关行的副标题
  /// 第 1 行恰好 15 字（246.7 ≤ 252.0 < 262.4）⇒ **2 行**。
  /// 这里按「每字 1em」估算（中日韩全角字符逐字步进 = 1em，是 DESIGN 的既定反推法）。
  int get _wrapLineCount {
    if (subtitle == null) return 0;
    final avail = titleColW ?? double.infinity;
    if (!avail.isFinite) return 1;
    // 全角字符按 1em 计、ASCII 按 0.5em 计（本页文案全是全角，留个保守系数）
    var em = 0.0;
    for (final r in subtitle!.runes) {
      em += r < 0x2000 ? 0.5 : 1.0;
    }
    final lines = (em * _kBodySize / avail).ceil();
    return lines < 1 ? 1 : lines;
  }
}
