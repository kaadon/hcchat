import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'v2_kit.dart';

// ============================================================================
// V2 设置类页面共享设计系统（2026-09-14 像素级实测，基准逻辑宽 420）
//
// 适用：设备 / 聊天设置 / 数据和存储 / 通知和声音 / 钱包 等「AppBar + 分组白卡」页面。
// 逐元素测量报告见 `UI-ref/measure/`，规格见 `UI-ref/DESIGN.md` §12。
//
// 为什么单独开文件：这 4 个页面是同一套设计语言（同一 AppBar、同一分组卡、同一开关），
// 分散各写会漂移；抽成一套后页面只需要描述「有哪些行」，尺寸/色值集中一处。
//
// 尺度：所有数字都是参考截图的**逻辑 px**（截图物理宽 1260 / DPR 3 ⇒ 逻辑宽 420），
// 落地时统一 `* v2Scale(context)`。见 v2_kit.dart 顶部说明。
// ============================================================================

// ---------- 色板（实测） ----------
/// 页面底色 #F6F7F9（聊天设置页实测）／#F3F2F7（通知·数据·设备页实测）——取前者，差异在 JPEG 噪声内
const Color kSetPageBg = Color(0xFFF6F7F9);
const Color kSetPageBgDark = Color(0xFF000000);
const Color kSetCard = Color(0xFFFFFFFF);
const Color kSetCardDark = Color(0xFF1C1C1E);

/// 分组小标题（「消息」「外观」「当前设备」）实测 #6B727D
const Color kSetLabel = Color(0xFF6B727D);

/// 行主标题实测 #121824
const Color kSetTitle = Color(0xFF121824);

/// 行副标题实测 #6C727B
const Color kSetSub = Color(0xFF6C727B);

/// 行间分隔线实测 #F3F3F3
const Color kSetHair = Color(0xFFF3F3F3);

/// 右侧箭头实测 #6C727E
const Color kSetChevron = Color(0xFF6C727E);

/// 危险/红色文字实测 #E53A34（设备页「退出登录」、通知页「重置所有通知设置」、
/// 数据页「重置加密身份」、好友资料页「举报/屏蔽用户」四处一致）
const Color kSetDanger = Color(0xFFE53A34);

/// 开关：ON = 实心灰轨道 #A7A8AA + 近黑滑块；OFF = 透明底 + 近黑描边 + 较小的近黑滑块
const Color kSetTrackOn = Color(0xFFA7A8AA);
const Color kSetTrackOnDark = Color(0xFF48484A);
const Color kSetKnob = Color(0xFF0C0D12);
const Color kSetKnobDark = Color(0xFFFFFFFF);

// ---------- 尺寸（实测逻辑 px） ----------
/// 卡片：左 20.7 / 宽 378.7 / 圆角 16（与「我的」页卡片同宽，但圆角更小）
const double kSetCardX = 20.7;
const double kSetCardW = 378.7;
const double kSetCardR = 16.0;

/// 分组小标题：ink 左缘 22.0，字号 15（「消息」2 字 = 30 ⇒ 逐字步进 15）
const double kSetLabelX = 22.0;
const double kSetLabelSize = 15.0;

/// 行主标题：ink 左缘 43.0（= 卡左 20.7 + 内边距 22.3），字号 19.5（「消息预览」4 字 = 78）
const double kSetTitleX = 43.0;
const double kSetTitleSize = 19.5;
const double kSetSubSize = 16.0;

/// 行高：带副标题 93.0（卡高 186 / 2 行）／仅主标题 64.0
const double kSetRowH = 93.0;
const double kSetRowH1 = 64.0;

/// 分隔线：左起 41.0（= 卡左 + 20.3），右**通到卡片右缘**；厚约 0.7（2 物理 px）
const double kSetHairInset = 20.3;
const double kSetHairThickness = 0.7;

/// 尾部元素（开关 / 箭头）右缘距卡片右缘 25.3（开关 x 307.0..374.0，卡右 399.3）
const double kSetTailInset = 25.3;

/// 开关实测 67.0 × 41.3；ON 滑块 ∅31.3、OFF 滑块 ∅23.0；滑块内缩 5.0
const double kSetSwitchW = 67.0;
const double kSetSwitchH = 41.3;
const double kSetKnobOn = 31.3;
const double kSetKnobOff = 23.0;
const double kSetKnobInset = 5.0;

