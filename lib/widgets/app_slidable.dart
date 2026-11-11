import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 仿微信侧滑：滑动会话项露出右侧操作按钮，点击直接执行
class AppSlidable extends StatefulWidget {
  final Widget child;
  final List<SlidableAction> actions;
  final double actionWidth;

  /// 行内容身份（如会话 ID）：列表按索引复用 element，置顶等操作引发重排后
  /// 同一位置的 State 可能被拿去渲染另一个会话——此时立即强制收起，
  /// 否则出现"置顶后按钮直接显示在别的行上"的错配。
  final String convId;

  /// 卡片背景色（用于 Stack 底盘同步，避免圆角缺口透出后层按钮颜色）
  final Color? cardColor;

  AppSlidable({
    super.key,
    required this.child,
    required this.actions,
    required this.convId,
    this.actionWidth = 72,
    this.cardColor,
  });

  @override
  State<AppSlidable> createState() => AppSlidableState();
}

class AppSlidableState extends State<AppSlidable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<Offset> _animation;
  double _dragExtent = 0;
  bool _open = false;

  /// 显式收起侧滑（供外部经 GlobalKey 调用：置顶/免打扰等操作后确保菜单关闭）
  void close() => _close();

  double get _maxOffset => -(widget.actions.length * widget.actionWidth);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _animation = Tween<Offset>(
      begin: Offset.zero,
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut))
      ..addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(AppSlidable oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 行数据换了会话（列表重排导致按索引错配）→ 展开状态属于"别人"，立即收起。
    // 不做动画直接归零：此刻屏幕上不该有任何展开残影。
    if (widget.convId != oldWidget.convId && (_open || _dragExtent != 0)) {
      _controller.stop();
      _dragExtent = 0;
      _open = false;
    }
  }

  void _animateTo(double target) {
    _animation = Tween<Offset>(
      begin: Offset(_dragExtent / _maxOffset, 0),
      end: Offset(target / _maxOffset, 0),
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut))
      ..addListener(() => setState(() {}));
    _controller.value = 0;
    _controller.forward();
    _dragExtent = target;
    _open = target != 0;
  }

  void _close() {
    if (!_open) return;
    _animateTo(0);
  }

  void _onDragUpdate(DragUpdateDetails d) {
    _dragExtent += d.delta.dx;
    if (_dragExtent > 0) _dragExtent = 0;
    if (_dragExtent < _maxOffset) _dragExtent = _maxOffset;
    setState(() {});
  }

  void _onDragEnd(DragEndDetails d) {
    final velocity = d.primaryVelocity ?? 0;
    final threshold = _maxOffset * 0.4;
    // 快速向左滑 → 展开；快速向右滑 → 收起
    if (velocity < -500) {
      _animateTo(_maxOffset);
    } else if (velocity > 500) {
      _animateTo(0);
    } else if (_dragExtent < threshold) {
      _animateTo(_maxOffset);
    } else {
      _animateTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cardColor = widget.cardColor ?? scheme.surface;
    // ClipRRect 物理裁切：卡片圆角以外的区域（含后层红/灰按钮）完全不可见，
    // 彻底解决消息列表四角漏色问题（需求：卡片外观干净一致）
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // 0) 底盘：与卡片背景同色铺满
          Positioned.fill(child: Container(color: cardColor)),
          // 后层：操作按钮（固定宽度，与 _maxOffset 一致）
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: -_maxOffset,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (final a in widget.actions)
                  SizedBox(
                    width: widget.actionWidth,
                    child: InkWell(
                      onTap: () {
                        _close();
                        a.onTap();
                      },
                      child: Container(
                        color: a.color,
                        alignment: Alignment.center,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(a.icon, color: a.foregroundColor, size: 22),
                            const SizedBox(height: 4),
                            Text(a.label,
                                style: TextStyle(
                                    color: a.foregroundColor, fontSize: 11)),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 前层：可拖动内容
          GestureDetector(
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            // 关键：拖拽被打断（手势被列表滚动抢占/组件树重排）时 onDragEnd
            // 不会触发，_dragExtent 会冻结在半开值 → 按钮永久残留。
            // 取消时必须归位。
            onHorizontalDragCancel: () => _animateTo(0),
            onTap: _open ? _close : null,
            child: Transform.translate(
              offset: Offset(
                _controller.isAnimating
                    ? _animation.value.dx * _maxOffset
                    : _dragExtent,
                0,
              ),
              child: widget.child,
            ),
          ),
        ],
      ),
    );
  }
}

class SlidableAction {
  final IconData icon;
  final String label;
  final Color color;
  final Color foregroundColor;
  final VoidCallback onTap;

  const SlidableAction({
    required this.icon,
    required this.label,
    required this.color,
    this.foregroundColor = Colors.white,
    required this.onTap,
  });
}
