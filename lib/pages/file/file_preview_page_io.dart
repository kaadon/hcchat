import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';
import 'package:photo_view/photo_view.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../config/app_config.dart';
import '../../services/api_client.dart';
import '../../services/conversation_service.dart';
import '../../services/group_file_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_dialogs.dart';

/// 文件预览页（移动端 / IO 平台实现）。
///
/// 数据来自 [GroupFileService.preview]：
/// - `status: "ready"` → 拿到 url 渲染；
///   - 图片（category=image / URL 后缀为图片）→ [photo_view] 缩放浏览；
///   - `kind: "text"`（txt / log / md / csv / json…）→ 解码后直接渲染文本；
///   - 其它（PDF / Office 转后的 PDF）→ [pdfx] 渲染；
/// - `status: "processing"` → 显示加载中（可手动刷新重试）；
/// - 后端返回 409 / 422（不支持预览）→ 居中提示「暂不支持预览，请下载」+ 下载按钮。
///
/// 为兼容鉴权：图片与 PDF 均先经 [ApiClient]（带 Bearer）拉取字节再渲染，
/// 避免裸 [Image.network] 缺少 token 导致 403。
class FilePreviewPage extends StatefulWidget {
  final GroupFileItem item;
  final String convId;
  final String convName;

  const FilePreviewPage({
    super.key,
    required this.item,
    required this.convId,
    this.convName = '',
  });

  @override
  State<FilePreviewPage> createState() => _FilePreviewPageState();
}

/// 预览内部状态机。
enum _PreviewState {
  loading,
  processing,
  image,
  pdf,
  text,
  video, // 2026-09-16：后端 preview kind=video → video_player 在线流式播放
  error,
  notSupported,
}

class _FilePreviewPageState extends State<FilePreviewPage> {
  final _api = ApiClient.instance;
  final _svc = GroupFileService.instance;

  _PreviewState _state = _PreviewState.loading;
  String _errMsg = '';
  String _absUrl = '';
  String _textContent = '';

