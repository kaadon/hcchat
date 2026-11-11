import 'package:flutter/material.dart';

import '../widgets/transitions.dart';

/// ChatPulse 风格设计系统（依据 D:\im-project\UI\ 参考图）
/// 浅灰背景 + 白色卡片 + 标准科技蓝主色 + Inter 字体
class AppTheme {
  // ===== 主色 =====
  static const Color primary = Color(0xFF007AFF); // iOS 科技蓝，贴近截图
  static const Color onPrimary = Color(0xFFFFFFFF);
  static const Color primaryContainer = Color(0xFFE5F1FF); // 淡蓝底（按钮/高亮）

  // ===== 背景/表面 =====
  static const Color background = Color(0xFFF5F6F8); // 页面浅灰背景
  static const Color surface = Color(0xFFFFFFFF); // 卡片/列表项白色
  static const Color surfaceVariant = Color(0xFFF2F3F5); // 次级背景
  static const Color surfaceContainerLow = Color(0xFFF7F8FA); // 二级页面底色

  // ===== 文字 =====
  static const Color textPrimary = Color(0xFF111111); // 标题/名字
  static const Color textSecondary = Color(0xFF666666); // 预览/副文案
  static const Color textTertiary = Color(0xFF999999); // 时间/占位
  static const Color textLink = Color(0xFF007AFF);

  // ===== 分割线 =====
  static const Color divider = Color(0xFFE8E8E8);

  // ===== 中性灰阶（显式定义）=====
  // 背景：ColorScheme.fromSeed 会用 seedColor(蓝) 派生 outlineVariant / surfaceContainer，
  // 结果是「偏蓝的中灰」，画在白色卡片上是明显的一圈蓝灰描边（浅色模式下尤其刺眼）。
  // 这里显式锁定为微信式中性灰，并以 ColorScheme 角色注入，全局 58 处引用一次性生效。
  // ——浅色——
  static const Color ltFill = Color(0xFFF2F3F5); // 次级填充：搜索框/引用气泡/置顶条
  static const Color ltFillLow = Color(0xFFF7F8FA); // 二级页面底色
  static const Color ltFillHigh = Color(0xFFEDEDF0); // 按下态/高一级填充
  static const Color ltFillHighest = Color(0xFFE4E5E7);
  static const Color ltHairline = Color(0xFFECECEE); // 发丝线：卡片描边 / 列表分隔
  static const Color ltOutline = Color(0xFFD9DADD); // 输入框描边（比发丝线实一点）
  // ——深色——
  static const Color dkFill = Color(0xFF2C2C2E);
  static const Color dkFillLow = Color(0xFF232325);
  static const Color dkFillHigh = Color(0xFF3A3A3C);
  static const Color dkFillHighest = Color(0xFF48484A);
  static const Color dkHairline = Color(0xFF2C2C2E);
  static const Color dkOutline = Color(0xFF3A3A3C);
  static const Color dkOnSurface = Color(0xFFFFFFFF);
  static const Color dkOnSurfaceVariant = Color(0xFF98989F);

  // ===== 业务色 =====
  static const Color success = Color(0xFF34C759);
  static const Color warning = Color(0xFFFF9500);
  static const Color danger = Color(0xFFFF3B30);

  // ===== 扩展色（发现页/菜单图标） =====
  static const Color orange = Color(0xFFFF9500); // 新朋友/朋友圈
  static const Color green = Color(0xFF34C759); // 群聊
  static const Color cyan = Color(0xFF00C7D4); // 系统公告/扫一扫
  static const Color purple = Color(0xFFAF52DE); // 账号安全/切换语言
  static const Color pink = Color(0xFFFF2D55); // 检测更新红点

  // ===== 红包/转账 =====
  static const Color redPacket = Color(0xFFFA5151);
  static const Color redPacketDark = Color(0xFFD73B3B);
  static const Color transfer = Color(0xFFF5A623);
  static const Color transferDark = Color(0xFFE08D0A);

  static const Color unreadBadge = Color(0xFF007AFF);
  static const Color announcementBg = Color(0xFFE8F4FD); // 顶部提示条
  static const Color pinnedBar = Color(0xFFF7F8FA); // 置顶消息条

  // 在线状态
  static const Color onlineDot = Color(0xFF34C759);

  // 头像色板
  static const List<Color> avatarColors = [
    Color(0xFF007AFF),
    Color(0xFF5856D6),
    Color(0xFFFF2D55),
    Color(0xFFFF9500),
    Color(0xFF34C759),
    Color(0xFFAF52DE),
  ];

