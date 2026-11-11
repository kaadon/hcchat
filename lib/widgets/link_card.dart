import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../models/link_card.dart';
import '../pages/web/web_view_page.dart';
import '../theme/app_theme.dart';
import 'app_net_image.dart';

/// 聊天消息里的链接卡片（type=11）。
///
/// 两态：
/// - **白名单内（[LinkCardData.inApp]==true）**：微信式正方形小程序卡片。
///   顶部 = 站点 favicon（card.icon）+ 小程序名（card.displayName）；
///   中部 = 封面大图（card.image，og:image；缺省回落 icon/占位）；
///   底部 = 纯文字「小程序」标识；点击 → 应用内 WebView（[InAppWebViewPage]）。
/// - **非白名单**：灰色横向「浏览器打开」卡片（icon + 标题 + 描述 + 真实域名 + 浏览器打开）；
///   点击 → 系统浏览器打开。
///
/// 解析失败（坏 JSON）→ 回落普通文本气泡，避免渲染崩溃。
class LinkCardWidget extends StatelessWidget {
  final String content; // 卡片 JSON 字符串
  final bool isMine;
  final VoidCallback? onTap; // 为空时走默认跳转逻辑

  const LinkCardWidget({
    super.key,
    required this.content,
    this.isMine = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final card = LinkCardData.tryParse(content);
    if (card == null) return _fallbackText(context);
    // 白名单内走正方形小程序卡片；其余走灰色横向「浏览器打开」卡片
    if (card.inApp) return _miniProgramCard(context, card);
    return _grayCard(context, card);
  }

  /// 解析失败时的普通文本气泡。
  ///
  /// 注意：[StatelessWidget] 没有 `context` 成员 getter（只有 [State] 才有），
  /// 因此使用 `context.cs` 的成员方法必须显式接收 [BuildContext] 参数。
  Widget _fallbackText(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isMine ? AppTheme.primary : context.cs.surface,
          borderRadius: BorderRadius.circular(AppTheme.radiusBubble),
        ),
        constraints: const BoxConstraints(maxWidth: 280),
        child: Text(content,
            style: TextStyle(
                fontSize: 15,
                color: isMine ? Colors.white : context.cs.onSurface)),
      );

  /// 微信式正方形小程序卡片（仅 inApp==true）。
  ///
  /// 设计参考微信小程序聊天卡片：
  /// - 圆角 12 + 淡灰边 + 柔阴影（立体但不刺眼；上一版的纯蓝边过重）
  /// - 顶栏 logo 26 + 名称 14/medium
  /// - 中部缩略图内置圆角 8 + 上下间距
  /// - 底栏「小程序」用主色点缀（保留品牌色但不靠边框撑视觉）
  Widget _miniProgramCard(BuildContext context, LinkCardData card) {
    final name = card.displayName.isNotEmpty ? card.displayName : '小程序';
    return GestureDetector(
      onTap: () {
        if (onTap != null) {
          onTap!();
          return;
        }
        _defaultOpen(context, card);
      },
      child: Container(
        width: 220,
        height: 240,
        decoration: BoxDecoration(
          color: context.cs.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.cs.outlineVariant, width: 0.6),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 顶部：站点 favicon + 小程序名
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Row(
                children: [
                  _logo(card.icon, 26),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: context.cs.onSurface)),
                  ),
                ],
              ),
            ),
            // 中部：封面缩略图（圆角 + 上下间距）
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _cover(card.image.isNotEmpty ? card.image : card.icon),
                ),
              ),
            ),
            // 底部：「小程序」标签 + 右下角箭头（更接近微信的"可点"暗示）
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Row(
                children: [
                  Text('小程序',
                      style: TextStyle(
                          fontSize: 12, color: context.cs.onSurfaceVariant)),
                  const Spacer(),
                  Icon(Icons.chevron_right,
                      size: 14, color: context.cs.onSurfaceVariant),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 中部封面大图（og:image；缺省回落 icon 或占位图块）。
  Widget _cover(String url) {
    final placeholder = Container(
      color: AppTheme.primaryContainer,
      child: Center(
        child:
            Icon(Icons.landscape_outlined, size: 40, color: AppTheme.primary),
      ),
    );
    if (url.isEmpty) return placeholder;
    return AppNetImage(
        url: AppConfig.assetUrl(url), fit: BoxFit.cover, iconSize: 40);
  }

  /// 左上角小 logo（站点 favicon）。
  Widget _logo(String icon, double size) {
    if (icon.isEmpty) return _defaultIcon(true, size);
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(child: _defaultIcon(true, size)),
            // 加载中/失败都露出底层图标，避免白块
            Image.network(
              icon,
              fit: BoxFit.cover,
              frameBuilder: (ctx, child, frame, wasSync) =>
                  (wasSync || frame != null) ? child : const SizedBox.shrink(),
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  /// 非白名单：灰色横向「浏览器打开」卡片（icon + 标题 + 描述 + 域名 + 浏览器打开）。
  ///
  /// 设计：缩略图加大到 48、字号梯度更明显、底部"浏览器打开"与域名用
  /// 顶部细线分隔成独立区域，整体比微信「链接卡片」更克制。
  Widget _grayCard(BuildContext context, LinkCardData card) {
    final title = card.title.isNotEmpty ? card.title : card.url;
    return GestureDetector(
      onTap: () {
        if (onTap != null) {
          onTap!();
          return;
        }
        _defaultOpen(context, card);
      },
      child: Container(
        width: 280,
        decoration: BoxDecoration(
          color: context.cs.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.cs.outlineVariant, width: 0.6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 左：图标（优先 payload.icon，失败回落默认链接图标）
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: context.cs.surfaceContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: _leading(card.icon),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                color: context.cs.onSurface)),
                        if (card.description.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(card.description,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 13,
                                    color: context.cs.onSurfaceVariant)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // 底部：域名 + 浏览器打开（顶部细线与上面分隔）
            Container(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: context.cs.outlineVariant, width: 0.5),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(card.footer,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: context.cs.onSurfaceVariant)),
                  ),
                  const SizedBox(width: 6),
                  Text('浏览器打开',
                      style: TextStyle(fontSize: 12, color: AppTheme.primary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _leading(String icon) {
    if (icon.isEmpty) return _defaultIcon(false);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 40,
        height: 40,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(child: _defaultIcon(false)),
            // 加载中/失败都露出底层图标，避免白块
            Image.network(
              icon,
              fit: BoxFit.cover,
              frameBuilder: (ctx, child, frame, wasSync) =>
                  (wasSync || frame != null) ? child : const SizedBox.shrink(),
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _defaultIcon(bool blue, [double size = 22]) => Icon(
        Icons.link,
        size: size,
        color: blue ? AppTheme.primary : AppTheme.textSecondary,
      );

  /// 默认跳转：白名单内（inApp）走应用内 WebView，否则系统浏览器。
  static Future<void> _defaultOpen(
      BuildContext context, LinkCardData card) async {
    if (card.inApp) {
      if (!context.mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => InAppWebViewPage(
          url: card.url,
          displayName: card.displayTitle,
          nativeBridge: card.nativeBridge,
          domain: card.domain,
        ),
      ));
    } else {
      final uri = Uri.tryParse(card.url);
      if (uri == null) return;
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
  }
}
