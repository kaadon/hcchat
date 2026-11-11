import 'dart:ui';

import 'package:flutter/widgets.dart';

/// 折叠屏 / 大屏断点与铰链避让工具（B 方案，见 UI/foldable_responsive_design.md）
///
/// - < 650dp（compact）：手机竖屏、折叠屏外屏 → 现状单栏，零改动
/// - >= 650dp（expanded）：折叠屏内屏展开 / 平板 / 手机横屏 → 双栏
class Breakpoints {
  Breakpoints._();

  /// 双栏断点：宽度 >= 650dp 视为宽屏（展开态）
  static const double wide = 650;

  /// 超宽限宽：内容整体居中，不超过该宽度（大显示器 / 平板横屏）
  static const double maxContentWidth = 1200;

  /// 宽屏下会话列表列固定宽
  static const double listPaneWidth = 320;

  /// 宽屏下左侧导航 rail 宽
  static const double navRailWidth = 72;

  /// 当前是否宽屏（折叠屏展开 / 平板 / 横屏）
  static bool isWide(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= wide;

  /// 宽屏下两栏之间需要让出的横向空间（铰链/DisplayCutout 穿过中缝时）。
  ///
  /// 取竖向 hinge（含 fold）与屏幕左右边缘之间、不与两栏重叠的区间宽度：
  /// - Samsung Fold 类机型 hinge 居中 → 返回铰链宽度，分栏线自动落在折痕上；
  /// - 无铰链（平板/普通横屏）→ 返回 0。
  static double paneGap(BuildContext context) {
    final view = View.of(context);
    final size = view.physicalSize / view.devicePixelRatio;
    double gap = 0;
    for (final f in view.displayFeatures) {
      // 只关心竖向（左右分栏方向的）不可用区
      if (f.type == DisplayFeatureType.cutout) continue; // 刘海走 SafeArea
      final vertical = f.bounds.width < f.bounds.height;
      if (!vertical) continue;
      // 铰链横穿屏幕中部才算（贴边的 cutout 已排除）
      if (f.bounds.left > size.width * 0.1 &&
          f.bounds.right < size.width * 0.9) {
        gap = gap > f.bounds.width ? gap : f.bounds.width;
      }
    }
    return gap;
  }
}
