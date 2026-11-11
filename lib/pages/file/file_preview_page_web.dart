import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../config/app_config.dart';
import '../../services/api_client.dart';
import '../../services/conversation_service.dart';
import '../../services/group_file_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_dialogs.dart';

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

enum _PreviewState {
  loading,
  processing,
  image,
  text,
  video,
  browser,
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
  VideoPlayerController? _videoController;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _state = _PreviewState.loading;
      _imageProvider = null;
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
      if (status != 'ready') {
        setState(() => _state = _PreviewState.notSupported);
        return;
      }

      final rawUrl = (data['url'] ?? '').toString();
      if (rawUrl.isEmpty) {
        setState(() => _state = _PreviewState.notSupported);
        return;
      }
      _absUrl = _abs(rawUrl);

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

      if (kind == 'video' || widget.item.category == 'video' || _isVideo(rawUrl)) {
        await _initVideo();
        return;
      }

      if (_isImage(rawUrl, data['contentType'])) {
        final bytes = await _fetchBytes(_absUrl);
        if (!mounted) return;
        if (bytes == null) {
          setState(() {
            _state = _PreviewState.error;
            _errMsg = '图片加载失败，请稍后重试';
          });
          return;
        }
        _imageProvider = MemoryImage(Uint8List.fromList(bytes));
        setState(() => _state = _PreviewState.image);
        return;
      }

      setState(() => _state = _PreviewState.browser);
    } on ApiException catch (_) {
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

  Future<void> _initVideo() async {
    final ctl = VideoPlayerController.networkUrl(Uri.parse(_absUrl));
    _videoController = ctl;
    try {
      await ctl.initialize();
      if (!mounted) return;
      setState(() => _state = _PreviewState.video);
      await ctl.play();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _state = _PreviewState.error;
        _errMsg = '视频加载失败，请稍后重试';
      });
    }
  }

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

  bool _isVideo(String url) {
    final lower = url.toLowerCase();
    final name = widget.item.name.toLowerCase();
    const exts = [
      '.mp4',
      '.webm',
      '.mov',
      '.m4v',
      '.mkv',
      '.avi',
      '.ogg',
      '.ogv',
    ];
    return exts.any((e) => lower.contains(e) || name.endsWith(e));
  }

  String _decodeText(List<int> bytes) {
    try {
      return const Utf8Decoder(allowMalformed: true).convert(bytes);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  String _abs(String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    final base = AppConfig.instance.apiBase;
    if (base.endsWith('/')) {
      return '$base${url.startsWith('/') ? url.substring(1) : url}';
    }
    return '$base${url.startsWith('/') ? url : '/$url'}';
  }

  Future<void> _openBrowser() async {
    final uri = Uri.tryParse(_absUrl);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) AppDialogs.toast(context, '打开失败');
    }
  }

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
    final dark = _state == _PreviewState.image || _state == _PreviewState.video;
    return Scaffold(
      backgroundColor:
          dark ? Colors.black : Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: context.cs.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              size: 26, color: Color(0xFF111111)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(widget.item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: Color(0xFF111111))),
        centerTitle: true,
        actions: [
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
        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 4,
          child: Center(
            child: Image(
              image: _imageProvider!,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => _centerNote(
                  icon: Icons.broken_image_outlined, text: '图片加载失败'),
            ),
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
          return _centerNote(
              icon: Icons.videocam_off_outlined, text: '视频加载失败');
        }
        return _VideoPlayerView(controller: ctl);
      case _PreviewState.browser:
        return _centerNote(
          icon: Icons.open_in_browser_outlined,
          text: '该类型请用浏览器打开查看',
          actionLabel: '用浏览器打开',
          actionIcon: Icons.open_in_browser,
          onAction: _openBrowser,
        );
      case _PreviewState.notSupported:
        return _centerNote(
          icon: Icons.file_open_outlined,
          text: '暂不支持预览，请下载',
          actionLabel: '下载',
          actionIcon: Icons.download_outlined,
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
    IconData actionIcon = Icons.refresh,
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
                style: TextStyle(
                    fontSize: 15, color: context.cs.onSurfaceVariant)),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: onAction,
                icon: Icon(actionIcon, size: 18),
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
    if (mounted) setState(() {});
  }

  void _toggle() {
    final c = widget.controller;
    if (c.value.isPlaying) {
      c.pause();
    } else {
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
                aspectRatio:
                    c.value.aspectRatio <= 0 ? 16 / 9 : c.value.aspectRatio,
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