/// AppBar：内容区高 56（标题 ink 垂直中心在内容区 **28.0**；标题居中、字号 21）
const double kSetHeaderH = 56.0;
const double kSetHeaderTitleSize = 21.0;
const double kSetHeaderTitleWeight = 600;

/// 返回图标的**命中盒**边长（逻辑 px）。参考的 ink 只有 ~20 高，
/// 直接用 ink 尺寸做 `SizedBox` 会让点击区小于 44 的无障碍下限，
/// 故命中盒固定 44（图标在其中居中，ink 位置不受影响）。
const double kSetBackIconHit = 44.0;

/// 返回图标的几何预设。
///
/// **光给 size 不足以定位**：不同图标在自身 24×24 视框里的 ink 位置不同
/// （`arrow_back` ink 左偏 4/24，`arrow_back_ios_new` ink 左偏 6/24），
/// 所以 icon box 左缘必须由「目标 ink 左缘」反推，否则一换图标整块就平移。
///
/// 实测（`UI-ref/measure/_scan_back2.txt`：逐物理行游程 + 逐行单游程判无横杠）：
/// 参考包里**两族页面用的不是同一个返回图标**——
/// * A 型（聊天设置等）：完整 `←`，ink **21.00 × 21.00**，ink 左缘 **25.00**
/// * B 型（设备 / 数据和存储 / 通知和声音）：细雪佛龙 `<`，ink **11.67 × 20.33**、
///   ink 左缘 **30.00**；四页 ink 中心 ly 全为 **87.00**（与标题 ink 中心 87.17 齐）
///
/// 字形占比（由 path 数据算出的精确值，不是估的）：
/// * `Icons.arrow_back` `M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z`
///   ⇒ ink 16/24 × 16/24 = **0.6667 × 0.6667** em，ink 左偏 4/24 = **0.1667** em，
///   ink 垂直中心 = box 中心
/// * `Icons.arrow_back_ios_new` `M17.77 3.77L16 2 6 12l10 10 1.77-1.77L9.54 12z`
///   ⇒ ink 11.77/24 × 20/24 = **0.4904 × 0.8333** em，ink 左偏 6/24 = **0.25** em，
///   ink 垂直中心 = box 中心
///
/// 对齐验算（用 ink **高**定 size，再用 ink 宽交叉验证）：
/// * A 型：size = 21.00 ÷ 0.6667 = **31.5** ⇒ ink 宽 21.00（参考 21.00 ✓）；
///   box 左 = 25.00 − 0.1667×31.5 = **19.75**
/// * B 型：size = 20.33 ÷ 0.8333 = **24.4** ⇒ ink 宽 11.97（参考 11.67，Δ0.30）；
///   box 左 = 30.00 − 0.25×24.4 = **23.90**
///
/// 宽高比交叉验证：参考 A 21.00/21.00 = **1.000**、B 11.67/20.33 = **0.574**；
/// `arrow_back` 0.6667/0.6667 = 1.000 ✓、`arrow_back_ios_new` 0.4904/0.8333 = 0.588（Δ0.014 ✓）。
/// ⚠️ 此前本库把 B 型写成 `chevron_left`，是**错的**：它 ink 占比 0.3088×0.5（ratio 0.618）、
/// 笔画相对厚 0.167，与参考的 0.574 / 0.125 都差得多。
class V2SetBackSpec {
  const V2SetBackSpec(
      {required this.icon, required this.size, required this.left});

  /// 图标（Material 字体字形）。
  final IconData icon;

  /// 图标边长（逻辑 px，@420 基准）。
  final double size;

  /// icon box 左缘（逻辑 px，@420 基准）= 目标 ink 左缘 − ink 左偏 × [size]。
  final double left;

  /// A 型：完整 `←`，ink 21.00×21.00、ink 左缘 25.00。
  static const V2SetBackSpec full =
      V2SetBackSpec(icon: Icons.arrow_back, size: 31.5, left: 19.75);

  /// B 型：细雪佛龙 `<`，ink 11.67×20.33、ink 左缘 30.00。
  static const V2SetBackSpec chevron =
      V2SetBackSpec(icon: Icons.arrow_back_ios_new, size: 24.4, left: 23.9);
}

