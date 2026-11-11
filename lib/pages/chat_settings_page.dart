import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n/app_locale.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';
import '../widgets/v2_kit.dart';
import '../widgets/v2_settings.dart';

// ============================================================================
// 聊天设置页（像素级复刻，2026-09-14）
//
// 参考截图：Screenshot_20260914_203943.jpg（页面本体）
//          Screenshot_20260914_203935.jpg（同页打开的「聊天背景」bottom sheet）
// 物理 1260 / DPR 3 ⇒ 逻辑宽 420，与 v2Scale 基准一致，数字 * v2Scale(context) 落地。
// 逐元素测量见 `UI-ref/measure/measure_chatset_storage.md`。
//
// 为什么用共享 v2_settings.dart 的骨架/卡片/开关，却自己写行（_CsRow）：
//   V2SetRow 在 `leading == null` 时把 title 放在 卡内 22.3（双层 Padding）⇒ 页面 65.3，
//   而实测是 42.0；尾部元素右缘也随之偏 ~1.6。见测量报告「与共享组件的差异」。
//   共享文件不改（多页并行），本页局部覆盖。
// ============================================================================

// ---------- 实测常量（逻辑 px）----------
const double _kTitleX = 42.0; // 行标题 ink 左缘
const double _kTitleSize = 20.5; // 逐字步进实测 20.3~20.5（共享 19.5）
const double _kSubSize = 16.6; // 副标题逐字步进实测 16.56（共享 16.0）
const double _kSubLineH = 1.25; // 副标题行高倍率（实测 ink 步进 20.7）
const double _kTitleSubGap = 7.5; // 主标题盒底 → 副标题盒（实测 7.53）
const double _kSubShift = 3.1; // 有副标题时整体下移 1.55（居中会被抬高的补偿）
const double _kRowSubH = 93.0; // 标题 + 1 行副标题（实测卡高 186.0 = 92.5+0.7+92.8）
const double _kRowSwitchH = 92.7; // 标题 + 开关（媒体组）
const double _kRowBgH = 77.3; // 聊天背景行（缩略图 41.3 + 上下 18）
const double _kRowBubbleH = 67.3; // 气泡颜色行（色圆 31 + 上下 18.15）
const double _kRowFontH = 131.0; // 字体大小行（标题 + 滑杆）
const double _kThumbSize = 41.3; // 聊天背景缩略图边长
const double _kThumbRadius = 10.0;
const double _kDotSize = 31.0; // 气泡颜色圆直径
const double _kDotGap = 5.0;
/// 灰字右缘 = 尾部组（缩略图 / 色圆）左缘 − 11.4
/// 复测：聊天背景行 灰字右 285.3 / 缩略图左 296.7（差 11.4）；
///       气泡颜色行 灰字右 259.7 / 色圆左 271.0（差 11.3）⇒ 两行共用同一规则。
const double _kTailGap = 11.4;
const double _kChevronSize = 27.0; // ink 8.7×14.7 ⇒ size 27
const double _kChevronInset = 21.9; // 箭头盒右缘距卡右
const double _kSwitchInset = 25.4; // 开关右缘距卡右（开关 x 307.0..374.0）
const double _kLabelX = 21.3; // 分组标题 ink 左缘（team-lead 整页扫描复核值）
const double _kLabelSize = 16.5; // 分组标题逐字步进实测 16.4~16.7（共享 A 型默认 15 偏小）
const double _kLabelGapBefore = 34.6; // 卡片底 → 组标题盒（实测 ink 间距 34.8）
const double _kLabelGapAfter = 18.1; // 组标题盒底 → 卡片
const double _kPageTopPad = 32.4; // AppBar 底 115.3 → 首个组标题盒（实测 ink 148.3）

/// 聊天背景预设（截图 sheet 的 2×4 网格，顺序一致）。
/// 3 = 深色涂鸦（参考截图当前选中项）
class ChatBgPreset {
  const ChatBgPreset(this.top, this.bottom,
      {this.doodle = false, this.dark = false});
  final Color top;
  final Color bottom;
  final bool doodle;
  final bool dark;

  LinearGradient get gradient => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [top, bottom],
      );

  /// 涂鸦线颜色：深色底用白（低透明度），浅色底用黑（低透明度）
  Color get doodleColor => dark ? const Color(0x29FFFFFF) : const Color(0x1A000000);

  /// 示例气泡底色（预览卡里 3 条气泡用）
  Color get bubbleFill => dark ? const Color(0xFFF4F4F4) : const Color(0xFFFFFFFF);
}

const List<ChatBgPreset> kChatBgPresets = <ChatBgPreset>[
  ChatBgPreset(Color(0xFFF8F9FB), Color(0xFFE8E9ED)),
  ChatBgPreset(Color(0xFFF5F6F8), Color(0xFFDDE0E6)),
  ChatBgPreset(Color(0xFFE3E4E9), Color(0xFFA5ABB7), doodle: true),
  ChatBgPreset(Color(0xFF121927), Color(0xFF3D3D42), doodle: true, dark: true),
  ChatBgPreset(Color(0xFFECF3FD), Color(0xFFDCE9F8)),
  ChatBgPreset(Color(0xFFD9F0FE), Color(0xFFBFE4FC)),
  ChatBgPreset(Color(0xFF141A28), Color(0xFF2E3038), doodle: true, dark: true),
  ChatBgPreset(Color(0xFF131826), Color(0xFF2A2C34), doodle: true, dark: true),
  // ---- 纯色背景（sheet 的「纯色背景」按钮专用，**不进**上面 2×4 参考网格）----
  // top == bottom ⇒ 纯色；从 [kSolidBgStart] 起追加，按索引取值的地方不受影响
  ChatBgPreset(Color(0xFFFFFFFF), Color(0xFFFFFFFF)),
  ChatBgPreset(Color(0xFFEEF2F7), Color(0xFFEEF2F7)),
  ChatBgPreset(Color(0xFFE7F3EC), Color(0xFFE7F3EC)),
  ChatBgPreset(Color(0xFFF7F1E8), Color(0xFFF7F1E8)),
];

/// 参考网格（2×4，前 8 个预设）之后的纯色预设起点（sheet 底部按钮用）
const int kSolidBgStart = 8;

