/// 非 web 平台的空实现（条件导入的 else 分支，绝不会被调用）。
/// 真实实现见 voice_recorder_web.dart（dart:html MediaRecorder）。
class WebVoiceRecorder {
  WebVoiceRecorder._();
  static final instance = WebVoiceRecorder._();

  bool get recording => false;

  Future<bool> start() async => false;
  Future<String?> stop() async => null;
  Future<void> cancel() async {}
}
