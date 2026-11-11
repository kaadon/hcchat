import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 支付密码输入框：6 位纯数字 PIN，单隐藏 TextField 驱动 + 可视化方块。
///
/// - 自动聚焦、只允许数字、满 6 位触发 [onCompleted]（微信式无需确认按钮）。
/// - [onChanged] 每次输入变化都会回调（供父组件跟踪当前值 / 启用确认按钮）。
/// - 用于「设置支付密码」页与「发红包/转账」输入弹窗。
class PayPwdField extends StatefulWidget {
  final int length;
  final bool autoFocus;
  final Color? fillColor;
  final Color? borderColor;
  final Color? dotColor;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onCompleted;

  const PayPwdField({
    super.key,
    this.length = 6,
    this.autoFocus = true,
    this.fillColor,
    this.borderColor,
    this.dotColor,
    this.onChanged,
    this.onCompleted,
  });

  @override
  State<PayPwdField> createState() => _PayPwdFieldState();
}

class _PayPwdFieldState extends State<PayPwdField> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  String get _val => _ctrl.text;

  @override
  void initState() {
    super.initState();
    if (widget.autoFocus) {
      // 等首帧布局完成再抢焦点（弹窗/页面刚弹出时直接 requestFocus 可能抢不到）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    setState(() {}); // 刷新方块填充态
    widget.onChanged?.call(v);
    if (v.length == widget.length) {
      widget.onCompleted?.call(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final fill = widget.fillColor ??
        (isDark ? scheme.surfaceContainerHighest : const Color(0xFFF7F8FA));
    final border = widget.borderColor ?? scheme.outline;
    final dot = widget.dotColor ?? scheme.onSurface;

    return Stack(
      alignment: Alignment.center,
      children: [
        // 自适应格宽（2026-09-15 十四批修溢出）：原固定 6 格 × (44 + 10) = 324，
        // 360 逻辑宽小屏在页面 24×2 padding 下可用仅 312 → 最右格溢出 12px
        // （「设置支付密码」页与红包/转账弹窗同坑）。改按可用宽收缩格宽：
        // 上限仍 44、高 50 与间距不动（格比例基本不变、宽屏视觉零变化）。
        // 360 宽下格宽 42，右侧余量 = 页面 padding 24 ≥ 16；极窄屏 28 兜底。
        LayoutBuilder(builder: (context, cons) {
          const sideGap = 5.0;
          final avail = cons.maxWidth;
          final boxW = avail.isFinite
              ? math.max(
                  28.0,
                  math.min(44.0,
                      (avail - widget.length * sideGap * 2) / widget.length))
              : 44.0;
          final boxes = <Widget>[];
          for (int i = 0; i < widget.length; i++) {
            final filled = i < _val.length;
            boxes.add(Container(
              width: boxW,
              height: 50,
              margin: const EdgeInsets.symmetric(horizontal: sideGap),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: filled ? scheme.primary : border,
                  width: 1.5,
                ),
              ),
              alignment: Alignment.center,
              child: filled
                  ? Container(
                      width: 10,
                      height: 10,
                      decoration:
                          BoxDecoration(color: dot, shape: BoxShape.circle),
                    )
                  : null,
            ));
          }
          return Row(
              mainAxisAlignment: MainAxisAlignment.center, children: boxes);
        }),
        // 透明 TextField 负责接键盘输入（obscureText 不影响捕获，仅视觉上隐藏）
        Positioned.fill(
          child: Opacity(
            opacity: 0,
            child: TextField(
              controller: _ctrl,
              focusNode: _focus,
              keyboardType: TextInputType.number,
              maxLength: widget.length,
              obscureText: true,
              enableInteractiveSelection: false,
              autofocus: false,
              decoration: const InputDecoration(
                counterText: '',
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(widget.length),
              ],
              onChanged: _onChanged,
            ),
          ),
        ),
      ],
    );
  }
}
