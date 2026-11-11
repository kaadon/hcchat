import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

// V2 复刻基础组件（尺寸全部来自 `UI-ref/DESIGN.md` 的截图像素级实测）。
//
// 为什么单独开一个 kit、而不是改 `AppTheme.primaryButton`：
// `AppTheme` 里那套（蓝底按钮 / 浅灰底输入框）仍被尚未迁移的 58 处页面引用，
// 就地改会连带改坏。这里走「只加不改」，四个批次迁移完再把两套合并。
//
// ===== 尺度基准（重要）=====
// 参考设备截图：1260 物理px 宽、DPR 3 → **逻辑宽 420**。下面所有数字都按 420 宽推导。
// 实际渲染时用 `v2Scale(context)` 按屏幕宽等比缩放，这样在 360/390/412 等窄屏上
// 「元素与屏宽的比值」与参考截图完全一致 —— 也就是「看起来一样」。
// （DPR 究竟取 3 还是 3.5 不影响还原度：物理像素是固定的，
//   未知的 DPR 只影响「逻辑基准宽取 420 还是 360」，而屏幕宽等比缩放会把这一项约掉。）
//
// 组件内部一律通过 `context.v2*` 取色，深浅色自动适配，页面不需要传 isDark。

/// V2 页面的统一缩放系数：以参考设备逻辑宽 420 为 1.0，窄屏按比例缩小，宽屏不放大。
double v2Scale(BuildContext context) {
  final w = MediaQuery.of(context).size.width;
  return w.clamp(320.0, 420.0) / 420.0;
}

/// 纵向缩放系数：**只给「顶部留白 / Logo / 大间距」这类纵向大块尺寸用**。
///
/// 设计稿是按逻辑尺寸 420×1153 的机型出的。那些绝对值（留白 96、Logo 118、
/// 间距 57/70）直接搬到逻辑高 800 的屏上，「留白+Logo+应用名」会吃掉近一半屏高
/// —— 这正是「登录页上半部分太占地方」的根因。这里按屏高线性过渡：
///
/// | 屏高 | 系数 | 效果 |
/// |---|---|---|
/// | ≥1150 | 1.0 | 与设计稿完全一致 |
/// | 800 | 0.65 | 明显收紧 |
/// | ≤700 | 0.55（下限）| 再小就贴得太紧 |
///
/// 字号与输入框间距**不要**用它，否则矮屏上文字会明显变小。
double v2VScale(BuildContext context) {
  final h = MediaQuery.sizeOf(context).height;
  return (0.55 + (h - 700) / 1000).clamp(0.55, 1.0);
}

