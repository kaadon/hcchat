import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 品牌化加载组件（2026-09-06 需求：替换全 App 默认转圈）
///
/// - [BrandRingLoader]：品牌渐变圆环（方案2），SweepGradient 三色
///   （4F8CFF→B14FFF→FF6F91，与引导页倒计时同色系）+ 270° 弧旋转，
///   "彗星环"观感。首屏 AuthGate / 登录页 / 游客引导页等全屏等待场景。
///   `color` 传值时改为单色弧（彩色按钮/深色底上用白色版）。
/// - [SkeletonList]：列表页骨架屏（shimmer 滑光），
///   style 分别对齐会话列表 / 通讯录 / 朋友圈的真实条目布局。
///
/// 全部纯 Flutter 自绘，零第三方依赖；明暗主题自适应。

/// 品牌渐变圆环加载器
class BrandRingLoader extends StatefulWidget {
  const BrandRingLoader({
    super.key,
    this.size = 44,
    this.strokeWidth = 3.5,
    this.color,
  });

  final double size;
  final double strokeWidth;

  /// 为空 → 品牌三色渐变；传值（如 Colors.white）→ 单色弧
  final Color? color;

  @override
  State<BrandRingLoader> createState() => _BrandRingLoaderState();
}

class _BrandRingLoaderState extends State<BrandRingLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctl,
      builder: (_, __) => Transform.rotate(
        angle: _ctl.value * 2 * math.pi,
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _RingPainter(
              strokeWidth: widget.strokeWidth, color: widget.color),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.strokeWidth, this.color});

  final double strokeWidth;
  final Color? color;

  // 首尾同色（pink…pink）保证渐变在圆环接缝处无断色
  static const _brandColors = [
    Color(0xFFFF6F91),
    Color(0xFF4F8CFF),
    Color(0xFFB14FFF),
    Color(0xFFFF6F91),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final inset = strokeWidth / 2;
    final arcRect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.shortestSide / 2 - inset,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    if (color != null) {
      paint.color = color!;
    } else {
      paint.shader =
          const SweepGradient(colors: _brandColors).createShader(arcRect);
    }
    // 270° 弧留 90° 缺口，旋转时呈"彗星环"
    canvas.drawArc(arcRect, -math.pi / 2, math.pi * 1.5, false, paint);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.strokeWidth != strokeWidth || old.color != color;
}

/// 骨架屏风格
enum SkeletonStyle { chat, contacts, moments }

/// 列表页骨架屏：按 style 模拟对应页面真实条目的布局占位
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, required this.style, this.rows = 12});

  final SkeletonStyle style;
  final int rows;

  @override
  Widget build(BuildContext context) {
    switch (style) {
      case SkeletonStyle.chat:
        // 对齐会话列表：横向 16 内边距，头像 48 + 两行文字
        return ListView.builder(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: rows,
          itemBuilder: (_, __) => const _SkeletonChatRow(),
        );
      case SkeletonStyle.contacts:
        // 对齐通讯录：横向 12 内边距（与真实列表 padding 一致），头像 40 + 一行
        return ListView.builder(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 16),
          itemCount: rows,
          itemBuilder: (_, __) => const _SkeletonContactRow(),
        );
      case SkeletonStyle.moments:
        // 对齐朋友圈：头像 40 + 昵称/时间 + 正文两行 + 大图占位块
        return ListView.builder(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          itemCount: rows < 4 ? rows : 4,
          itemBuilder: (_, __) => const _SkeletonMomentRow(),
        );
    }
  }
}

/// shimmer 滑光占位块
class _Shimmer extends StatefulWidget {
  const _Shimmer({
    required this.width,
    required this.height,
    this.radius = 6,
    this.circle = false,
    this.expand = false,
  });

  final double width;
  final double height;
  final double radius;
  final bool circle;
  final bool expand; // true 时占满可用宽度（朋友圈大图块用）

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = dark ? const Color(0xFF2C2C30) : const Color(0xFFE9EBEF);
    final hi = dark ? const Color(0xFF3C3C42) : const Color(0xFFF7F8FA);
    final box = AnimatedBuilder(
      animation: _ctl,
      builder: (_, __) {
        final t = _ctl.value;
        return Container(
          width: widget.expand ? null : widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: base,
            shape: widget.circle ? BoxShape.circle : BoxShape.rectangle,
            borderRadius:
                widget.circle ? null : BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              begin: Alignment(t * 4 - 3, 0),
              end: Alignment(t * 4 - 1, 0),
              colors: [base, hi, base],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
        );
      },
    );
    if (!widget.expand) return box;
    return SizedBox(width: double.infinity, child: box);
  }
}

/// 会话行：头像 48 + 标题/预览两行（与真实会话卡布局对齐）
class _SkeletonChatRow extends StatelessWidget {
  const _SkeletonChatRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Shimmer(width: 48, height: 48, circle: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Shimmer(width: 120, height: 13, radius: 5),
                const SizedBox(height: 8),
                _Shimmer(
                    width: MediaQuery.of(context).size.width * 0.42,
                    height: 11,
                    radius: 5),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 通讯录行：头像 40 + 单行昵称
class _SkeletonContactRow extends StatelessWidget {
  const _SkeletonContactRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          _Shimmer(width: 40, height: 40, circle: true),
          SizedBox(width: 12),
          _Shimmer(width: 96, height: 12, radius: 5),
        ],
      ),
    );
  }
}

/// 朋友圈行：头像 + 昵称/时间 + 正文 + 大图块（与真实动态卡布局对齐）
class _SkeletonMomentRow extends StatelessWidget {
  const _SkeletonMomentRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Shimmer(width: 40, height: 40, circle: true),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Shimmer(width: 88, height: 12, radius: 5),
                SizedBox(height: 8),
                _Shimmer(width: 48, height: 10, radius: 5),
                SizedBox(height: 10),
                _Shimmer(width: 0, height: 12, radius: 5, expand: true),
                SizedBox(height: 6),
                _Shimmer(width: 220, height: 12, radius: 5),
                SizedBox(height: 12),
                _Shimmer(width: 240, height: 150, radius: 10, expand: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