  // ===== 圆角 =====
  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusLg = 16;
  static const double radiusBubble = 18;
  static const double radiusFull = 9999;

  // ============================================================
  // ===== V2 复刻 token（UI-ref/DESIGN.md，逐页复刻用）=====
  // ============================================================
  // 来源：目标 APK 反编译目录 + 真机截图程序化取色（Pillow），DPR=3，逻辑尺寸 420×1153。
  //
  // 【重要】这一组是「只加不改」：现有 primary/background 仍被 58 处旧页面引用，
  // 若直接把 primary 改成黑，尚未迁移的页面会连带改坏。等四个批次全部迁移完，
  // 再把这些合并回主 token（届时 primary 可能变黑，蓝色只留给 Logo 与链接）。
  static const Color v2PageBg = Color(0xFFFFFFFF); // 纯白底（截图占比 79.4%）
  static const Color v2PageBgDark = Color(0xFF000000);
  static const Color v2FieldFill = Color(0xFFF1F2F4); // 输入框填充（占比 8.06%）
  static const Color v2FieldFillDark = Color(0xFF2C2C2E);
  static const Color v2Action = Color(0xFF0C0D12); // 主按钮填充（近黑，占比 3.85%）
  static const Color v2ActionDark = Color(0xFFFFFFFF); // 深色下反相，否则黑底黑按钮不可见
  static const Color v2OnAction = Color(0xFFFFFFFF);
  static const Color v2OnActionDark = Color(0xFF0C0D12);
  static const Color v2Hint = Color(0xFF9AA0AA); // 输入占位灰
  static const Color v2Muted = Color(0xFF6D737F); // 说明/次要链接灰
  static const Color v2Hairline = Color(0xFFE6E8EB); // 「或者」分隔线 / 描边按钮描边

  /// 输入框 / 按钮圆角。实测：输入框内缩 36 图像px → r≈45、按钮内缩 37.5 → r≈46，
  /// 两元素互证 r≈45 图像px ÷ DPR3 = 15 逻辑px，这里取 16。
  static const double v2Radius = 16;
  static const double v2FieldHeight =
      69; // 输入框高（逻辑px，实测值）。曾按用户要求临时压到 44，2026-09-15 用户要求调回原高
  static const double v2PrimaryBtnHeight = 65; // 主按钮高（实测）
  static const double v2OutlineBtnHeight = 64; // 描边按钮高（实测）
  static const double v2Gutter = 51; // 页面左右留白（154÷3，51×2+317≈420）

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      primary: primary,
      secondary: primary,
      surface: surface,
      background: background,
      surfaceVariant: ltFill,
      // ↓ 显式锁定中性角色，避免蓝色 seed 派生出偏蓝的灰
      onSurface: textPrimary,
      onSurfaceVariant: textSecondary,
      surfaceContainerLowest: surface,
      surfaceContainerLow: ltFillLow,
      surfaceContainer: ltFill,
      surfaceContainerHigh: ltFillHigh,
      surfaceContainerHighest: ltFillHighest,
      outline: ltOutline,
      outlineVariant: ltHairline,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      fontFamily: 'Inter',
      // 全局二级页转场（2026-09-20 动效规范基线）：右→左滑入 push、
      // 左→右滑出返回；系统「减少动态效果」开启时自动降级纯淡入。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: AdaptiveSlidePageTransitionsBuilder(),
          TargetPlatform.iOS: AdaptiveSlidePageTransitionsBuilder(),
          TargetPlatform.windows: AdaptiveSlidePageTransitionsBuilder(),
          TargetPlatform.macOS: AdaptiveSlidePageTransitionsBuilder(),
          TargetPlatform.linux: AdaptiveSlidePageTransitionsBuilder(),
        },
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: IconThemeData(color: textPrimary),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: surfaceVariant,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusMd)),
          borderSide: BorderSide.none,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: divider,
        thickness: 0.5,
        space: 0.5,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: onPrimary,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusSm)),
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  /// 深色模式主题（Material 框架层）
  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      primary: primary,
      secondary: primary,
      brightness: Brightness.dark,
      surface: const Color(0xFF1C1C1E),
      background: const Color(0xFF000000),
      surfaceVariant: dkFill,
      // ↓ 同上：深色下的中性灰阶
      onSurface: dkOnSurface,
      onSurfaceVariant: dkOnSurfaceVariant,
      surfaceContainerLowest: const Color(0xFF1C1C1E),
      surfaceContainerLow: dkFillLow,
      surfaceContainer: dkFill,
      surfaceContainerHigh: dkFillHigh,
      surfaceContainerHighest: dkFillHighest,
      outline: dkOutline,
      outlineVariant: dkHairline,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFF000000),
      fontFamily: 'Inter',
      // 同浅色：全局二级页转场=右滑入基线（减少动态效果时降级淡入）
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: AdaptiveSlidePageTransitionsBuilder(),
          TargetPlatform.iOS: AdaptiveSlidePageTransitionsBuilder(),
          TargetPlatform.windows: AdaptiveSlidePageTransitionsBuilder(),
          TargetPlatform.macOS: AdaptiveSlidePageTransitionsBuilder(),
          TargetPlatform.linux: AdaptiveSlidePageTransitionsBuilder(),
        },
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF1C1C1E),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: IconThemeData(color: Colors.white),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFF2C2C2E),
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusMd)),
          borderSide: BorderSide.none,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF3A3A3C),
        thickness: 0.5,
        space: 0.5,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: onPrimary,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusSm)),
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  // ===================== 复用组件 =====================

  /// 登录/注册/搜索等输入框样式
  static InputDecoration authInput({
    required String hint,
    required IconData icon,
    bool obscure = false,
    Widget? suffix,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: textTertiary, fontSize: 15),
      prefixIcon: Icon(icon, size: 20, color: textTertiary),
      suffixIcon: suffix,
      filled: true,
      fillColor: surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(radiusMd)),
        borderSide: BorderSide(color: divider),
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(radiusMd)),
        borderSide: BorderSide(color: divider),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(radiusMd)),
        borderSide: BorderSide(color: primary, width: 1.5),
      ),
      errorBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(radiusMd)),
        borderSide: BorderSide(color: danger),
      ),
    );
  }

  /// 主按钮
  static Widget primaryButton({
    required String label,
    VoidCallback? onPressed,
    bool fullWidth = true,
  }) {
    final btn = SizedBox(
      height: 48,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: onPrimary,
          disabledBackgroundColor: primary.withValues(alpha: 0.4),
          disabledForegroundColor: onPrimary,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
    );
    return fullWidth ? SizedBox(width: double.infinity, child: btn) : btn;
  }

  /// 默认品牌头像（无头像时的占位）
  /// 2026-09-20：改为 App 图标（assets/icon/app_icon.png）——用户要求内置
  /// 默认 Logo 直接用应用图标，不再用带气泡图标的渐变占位。加载失败回退
  /// 原渐变+图标（理论上不会触发，app_icon.png 随包内置）。
  static Widget brandAvatar({double size = 80}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 4),
      child: Image.asset(
        'assets/icon/app_icon.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [primary, primary.withValues(alpha: 0.75)],
            ),
            borderRadius: BorderRadius.circular(size / 4),
          ),
          child: Icon(
            Icons.chat_bubble_rounded,
            color: onPrimary,
            size: size * 0.45,
          ),
        ),
      ),
    );
  }
}

