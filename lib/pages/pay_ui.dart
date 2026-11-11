import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 钱包/支付类页面统一视觉规范。
/// 适用页面：我的钱包 / 发红包 / 转账 / 手动充值 / 手动提现 / 绑定收款方式。
/// 主按钮、选中态、单选指示器、分段切换、上传框必须从这里取样式，保证全局一致。
class PayUI {
  /// 主色（与设计稿统一的蓝色）
  static const Color primary = Color(0xFF2196F3);

  /// 主按钮禁用色
  static const Color primaryDisabled = Color(0xFFA9D8FB);

  /// 余额卡渐变（左上 → 右下）
  static const List<Color> balanceGradient = [
    Color(0xFF1279CC),
    Color(0xFF41AAE8),
  ];

  /// 统一主操作按钮：全宽、高 48、圆角 12、字号 16 w600、支持 loading 态
  static Widget primaryButton({
    required String label,
    required VoidCallback? onPressed,
    bool loading = false,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: FilledButton(
        onPressed: loading ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          disabledBackgroundColor: primaryDisabled,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
            : Text(label,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
    );
  }

  /// 统一圆形单选指示器（列表单选行右侧）
  static Widget radio(BuildContext context, bool selected) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? primary : Colors.transparent,
        border: Border.all(
            color: selected ? primary : scheme.outlineVariant,
            width: selected ? 0 : 1.5),
      ),
      alignment: Alignment.center,
      child: selected
          ? const Icon(Icons.check, size: 13, color: Colors.white)
          : null,
    );
  }

  /// 统一分段切换（白底容器 + 选中段主蓝底白字，支持图标）
  static Widget segmentTabs({
    required BuildContext context,
    required List<(int, String, IconData?)> items, // (id, 文案, 图标可空)
    required int selected,
    required ValueChanged<int> onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          for (final (id, label, icon) in items)
            Expanded(
              child: InkWell(
                onTap: () => onChanged(id),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected == id ? primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (icon != null) ...[
                        Icon(icon,
                            size: 16,
                            color: selected == id
                                ? Colors.white
                                : scheme.onSurfaceVariant),
                        const SizedBox(width: 5),
                      ],
                      Text(label,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: selected == id
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: selected == id
                                  ? Colors.white
                                  : scheme.onSurface)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 红包红渐变主按钮（左浅红 → 右深红）
  static Widget redPacketButton({
    required String label,
    required VoidCallback? onPressed,
    bool loading = false,
    IconData? icon,
  }) {
    const gradient = LinearGradient(
      colors: [Color(0xFFFF7A7A), AppTheme.redPacket],
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
    );
    return _gradientButton(
      gradient: gradient,
      label: label,
      onPressed: onPressed,
      loading: loading,
      disabledColors: const [Color(0xFFFBC7C7), Color(0xFFF2A0A0)],
      icon: icon,
    );
  }

  /// 转账橙渐变主按钮（左浅橙 → 右深橙）
  static Widget transferButton({
    required String label,
    required VoidCallback? onPressed,
    bool loading = false,
  }) {
    const gradient = LinearGradient(
      colors: [Color(0xFFFFB86B), AppTheme.transfer],
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
    );
    return _gradientButton(
      gradient: gradient,
      label: label,
      onPressed: onPressed,
      loading: loading,
      disabledColors: const [Color(0xFFFFE0B8), Color(0xFFF4C084)],
    );
  }

  /// 通用蓝渐变主按钮（登录/注册等通用场景）
  static Widget blueButton({
    required String label,
    required VoidCallback? onPressed,
    bool loading = false,
  }) {
    const gradient = LinearGradient(
      colors: [Color(0xFF63B4FF), AppTheme.primary],
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
    );
    return _gradientButton(
      gradient: gradient,
      label: label,
      onPressed: onPressed,
      loading: loading,
      disabledColors: const [Color(0xFFC4E2FB), Color(0xFFA7D1F3)],
    );
  }

  /// 渐变按钮通用实现
  static Widget _gradientButton({
    required Gradient gradient,
    required String label,
    required VoidCallback? onPressed,
    required bool loading,
    required List<Color> disabledColors,
    IconData? icon,
  }) {
    final enabled = onPressed != null && !loading;
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: enabled ? gradient : LinearGradient(colors: disabledColors),
          borderRadius: BorderRadius.circular(16),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: (gradient is LinearGradient
                            ? gradient.colors.last
                            : Colors.black)
                        .withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? onPressed : null,
            borderRadius: BorderRadius.circular(16),
            child: Center(
              child: loading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[
                          Icon(icon, size: 20, color: Colors.white),
                          const SizedBox(width: 7),
                        ],
                        Text(
                          label,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  /// 统一虚线边框上传框（收款码 / 支付凭证上传区）
  static Widget dashedUploadBox({
    required BuildContext context,
    required Widget child,
    required VoidCallback onTap,
    double height = 150,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: CustomPaint(
        painter: _DashedRRectPainter(
            color: scheme.outlineVariant,
            radius: 10,
            strokeWidth: 1,
            dash: const [5, 3]),
        child: Container(
          width: double.infinity,
          height: height,
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );
  }
}

/// 虚线圆角边框画笔
class _DashedRRectPainter extends CustomPainter {
  final Color color;
  final double radius;
  final double strokeWidth;
  final List<double> dash;

  _DashedRRectPainter({
    required this.color,
    required this.radius,
    required this.strokeWidth,
    required this.dash,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height), Radius.circular(radius));
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = color;
    for (final metric in path.computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        final next = (dist + dash[0]).clamp(0.0, metric.length);
        canvas.drawLine(metric.getTangentForOffset(dist)!.position,
            metric.getTangentForOffset(next)!.position, paint);
        dist += dash[0] + dash[1];
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRRectPainter old) =>
      old.color != color || old.radius != radius;
}
