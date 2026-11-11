import 'dart:async';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' show VideoTrack;
// ignore: implementation_imports
// TrackStreamUpdatedEvent 未从包根导出（src/internal/events.dart），官方
// VideoTrackRenderer 也是这么监听的；用于轨道流被替换时（restartTrack 等）重挂。
import 'package:livekit_client/src/internal/events.dart'
    show TrackStreamUpdatedEvent;

/// Web 端 LiveKit 视频渲染：原生 <video> 元素 + **自建 MediaStream(jsTrack)**。
///
/// 为什么不用 VideoTrackRenderer（livekit_client web 默认渲染）：它走
/// flutter_webrtc 的抓帧链（隐藏 video + CustomPaint），本项目实测黑屏
/// （2026-09-21）；改直挂 track.mediaStream 后本地预览正常、远端在
/// iOS Safari 仍不渲染（收流 MediaStream 包装对象的状态不可靠）。
///
/// 终版做法与 livekit_client 官方 web 音频播放（_audio_html.dart）同构：
/// 取 mediaStreamTrack 的原生 js 轨道，`new MediaStream()` + addTrack 后挂
/// srcObject —— 只依赖具体的 js 轨道本身，不依赖任何包装/收流对象。
/// 元素 muted=true：远端音频由 LiveKit SDK 自己的隐藏 <audio> 播放，
/// 视频元素只出画面，静音同时免除自动播放手势限制。
///
/// 帧呈现级诊断（2026-09-22）：readyState=4 只证明解码器有数据，不证明帧
/// 被合成到屏幕。用 requestVideoFrameCallback（Safari 15.4+，帧真正呈现时
/// 触发）统计呈现帧数；若「有解码尺寸、零呈现帧」→ iOS 合成层不绘制，
/// 自动干预：补 translateZ(0) 合成层提示 + 重挂 srcObject + 复查并报
/// STILL-NO-FRAME。
class LiveKitVideoPlatformView extends StatefulWidget {
  final VideoTrack track;
  final bool mirror;
  final String slotId;
  const LiveKitVideoPlatformView({
    super.key,
    required this.track,
    required this.slotId,
    this.mirror = false,
  });

  @override
  State<LiveKitVideoPlatformView> createState() =>
      _LiveKitVideoPlatformViewState();
}

class _LiveKitVideoPlatformViewState extends State<LiveKitVideoPlatformView> {
  static int _seq = 0;

  late final String _viewType = 'lk-video-${widget.slotId}-${_seq++}';
  html.VideoElement? _el;
  dynamic _listener; // EventsListener<TrackEvent>（仅 dispose 用）
  Timer? _healthTimer;
  bool _retryArmed = false;
  int _frameCount = 0; // requestVideoFrameCallback 实际呈现帧数