/// 输入框：固定高的圆角填充框（左图标 + 可选右后缀）。
///
/// 用 `InputDecoration.collapsed` 把 Material 默认的内外边距与下划线全部清掉，
/// 高度由外层 `Container` 精确锁定 —— 若用普通 `InputDecoration`，
/// 高度会随 `errorText`/`helperText` 变化，做不到「像素级」也容易在固定高度里溢出。
/// 因此校验提示不走 `validator` 的内联文字，由页面用 Toast 呈现。
///
/// 点击区（2026-09-15 二十三/二十四批两轮修正）：collapsed 输入框自身可点区域
/// 只有文字行高（居中的一小条）。不能靠 expands 撑高——`obscureText` 与 multiline
/// 互斥（Flutter 断言 '!obscureText || maxLines == 1'），密码框直接红屏。
/// 最终方案：外层 GestureDetector(opaque) 把**整个框**变成聚焦热区（点框内任意
/// 位置 requestFocus），TextField 保持单行固有高度由 Row 垂直居中——居中与全框
/// 可点兼得，且对 obscureText 安全。
class V2Field extends StatefulWidget {
  const V2Field({
    super.key,
    required this.controller,
    required this.hint,
    this.icon,
    this.suffix,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.inputFormatters,
    this.focusNode,
    this.onSubmitted,
    this.onChanged,
    this.enabled = true,
    this.readOnly = false,
    this.onTap,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String hint;
  final IconData? icon;
  final Widget? suffix;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final List<TextInputFormatter>? inputFormatters;
  final FocusNode? focusNode;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final bool enabled;
  final bool readOnly;
  final VoidCallback? onTap;
  final bool autofocus;

  @override
  State<V2Field> createState() => _V2FieldState();
}

class _V2FieldState extends State<V2Field> {
  FocusNode? _ownFocus; // 调用方未传 focusNode 时自建（点整框聚焦用）

  FocusNode get _effectiveFocus =>
      widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void dispose() {
    _ownFocus?.dispose();
    super.dispose();
  }

  void _focusField() {
    _effectiveFocus.requestFocus();
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return GestureDetector(
      // 整框热区：点输入框任何位置都聚焦（原可点区只有文字那一小条）
      behavior: HitTestBehavior.opaque,
      onTap: _focusField,
      child: Container(
        height: AppTheme.v2FieldHeight * s,
        decoration: BoxDecoration(
          color: context.v2Fill,
          borderRadius: BorderRadius.circular(AppTheme.v2Radius * s),
        ),
        padding: EdgeInsets.symmetric(horizontal: 18 * s),
        child: Row(
          children: [
            if (widget.icon != null) ...[
              Icon(widget.icon, size: 24 * s, color: context.v2HintColor),
              SizedBox(width: 25 * s),
            ],
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: _effectiveFocus,
                obscureText: widget.obscureText,
                keyboardType: widget.keyboardType,
                textInputAction: widget.textInputAction,
                autofillHints: widget.autofillHints,
                inputFormatters: widget.inputFormatters,
                enabled: widget.enabled,
                readOnly: widget.readOnly,
                autofocus: widget.autofocus,
                onSubmitted: widget.onSubmitted,
                onChanged: widget.onChanged,
                textAlignVertical: TextAlignVertical.center,
                style: TextStyle(
                  fontSize: 18 * s,
                  fontWeight: FontWeight.w500,
                  height: 1.0,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                decoration: InputDecoration.collapsed(
                  hintText: widget.hint,
                  hintStyle: TextStyle(
                    fontSize: 18 * s,
                    fontWeight: FontWeight.w400,
                    height: 1.0,
                    color: context.v2HintColor,
                  ),
                ),
              ),
            ),
            if (widget.suffix != null) ...[
              SizedBox(width: 8 * s),
              widget.suffix!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 主按钮：近黑填充 + 白字，高 64、圆角 16。
/// [loading] 为真时显示同色系转圈并自动禁用点击。
/// 主按钮（近黑填充）。
/// 2026-09-20 动画：①按压缩放（按住 0.97、松开 100ms 回弹，Listener 不抢占
/// ElevatedButton 自身手势）；②loading 态换成「单白点左右摆钟」动画，替代
/// 原转圈——用户点名要对齐参考 App 的摆钟效果。
class V2PrimaryButton extends StatefulWidget {
  const V2PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.height = AppTheme.v2PrimaryBtnHeight,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final double height;

  @override
  State<V2PrimaryButton> createState() => _V2PrimaryButtonState();
}

class _V2PrimaryButtonState extends State<V2PrimaryButton> {
  bool _pressed = false;

  bool get _interactive => !widget.loading && widget.onPressed != null;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final bg = context.v2ActionBg;
    final fg = context.v2ActionFg;
    return SizedBox(
      width: double.infinity,
      height: widget.height * s,
      child: Listener(
        // Listener 不参与手势竞争：只观察指针做按压缩放，点击仍由按钮自己处理
        onPointerDown: (_) {
          if (_interactive) setState(() => _pressed = true);
        },
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1.0,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
          child: ElevatedButton(
            onPressed: widget.loading ? null : widget.onPressed,
            style: ElevatedButton.styleFrom(
              backgroundColor: bg,
              foregroundColor: fg,
              disabledBackgroundColor: bg.withValues(alpha: 0.35),
              disabledForegroundColor: fg,
              elevation: 0,
              shadowColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.v2Radius * s),
              ),
            ),
            child: widget.loading
                ? _PendulumLoader(color: fg, unit: s)
                : Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 20 * s,
                      fontWeight: FontWeight.w600,
                      height: 1.0,
                      letterSpacing: 0.2,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// 摆钟 loading（2026-09-20 v2 两点式）：中心固定一颗圆点，另一颗圆点
/// 在其左右往复摆动（easeInOut，900ms 单程），对齐参考 App 的两点效果。
/// v1 只有一颗摆动点且太小，用户反馈「太小了，别人是两个点」。
class _PendulumLoader extends StatefulWidget {
  const _PendulumLoader({required this.color, required this.unit});

  final Color color;
  final double unit;

  @override
  State<_PendulumLoader> createState() => _PendulumLoaderState();
}

class _PendulumLoaderState extends State<_PendulumLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);
  late final Animation<double> _t =
      CurvedAnimation(parent: _c, curve: Curves.easeInOut);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = 7.0 * widget.unit; // 圆点直径
    return SizedBox(
      width: 46 * widget.unit,
      height: 20 * widget.unit,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 中心固定点
          Container(
            width: dot,
            height: dot,
            decoration:
                BoxDecoration(color: widget.color, shape: BoxShape.circle),
          ),
          // 左右摆动点（±0.9 行程，两端与中心点留出间隙不重叠）
          AnimatedBuilder(
            animation: _t,
            builder: (_, __) => Align(
              alignment: Alignment(-0.9 + 1.8 * _t.value, 0),
              child: Container(
                width: dot,
                height: dot,
                decoration: BoxDecoration(
                  color: widget.color,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 次按钮：透明底 + 近黑描边，高 64、圆角 16。
class V2OutlineButton extends StatelessWidget {
  const V2OutlineButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.height = AppTheme.v2OutlineBtnHeight,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final double height;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final stroke = context.v2ActionBg;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      width: double.infinity,
      height: height * s,
      child: OutlinedButton(
        onPressed: loading ? null : onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: onSurface,
          backgroundColor: Colors.transparent,
          side:
              BorderSide(color: stroke.withValues(alpha: 0.85), width: 1.2 * s),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.v2Radius * s),
          ),
        ),
        child: loading
            ? SizedBox(
                width: 20 * s,
                height: 20 * s,
                child: CircularProgressIndicator(
                    strokeWidth: 2 * s, color: onSurface),
              )
            : Text(
                label,
                style: TextStyle(
                  fontSize: 20 * s,
                  fontWeight: FontWeight.w600,
                  height: 1.0,
                  letterSpacing: 0.2,
                ),
              ),
      ),
    );
  }
}

/// 「或者」分隔行：两侧细线 + 中间灰字（截图 y 逻辑 861..874）。
class V2OrDivider extends StatelessWidget {
  const V2OrDivider({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final line = Container(height: 1, color: context.v2HairlineColor);
    return Row(
      children: [
        Expanded(child: line),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 14 * s),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 15 * s,
              height: 1.0,
              color: context.v2MutedColor,
            ),
          ),
        ),
        Expanded(child: line),
      ],
    );
  }
}

/// 两步式注册的步骤指示器。
///
/// 实测（逻辑 px，基准 420）：圆 d=41.3、两圆间距 10.7、连线宽 76.7 高 2.3，
/// 整体宽 179.7 居中；未到达的圆为 2px 浅灰描边 + 灰数字，
/// 已完成/当前步骤为近黑实心圆 + 白色对勾。
class V2StepIndicator extends StatelessWidget {
  const V2StepIndicator({super.key, required this.current, this.total = 2});

  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final d = 41.0 * s;
    final children = <Widget>[];
    for (var i = 1; i <= total; i++) {
      if (i > 1) {
        children.add(Container(
          width: 76.7 * s,
          height: 2.3 * s,
          margin: EdgeInsets.symmetric(horizontal: 10.7 * s),
          decoration: BoxDecoration(
            color: context.v2HairlineColor,
            borderRadius: BorderRadius.circular(2 * s),
          ),
        ));
      }
      final done = i <= current;
      children.add(Container(
        width: d,
        height: d,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: done ? context.v2ActionBg : Colors.transparent,
          border: done
              ? null
              : Border.all(color: context.v2HairlineColor, width: 2 * s),
        ),
        child: done
            ? Icon(Icons.check_rounded,
                size: 22 * s, color: context.v2ActionFg, weight: 700)
            : Text(
                '$i',
                style: TextStyle(
                  fontSize: 19 * s,
                  fontWeight: FontWeight.w600,
                  height: 1.0,
                  color: context.v2MutedColor,
                ),
              ),
      ));
    }
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: children);
  }
}
