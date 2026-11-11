import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../l10n/app_locale.dart';
import '../utils/image_saver.dart';
import '../widgets/app_dialogs.dart';

/// 全屏图片预览（微信看大图交互：黑底 + 双指/双击缩放 + 左右滑切换 + 右上角关闭 +
/// 底部「保存到相册」胶囊按钮 / 长按大图保存）。
///
/// 传 [urls]（≥1 张）即可：1 张时自然无页码无可滑动；多图消息点开网格某张时
/// 用 [initialIndex] 定位当前图，左右滑查看上一张/下一张。未传 urls 时用单
/// [url]（老调用兼容）。
class ImageViewerPage extends StatefulWidget {
  /// 单图 url（老调用）；传 urls 时忽略
  final String url;
  final List<String>? urls;
  final int initialIndex;
  const ImageViewerPage(
      {super.key, this.url = '', this.urls, this.initialIndex = 0});

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final List<String> _list =
      (widget.urls != null && widget.urls!.isNotEmpty)
          ? List<String>.from(widget.urls!)
          : [widget.url];
  late final PageController _pageCtrl;
  int _index = 0;

  /// 当前页处于缩放态：禁 PageView 横滑，把平移手势留给 InteractiveViewer
  bool _zoomed = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final start = widget.initialIndex.clamp(0, _list.length - 1).toInt();
    _pageCtrl = PageController(initialPage: start);
    _index = start;
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  String get _currentUrl => _list[_index.clamp(0, _list.length - 1)];

  /// 保存当前大图到相册，结果用轻提示反馈
  Future<void> _save() async {
    if (_saving) return;
    final t = AppLocalizations.of(context).t;
    setState(() => _saving = true);
    try {
      final ok = await ImageSaver.saveNetworkImage(_currentUrl);
      if (!mounted) return;
      AppDialogs.toast(
          context, ok ? t('momentsSaved') : t('momentsSaveFailed'));
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('momentsSaveFailed'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final multiple = _list.length > 1;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 图片层：横向 PageView 翻页；单图只有 1 页（无滑动、无页码）
          Positioned.fill(
            child: PageView.builder(
              controller: _pageCtrl,
              itemCount: _list.length,
              // 缩放中禁翻页：平移手势交给 InteractiveViewer 看细节
              physics: _zoomed
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) => _ZoomableImage(
                url: _list[i],
                onZoom: (v) {
                  if (mounted && v != _zoomed) setState(() => _zoomed = v);
                },
                onSave: _save,
              ),
            ),
          ),
          // 右上角关闭按钮：半透明黑圆底 —— 白图上也看得清（纯白图标浮在白图上看不见）
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Material(
                  color: Colors.black45,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => Navigator.of(context).pop(),
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.close, size: 22, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 页码指示（多图时）：顶部居中小胶囊
          if (multiple)
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      '${_index + 1} / ${_list.length}',
                      style: const TextStyle(fontSize: 13, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          // 底部居中「保存到相册」半透明胶囊按钮（微信式）
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Material(
                  color: Colors.white.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(22),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(22),
                    onTap: _saving ? null : _save,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_saving)
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          else
                            const Icon(Icons.save_alt,
                                size: 18, color: Colors.white),
                          const SizedBox(width: 6),
                          Text(t('momentsSaveToAlbum'),
                              style: const TextStyle(
                                  fontSize: 13, color: Colors.white)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单页可缩放大图：1x 时把横滑让给 PageView 翻页；捏合放大后 panEnabled 打开
/// （可平移看细节），缩放回到 1x 自动复位并把横滑交还翻页。
class _ZoomableImage extends StatefulWidget {
  final String url;
  final ValueChanged<bool> onZoom;
  final VoidCallback onSave;
  const _ZoomableImage(
      {required this.url, required this.onZoom, required this.onSave});

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage> {
  final _ctrl = TransformationController();
  bool _zoomed = false;

  /// 加载失败标记 + 重试代次（2026-09-26）：磁盘缓存组件失败不缓存，
  /// 点一下 bump 代次换 key 重建即可重发下载；成功后磁盘命中秒开
  bool _failed = false;
  int _attempt = 0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _setZoom(bool v) {
    if (_zoomed == v) return;
    _zoomed = v;
    widget.onZoom(v);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      transformationController: _ctrl,
      minScale: 1,
      maxScale: 4,
      panEnabled: _zoomed, // 1x 时禁平移：横滑交给 PageView 翻页
      clipBehavior: Clip.none,
      onInteractionStart: (d) {
        // 双指按下立即进入缩放态（ScaleStartDetails 无 scale，捏合量在 update 里）
        if (!_zoomed && d.pointerCount > 1) _setZoom(true);
      },
      onInteractionUpdate: (d) {
        if (!_zoomed && d.scale != 1.0) _setZoom(true);
      },
      onInteractionEnd: (_) {
        if (_zoomed && _ctrl.value.getMaxScaleOnAxis() <= 1.01) {
          _ctrl.value = Matrix4.identity();
          _setZoom(false); // 缩放回到 1x → 复位并交还翻页手势
        }
      },
      child: Center(
        child: GestureDetector(
          // 长按大图 = 保存到相册（微信式）；加载失败时点一下重试
          onLongPress: widget.onSave,
          onTap: () {
            if (!_failed) return;
            setState(() {
              _failed = false;
              _attempt++;
            });
          },
          child: Hero(
            tag: 'hero-chat-img-${widget.url}',
            // 2026-09-26：Image.network → CachedNetworkImage（磁盘缓存：
            // 打开过一次的图冷启动/翻页秒开；失败可点击重试，不再黑屏干等）
            child: CachedNetworkImage(
              key: ValueKey('viewer-${widget.url}#$_attempt'),
              imageUrl: widget.url,
              fit: BoxFit.contain,
              placeholder: (_, __) => const Center(
                child: CircularProgressIndicator(color: Colors.white70),
              ),
              errorWidget: (_, __, ___) {
                // builder 内只记标记（不触发重建），重试由点击处理
                _failed = true;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.broken_image_outlined,
                        size: 56, color: Colors.white54),
                    const SizedBox(height: 8),
                    Text('图片加载失败，点击重试',
                        style: TextStyle(
                            fontSize: 13,
                            color: Colors.white.withValues(alpha: 0.7))),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