  @override
  void initState() {
    super.initState();
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final el = html.VideoElement()
        ..autoplay = true
        ..muted = true
        ..setAttribute('playsinline', 'true')
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = 'cover'
        ..style.border = 'none'
        ..style.backgroundColor = '#000'
        // 指针事件放行给 Flutter 手势层（挂断/最小化等按钮覆盖在视频上）
        ..style.pointerEvents = 'none';
      if (widget.mirror) el.style.transform = 'scaleX(-1)';
      _el = el;
      // iOS Safari 策略加固：元数据就绪（有首帧尺寸）后再补一次 play；
      // 元素级 error 也接住（MediaError code/message 直接进日志）
      el.addEventListener('loadedmetadata', (html.Event _) {
        debugPrint('[lk][web] video loadedmetadata $_viewType '
            'mirror=${widget.mirror} '
            'videoW=${el.videoWidth} videoH=${el.videoHeight}');
        _play();
      });
      el.addEventListener('error', (html.Event _) {
        final err = el.error;
        debugPrint('[lk][web] video element-error $_viewType '
            'code=${err?.code} msg=${err?.message}');
      });
      _hookFrameCallback();
      _applyStream();
      return el;
    });
    _listenTrack(widget.track);
  }

  @override
  void didUpdateWidget(LiveKitVideoPlatformView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.track, oldWidget.track)) {
      _listenTrack(widget.track);
      _applyStream();
    }
  }

  void _listenTrack(VideoTrack track) {
    try {
      _listener?.dispose();
    } catch (_) {}
    _listener = null;
    _listener = track.createListener()
      ..on<TrackStreamUpdatedEvent>((e) {
        if (mounted) _applyStream();
      });
  }

  /// requestVideoFrameCallback：只在帧被真正呈现（合成进屏幕）时触发。
  /// 「元素在播但屏幕黑」时用它一锤定音：
  ///   rvfcFrames>0 → 帧已上屏，黑屏是 CSS/遮挡/层叠问题
  ///   rvfcFrames=0 → 帧没进合成层（iOS Safari 合成问题）→ 走自愈
  ///
  /// 实现说明：rVFC 是 dart:html 未声明的 JS 方法，走 dynamic 派发
  /// （dart2js 等价于直接调 JS 属性，项目约定同 webrtc_web_audio_impl.dart，
  /// 刻意不用 dart:js_util —— web-only 库会让 analyze 报 uri_does_not_exist）。
  void _hookFrameCallback() {
    final el = _el;
    if (el == null) return;
    void frameCb(dynamic _, dynamic meta) {
      _frameCount++;
      if (_frameCount <= 3 || _frameCount % 300 == 0) {
        dynamic presented, fw, fh;
        try {
          final m = meta as dynamic;
          presented = m.presentedFrames;
          fw = m.width;
          fh = m.height;
        } catch (_) {}
        debugPrint('[lk][web] video frame $_viewType n=$_frameCount '
            'presentedFrames=$presented frameW=$fw frameH=$fh');
      }
      if (mounted && identical(_el, el)) {
        try {
          (el as dynamic).requestVideoFrameCallback(frameCb);
        } catch (_) {}
      }
    }

    try {
      (el as dynamic).requestVideoFrameCallback(frameCb);
    } catch (_) {
      debugPrint('[lk][web] video rvfc=unsupported $_viewType');
    }
  }

  /// 取轨道的原生 js 轨道 → 自建 MediaStream → 挂 srcObject。
  /// 多级兜底：jsTrack → jsMediaStream/jsStream（收流包装）→ 原对象直挂。
  void _applyStream() {
    final el = _el;
    if (el == null) return;
    dynamic jsTrack;
    try {
      jsTrack = (widget.track.mediaStreamTrack as dynamic).jsTrack;
    } catch (_) {}
    bool applied = false;
    if (jsTrack != null) {
      try {
        final s = html.MediaStream();
        (s as dynamic).addTrack(jsTrack);
        el.srcObject = s;
        applied = true;
      } catch (_) {}
    }
    if (!applied) {
      dynamic jsStream;
      try {
        jsStream = (widget.track.mediaStream as dynamic).jsStream;
      } catch (_) {}
      jsStream ??= widget.track.mediaStream;
      try {
        el.srcObject = jsStream;
        applied = true;
      } catch (_) {}
    }
    debugPrint('[lk][web] video apply $_viewType mirror=${widget.mirror} '
        'jsTrack=${jsTrack != null} applied=$applied');
    _scheduleHealthCheck();
    _play();
  }

  /// 挂流 1.5s 后报一次健康状态 + 判断是否需要自愈。release 也可见。
  void _scheduleHealthCheck() {
    _healthTimer?.cancel();
    _healthTimer = Timer(const Duration(milliseconds: 1500), () {
      _reportHealth('1.5s');
      _maybeHeal();
    });
  }

  void _reportHealth(String tag) {
    final el = _el;
    if (el == null || !mounted) return;
    dynamic tr;
    try {
      tr = (widget.track.mediaStreamTrack as dynamic).jsTrack;
    } catch (_) {}
    String quality = 'n/a';
    try {
      final q = (el as dynamic).getVideoPlaybackQuality();
      quality = '${(q as dynamic).totalVideoFrames}'
          '/dropped=${(q as dynamic).droppedVideoFrames}';
    } catch (_) {}
    debugPrint('[lk][web] video health$tag $_viewType '
        'mirror=${widget.mirror} '
        'videoW=${el.videoWidth} videoH=${el.videoHeight} '
        'readyState=${el.readyState} paused=${el.paused} '
        'trackState=${tr == null ? "?" : (tr as dynamic).readyState} '
        'trackEnabled=${tr == null ? "?" : (tr as dynamic).enabled} '
        'elW=${el.clientWidth}x${el.clientHeight} '
        'rvfcFrames=$_frameCount decoded=$quality');
  }

  /// 元素一切正常但一帧都没呈现（rvfcFrames=0）→ iOS Safari 合成层不绘制。
  /// 主动干预：补 translateZ(0) 合成层提示 + 重挂 srcObject + 3.5s 后复查。
  void _maybeHeal() {
    final el = _el;
    if (el == null || !mounted) return;
    if (!(_frameCount == 0 && el.videoWidth > 0 && el.readyState >= 2)) return;
    debugPrint('[lk][web] video NO-FRAME $_viewType -> heal: '
        'translateZ(0) + re-apply srcObject');
    try {
      el.style.transform =
          (widget.mirror ? 'scaleX(-1) ' : '') + 'translateZ(0)';
      final src = el.srcObject;
      el.srcObject = null;
      Timer(const Duration(milliseconds: 120), () {
        if (!mounted || _el == null) return;
        _el!.srcObject = src;
        _play();
        debugPrint('[lk][web] video heal-applied $_viewType');
      });
    } catch (_) {}
    Timer(const Duration(milliseconds: 3500), () {
      if (!mounted || _el == null) return;
      _reportHealth('+3.5s-after-heal');
      if (_frameCount == 0) {
        debugPrint('[lk][web] video STILL-NO-FRAME $_viewType '
            '-> 帧未进合成层，请回传本条日志与 element-error');
      }
    });
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

  /// 自动播放被策略拦截时，下一次点击后重试（muted 元素一般不需要）
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
    _healthTimer?.cancel();
    try {
      _listener?.dispose();
    } catch (_) {}
    try {
      _el?.srcObject = null;
      _el?.remove();
    } catch (_) {}
    _el = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }
}