// ---------- 深浅色适配 ----------
/// 页面里写 `context.setTitle` 而不是 `kSetTitle`，一处自动适配深浅色。
/// （公开：页面自绘的部分也能取到同一套色值，避免各页自己写死深浅判断。）
extension V2SetTheme on BuildContext {
  bool get _dark => v2IsDark;
  Color get setPageBg => _dark ? kSetPageBgDark : kSetPageBg;
  Color get setCard => _dark ? kSetCardDark : kSetCard;
  Color get setLabel => _dark ? const Color(0xFF8E8E93) : kSetLabel;
  Color get setTitle => _dark ? const Color(0xFFF2F2F7) : kSetTitle;
  Color get setSub => _dark ? const Color(0xFF98989F) : kSetSub;
  Color get setHair => _dark ? const Color(0xFF2C2C2E) : kSetHair;
  Color get setChevron => _dark ? const Color(0xFF8E8E93) : kSetChevron;
  Color get setTrackOn => _dark ? kSetTrackOnDark : kSetTrackOn;
  Color get setKnob => _dark ? kSetKnobDark : kSetKnob;
  Color get setDanger => _dark ? const Color(0xFFFF453A) : kSetDanger;
}

/// 页面骨架：底色 + 自绘 AppBar（返回箭头 + 居中标题）+ 可滚动内容。
///
/// 不用 Material `AppBar` 的原因：截图里标题**垂直中心在 y≈88.4**（状态栏较高 + 56 高
/// 内容区），且返回箭头 ink 左缘固定在 26.3；用 AppBar 会带上 `toolbarHeight`/`leading`
/// 的默认内边距，对不齐。这里自绘，`MediaQuery.padding.top` 交给状态栏。
class V2SetScaffold extends StatelessWidget {
  const V2SetScaffold({
    super.key,
    required this.title,
    required this.children,
    this.onBack,
    this.actions,
    this.bottom,
    this.bg,
    this.headerBg,
    this.headerExtra = 0,
    this.backSpec = V2SetBackSpec.full,
    this.padding = const EdgeInsets.only(top: 4, bottom: 40),
  });

  final String title;
  final List<Widget> children;
  final VoidCallback? onBack;
  final Widget? actions;
  final Widget? bottom;

  /// 页面底色。不给时用 [kSetPageBg]（#F6F7F9）。
  final Color? bg;

  /// 顶部 AppBar 区底色。**默认 = [bg]**；但参考包里有一类页面（设备 / 数据和存储 /
  /// 通知和声音）顶部是**纯白 #FFFFFF 条带（实测到 y=123，含状态栏）**，内容区才是 #F3F2F7
  /// —— 这类页面要显式传 `bg: Color(0xFFF3F2F7), headerBg: Color(0xFFFFFFFF)`。
  final Color? headerBg;

  /// 56 高内容区**之下**继续用 [headerBg] 填充的高度（逻辑 px）。
  ///
  /// B 型页实测白条带总高 **123.0** = 状态栏 59.35 + 内容区 56 + **7.65**
  /// （`_probe2`：x=5 处 123.00 由 `#FFFFFF` 转 `#F3F3F5`，123.33 转 `#F3F2F7`）。
  /// 故 B 型页传 `headerExtra: 7.7`；这样首个分组标题之前的留白就不必再用
  /// `padding.top` 补，白色条带也能盖满到 123.0。
  final double headerExtra;

  /// 返回图标几何，透传给 [V2SetHeader]。A 型页不传即用 [V2SetBackSpec.full]；
  /// B 型页（设备 / 数据和存储 / 通知和声音）传 [V2SetBackSpec.chevron]。
  final V2SetBackSpec backSpec;

  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final pageBg = bg ?? context.setPageBg;
    return Scaffold(
      backgroundColor: pageBg,
      body: Column(
        children: [
          V2SetHeader(
              title: title,
              onBack: onBack,
              actions: actions,
              bg: headerBg ?? pageBg,
              extra: headerExtra,
              backSpec: backSpec),
          Expanded(
            child: ListView(
              padding: EdgeInsets.only(
                  top: padding.top * s,
                  bottom: padding.bottom * s + MediaQuery.paddingOf(context).bottom),
              children: children,
            ),
          ),
          if (bottom != null)
            Container(
              color: pageBg,
              padding: EdgeInsets.only(
                  left: 20.7 * s,
                  right: 20.7 * s,
                  bottom: 20 * s + MediaQuery.paddingOf(context).bottom),
              child: bottom,
            ),
        ],
      ),
    );
  }
}