  ImageProvider? _imageProvider;
  PdfController? _pdfController;
  VideoPlayerController? _videoController;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pdfController?.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  /// 拉取预览元信息 + 渲染资源。
  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _state = _PreviewState.loading;
      _imageProvider = null;
      _pdfController?.dispose();
      _pdfController = null;
      _videoController?.dispose();
      _videoController = null;
    });

    try {
      final data = await _svc.preview(widget.item.fileId);
      if (!mounted) return;

      final status = (data['status'] ?? '').toString();
      if (status == 'processing') {
        setState(() => _state = _PreviewState.processing);
        return;
      }

      final rawUrl = (data['url'] ?? '').toString();
      if (rawUrl.isEmpty) {
        setState(() => _state = _PreviewState.notSupported);
        return;
      }
      _absUrl = _abs(rawUrl);

      // 纯文本（txt/log/md/csv/json…）：后端返回 kind == "text"，
      // 直接解码渲染，不再当 PDF 丢给 pdfx（pdfx 解析不了纯文本 → 报不支持预览）。
      final kind = (data['kind'] ?? '').toString();
      if (kind == 'text') {
        final textBytes = await _fetchBytes(_absUrl);
        if (!mounted) return;
        if (textBytes == null) {
          setState(() {
            _state = _PreviewState.error;
            _errMsg = '文件加载失败，请稍后重试';
          });
          return;
        }
        _textContent = _decodeText(textBytes);
        setState(() => _state = _PreviewState.text);
        return;
      }

      // 视频（后端 kind=video，2026-09-16）：不整文件拉字节，交给
      // video_player 流式播放（raw 代理支持 Range 分段）。老版本服务端没有
      // video 分支时会 409 → 落到 notSupported（与旧行为一致），按 category 兜底兼容。
      if (kind == 'video' || widget.item.category == 'video') {
        await _initVideo();
        return;
      }

      final bytes = await _fetchBytes(_absUrl);
      if (!mounted) return;
      if (bytes == null) {
        setState(() {
          _state = _PreviewState.error;
          _errMsg = '文件加载失败，请稍后重试';
        });
        return;
      }

      // 图片优先用 photo_view 缩放；其余走 pdfx。
      if (_isImage(rawUrl, data['contentType'])) {
        _imageProvider = MemoryImage(Uint8List.fromList(bytes));
        setState(() => _state = _PreviewState.image);
      } else {
        _pdfController = PdfController(
          document: PdfDocument.openData(Uint8List.fromList(bytes)),
        );
        setState(() => _state = _PreviewState.pdf);
      }
    } on ApiException catch (_) {
      // 409 / 422：后端明确不支持预览
      if (!mounted) return;
      setState(() => _state = _PreviewState.notSupported);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _PreviewState.error;
        _errMsg = '预览加载失败：${e.toString()}';
      });
    }
  }

  /// 初始化视频播放器（流式，不整文件进内存）。
  /// raw 代理链接自带 HMAC 签名（免鉴权中间件），无需额外带 Bearer 头。
  Future<void> _initVideo() async {
    final ctl = VideoPlayerController.networkUrl(Uri.parse(_absUrl));
    _videoController = ctl;
    try {
      await ctl.initialize();
      if (!mounted) return;
      setState(() => _state = _PreviewState.video);
      await ctl.play(); // 进页即播（微信/Telegram 习惯）
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _state = _PreviewState.error;
        _errMsg = '视频加载失败，请稍后重试';
      });
    }
  }

  /// 经 [ApiClient]（带 Bearer）拉取文件字节；失败返回 null。
  Future<List<int>?> _fetchBytes(String url) async {
    try {
      final r = await _api.dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'Authorization': 'Bearer ${await _api.readToken()}'},
        ),
      );
      return r.data;
    } catch (_) {
      return null;
    }
  }

  /// 是否图片：category 为 image，或 URL 后缀为图片，或后端 contentType 以 image/ 开头。
  bool _isImage(String url, dynamic contentType) {
    if (widget.item.category == 'image') return true;
    final ct = (contentType ?? '').toString().toLowerCase();
    if (ct.startsWith('image/')) return true;
    final lower = url.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
  }

  /// 文本解码：优先 UTF-8（容忍非法字节），失败降级按原始码位直转。
  String _decodeText(List<int> bytes) {
    try {
      return const Utf8Decoder(allowMalformed: true).convert(bytes);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  /// 相对路径补全为同源绝对地址（兼容后端返回相对路径）。
  String _abs(String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    final base = AppConfig.instance.apiBase;
    if (base.endsWith('/')) return '$base${url.startsWith('/') ? url.substring(1) : url}';
    return '$base${url.startsWith('/') ? url : '/$url'}';
  }

  /// 下载：走后端独立签名接口 [GroupFileService.downloadUrl]，与预览解耦。
  /// 预览 409（不支持预览）时 _absUrl 为空，下载依然可用。
  Future<void> _download() async {
    try {
      final raw = await _svc.downloadUrl(widget.item.fileId);
      if (raw.isEmpty) {
        if (mounted) AppDialogs.toast(context, '下载失败：未获取到文件地址');
        return;
      }
      final uri = Uri.tryParse(_abs(raw));
      if (uri == null) {
        if (mounted) AppDialogs.toast(context, '下载失败：文件地址无效');
        return;
      }
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) AppDialogs.toast(context, '下载失败，请检查网络');
    } on ApiException catch (e) {
      if (mounted) AppDialogs.toast(context, '下载失败：${e.message}');
    } catch (_) {
      if (mounted) AppDialogs.toast(context, '下载失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _state == _PreviewState.image ||
              _state == _PreviewState.pdf ||
              _state == _PreviewState.video
          ? Colors.black
          : Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: context.cs.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 26, color: Color(0xFF111111)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(widget.item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: Color(0xFF111111))),
        centerTitle: true,
        actions: [
          // 非加载中 / 非错误态都给下载入口：不支持预览（409）时也要能下载。
          if (_state != _PreviewState.loading && _state != _PreviewState.error)
            IconButton(
              icon: const Icon(Icons.download_outlined,
                  size: 22, color: Color(0xFF111111)),
              onPressed: _download,
              tooltip: '下载',
            ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    switch (_state) {
      case _PreviewState.loading:
        return const Center(
            child: CircularProgressIndicator(color: AppTheme.primary));
      case _PreviewState.processing:
        return _centerNote(
          icon: Icons.hourglass_top_outlined,
          text: '文件预览生成中…',
          actionLabel: '刷新',
          onAction: _load,
        );
      case _PreviewState.image:
        if (_imageProvider == null) {
          return _centerNote(
              icon: Icons.broken_image_outlined, text: '图片加载失败');
        }
        return PhotoView(
          imageProvider: _imageProvider!,
          loadingBuilder: (_, __) => const Center(
              child: CircularProgressIndicator(color: AppTheme.primary)),
          errorBuilder: (_, __, ___) => _centerNote(
              icon: Icons.broken_image_outlined, text: '图片加载失败'),
          backgroundDecoration:
              const BoxDecoration(color: Colors.black),
        );
      case _PreviewState.pdf:
        if (_pdfController == null) {
          return _centerNote(icon: Icons.picture_as_pdf_outlined, text: '文档加载失败');
        }
        return PdfView(
          controller: _pdfController!,
          builders: PdfViewBuilders<DefaultBuilderOptions>(
            // pdfx 2.11.0 起 options 为 required 命名参数（见
            // pdfx/lib/src/viewer/simple/pdf_view_builders.dart），必须显式传入。
            options: const DefaultBuilderOptions(),
            documentLoaderBuilder: (_) => const Center(
                child: CircularProgressIndicator(color: AppTheme.primary)),
            pageLoaderBuilder: (_) => const Center(
                child: CircularProgressIndicator(color: AppTheme.primary)),
            errorBuilder: (_, __) => _centerNote(
                icon: Icons.picture_as_pdf_outlined, text: '文档渲染失败'),
          ),
        );
      case _PreviewState.text:
        return Scrollbar(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              _textContent,
              style: TextStyle(
                  fontSize: 14, height: 1.5, color: context.cs.onSurface),
            ),
          ),
        );
      case _PreviewState.video:
        final ctl = _videoController;
        if (ctl == null || !ctl.value.isInitialized) {
          return _centerNote(icon: Icons.videocam_off_outlined, text: '视频加载失败');
        }
        return _VideoPlayerView(controller: ctl);
      case _PreviewState.notSupported:
        return _centerNote(
          icon: Icons.file_open_outlined,
          text: '暂不支持预览，请下载',
          actionLabel: '下载',
          onAction: _download,
        );
      case _PreviewState.error:
        return _centerNote(
          icon: Icons.error_outline,
          text: _errMsg.isNotEmpty ? _errMsg : '加载失败',
          actionLabel: '重试',
          onAction: _load,
        );
    }
  }

  Widget _centerNote({
    required IconData icon,
    required String text,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 52, color: context.cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: context.cs.onSurfaceVariant)),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(actionLabel),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 内嵌视频播放器（video_player 裸用，不引 chewie）：
/// 黑底居中按宽高比铺放 + 播放/暂停 + 进度条 + 时间；点画面切换播放/暂停。
class _VideoPlayerView extends StatefulWidget {
  final VideoPlayerController controller;

  const _VideoPlayerView({required this.controller});

  @override
  State<_VideoPlayerView> createState() => _VideoPlayerViewState();
}

class _VideoPlayerViewState extends State<_VideoPlayerView> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant _VideoPlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {}); // 播放位置/缓冲态刷新
  }

  void _toggle() {
    final c = widget.controller;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      // 播到结尾后再点 = 从头播
      if (c.value.position >= c.value.duration) c.seekTo(Duration.zero);
      c.play();
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Column(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: _toggle,
            child: Center(
              child: AspectRatio(
                aspectRatio: c.value.aspectRatio <= 0
                    ? 16 / 9
                    : c.value.aspectRatio,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    VideoPlayer(c),
                    if (!c.value.isPlaying)
                      Container(
                        width: 64,
                        height: 64,
                        decoration: const BoxDecoration(
                            color: Colors.black38, shape: BoxShape.circle),
                        child: const Icon(Icons.play_arrow,
                            size: 42, color: Colors.white),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // 底部控制条：播放/暂停 + 进度（可拖动）+ 时间
        Container(
          color: Colors.black,
          padding: const EdgeInsets.fromLTRB(8, 4, 12, 10),
          child: Row(
            children: [
              IconButton(
                icon: Icon(
                  c.value.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                ),
                onPressed: _toggle,
              ),
              Expanded(
                child: VideoProgressIndicator(
                  c,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(
                    playedColor: AppTheme.primary,
                    bufferedColor: Colors.white24,
                    backgroundColor: Colors.white12,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${_fmt(c.value.position)} / ${_fmt(c.value.duration)}',
                style: const TextStyle(fontSize: 11, color: Colors.white70),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
