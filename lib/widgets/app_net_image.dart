import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// 通用网络图片。
///
/// 统一「加载中 / 空 URL / 加载失败」三种状态的缺省占位：
/// 浅底（surfaceContainerHighest）+ 居中图标，避免出现白块、半截灰块或破图。
/// 加载成功后直接显示（首帧到达前显示占位，不闪烁）。
///
/// 需要点击查看大图等交互时，把本组件包在 GestureDetector 里即可。
///
/// 2026-09-26：原生分支从 Image.network 换成 CachedNetworkImage（磁盘缓存）——
/// Image.network 无磁盘缓存，每次冷启动打开 App 所有历史图片全量重新下载，
/// 网络抖动下载失败后 errorBuilder 常驻灰占位不重试（气泡"缺省"、点开黑屏），
/// 而长按保存走独立 dio 请求又能成功，表现自相矛盾。磁盘缓存后：一次下载成功
/// 永久命中，冷启动直接读盘不再走网络。H5 分支保持 Image.network（
/// cached_network_image 的磁盘缓存不适用于 Web，见 app_avatar.dart 同口径）。
class AppNetImage extends StatelessWidget {
  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final BorderRadius? radius;

  /// 解码宽度上限（列表/网格里传值可显著降内存与解码耗时）
  final int? cacheWidth;

  final double iconSize;

  const AppNetImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.radius,
    this.cacheWidth,
    this.iconSize = 28,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasUrl = url.trim().isNotEmpty;
    Widget img = !hasUrl
        ? _placeholder(cs, Icons.image_outlined)
        : kIsWeb
            ? Image.network(
                url,
                fit: fit,
                width: width,
                height: height,
                cacheWidth: cacheWidth,
                frameBuilder: (ctx, child, frame, wasSynchronouslyLoaded) {
                  if (wasSynchronouslyLoaded || frame != null) return child;
                  return _placeholder(cs, Icons.image_outlined);
                },
                errorBuilder: (_, __, ___) =>
                    _placeholder(cs, Icons.broken_image_outlined),
              )
            : CachedNetworkImage(
                imageUrl: url,
                fit: fit,
                width: width,
                height: height,
                memCacheWidth: cacheWidth,
                // 短淡入：占位 → 成图不生硬；比默认 500ms 跟手（列表滚动场景）
                fadeInDuration: const Duration(milliseconds: 150),
                placeholder: (_, __) => _placeholder(cs, Icons.image_outlined),
                errorWidget: (_, __, ___) =>
                    _placeholder(cs, Icons.broken_image_outlined),
              );
    if (radius != null) {
      img = ClipRRect(borderRadius: radius!, child: img);
    }
    return img;
  }

  Widget _placeholder(ColorScheme cs, IconData icon) {
    return Container(
      width: width,
      height: height,
      color: cs.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(icon,
          size: iconSize, color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
    );
  }
}