/// 自绘 AppBar（供 [V2SetScaffold] 与需要自定义 body 的页面直接用）。
class V2SetHeader extends StatelessWidget {
  const V2SetHeader({
    super.key,
    required this.title,
    this.onBack,
    this.actions,
    this.bg,
    this.extra = 0,
    this.backSpec = V2SetBackSpec.full,
  });

  final String title;
  final VoidCallback? onBack;
  final Widget? actions;

  /// 头部条带底色；不给时用页面底色（见 [V2SetScaffold.headerBg] 的说明）。
  final Color? bg;

  /// 56 高内容区**之下**再用 [bg] 填充的高度（见 [V2SetScaffold.headerExtra]）。
  final double extra;

  /// 返回图标几何（字形 + 边长 + box 左缘）。默认 A 型完整 `←`；
  /// B 型页传 [V2SetBackSpec.chevron]（细雪佛龙 `<`）。见 [V2SetBackSpec] 的实测推导。
  final V2SetBackSpec backSpec;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final top = MediaQuery.paddingOf(context).top;
    final h = (kSetHeaderH + extra) * s;
    final bs = backSpec.size * s;
    return Container(
      color: bg ?? context.setPageBg,
      height: top + h,
      padding: EdgeInsets.only(top: top),
      child: Stack(
        children: [
          // 返回图标：box 左缘 = 目标 ink 左缘 − ink 左偏×size（见 V2SetBackSpec）。
          // 命中盒不小于 44×44，图标在其中居中 —— 参考的 ink 只有 ~20 高，
          // 若直接把 SizedBox 做成 bs 大小，点击区会小到 24.4。
          Positioned(
            left: (backSpec.left - (kSetBackIconHit - backSpec.size) / 2) * s,
            top: (kSetHeaderH - kSetBackIconHit) / 2 * s,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onBack ?? () => Navigator.of(context).maybePop(),
              child: SizedBox(
                width: kSetBackIconHit * s,
                height: kSetBackIconHit * s,
                child: Center(
                  child: Icon(backSpec.icon,
                      size: bs, color: context.setTitle),
                ),
              ),
            ),
          ),
          Center(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: kSetHeaderTitleSize * s,
                fontWeight: FontWeight.w600,
                height: 1.0,
                color: context.setTitle,
              ),
            ),
          ),
          if (actions != null)
            Positioned(
              right: 20.7 * s,
              top: 0,
              bottom: 0,
              child: Center(child: actions!),
            ),
        ],
      ),
    );
  }
}

/// 分组小标题（灰字，无底色）。上下留白由页面用 [V2SetGap] 控制。
///
/// 参考包里实测存在**两套分组标题模板**（不是测量误差，是多张截图的真实差异）：
/// * **A 型**（默认，聊天设置页）：ink 左缘 **22.0**、字号 **15**、色 `#6B727D`
///   （「消息」2 字 ink 宽 30 ⇒ 15/字）。
/// * **B 型**（设备 / 数据和存储 / 通知和声音页）：ink 左缘 **42.3**（与行主标题 43.0 对齐）、
///   字号 **16**、色 `#9A9EA8`（「系统通知权限」6 字 ink 宽 96.7 ⇒ 16.1/字）。
///
/// B 型页面这样用：
/// ```dart
/// V2SetSectionLabel(t('nsetPerm'), left: 42.3, fontSize: 16, color: Color(0xFF9A9EA8))
/// ```
class V2SetSectionLabel extends StatelessWidget {
  const V2SetSectionLabel(
    this.text, {
    super.key,
    this.extra,
    this.left,
    this.fontSize,
    this.color,
  });

  final String text;
  final Widget? extra;

  /// ink 左缘，默认 [kSetLabelX]（A 型 22.0）；B 型传 42.3。
  final double? left;

  /// 字号，默认 [kSetLabelSize]（A 型 15）；B 型传 16。
  final double? fontSize;

  /// 颜色，默认 `context.setLabel`（A 型 #6B727D）；B 型传 #9A9EA8。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return Padding(
      padding: EdgeInsets.only(left: (left ?? kSetLabelX) * s, right: kSetCardX * s),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: (fontSize ?? kSetLabelSize) * s,
                fontWeight: FontWeight.w400,
                height: 1.0,
                color: color ?? context.setLabel,
              ),
            ),
          ),
          if (extra != null) extra!,
        ],
      ),
    );
  }
}

