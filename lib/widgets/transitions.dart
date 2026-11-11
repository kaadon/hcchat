import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// 通用动效基线（2026-09-20 规范落地）：
///
/// - Push 二级页：右→左滑入、返回左→右滑出（Cupertino），easeInOut、
///   无弹簧，全部二级页默认；
/// - 系统「减少动态效果」开启：降级为 Cross Dissolve（纯淡入，无位移）；
/// - 特例路由用 [fadeScaleRoute]：二维码页淡入+0.96→1 微缩放（220ms）、
///   大图预览纯淡入（遮罩 alpha 0→1，配合 Hero 缩放展开）。
class AdaptiveSlidePageTransitionsBuilder extends PageTransitionsBuilder {
  const AdaptiveSlidePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 系统「减少动态效果」→ Cross Dissolve（底页保持不动，新页纯淡入）
    if (MediaQuery.of(context).disableAnimations) {
      return FadeTransition(opacity: animation, child: child);
    }
    return const CupertinoPageTransitionsBuilder()
        .buildTransitions(route, context, animation, secondaryAnimation, child);
  }
}

/// 特例页转场：淡入（可选 0.96→1 微缩放）。
///
/// - 二维码/扫码页：`fadeScaleRoute(page, scale: true)`，220ms，二维码先出、
///   关闭 1→0.98 缩回；
/// - 大图预览：`fadeScaleRoute(page)`，遮罩 alpha 0→1；配合同 tag 的
///   Hero 缩略图即为「缩放展开/原路返回」。
///
/// opaque 关闭：转场期间底层页面保持可见（淡入必需）。
PageRoute<T> fadeScaleRoute<T>(Widget page, {bool scale = false}) {
  return PageRouteBuilder<T>(
    transitionDuration: Duration(milliseconds: scale ? 220 : 240),
    reverseTransitionDuration: Duration(milliseconds: scale ? 200 : 220),
    opaque: false,
    pageBuilder: (_, __, ___) => page,
    transitionsBuilder: (context, animation, __, child) {
      final curved =
          CurvedAnimation(parent: animation, curve: Curves.easeInOut);
      Widget w = FadeTransition(opacity: curved, child: child);
      // 系统「减少动态效果」→ 不缩放，只淡入
      if (scale && !MediaQuery.of(context).disableAnimations) {
        w = ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
          child: w,
        );
      }
      return w;
    },
  );
}
