import 'package:flutter/material.dart';

/// 微信小程序风格「胶囊」按钮（发现页内置浏览器 / 聊天小程序 WebView 共用）。
///
/// 左半「···」= 更多菜单，右半「⭕」= 关闭页面，中间 0.5px 竖分隔线。
/// 抽成公共组件是为了保证两个入口的标题栏**长得一模一样**（此前两处各写一份，
/// 聊天小程序用的是分离式 IconButton + 小圆圈，和发现页对不上）。
class WebBrowserCapsule extends StatelessWidget {
  final VoidCallback onMore;
  final VoidCallback onClose;

  const WebBrowserCapsule({
    super.key,
    required this.onMore,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 88,
      height: 32,
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F7),
        border: Border.all(color: const Color(0xFFE6E6E6), width: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onMore,
              borderRadius:
                  const BorderRadius.horizontal(left: Radius.circular(16)),
              child: const Center(
                child: Icon(Icons.more_horiz,
                    size: 20, color: Color(0xFF111111)),
              ),
            ),
          ),
          const VerticalDivider(
              width: 0.5, color: Color(0xFFE6E6E6), indent: 6, endIndent: 6),
          Expanded(
            child: InkWell(
              onTap: onClose,
              borderRadius:
                  const BorderRadius.horizontal(right: Radius.circular(16)),
              child: const Center(
                child: Icon(Icons.radio_button_unchecked,
                    size: 18, color: Color(0xFF111111)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