/// 卡片之间的留白节奏（实测）：组标题上方 35.4、标题下方 18.4、组与组之间 31.3。
/// 用法：`V2SetGap.beforeLabel()` / `V2SetGap.afterLabel()` / `V2SetGap.betweenCards()`。
class V2SetGap extends StatelessWidget {
  const V2SetGap(this.h, {super.key});

  /// 组标题**上方**留白（上一个卡片 → 标题）
  const V2SetGap.beforeLabel({super.key}) : h = 35.4;

  /// 组标题**下方**留白（标题 → 本组卡片）
  const V2SetGap.afterLabel({super.key}) : h = 18.4;

  /// 组与组之间（无标题时的卡片间距）
  const V2SetGap.betweenCards({super.key}) : h = 31.3;

  final double h;

  @override
  Widget build(BuildContext context) => SizedBox(height: h * v2Scale(context));
}

/// 分组白卡：左 20.7 / 宽 378.7 / 圆角 16，子项之间自动插入分隔线。
///
/// 分隔线规则（实测）：左起卡内 20.3、**右通到卡片右缘**、厚 0.7、色 #F3F3F3；
/// 最后一项之后**不再补线**（与消息列表页「最后一行也有线」不同）。
class V2SetCard extends StatelessWidget {
  const V2SetCard({super.key, required this.rows, this.padBottom = 0});

