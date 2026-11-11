import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Web 端 WebRTC 视频渲染：直接用原生 <video> 元素的 platform view 显示。
///
/// 为什么不用 RTCVideoView（flutter_webrtc web 默认渲染链，2026-09-21 实测
/// H5 视频通话黑屏、声音正常——App 端能看到 H5 画面，证明轨道收发均正常，
/// 纯显示问题）：默认实现是「隐藏 video 元素（opacity:0）+ 抓帧
/// createImageFromTextureSource → ui.Image → CustomPaint 重绘」，抓帧链路
/// 在部分 Flutter/浏览器组合下抓不到帧 → 黑屏。原生 video 元素直接显示
/// 最可靠。
///
/// 远端元素不静音：视频通话的远端音频也由它承载（替代渲染器的隐藏
/// audio 元素，注意不要双重出声）；本地预览 muted=true 防回声。
/// slotId 必须唯一：platformViewRegistry 同一 viewType 只能注册一次，
/// 每次挂载追加自增序号。
class WebVideoPlatformView extends StatefulWidget {
  final MediaStream? stream;
  final int revision;
  final bool mirror;
  final bool muted;
  final String slotId;
  const WebVideoPlatformView({
    super.key,
    required this.slotId,
    required this.stream,
    this.revision = 0,
    this.mirror = false,
    this.muted = false,
  });

  @override
  State<WebVideoPlatformView> createState() => _WebVideoPlatformViewState();
}

class _WebVideoPlatformViewState extends State<WebVideoPlatformView> {
  static int _seq = 0;

  late final String _viewType;
  html.VideoElement? _el;
  bool _retryArmed = false;

  @override
  void initState() {
    super.initState();
    _viewType = 'webrtc-video-${widget.slotId}-${_seq++}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final el = html.VideoElement()
        ..autoplay = true
        ..muted = widget.muted
        ..setAttribute('playsinline', 'true')
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = 'cover'
        ..style.border = 'none'
        // 指针事件放行给 Flutter 手势层（挂断/最小化等按钮覆盖在视频上）
        ..style.pointerEvents = 'none';
      if (widget.mirror) el.style.transform = 'scaleX(-1)';
      _el = el;
      _applyStream();
      return el;
    });
  }

  @override
  void didUpdateWidget(WebVideoPlatformView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.stream, oldWidget.stream) ||
        widget.revision != oldWidget.revision) {
      _applyStream();
    }
  }

  void _applyStream() {
    final el = _el;
    if (el == null) return;
    final stream = widget.stream;
    dynamic jsStream;
    if (stream != null) {
      // MediaStreamWeb → jsStream（package:web 原生对象），同 webrtc_web_audio
      try {
        final inner = (stream as dynamic).jsStream;
        if (inner != null) jsStream = inner;
      } catch (_) {}
      jsStream ??= stream;
    }
    try {
      (el as dynamic).srcObject = jsStream;
    } catch (_) {}
    _play();
  }

  void _play() {
    final el = _el;
    if (el == null) return;
    try {
      el.play().then((_) {}, onError: (Object _) => _armGestureRetry());
    } catch (_) {
      _armGestureRetry();
    }
  }

  /// 自动播放被策略拦截时，下一次点击后重试（unmuted 视频元素需要手势激活）
  void _armGestureRetry() {
    if (_retryArmed) return;
    _retryArmed = true;
    html.document.onClick.first.then((_) {
      _retryArmed = false;
      _play();
    }).catchError((_) {});
  }

  @override
  void dispose() {
    try {
      _el?.remove();
    } catch (_) {}
    _el = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (kDebugMode) {
      debugPrint(
          '[webrtc][video-view] build $_viewType stream=${widget.stream != null} rev=${widget.revision}');
    }
    return HtmlElementView(viewType: _viewType);
  }
}