/// 气泡颜色预设（参考图 bf71...37.jpg 的「气泡颜色」sheet，5×2 网格逐格 PIL 取色）。
/// 每组 = （收到的浅色, 发送的彩色）成对：recv 作用于对方气泡、sent 作用于我的气泡。
/// 索引 9 = 网格右下角的「默认」格（白卡黑描边 + ✓），与预览卡两只气泡同色。
class ChatBubblePreset {
  const ChatBubblePreset(this.recv, this.sent);
  final Color recv; // 收到的消息（对方气泡底色）
  final Color sent; // 发送的消息（我的气泡底色）
}

const List<ChatBubblePreset> kChatBubblePresets = <ChatBubblePreset>[
  ChatBubblePreset(Color(0xFFF5F3FF), Color(0xFFDDD6FF)), // 紫
  ChatBubblePreset(Color(0xFFFEFBEA), Color(0xFFFEF3C6)), // 黄
  ChatBubblePreset(Color(0xFFEFF6FF), Color(0xFF92C5FC)), // 蓝
  ChatBubblePreset(Color(0xFFECFDF5), Color(0xFF86EFAC)), // 绿
  ChatBubblePreset(Color(0xFFFFF6ED), Color(0xFFFED8AB)), // 橙
  ChatBubblePreset(Color(0xFFFDE7F3), Color(0xFFF9A8D3)), // 粉
  ChatBubblePreset(Color(0xFFFFFFFF), Color(0xFFF1F4F9)), // 灰白
  ChatBubblePreset(Color(0xFFF9FAFC), Color(0xFFE1E8F0)), // 蓝灰
  ChatBubblePreset(Color(0xFFFAFAF8), Color(0xFFE6E5E3)), // 暖灰
  // 2026-09-28：默认配色改为 TG 同款——对方白色、自己 #EFFDDE（浅绿）
  ChatBubblePreset(Color(0xFFFFFFFF), Color(0xFFEFFDDE)), // 默认
];

class ChatSettingsPage extends StatefulWidget {
  const ChatSettingsPage({super.key, this.onBack});

  /// 返回回调（不传则 pop）
  final VoidCallback? onBack;

  @override
  State<ChatSettingsPage> createState() => _ChatSettingsPageState();
}

class _ChatSettingsPageState extends State<ChatSettingsPage> {
  final AppSettings _set = AppSettings.instance;

  @override
  void initState() {
    super.initState();
    _set.addListener(_onChanged);
  }

  @override
  void dispose() {
    _set.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 当前选中的气泡配对（收/发成对，越界兜底到默认档）
  ChatBubblePreset get _bubblePreset => kChatBubblePresets[
      _set.chatBubbleColor.clamp(0, kChatBubblePresets.length - 1)];

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final t = AppLocalizations.of(context).t;

    return V2SetScaffold(
      title: t('meRowChatSettings'),
      onBack: widget.onBack,
      padding: EdgeInsets.only(top: _kPageTopPad * s, bottom: 40 * s),
      children: [
        // ===== 消息 =====
        V2SetSectionLabel(t('csetGrpMsg'), left: _kLabelX, fontSize: _kLabelSize),
        SizedBox(height: _kLabelGapAfter * s),
        V2SetCard(rows: [
          _CsRow(
            height: _kRowSubH,
            title: t('csetMsgPreview'),
            subtitle: t('csetMsgPreviewDesc'),
            trailingInset: _kSwitchInset,
            trailing: V2SetSwitch(
              value: _set.chatMsgPreview,
              onChanged: _set.setChatMsgPreview,
            ),
          ),
          _CsRow(
            height: _kRowSubH,
            title: t('csetLinkPreview'),
            subtitle: t('csetLinkPreviewDesc'),
            trailingInset: _kSwitchInset,
            trailing: V2SetSwitch(
              value: _set.chatLinkPreview,
              onChanged: _set.setChatLinkPreview,
            ),
          ),
        ]),
        // ===== 外观 =====
        SizedBox(height: _kLabelGapBefore * s),
        V2SetSectionLabel(t('csetGrpLook'), left: _kLabelX, fontSize: _kLabelSize),
        SizedBox(height: _kLabelGapAfter * s),
        V2SetCard(rows: [
          _CsRow(
            height: _kRowBgH,
            title: t('csetChatBg'),
            onTap: () => _openBackgroundSheet(context),
            tail: t('csetChatBgCustom'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ChatBgThumb(preset: kChatBgPresets[_set.chatBackground]),
                SizedBox(width: 12.5 * s),
                const V2SetChevron(size: _kChevronSize),
              ],
            ),
          ),
          _CsRow(
            height: _kRowBubbleH,
            title: t('csetBubbleColor'),
            onTap: () => _openBubbleSheet(context),
            tail: t('csetBubbleDefault'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 当前配对的收/发两色作指示（点按行打开「气泡颜色」sheet 选择）
                _BubbleDot(color: _bubblePreset.recv),
                SizedBox(width: _kDotGap * s),
                _BubbleDot(color: _bubblePreset.sent),
                SizedBox(width: 12.5 * s),
                const V2SetChevron(size: _kChevronSize),
              ],
            ),
          ),
          _FontSizeRow(
            height: _kRowFontH,
            title: t('csetFontSize'),
            small: t('csetFontSmall'),
            large: t('csetFontLarge'),
            level: _set.chatFontLevel,
            onLevel: _set.setChatFontLevel,
          ),
        ]),
        // ===== 媒体 =====
        SizedBox(height: _kLabelGapBefore * s),
        V2SetSectionLabel(t('csetGrpMedia'), left: _kLabelX, fontSize: _kLabelSize),
        SizedBox(height: _kLabelGapAfter * s),
        V2SetCard(rows: [
          _CsRow(
            height: _kRowSwitchH,
            title: t('csetAutoDlImage'),
            trailingInset: _kSwitchInset,
            trailing: V2SetSwitch(
              value: _set.autoDownloadImage,
              onChanged: _set.setAutoDownloadImage,
            ),
          ),
          _CsRow(
            height: _kRowSwitchH,
            title: t('csetAutoDlVideo'),
            trailingInset: _kSwitchInset,
            trailing: V2SetSwitch(
              value: _set.autoDownloadVideo,
              onChanged: _set.setAutoDownloadVideo,
            ),
          ),
        ]),
      ],
    );
  }

  Future<void> _openBackgroundSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      // 实测：页面被压成 #717171（页面底色 #F6F7F9 × 0.46）⇒ black54
      barrierColor: Colors.black54,
      // 点空白（遮罩）关闭：showModalBottomSheet 固定 barrierDismissible=true，
      // sheet 内容区未包全屏手势，点外部即 pop（第十二批追加核查确认）
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      builder: (_) => const _ChatBackgroundSheet(),
    );
  }

  /// 「气泡颜色」bottom sheet（第九批返工：参考图 bf71...37.jpg 的完整弹层）
  Future<void> _openBubbleSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      barrierColor: Colors.black54,
      // 点空白（遮罩）关闭：同背景 sheet，框架固定 barrierDismissible=true
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      builder: (_) => const _ChatBubbleSheet(),
    );
  }
}