  final List<Widget> rows;
  final double padBottom;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) {
        children.add(Padding(
          padding: EdgeInsets.only(left: kSetHairInset * s),
          child: Container(
            height: kSetHairThickness * s,
            color: context.setHair,
          ),
        ));
      }
      children.add(rows[i]);
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: kSetCardX * s),
      child: Container(
        width: kSetCardW * s,
        decoration: BoxDecoration(
          color: context.setCard,
          borderRadius: BorderRadius.circular(kSetCardR * s),
        ),
        clipBehavior: Clip.antiAlias,
        padding: EdgeInsets.only(bottom: padBottom * s),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// 设置行：主标题 + 可选副标题 + 可选左侧图标块 + 尾部元素。
///
/// 对齐（实测）：文字 ink 左缘统一 43.0；尾部元素右缘距卡右 25.3。
/// [height] 不给时按有无副标题自动取 93.0 / 64.0。
class V2SetRow extends StatelessWidget {
  const V2SetRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.danger = false,
    this.height,
    this.titleSize,
    this.titleColor,
    this.centerTitleOnly = false,
    this.showChevron = false,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// 红色行（危险操作）：主标题与副标题都用 [kSetDanger]。
  final bool danger;
  final double? height;
  final double? titleSize;

  /// 主标题颜色覆盖。默认 `context.setTitle`（A 型 #121824）；
  /// B 型页面（设备 / 数据 / 通知）实测是**纯黑 #000000**，传 [Colors.black]。
  final Color? titleColor;

  /// 无副标题时，只有一行文字也要**垂直居中**（默认 true 时按行高居中）。
  final bool centerTitleOnly;

  /// 尾部是否自动补一个 `chevron_right`（在 [trailing] 之前）。
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final h = (height ?? (subtitle == null ? kSetRowH1 : kSetRowH)) * s;
    final hasLead = leading != null;
    final textLeft = (hasLead ? 0.0 : (kSetTitleX - kSetCardX)) * s;

    final colors = danger
        ? (context.setDanger, context.setDanger)
        : (titleColor ?? context.setTitle, context.setSub);

    Widget body = Row(
      children: [
        if (hasLead) ...[
          leading!,
          SizedBox(width: 14 * s),
        ],
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: (titleSize ?? kSetTitleSize) * s,
                  fontWeight: FontWeight.w400,
                  height: 1.0,
                  color: colors.$1,
                ),
              ),
              if (subtitle != null) ...[
                SizedBox(height: (subtitle!.isEmpty ? 0 : 11) * s),
                Text(
                  subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: kSetSubSize * s,
                    fontWeight: FontWeight.w400,
                    height: 1.25,
                    color: colors.$2,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (showChevron || trailing != null) SizedBox(width: 12 * s),
        if (showChevron)
          Padding(
            padding: EdgeInsets.only(right: (kSetTailInset - kSetCardX) * s),
            child: V2SetChevron(size: 24),
          ),
        if (trailing != null)
          Padding(
            padding: EdgeInsets.only(
                right: (kSetTailInset - kSetCardX) * s + (showChevron ? 0 : 0)),
            child: trailing!,
          ),
      ],
    );

    body = Padding(
      padding: EdgeInsets.only(left: 22.3 * s, right: 0, top: 0, bottom: 0),
      child: SizedBox(
        height: h,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: EdgeInsets.only(left: textLeft),
            child: body,
          ),
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

/// 右侧箭头（实测 ink 7.3 × 13.3，色 #6C727E）。
class V2SetChevron extends StatelessWidget {
  const V2SetChevron({super.key, this.size = 24, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return Icon(Icons.chevron_right,
        size: size * s, color: color ?? context.setChevron);
  }
}

/// 尾部纯文字（如钱包页「未设置」）。
class V2SetTailText extends StatelessWidget {
  const V2SetTailText(this.text, {super.key, this.color, this.fontSize = 16.2});

  final String text;
  final Color? color;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return Text(
      text,
      style: TextStyle(
        fontSize: fontSize * s,
        fontWeight: FontWeight.w400,
        height: 1.0,
        color: color ?? context.setSub,
      ),
    );
  }
}

/// 开关：67.0 × 41.3，自绘。
///
/// 截图的两种形态（**形状不同，不是同一控件的换色**）：
/// - ON：**实心灰**轨道 #A7A8AA、无描边，**大**滑块 ∅31.3 近黑，靠右（内缩 5.0）
/// - OFF：**透明**轨道 + 2.5 **近黑描边**，**小**滑块 ∅23.0 近黑，靠左（内缩 5.0）
///
/// 不用 Material `Switch`：Material 的 ON 是主色填充 + 白滑块，与截图完全不同，
/// 且尺寸受 `MaterialTapTargetSize` 影响做不到 67×41.3 的精确值。
class V2SetSwitch extends StatelessWidget {
  const V2SetSwitch({super.key, required this.value, this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final w = kSetSwitchW * s;
    final h = kSetSwitchH * s;
    const dur = Duration(milliseconds: 180);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: AnimatedContainer(
        duration: dur,
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: value ? context.setTrackOn : Colors.transparent,
          borderRadius: BorderRadius.circular(h / 2),
          border: value
              ? null
              : Border.all(color: context.setKnob, width: 2.5 * s),
        ),
        child: AnimatedAlign(
          duration: dur,
          curve: Curves.easeOut,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: kSetKnobInset * s),
            child: AnimatedContainer(
              duration: dur,
              width: (value ? kSetKnobOn : kSetKnobOff) * s,
              height: (value ? kSetKnobOn : kSetKnobOff) * s,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: context.setKnob,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 卡片内的「说明段」：多行灰字，左 22.3、字号 16、行距宽松（截图里 1.55）。
class V2SetNote extends StatelessWidget {
  const V2SetNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return Padding(
      padding: EdgeInsets.only(
          left: kSetTitleX * s, right: kSetCardX * s + 10 * s, top: 12 * s),
      child: Text(
        text,
        style: TextStyle(
          fontSize: kSetSubSize * s,
          fontWeight: FontWeight.w400,
          height: 1.55,
          color: context.setSub,
        ),
      ),
    );
  }
}

/// 危险操作行（居中红字，如「退出登录」「重置所有通知设置」）。
class V2SetDangerButton extends StatelessWidget {
  const V2SetDangerButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.height = 73.0,
    this.filled = true,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final double height;

  /// true = 白色卡片内的居中红字（截图的「退出登录」）；false = 直接铺在页面底色上的红字。
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final content = SizedBox(
      height: height * s,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 22 * s, color: context.setDanger),
              SizedBox(width: 10 * s),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: kSetTitleSize * s,
                fontWeight: FontWeight.w500,
                height: 1.0,
                color: context.setDanger,
              ),
            ),
          ],
        ),
      ),
    );
    if (!filled) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: content,
      );
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: kSetCardX * s),
      child: Container(
        decoration: BoxDecoration(
          color: context.setCard,
          borderRadius: BorderRadius.circular(kSetCardR * s),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(onTap: onTap, child: content),
        ),
      ),
    );
  }
}
