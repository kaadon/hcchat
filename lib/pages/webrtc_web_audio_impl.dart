import 'dart:html' as html;

/// Web 端实现：为每一路远端音频流创建隐藏的 <audio> 元素并挂流播放。
///
/// 为什么不用 RTCVideoView：
/// - 语音通话没有视频视图，远端音频流没有任何元素承载 → 无声；
/// - 视频通话远端视频（video 元素）已经会播音频，这里只在语音通话挂载，
///   否则会双重出声（调用方用 _video 标记区分）。
///
/// 自动播放策略：接听是用户手势，产生 sticky activation，
/// 之后异步到达的流调用 play() 允许出声，不需要额外解锁。
/// 若仍被策略拦截（play() 返回值 reject），监听下一次用户手势后重试。
///
/// 实现说明：刻意不依赖 dart:js_util（web-only 库，原生 analyze 报
/// uri_does_not_exist）。dart:html 元素上未声明的属性（srcObject）用
/// dynamic 赋值，dart2js 下等价于直接设置 JS 属性。
///
/// 流包装兼容（2026-09-20 实锤根因）：dart_webrtc 的远端流是 MediaStreamWeb
/// 包装对象，原生 MediaStream 在其 `jsStream` 字段——之前探测的
/// `jsMediaStream` 字段不存在 → 整个 Dart 包装对象被塞进 srcObject →
/// 浏览器 TypeError → 音频元素根本没创建，语音通话全端无声。
class WebRtcWebAudio {
  static final Map<String, html.MediaElement> _els = {};

  /// 手势重试是否已挂（防止重复注册监听）
  static bool _gestureArmed = false;

  static void attach(String peerId, dynamic stream) {
    detach(peerId);
    try {
      final el = html.document.createElement('audio') as html.MediaElement;
      el.id = 'webrtc-remote-audio-$peerId';
      el.autoplay = true;
      el.muted = false;
      // 从包装对象里剥出原生 MediaStream，兼容三种形态：
      // 1) MediaStreamWeb（dart_webrtc，字段 jsStream，web 主路径）；
      // 2) 旧版包装字段 jsMediaStream（历史兼容）；
      // 3) dart:html 原生流（无包装，直接用）。
      dynamic jsStream;
      try {
        final inner = (stream as dynamic).jsStream;
        if (inner != null) jsStream = inner;
      } catch (_) {}
      if (jsStream == null) {
        try {
          final inner = (stream as dynamic).jsMediaStream;
          if (inner != null) jsStream = inner;
        } catch (_) {}
      }
      jsStream ??= stream;
      // MediaElement 未声明 srcObject 类型，dynamic 设置直通 JS 属性
      (el as dynamic).srcObject = jsStream;
      html.document.body?.append(el);
      _els[peerId] = el;
      _play(el);
    } catch (_) {
      // 挂载失败退回无声（与旧行为一致），不影响信令层
    }
  }

  /// play() 的返回值必须处理：被自动播放策略拒绝时捕获并挂手势重试，
  /// 否则是未 await 的异常且永远无声。
  static void _play(html.MediaElement el) {
    try {
      el.play().then((_) {}, onError: (Object _) => _armGestureRetry());
    } catch (_) {
      _armGestureRetry();
    }
  }

  /// 下一次用户手势（点击/按压）后对所有在挂音频元素重试 play。
  static void _armGestureRetry() {
    if (_gestureArmed) return;
    _gestureArmed = true;
    void retry(html.Event _) {
      _gestureArmed = false;
      for (final el in List<html.MediaElement>.from(_els.values)) {
        try {
          el.play().then((_) {}, onError: (Object _) => _armGestureRetry());
        } catch (_) {}
      }
    }

    html.document.onClick.first.then(retry).catchError((_) {});
    // dart:html 的 HtmlDocument 未声明 onPointerDown，用通用事件流挂载
    html.document.on['pointerdown'].first.then(retry).catchError((_) {});
  }

  static void detach(String peerId) {
    final el = _els.remove(peerId);
    if (el == null) return;
    try {
      (el as dynamic).srcObject = null;
    } catch (_) {}
    el.remove();
  }

  static void detachAll() {
    for (final k in List<String>.from(_els.keys)) {
      detach(k);
    }
  }
}