/// 设置行（本页局部实现，尺寸按实测）。
///
/// ⚠️ **技术债**：这里绕开了共享 `V2SetRow`，因为后者有两处已知偏差：
///   1. `leading == null` 时 title 盒左缘落在卡内 **44.6**，目标 **43.0**（偏右 1.6）；
///   2. 尾部元素（缩略图 / 色圆 / 箭头）右缘整体偏 **~1.6px**。
/// 本页两行恰好都是「无 leading + 尾部自定义 widget」，直接复用会两点都偏。
/// team-lead 裁定本批**不改共享件**（`V2SetRow` 被 5 个页面消费、其中 3 个正在被并行修改，
/// 现在动几何会让已量准的页面测量全部失效），下一轮单独做一次共享件几何统一；
/// 届时本类可整体删除、改回 `V2SetRow`。详见
/// `UI-ref/measure/audit_chatset_storage.md` §5「共享件偏差与绕开方式」。
class _CsRow extends StatelessWidget {
  const _CsRow({
    required this.height,
    required this.title,
    this.subtitle,
    this.tail,
    this.trailing,
    this.trailingInset = _kChevronInset,
    this.onTap,
  });

  final double height;
  final String title;
  final String? subtitle;

  /// 尾部左侧的灰字（如「自定义聊天背景」「默认」），右对齐到 [_kTrailRight]
  final String? tail;
  final Widget? trailing;
  final double trailingInset;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final sub = subtitle;
    Widget content = SizedBox(
      height: height * s,
      child: Padding(
        padding: EdgeInsets.only(
            left: (_kTitleX - kSetCardX) * s, right: trailingInset * s),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 有副标题的行实测比「垂直居中」低 1.9（标题 ink 206.7 vs 居中 204.8）
                  if (sub != null) SizedBox(height: _kSubShift * s),
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: _kTitleSize * s,
                      fontWeight: FontWeight.w400,
                      height: 1.0,
                      color: context.setTitle,
                    ),
                  ),
                  if (sub != null) ...[
                    SizedBox(height: _kTitleSubGap * s),
                    Text(
                      sub,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: _kSubSize * s,
                        fontWeight: FontWeight.w400,
                        height: _kSubLineH,
                        color: context.setSub,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (tail != null) ...[
              V2SetTailText(tail!),
              SizedBox(width: _kTailGap * s),
            ],
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
    if (onTap == null) return content;
    content = InkWell(onTap: onTap, child: content);
    return content;
  }
}

/// 聊天背景缩略图：41.3 圆角方，深色底 + 抽象涂鸦
class _ChatBgThumb extends StatelessWidget {
  const _ChatBgThumb({required this.preset});

  final ChatBgPreset preset;
  static const double size = _kThumbSize;
  static const double radius = _kThumbRadius;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return Container(
      width: size * s,
      height: size * s,
      decoration: BoxDecoration(
        gradient: preset.gradient,
        borderRadius: BorderRadius.circular(radius * s),
      ),
      clipBehavior: Clip.antiAlias,
      child: preset.doodle
          ? CustomPaint(painter: _DoodlePainter(color: preset.doodleColor, cells: 3))
          : null,
    );
  }
}

/// 气泡颜色圆：31 直径 + 1px 描边（第九批起作「当前配对」指示，选中态移入 sheet 格子）
class _BubbleDot extends StatelessWidget {
  const _BubbleDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return Container(
      width: _kDotSize * s,
      height: _kDotSize * s,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: _dotBorder(color), width: 1.0 * s),
      ),
    );
  }

  static Color _dotBorder(Color c) {
    final h = HSLColor.fromColor(c);
    return h.withLightness((h.lightness - 0.07).clamp(0.0, 1.0)).toColor();
  }
}

/// 字体大小行：标题 + 下方滑杆（7 档，两端「小」「大」，大字号更大）
class _FontSizeRow extends StatelessWidget {
  const _FontSizeRow({
    required this.height,
    required this.title,
    required this.small,
    required this.large,
    required this.level,
    required this.onLevel,
  });

