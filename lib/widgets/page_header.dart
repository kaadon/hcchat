import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 主 Tab 页通用「顶栏 + 搜索框」（首页/通讯录共用一套实现）。
/// 统一项（除标题文字与右侧图标本身外全部一致）：
/// - 顶栏：标题字号 26 / w800、内边距 LTRB(16,8,8,0)、右侧 IconButton 尺寸 26 / splashRadius 22
/// - 搜索框：高度 42、外边距 LTRB(12,10,12,0)、水平内边距 14、surface 底色 +
///   radiusMd 圆角（无描边）、搜索图标 20、文字/提示字号 14
class PageHeader extends StatelessWidget {
  final String title;
  final IconData trailingIcon;
  final VoidCallback onTrailingTap;

  const PageHeader({
    super.key,
    required this.title,
    required this.trailingIcon,
    required this.onTrailingTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Row(
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: context.cs.onSurface)),
          const Spacer(),
          IconButton(
            onPressed: onTrailingTap,
            icon: Icon(trailingIcon, size: 26, color: context.cs.onSurface),
            splashRadius: 22,
          ),
        ],
      ),
    );
  }
}

/// 统一搜索框。两种用法：
/// - 静态入口（首页）：只传 hint + onTap，整框可点跳搜索页；
/// - 实时过滤（通讯录）：传 controller + onChanged，输入时右侧出清除按钮。
class PageSearchBar extends StatelessWidget {
  final String hint;
  final VoidCallback? onTap;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;

  const PageSearchBar({
    super.key,
    required this.hint,
    this.onTap,
    this.controller,
    this.onChanged,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final hasInput = controller != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: context.cs.surface,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        ),
        child: Row(
          children: [
            Icon(Icons.search, size: 20, color: context.cs.onSurfaceVariant),
            const SizedBox(width: 8),
            if (!hasInput)
              Expanded(
                child: Text(hint,
                    style: TextStyle(
                        fontSize: 14, color: context.cs.onSurface)),
              )
            else
              Expanded(
                child: TextField(
                  controller: controller,
                  style:
                      TextStyle(fontSize: 14, color: context.cs.onSurface),
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: TextStyle(
                        fontSize: 14, color: context.cs.onSurface),
                    isDense: true,
                    // 关键：全局 inputDecorationTheme 是 filled:true + 灰色，
                    // 背景由外层 Container 提供，必须显式关掉否则文字后有灰条
                    filled: false,
                    fillColor: Colors.transparent,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    suffixIcon: (controller?.text.isNotEmpty ?? false)
                        ? IconButton(
                            icon: Icon(Icons.close,
                                size: 18,
                                color: context.cs.onSurfaceVariant),
                            onPressed: () {
                              controller?.clear();
                              if (onClear != null) {
                                onClear!();
                              } else {
                                onChanged?.call('');
                              }
                            },
                          )
                        : null,
                  ),
                  onChanged: onChanged,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