/// BuildContext 快捷取色（深色模式适配）
extension AppContextColors on BuildContext {
  ColorScheme get cs => Theme.of(this).colorScheme;
}

/// V2 复刻 token 的深色感知快捷取色（token 定义见文件末尾 V2 区块）。
///
/// 页面里写 `context.v2Bg` 而不是 `AppTheme.v2PageBg`，一处自动适配深浅色，
/// 避免每页再写一遍 `isDark ? A : B`。
extension AppV2Colors on BuildContext {
  bool get v2IsDark => Theme.of(this).brightness == Brightness.dark;

  /// 页面底色（浅色纯白 / 深色纯黑）
  Color get v2Bg => v2IsDark ? AppTheme.v2PageBgDark : AppTheme.v2PageBg;

  /// 输入框填充
  Color get v2Fill =>
      v2IsDark ? AppTheme.v2FieldFillDark : AppTheme.v2FieldFill;

  /// 主按钮底色（浅色近黑 / 深色反相为白）
  Color get v2ActionBg => v2IsDark ? AppTheme.v2ActionDark : AppTheme.v2Action;

  /// 主按钮前景色
  Color get v2ActionFg =>
      v2IsDark ? AppTheme.v2OnActionDark : AppTheme.v2OnAction;

  /// 占位灰
  Color get v2HintColor =>
      v2IsDark ? AppTheme.dkOnSurfaceVariant : AppTheme.v2Hint;

  /// 说明/次要链接灰
  Color get v2MutedColor =>
      v2IsDark ? AppTheme.dkOnSurfaceVariant : AppTheme.v2Muted;

  /// 发丝线色（「或者」分隔线、描边按钮描边）
  Color get v2HairlineColor =>
      v2IsDark ? AppTheme.dkOutline : AppTheme.v2Hairline;
}