  final double height;
  final String title;
  final String small;
  final String large;
  final int level;
  final ValueChanged<int> onLevel;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return SizedBox(
      height: height * s,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: 19.45 * s),
          Padding(
            padding: EdgeInsets.only(left: (_kTitleX - kSetCardX) * s),
            child: Text(
              title,
              style: TextStyle(
                fontSize: _kTitleSize * s,
                fontWeight: FontWeight.w400,
                height: 1.0,
                color: context.setTitle,
              ),
            ),
          ),
          Expanded(
            child: Padding(
              // 小 左缘 42.0（页面）；大 右缘 377.3 ⇒ 卡右内缩 22.1
              padding: EdgeInsets.only(
                  left: (_kTitleX - kSetCardX) * s, right: 20.3 * s),
              child: Row(
                children: [
                  SizedBox(
                    width: 16 * s,
                    child: Text(
                      small,
                      style: TextStyle(
                        fontSize: 16 * s,
                        height: 1.0,
                        color: context.setSub,
                      ),
                    ),
                  ),
                  SizedBox(width: 29 * s),
                  Expanded(
                    child: _LevelSlider(level: level, onLevel: onLevel),
                  ),
                  SizedBox(width: 30 * s),
                  SizedBox(
                    width: 26 * s,
                    child: Text(
                      large,
                      style: TextStyle(
                        fontSize: 26 * s,
                        height: 1.0,
                        color: context.setSub,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 7 档滑杆：轨道高 5.3（未填充）/ 7.3（已填充，近黑）+ ∅25.5 滑块 + 7 个刻度点。
/// 刻度颜色随所在区段反转（深色轨道上为浅点，浅色轨道上为深点）——实测如此。
class _LevelSlider extends StatelessWidget {
  const _LevelSlider({required this.level, required this.onLevel});

  final int level;
  final ValueChanged<int> onLevel;

  static const int steps = 6; // 0..6 ⇒ 7 档

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      final stepW = w <= 0 ? 0.0 : (w - 2 * _tickInset(s)) / steps;
      void handle(Offset local) {
        if (stepW <= 0) return;
        final i = ((local.dx - _tickInset(s)) / stepW).round().clamp(0, steps);
        onLevel(i);
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => handle(d.localPosition),
        onHorizontalDragUpdate: (d) => handle(d.localPosition),
        child: SizedBox(
          height: 26 * s,
          width: w,
          child: CustomPaint(
            painter: _LevelSliderPainter(
              level: level,
              scale: s,
              dark: context.v2IsDark,
            ),
          ),
        ),
      );
    });
  }

  /// 刻度内缩（实测：首刻度 89.5、末刻度 319.7，轨道 87.0..322.7）
  static double _tickInset(double s) => 2.6 * s;
}

class _LevelSliderPainter extends CustomPainter {
  _LevelSliderPainter({required this.level, required this.scale, required this.dark});

  final int level;
  final double scale;
  final bool dark;

  static const int steps = 6;

  @override
  void paint(Canvas canvas, Size size) {
    final s = scale;
    final cy = size.height / 2;
    final inset = 2.6 * s;
    final stepW = (size.width - 2 * inset) / steps;
    final knobX = inset + stepW * level;

    final track = Paint()..color = dark ? const Color(0xFF3A3A3C) : const Color(0xFFE5E5E5);
    final fill = Paint()..color = dark ? const Color(0xFFFFFFFF) : kSetKnob;

    // 未填充轨道（细）
    final tr = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, cy - 2.65 * s, size.width, 5.3 * s),
      Radius.circular(2.65 * s),
    );
    canvas.drawRRect(tr, track);

    // 已填充（粗）
    if (knobX > 0) {
      final fr = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, cy - 3.65 * s, knobX, 7.3 * s),
        Radius.circular(3.65 * s),
      );
      canvas.drawRRect(fr, fill);
    }

    // 刻度点（区内反色）
    for (var i = 0; i <= steps; i++) {
      final x = inset + stepW * i;
      final c = x < knobX ? track.color : fill.color;
      canvas.drawCircle(Offset(x, cy), 1.3 * s, Paint()..color = c);
    }

    // 滑块
    canvas.drawCircle(Offset(knobX, cy), 12.75 * s, Paint()..color = fill.color);
  }

  @override
  bool shouldRepaint(covariant _LevelSliderPainter old) =>
      old.level != level || old.dark != dark || old.scale != scale;
}

// ============================================================================
// 聊天背景 bottom sheet（参考图 clipboard-...759Z-5e1dc237.jpg）
// 实测：sheet 顶 y=137.3、顶角 r=26、白底；拖拽条 51.3×5.3（y 152.7~158.0）；
//      标题「聊天背景」ink 21.7..121.7 / y 197.7..221.4（h 23.7 ⇒ 字号 25、w600）；
//      「完成」ink 340.3..376.6 / y 200.0..218.0（h 18.0 ⇒ 字号 18.2、w500）；
//      预览卡 378.7×359.3（x 20.7..399.3 / y 260.7..620.0）、r≈21、深色渐变 + 涂鸦；
//      3 条气泡 h=46.3（r=23.15 胶囊）：x 41.0(卡内 20.3)/167.0/20.3，
//        y 337.7/414.7/491.7（卡内 77.0/154.0/231.0），宽 191.3/191.3/129.3，
//        b1/b3 填充 #F4F4F4、b2 填充 #D4D3D8；
//      缩略图 2×4：83.3×111.0、列距 15.27（网格总宽 379.0）、行距 15.0、
//        r=14、选中项 3.4 近黑描边 + 右上 ∅26.5 勾选徽标（右内缩 11.3 / 上内缩 11.5）；
//      底部按钮条：白底、两个 181.7×56.6 按钮（r=16、#F5F5F5）。
// ============================================================================
const double _kSheetTop = 220.0; // 第十二批追加紧凑化：原参考值 137.3，sheet 顶下移、整体变矮
const double _kSheetRadius = 26.0;
// sheet 内：拖拽条上留白 15.4 + 条 5.3 + 标题行 102.7 ⇒ 预览卡顶 123.4
const double _kCardW = 378.7; // 实测 x 20.7..399.3
const double _kCardH = 359.3; // 实测 y 260.7..620.0（sheet 内 123.4 起）
const double _kCardRadius = 21.0; // 顶角实测 ~21~22
const double _kCardTileGap = 20.0; // 第十二批追加：原 31.0（参考值），卡底 → 缩略图行1 顶
const double _kTileW = 83.3;
const double _kTileH = 111.0;
const double _kTileGapX = 15.27; // 4 列总宽 379.0，等分列距
const double _kTileGapY = 12.0; // 第十二批追加：原 15.0（参考值），行1 底 → 行2 顶
const double _kTileGridW = 379.0; // 缩略图网格总宽（左 20.5 / 右 20.5）
const double _kTileRadius = 14.0; // 逐 y 扫边实测 r≈14
const double _kTileRing = 3.4; // 选中黑描边厚度（实测左 316.3..319.7、右 395.6..398.9）
const double _kBadgeSize = 26.5; // 勾选徽标直径（白勾 ink 12.7×9.7 居中其上）
const double _kBadgeRight = 11.3; // 徽标右缘距 tile 右缘
const double _kBadgeTop = 11.5; // 徽标上缘距 tile 上缘
const double _kBubbleH = 46.3;
const double _kBubbleRadius = 23.15; // 胶囊（= 高 / 2）
const double _kBubbleInset = 20.3; // 气泡距卡左/右缘
const double _kBubblePadX = 20.7; // 气泡内左右留白
const double _kDoneRight = 35.4; // 「完成」ink 右缘 376.6（含 8 的点击热区）
// 底部按钮条 = 上 20.4 + 按钮 56.6 + 下 41.4 = 118.4
const double _kBtnH = 56.6;
const double _kSheetBtnGap = 15.4;

class _ChatBackgroundSheet extends StatefulWidget {
  const _ChatBackgroundSheet();

  @override
  State<_ChatBackgroundSheet> createState() => _ChatBackgroundSheetState();
}

class _ChatBackgroundSheetState extends State<_ChatBackgroundSheet> {
  final AppSettings _set = AppSettings.instance;

  @override
  void initState() {
    super.initState();
    _set.addListener(_onChanged);
  }

