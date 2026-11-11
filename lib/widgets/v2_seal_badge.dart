import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'v2_kit.dart';

// V2「星形认证徽标」（2026-09-14 批次：好友资料页 / 群资料页共用）。
//
// 为什么不用 `v2_tags.dart` 的 `V2VerifiedShield`：
// 参考截图里这两处（好友名右侧的蓝徽、群名右侧的黑徽）放大后是**12 角星形印章
// + 白色对勾**（星芒脉冲状），而不是盾形。`V2VerifiedShield` 用的是
// `Icons.verified_user`（盾 + 对勾），轮廓差得较明显，故这里用 CustomPainter 画。
//
// 实测（逻辑 px，基准宽 420）：
// - 好友资料页：ink 16.5 × 16.5（外接圆直径 ≈ 16.5），蓝 #4FA4EE，白色对勾
// - 群资料页：ink 26.0 × 24.3，黑（跟随标题色），白色对勾
// 两处形状一致，只有尺寸与颜色不同，所以只有一个 `size` + `color`。
//
// 形状：24 个顶点交替取 R / 0.78R（12 个尖角），尖角朝正上方（-90°）。

/// 星芒印章徽标。[size] 为**外接圆直径**（逻辑 px，未缩放）。
class V2SealBadge extends StatelessWidget {
  const V2SealBadge({super.key, required this.size, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final c = color ?? const Color(0xFF4FA4EE);
    return SizedBox(
      width: size * s,
      height: size * s,
      child: CustomPaint(painter: _SealPainter(color: c)),
    );
  }
}

class _SealPainter extends CustomPainter {
  const _SealPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final d = size.shortestSide;
    final c = Offset(size.width / 2, size.height / 2);
    final rOuter = d / 2;
    final rInner = rOuter * 0.78;
    const points = 24; // 12 个尖角（奇偶交替）
    final path = Path();
    for (var i = 0; i < points; i++) {
      final r = i.isEven ? rOuter : rInner;
      final a = -math.pi / 2 + i * math.pi / (points / 2);
      final p = Offset(c.dx + r * math.cos(a), c.dy + r * math.sin(a));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color..isAntiAlias = true);

    // 白色对勾（与星形同心，笔画 ≈ 0.12✕直径）
    final stroke = d * 0.13;
    final check = Path()
      ..moveTo(c.dx - d * 0.24, c.dy + d * 0.02)
      ..lineTo(c.dx - d * 0.06, c.dy + d * 0.19)
      ..lineTo(c.dx + d * 0.24, c.dy - d * 0.18);
    canvas.drawPath(
      check,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(covariant _SealPainter old) => old.color != color;
}
