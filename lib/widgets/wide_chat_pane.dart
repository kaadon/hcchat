import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/wide_layout_store.dart';

/// 宽屏（折叠屏展开/平板）双栏布局的右侧内容栏。
///
/// - 无选中 → 品牌空态占位；
/// - 有选中 → IndexedStack 渲染保活队列（LRU 上限见 WideLayoutStore._maxKeep），
///   聊天/朋友圈/扫一扫/浏览器/我的等二级页都在这里打开，左侧列表不动。
/// - 切换右栏内容时 180ms 淡入+微滑动画（只对整层做动画，IndexedStack
///   位置不变 → 各页面 State 保活不受影响，草稿/滚动位置不丢）。
/// - 返回键（清右栏）由 HomeShell 的 PopScope 统一处理，这里只管渲染。
class WideChatPane extends StatefulWidget {
  const WideChatPane({super.key});

  @override
  State<WideChatPane> createState() => _WideChatPaneState();
}

class _WideChatPaneState extends State<WideChatPane>
    with SingleTickerProviderStateMixin {
  late final AnimationController _switch = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: 1, // 首次进入不播动画
  );
  // 上一次渲染的右栏 key：变化时触发切换动画
  String? _lastKey;

  @override
  void dispose() {
    _switch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: WideLayoutStore.instance,
      builder: (context, _) {
        final store = WideLayoutStore.instance;
        final current = store.currentKey;
        // key 变化（切到另一个会话/页面）→ 帧末触发切换动画。
        // 不能在 build 里直接 forward（动画会回调 setState → build 期异常）
        if (current != _lastKey) {
          _lastKey = current;
          if (current != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _switch.forward(from: 0);
            });
          }
        }
        if (current == null || store.keep.isEmpty) return _empty(context);
        // 保活队列渲染：当前 key 对应的页面实例
        final children = [
          for (final e in store.keep) _page(context, e),
        ];
        var index = store.keep.indexWhere((e) => e.key == current);
        if (index < 0) index = 0; // LRU 淘汰兜底（正常不会发生）
        // 整层淡入 + 微上滑：切换有可感知的过渡，同时不打断保活
        return FadeTransition(
          opacity: CurvedAnimation(parent: _switch, curve: Curves.easeOut),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.015),
              end: Offset.zero,
            ).animate(
                CurvedAnimation(parent: _switch, curve: Curves.easeOut)),
            child: IndexedStack(index: index, children: children),
          ),
        );
      },
    );
  }

  /// 单个右栏页面：整体限宽 800 居中 —— 超宽屏（平板横屏/大屏）下
  /// 聊天与二级页内容不至于拉成一条横跨整屏的长行，视觉是一根居中内容柱。
  /// 背景与 Scaffold 一致，窄于 800 时（折叠屏内屏）不受影响。
  Widget _page(BuildContext context, PaneEntry e) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: e.page,
        ),
      ),
    );
  }

  /// 空态占位：引导文案
  Widget _empty(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined,
              size: 64, color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
          const SizedBox(height: 14),
          Text(t('widePaneEmpty'),
              style: TextStyle(
                  fontSize: 14,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.8))),
          const SizedBox(height: 6),
          Text(t('widePaneEmptyHint'),
              style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.6))),
        ],
      ),
    );
  }
}