  @override
  void dispose() {
    _set.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final t = AppLocalizations.of(context).t;
    final screenH = MediaQuery.sizeOf(context).height;
    final sheetH = math.min((screenH - _kSheetTop * s), screenH * 0.85);
    final preset = kChatBgPresets[_set.chatBackground.clamp(0, kChatBgPresets.length - 1)];

    // ⚠️ 不能用 Align(bottomCenter) 包这里：BottomSheetLayout 给 child 的约束
    // 是「宽 tight、高 loose(≤全屏)」，Align 会扩满全屏 → BottomSheet 的透明
    // Material 也全屏 → 其 ink 层(opaque) 吃掉遮罩区点击 → **点空白无法关闭**。
    // 直接返回固定高 SizedBox：框架本身就把 child 底对齐并从底部滑入
    // （_getPositionForChild：size.height − childSize.height × animationValue）。
    return SizedBox(
      height: sheetH,
      child: Container(
        decoration: BoxDecoration(
          color: context.setCard,
          borderRadius: BorderRadius.vertical(top: Radius.circular(_kSheetRadius * s)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
            children: [
              Positioned.fill(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(height: 10.0 * s),
                      // 拖拽条
                      Center(
                        child: Container(
                          width: 51.3 * s,
                          height: 5.3 * s,
                          decoration: BoxDecoration(
                            color: const Color(0xFFE2E2E2),
                            borderRadius: BorderRadius.circular(2.65 * s),
                          ),
                        ),
                      ),
                      // 标题行（原参考值 102.7，第十二批追加紧凑化 → 64.0）
                      SizedBox(
                        height: 64.0 * s,
                        child: Padding(
                          padding: EdgeInsets.only(left: 21.7 * s, right: _kDoneRight * s),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  t('csetChatBg'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 25 * s,
                                    fontWeight: FontWeight.w600,
                                    height: 1.0,
                                    color: context.setTitle,
                                  ),
                                ),
                              ),
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => Navigator.of(context).maybePop(),
                                child: Padding(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: 8 * s, vertical: 6 * s),
                                  child: Text(
                                    t('massDone'),
                                    style: TextStyle(
                                      fontSize: 18.2 * s,
                                      fontWeight: FontWeight.w500,
                                      height: 1.0,
                                      color: const Color(0xFF0C0D11),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // 预览卡
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: (420 - _kCardW) / 2 * s),
                        child: _ChatPreviewCard(preset: preset),
                      ),
                      SizedBox(height: _kCardTileGap * s),
                      // 缩略图网格 2×4（第九批返工：一排 4 个，与参考几何一致；
                      // 原来 Wrap 因 4×83.3+3×15.27=379.01 比容器宽 0.01 被挤成 3 个）
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: (420 - _kTileGridW) / 2 * s),
                        child: GridView.count(
                          crossAxisCount: 4,
                          mainAxisSpacing: _kTileGapY * s,
                          crossAxisSpacing: _kTileGapX * s,
                          childAspectRatio: _kTileW / _kTileH,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          padding: EdgeInsets.zero,
                          children: [
                            // 只显示参考网格里的 8 个预设（后面的纯色预设走「纯色背景」按钮）
                            for (var i = 0;
                                i < kSolidBgStart && i < kChatBgPresets.length;
                                i++)
                              _ChatBgTile(
                                preset: kChatBgPresets[i],
                                selected: i == _set.chatBackground,
                                onTap: () => _set.setChatBackground(i),
                              ),
                          ],
                        ),
                      ),
                      SizedBox(height: 16.0 * s),
                    ],
                  ),
                ),
              ),
              // 底部按钮条（白底，盖住网格第二行 —— 与截图一致）
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: context.setCard,
                  padding: EdgeInsets.only(
                    top: 14.0 * s,
                    left: 20.3 * s,
                    right: 20.3 * s,
                    bottom: 28.0 * s,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _SheetButton(
                          icon: Icons.photo_library,
                          label: t('regFromGallery'),
                          // 相册选图 → 自定义聊天背景（真实生效）
                          onTap: () => _pickCustomBg(context),
                        ),
                      ),
                      SizedBox(width: _kSheetBtnGap * s),
                      Expanded(
                        child: _SheetButton(
                          icon: Icons.palette,
                          label: t('csetBgSolid'),
                          // 纯色背景：从纯色预设里选（真实写入 setChatBackground）
                          onTap: () => _pickSolidBg(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
    );
  }

  /// 「从相册选择」：选图 → 存为自定义聊天背景（真实生效，聊天页即时刷新）。
  ///
  /// 路径用 [AppSettings.setChatCustomBgPath] 持久化。注意 image_picker 给的是
  /// 应用缓存目录里的临时路径，系统清缓存后文件会丢 —— chat_page 读不到文件时
  /// 自动回退预设渐变（优雅降级）；等引入 path_provider 后再复制到文档目录永久化。
  Future<void> _pickCustomBg(BuildContext context) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 85,
    );
    if (picked == null || !context.mounted) return;
    await _set.setChatCustomBgPath(picked.path);
  }

