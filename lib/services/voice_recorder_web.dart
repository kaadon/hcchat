import 'dart:async';
import 'dart:html' as html;

/// H5 语音录制（仅 web 编译，条件导入 voice_recorder_service.dart）。
///
/// 为什么不用 flutter_sound 的 web 实现：openRecorder 会在 Chrome 抛出未捕获
/// JS Error（main.dart.js Uncaught Error，2026-09-20 实测）、MediaRecorder 模式
/// 下也不发 onProgress（时长恒 0）。浏览器原生 MediaRecorder 三行就够：
/// getUserMedia 拿麦 → MediaRecorder 收 chunk → stop 拼 Blob 给 blob: URL。
/// blob URL 交给上层 XFile.readAsBytes 上传（uploadXFile web 分支支持）。
class WebVoiceRecorder {
  WebVoiceRecorder._();
  static final instance = WebVoiceRecorder._();

  html.MediaStream? _stream;
  html.MediaRecorder? _mr;
  final List<html.EventListener> _listeners = [];
  final List<html.Blob> _chunks = [];
  bool _recording = false;

  bool get recording => _recording;

  /// 开始录音。失败（拒绝授权 / 不支持 / 非安全上下文）返回 false。
  ///
  /// 注意：浏览器只在 https 或 localhost 暴露麦克风，http 部署的 H5
  /// getUserMedia 直接拒绝——这是浏览器安全策略，代码绕不过。
  Future<bool> start() async {
    if (_recording) return false;
    html.MediaStream? stream;
    try {
      final md = html.window.navigator.mediaDevices;
      if (md == null) return false; // 非安全上下文 / 不支持
      stream = await md.getUserMedia({'audio': true});
      // opus/webm 全浏览器（Chrome/Firefox/Edge/Safari 14.1+）都支持，
      // isTypeSupported 探测兜底老内核。
      var mime = 'audio/webm;codecs=opus';
      if (!html.MediaRecorder.isTypeSupported(mime)) {
        mime = 'audio/webm';
      }
      final mr = html.MediaRecorder.isTypeSupported(mime)
          ? html.MediaRecorder(stream, {'mimeType': mime})
          : html.MediaRecorder(stream);
      _chunks.clear();
      // dart:html 这版没生成 onData/onStop 封装，走 addEventListener。
      // dataavailable 事件是 BlobEvent，dart:html 类型是 Event，动态取 .data。
      final dataL = (html.Event e) {
        final data = (e as dynamic).data;
        if (data is html.Blob) _chunks.add(data);
      };
      final stopL = (html.Event e) {};
      mr.addEventListener('dataavailable', dataL);
      mr.addEventListener('stop', stopL);
      _listeners
        ..clear()
        ..addAll([dataL, stopL]);
      _mr = mr;
      _stream = stream;
      mr.start();
      _recording = true;
      return true;
    } catch (_) {
      _release(stream);
      return false;
    }
  }

  /// 停止录音并返回 blob: URL（失败/未开始返回 null）。
  Future<String?> stop() async {
    final mr = _mr;
    if (!_recording || mr == null) return null;
    final c = Completer<String?>();
    mr.addEventListener('stop', (html.Event _) {
      String? url;
      try {
        final blob = html.Blob(_chunks, 'audio/webm');
        url = html.Url.createObjectUrl(blob);
      } catch (_) {}
      _release(_stream);
      if (!c.isCompleted) c.complete(url);
    });
    try {
      mr.stop();
    } catch (_) {
      _release(_stream);
      if (!c.isCompleted) c.complete(null);
    }
    return c.future.timeout(const Duration(seconds: 3), onTimeout: () {
      _release(_stream);
      return null;
    });
  }

  /// 取消录音：丢弃数据、释放麦克风。
  Future<void> cancel() async {
    try {
      if (_mr != null && _mr!.state == 'recording') _mr!.stop();
    } catch (_) {}
    _release(_stream);
  }

  void _release(html.MediaStream? stream) {
    // 移除挂在这个 recorder 上的监听（recorder 即将丢弃，防泄漏习惯）
    final mr = _mr;
    for (final l in _listeners) {
      try {
        mr?.removeEventListener('dataavailable', l);
        mr?.removeEventListener('stop', l);
      } catch (_) {}
    }
    _listeners.clear();
    _mr = null;
    try {
      stream?.getTracks().forEach((t) => t.stop());
    } catch (_) {}
    _stream = null;
    _chunks.clear();
    _recording = false;
  }
}