  /// 「纯色背景」：从纯色预设（index [kSolidBgStart]..）里选一个，真实写入
  /// `setChatBackground`，聊天页即时生效。用色卡弹窗而不是文字 actionSheet——
  /// 颜色没有现成词条（不改 l10n），色卡本身就是语义。
  Future<void> _pickSolidBg(BuildContext context) async {
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) {
        final ss = v2Scale(ctx);
        return AlertDialog(
          title: Text(AppLocalizations.of(ctx).t('csetBgSolid')),
          contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
          content: Wrap(
            spacing: 14 * ss,
            runSpacing: 14 * ss,
            children: [
              for (var i = kSolidBgStart; i < kChatBgPresets.length; i++)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(ctx).pop(i),
                  child: Container(
                    width: 46 * ss,
                    height: 46 * ss,
                    decoration: BoxDecoration(
                      color: kChatBgPresets[i].top,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: i == _set.chatBackground
                            ? kSetKnob
                            : const Color(0xFFD9D9DE),
                        width: (i == _set.chatBackground ? 2.4 : 1.0) * ss,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
    if (picked == null) return;
    await _set.setChatBackground(picked);
  }
}

/// 预览卡：深色渐变 + 涂鸦 + 3 条示例气泡（实测 379.3×358.8，r=20，带下方软阴影）
class _ChatPreviewCard extends StatelessWidget {
  const _ChatPreviewCard({required this.preset});

  final ChatBgPreset preset;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final t = AppLocalizations.of(context).t;
    final bubbles = <(double, double, String, Color, Color)>[
      // (left, top, text, fill, textColor)
      (_kBubbleInset, 77.0, t('csetBgHello'), preset.bubbleFill, const Color(0xFF1C1C1C)),
      (167.0, 154.0, t('csetBgGreat'), const Color(0xFFD4D3D8), const Color(0xFF1C1C1C)),
      (_kBubbleInset, 231.0, t('csetBgMeToo'), preset.bubbleFill, const Color(0xFF1C1C1C)),
    ];
    return Container(
      width: _kCardW * s,
      height: _kCardH * s,
      decoration: BoxDecoration(
        gradient: preset.gradient,
        borderRadius: BorderRadius.circular(_kCardRadius * s),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 18 * s,
            offset: Offset(0, 4 * s),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          if (preset.doodle)
            Positioned.fill(
              child: CustomPaint(painter: _DoodlePainter(color: preset.doodleColor, cells: 7)),
            ),
          for (final b in bubbles)
            Positioned(
              left: b.$1 * s,
              top: b.$2 * s,
              child: Container(
                height: _kBubbleH * s,
                padding: EdgeInsets.symmetric(horizontal: _kBubblePadX * s),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: b.$4,
                  borderRadius: BorderRadius.circular(_kBubbleRadius * s),
                ),
                child: Text(
                  b.$3,
                  style: TextStyle(
                    fontSize: 16.6 * s,
                    height: 1.0,
                    color: b.$5,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 背景缩略图（83.3×111.0，r=14；选中：3.4 近黑描边 + 右上 ∅26.5 勾选徽标）
class _ChatBgTile extends StatelessWidget {
  const _ChatBgTile({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final ChatBgPreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: _kTileW * s,
        height: _kTileH * s,
        child: Stack(
          children: [
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: preset.gradient,
                  borderRadius: BorderRadius.circular(_kTileRadius * s),
                  border: selected
                      ? Border.all(color: kSetKnob, width: _kTileRing * s)
                      : null,
                ),
                clipBehavior: Clip.antiAlias,
                child: preset.doodle
                    ? CustomPaint(painter: _DoodlePainter(color: preset.doodleColor, cells: 4))
                    : null,
              ),
            ),
            if (selected)
              Positioned(
                right: _kBadgeRight * s,
                top: _kBadgeTop * s,
                child: Container(
                  width: _kBadgeSize * s,
                  height: _kBadgeSize * s,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: kSetKnob,
                  ),
                  child: Icon(Icons.check, size: 15.4 * s, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// 气泡颜色 bottom sheet（第九批返工，参考图 bf71...37.jpg，物理 1260×2750 / DPR3）
// 实测（logical = px/3）：sheet 顶 y=275.0、白底、顶角 r=26、拖拽条同背景 sheet；
//   标题「气泡颜色」左对齐 ink x=23（与背景 sheet 头部同构：条 15.4+5.3 + 标题行 102.7）；
//   「完成」ink 右缘 374.3；预览卡 378.7×230.3（r=21，深色渐变 #141A28→#3C3D42 + 白涂鸦），
//   左白气泡(#F4F4F4)「收到的消息」(卡内 20.3, 51.3)、右灰气泡(#D4D3D8)「发送的消息」
//   (右缩进 20.3, y 135.7)，h=46.3 与背景 sheet 预览气泡一致；
//   「预设配色」标签 ink x=21.3 / #6B717D；网格 5 列：tile 65.3×58.7（r=14），
//   白底 + 1px #F1F1F1 描边，内上下两胶囊 46.2×18.2（全圆角 r=9.1，左右缩进 9.4、
//   上 8.3 / 中缝 6.2 / 下 7.7），列距 13.0、行距 31.3；
//   选中格 #0C0D12 描边 2.7 + 底边中央 ∅18 黑圆 ✓ 徽标（压底边，下探 ~9）。
// ============================================================================
const double _kBblSheetTop = 340.0; // 第十二批追加紧凑化：原参考值 275.0（y=825/3），sheet 顶下移
const double _kBblCardH = 230.3; // 预览卡高（691/3；宽/圆角复用 _kCardW/_kCardRadius）
const double _kBblRecvTop = 51.3; // 收到气泡距卡顶
const double _kBblSentTop = 135.7; // 发送气泡距卡顶
const double _kBblLabelGapBefore = 14.0; // 第十二批追加：原 24.2（参考值），卡底 → 标签盒
const double _kBblLabelGapAfter = 24.0; // 第十二批追加：原 47.8（参考值），标签盒 → 网格
const double _kBblGridGapX = 13.0; // 列距（5 列总宽 379.0 = _kTileGridW）
const double _kBblGridGapY = 20.0; // 第十二批追加：原 31.3（参考值），行距
const double _kBblTileW = 65.3;
const double _kBblTileH = 58.7;
const double _kBblTileBorder = 1.0; // 未选中描边 #F1F1F1
const double _kBblTileRing = 2.7; // 选中描边 #0C0D12（实测 8px/3）
const double _kBblCapW = 46.2;
const double _kBblCapH = 18.2;
const double _kBblCapRadius = 9.1;
const double _kBblCapInsetX = 9.4; // （参考上留白 8.3 已由 Column.center 均分替代）
const double _kBblCapMidGap = 6.2;
const double _kBblBadgeSize = 18.0; // ✓ 徽标（压底边中央，下探 9）

class _ChatBubbleSheet extends StatefulWidget {
  const _ChatBubbleSheet();

  @override
  State<_ChatBubbleSheet> createState() => _ChatBubbleSheetState();
}

class _ChatBubbleSheetState extends State<_ChatBubbleSheet> {
  final AppSettings _set = AppSettings.instance;

  @override
  void initState() {
    super.initState();
    _set.addListener(_onChanged);
  }

  @override
  void dispose() {
    _set.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final t = AppLocalizations.of(context).t;
    final screenH = MediaQuery.sizeOf(context).height;
    final sheetH = math.min((screenH - _kBblSheetTop * s), screenH * 0.85);
    final preset = kChatBubblePresets[
        _set.chatBubbleColor.clamp(0, kChatBubblePresets.length - 1)];

    // ⚠️ 不能用 Align(bottomCenter) 包这里（同背景 sheet）：Align 扩满全屏
    // → BottomSheet 透明 Material 全屏 → ink 层吃掉遮罩点击 → 点空白关不掉。
    return SizedBox(
      height: sheetH,
      child: Container(
        decoration: BoxDecoration(
          color: context.setCard,
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(_kSheetRadius * s)),
        ),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: 10.0 * s),
                // 拖拽条
                Center(
                  child: Container(
                    width: 51.3 * s,
                    height: 5.3 * s,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE2E2E2),
                      borderRadius: BorderRadius.circular(2.65 * s),
                    ),
                  ),
                ),
                // 标题行（同背景 sheet：原参考值 102.7，第十二批追加紧凑化 → 64.0）
                SizedBox(
                  height: 64.0 * s,
                  child: Padding(
                    padding: EdgeInsets.only(
                        left: 21.7 * s, right: _kDoneRight * s),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            t('csetBubbleColor'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 25 * s,
                              fontWeight: FontWeight.w600,
                              height: 1.0,
                              color: context.setTitle,
                            ),
                          ),
                        ),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => Navigator.of(context).maybePop(),
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 8 * s, vertical: 6 * s),
                            child: Text(
                              t('massDone'),
                              style: TextStyle(
                                fontSize: 18.2 * s,
                                fontWeight: FontWeight.w500,
                                height: 1.0,
                                color: const Color(0xFF0C0D11),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // 预览卡（深色涂鸦 + 当前配对的两只示例气泡）
                Padding(
                  padding:
                      EdgeInsets.symmetric(horizontal: (420 - _kCardW) / 2 * s),
                  child: _BubbleColorPreviewCard(preset: preset),
                ),
                SizedBox(height: _kBblLabelGapBefore * s),
                // 「预设配色」标签
                Padding(
                  padding: EdgeInsets.only(left: _kLabelX * s),
                  child: Text(
                    t('csetBubblePresetColors'),
                    style: TextStyle(
                      fontSize: _kLabelSize * s,
                      height: 1.0,
                      color: const Color(0xFF6B717D),
                    ),
                  ),
                ),
                SizedBox(height: _kBblLabelGapAfter * s),
                // 5 列预设网格
                Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: (420 - _kTileGridW) / 2 * s),
                  child: GridView.count(
                    crossAxisCount: 5,
                    mainAxisSpacing: _kBblGridGapY * s,
                    crossAxisSpacing: _kBblGridGapX * s,
                    childAspectRatio: _kBblTileW / _kBblTileH,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    // 选中格的 ✓ 徽标压出 tile 底边 ⇒ 不裁剪
                    clipBehavior: Clip.none,
                    padding: EdgeInsets.zero,
                    children: [
                      for (var i = 0; i < kChatBubblePresets.length; i++)
                        _ChatBubbleTile(
                          preset: kChatBubblePresets[i],
                          selected: i == _set.chatBubbleColor,
                          onTap: () => _set.setChatBubbleColor(i),
                        ),
                    ],
                  ),
                ),
                SizedBox(height: 28.0 * s),
              ],
            ),
          ),
        ),
    );
  }
}

/// 气泡颜色预览卡：深色渐变 + 参考图涂鸦线稿 + 左「收到的消息」/ 右「发送的消息」
class _BubbleColorPreviewCard extends StatelessWidget {
  const _BubbleColorPreviewCard({required this.preset});

  final ChatBubblePreset preset;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final t = AppLocalizations.of(context).t;
    final bubbles = <(bool, double, String, Color)>[
      // (是否左侧, top, text, fill)
      (true, _kBblRecvTop, t('csetBubbleRecvMsg'), preset.recv),
      (false, _kBblSentTop, t('csetBubbleSendMsg'), preset.sent),
    ];
    return Container(
      width: _kCardW * s,
      height: _kBblCardH * s,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF141A28), Color(0xFF3C3D42)],
        ),
        borderRadius: BorderRadius.circular(_kCardRadius * s),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 18 * s,
            offset: Offset(0, 4 * s),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // 参考图同款白色涂鸦线稿（透明 PNG；与聊天背景共用一份 asset）
          Positioned.fill(
            child: Image.asset('assets/chat_bg_doodle.png', fit: BoxFit.cover),
          ),
          for (final b in bubbles)
            Positioned(
              left: b.$1 ? _kBubbleInset * s : null,
              right: b.$1 ? null : _kBubbleInset * s,
              top: b.$2 * s,
              child: Container(
                height: _kBubbleH * s,
                padding: EdgeInsets.symmetric(horizontal: _kBubblePadX * s),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: b.$4,
                  borderRadius: BorderRadius.circular(_kBubbleRadius * s),
                ),
                child: Text(
                  b.$3,
                  style: TextStyle(
                    fontSize: 16.6 * s,
                    height: 1.0,
                    color: const Color(0xFF1C1C1C),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 气泡配色格（65.3×58.7 白卡）：上下两胶囊 = 收到的浅色 / 发送的彩色；
/// 选中：#0C0D12 描边 2.7 + 底边中央 ∅18 黑圆 ✓（压边，下探 ~9）
class _ChatBubbleTile extends StatelessWidget {
  const _ChatBubbleTile({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final ChatBubblePreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            height: double.infinity, // 填满 grid cell（结构上内容不可能溢出，见下）
            decoration: BoxDecoration(
              color: const Color(0xFFFFFFFF),
              borderRadius: BorderRadius.circular(_kTileRadius * s),
              border: Border.all(
                color: selected ? kSetKnob : const Color(0xFFF1F1F1),
                width: (selected ? _kBblTileRing : _kBblTileBorder) * s,
              ),
            ),
            // 上下留白不再写死：由 Column.center 自动均分（(cell 高 − 内容 42.6)
            // / 2 ≈ 8.1，与参考值 8.3/7.7 一致）。此前固定 padding 让内容总高
            // 58.6 只比 cell 58.77 余 0.17 ⇒ 真机取整/选中描边必溢出
            // （普通格 2.8px、选中格描边侵占内容区再溢至 5.7px）。
            // 胶囊 18.2 与中缝 6.2 保持参考值不动；内容固有高仅 42.6，
            // 即使选中描边占用 2×2.7 仍有 ~10.6 余量 —— 溢出在结构上不可能。
            padding: EdgeInsets.symmetric(horizontal: _kBblCapInsetX * s),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _capsule(preset.recv, s),
                SizedBox(height: _kBblCapMidGap * s),
                _capsule(preset.sent, s),
              ],
            ),
          ),
          if (selected)
            Positioned(
              left: 0,
              right: 0,
              bottom: -_kBblBadgeSize / 2 * s,
              child: Center(
                child: Container(
                  width: _kBblBadgeSize * s,
                  height: _kBblBadgeSize * s,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: kSetKnob,
                  ),
                  child: Icon(Icons.check, size: 11 * s, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _capsule(Color c, double s) {
    return Container(
      width: _kBblCapW * s,
      height: _kBblCapH * s,
      decoration: BoxDecoration(
        color: c,
        borderRadius: BorderRadius.circular(_kBblCapRadius * s),
      ),
    );
  }
}

/// sheet 底部按钮（181.7×56.6，r=16，#F5F5F5，图标 + 文字）
class _SheetButton extends StatelessWidget {
  const _SheetButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: _kBtnH * s,
        decoration: BoxDecoration(
          color: const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(16 * s),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 25 * s, color: const Color(0xFF0C0D11)),
            SizedBox(width: 13.4 * s),
            Text(
              label,
              style: TextStyle(
                fontSize: 17.5 * s,
                fontWeight: FontWeight.w400,
                height: 1.0,
                color: context.setTitle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// 抽象涂鸦图案（参考截图是太空主题线条画：星星 / 火箭 / 行星 / 猫 / 彗星 / 箭头）。
// 项目没有 flutter_svg（不改 pubspec），用 CustomPaint 画**抽象**图案表达同样的
// 「深色底 + 低透明度白色线条」质感；不追求逐笔还原。
// ============================================================================
class _DoodlePainter extends CustomPainter {
  const _DoodlePainter({required this.color, this.cells = 5});

  final Color color;

  /// 图案密度：横向格子数（格子越多图案越密）
  final int cells;

  /// 固定种子：同一预设每次重绘图案一致
  static const int seed = 20260914;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final rnd = math.Random(seed);
    final cell = size.width / cells;
    final rows = (size.height / cell).ceil();
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.6, size.width * 0.008)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    final dot = Paint()..color = color;

    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cells; c++) {
        final cx = (c + 0.5) * cell + (rnd.nextDouble() - 0.5) * cell * 0.35;
        final cy = (r + 0.5) * cell + (rnd.nextDouble() - 0.5) * cell * 0.35;
        final kind = rnd.nextInt(7);
        final scale = cell * (0.24 + rnd.nextDouble() * 0.16);
        final rot = rnd.nextDouble() * math.pi * 2;
        canvas.save();
        canvas.translate(cx, cy);
        canvas.rotate(rot);
        switch (kind) {
          case 0:
            _star(canvas, scale, stroke);
            break;
          case 1:
            canvas.drawCircle(Offset.zero, scale * 0.42, stroke);
            break;
          case 2:
            _rocket(canvas, scale, stroke);
            break;
          case 3:
            _planet(canvas, scale, stroke);
            break;
          case 4:
            _comet(canvas, scale, stroke);
            break;
          case 5:
            _cat(canvas, scale, stroke);
            break;
          default:
            canvas.drawCircle(Offset.zero, math.max(0.7, scale * 0.12), dot);
            canvas.drawLine(
                Offset(-scale * 0.7, scale * 0.5), Offset(scale * 0.7, scale * 0.5), stroke);
            break;
        }
        canvas.restore();
      }
    }
  }

  void _star(Canvas canvas, double r, Paint p) {
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final rr = i.isEven ? r : r * 0.44;
      final a = -math.pi / 2 + i * math.pi / 5;
      final pt = Offset(math.cos(a) * rr, math.sin(a) * rr);
      if (i == 0) {
        path.moveTo(pt.dx, pt.dy);
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
    }
    path.close();
    canvas.drawPath(path, p);
  }

  void _rocket(Canvas canvas, double r, Paint p) {
    final body = Path()
      ..moveTo(0, -r)
      ..quadraticBezierTo(r * 0.55, -r * 0.1, r * 0.35, r * 0.55)
      ..lineTo(-r * 0.35, r * 0.55)
      ..quadraticBezierTo(-r * 0.55, -r * 0.1, 0, -r)
      ..close();
    canvas.drawPath(body, p);
    canvas.drawCircle(Offset(0, -r * 0.25), r * 0.2, p);
    canvas.drawLine(Offset(-r * 0.42, r * 0.2), Offset(-r * 0.75, r * 0.6), p);
    canvas.drawLine(Offset(r * 0.42, r * 0.2), Offset(r * 0.75, r * 0.6), p);
    canvas.drawLine(Offset(-r * 0.18, r * 0.62), Offset(0, r * 0.95), p);
    canvas.drawLine(Offset(r * 0.18, r * 0.62), Offset(0, r * 0.95), p);
  }

  void _planet(Canvas canvas, double r, Paint p) {
    canvas.drawCircle(Offset.zero, r * 0.55, p);
    canvas.save();
    canvas.rotate(-0.35);
    canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: r * 1.9, height: r * 0.6), p);
    canvas.restore();
  }

  void _comet(Canvas canvas, double r, Paint p) {
    canvas.drawCircle(Offset(r * 0.5, 0), r * 0.42, p);
    canvas.drawLine(Offset(-r * 0.2, -r * 0.25), Offset(-r * 1.0, -r * 0.55), p);
    canvas.drawLine(Offset(-r * 0.2, 0), Offset(-r * 1.1, 0), p);
    canvas.drawLine(Offset(-r * 0.2, r * 0.25), Offset(-r * 1.0, r * 0.55), p);
  }

  void _cat(Canvas canvas, double r, Paint p) {
    final head = Path()
      ..addOval(Rect.fromCircle(center: Offset.zero, radius: r * 0.55));
    canvas.drawPath(head, p);
    final earL = Path()
      ..moveTo(-r * 0.5, -r * 0.35)
      ..lineTo(-r * 0.32, -r * 0.82)
      ..lineTo(-r * 0.08, -r * 0.5);
    final earR = Path()
      ..moveTo(r * 0.5, -r * 0.35)
      ..lineTo(r * 0.32, -r * 0.82)
      ..lineTo(r * 0.08, -r * 0.5);
    canvas.drawPath(earL, p);
    canvas.drawPath(earR, p);
    canvas.drawLine(Offset(-r * 0.65, 0), Offset(-r * 1.0, -r * 0.12), p);
    canvas.drawLine(Offset(-r * 0.65, r * 0.12), Offset(-r * 1.0, r * 0.2), p);
    canvas.drawLine(Offset(r * 0.65, 0), Offset(r * 1.0, -r * 0.12), p);
    canvas.drawLine(Offset(r * 0.65, r * 0.12), Offset(r * 1.0, r * 0.2), p);
  }

  @override
  bool shouldRepaint(covariant _DoodlePainter old) =>
      old.color != color || old.cells != cells;
}
