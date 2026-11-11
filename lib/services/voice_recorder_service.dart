import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../utils/web_media_permissions.dart';
import 'voice_recorder_web_stub.dart'
    if (dart.library.html) 'voice_recorder_web.dart' as webrec;

/// 单次录音结果：本地临时文件路径 + 元信息，由聊天页 [_sendVoice] 上传并拼成
/// 消息 content JSON（{"url","duration","waveform","size"}）。
class VoiceRecorderResult {
  final String path;
  final int durationMs;
  final List<double> waveform; // 归一化 0..1 的振幅采样（绘制波形条用）
  final int sizeBytes;

  VoiceRecorderResult({
    required this.path,
    required this.durationMs,
    required this.waveform,
    required this.sizeBytes,
  });
}

/// 语音录制服务（单例）：封装 flutter_sound，对外只暴露 [start]/[stop]/[cancel]
/// 三个动作与三个进度通知（[recording]/[elapsedMs]/[cancelMode]）。
///
/// 编码选型：
/// - 原生（Android/iOS）录 AAC 进 .m4a（aacMP4），跨端最省心；
/// - H5 受浏览器限制只能录 Opus 进 .webm（opusWebM），原生端播放 webm/opus
///   为尽力而为（详见交付说明的已知兼容限制）。
///
/// 60 秒上限由 UI 监听 [elapsedMs] 触发自动发送，这里只负责采集与归一化。
class VoiceRecorderService {
  VoiceRecorderService._();
  static final instance = VoiceRecorderService._();

  final FlutterSoundRecorder _rec = FlutterSoundRecorder();
  bool _open = false;
  bool _recording = false;
  String? _path;
  int _elapsed = 0;
  final List<double> _wave = [];
  StreamSubscription<RecordingDisposition>? _sub;
  Timer? _webTick; // H5 本地时长计时（MediaRecorder 无 onProgress 流）

  /// 是否正在录音（录音按钮按下态 / 浮层显隐）
  final ValueNotifier<bool> recording = ValueNotifier(false);

  /// 已录制毫秒（UI 浮层倒计时 + 60s 自动发送判定）
  final ValueNotifier<int> elapsedMs = ValueNotifier(0);

  /// 上滑取消态（UI 浮层切红字"松开取消"）
  final ValueNotifier<bool> cancelMode = ValueNotifier(false);

  bool get isRecording => _recording;

  Future<void> _ensureOpen() async {
    if (_open) return;
    await _rec.openRecorder();
    // onProgress 流默认不发事件（间隔 0ms），必须先 setSubscriptionDuration 才采 dBFS 波形。
    await _rec.setSubscriptionDuration(const Duration(milliseconds: 100));
    _open = true;
  }

  /// 运行时申请麦克风权限；无权限直接返回 false。
  /// H5（2026-09-21）：按住说话时用 getUserMedia 先请求浏览器授权，
  /// 成功才开始录音；原生走系统权限弹窗。
  Future<bool> ensurePermission() async {
    if (kIsWeb) return WebMediaPermissions.mic();
    final s = await Permission.microphone.request();
    return s.isGranted;
  }

  Codec _codec() => kIsWeb ? Codec.opusWebM : Codec.aacMP4;
  String _ext() => kIsWeb ? 'webm' : 'm4a';

  /// 开始录音。返回 false 表示未授权或启动失败（如已在进行中）。
  Future<bool> start() async {
    if (_recording) return false;
    if (!await ensurePermission()) return false;
    _wave.clear();
    _elapsed = 0;
    elapsedMs.value = 0;
    cancelMode.value = false;
    if (kIsWeb) {
      // H5：flutter_sound 的 web 实现不可靠（openRecorder 抛未捕获 JS
      // Error、MediaRecorder 模式不发 onProgress）——直接用浏览器原生
      // MediaRecorder 自实现（见 voice_recorder_web.dart）。时长由
      // [_webTick] 本地计时；波形 dBFS 拿不到，气泡端占位平条兜底。
      final ok = await webrec.WebVoiceRecorder.instance.start();
      if (!ok) return false;
      _path = 'voice_${DateTime.now().microsecondsSinceEpoch}.webm';
      _recording = true;
      recording.value = true;
      _webTick = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (!_recording) return;
        _elapsed += 100;
        elapsedMs.value = _elapsed;
      });
      return true;
    }
    try {
      await _ensureOpen();
      final dir = await getTemporaryDirectory();
      _path =
          '${dir.path}/voice_${DateTime.now().microsecondsSinceEpoch}.${_ext()}';
      await _rec.startRecorder(
        toFile: _path,
        codec: _codec(),
        audioSource: AudioSource.microphone,
      );
    } catch (_) {
      return false;
    }
    _recording = true;
    recording.value = true;
    _sub = _rec.onProgress?.listen(_onProgress);
    return true;
  }

  void _onProgress(RecordingDisposition d) {
    if (!_recording) return;
    _elapsed = d.duration.inMilliseconds;
    elapsedMs.value = _elapsed;
    final db = d.decibels;
    if (db != null) {
      // dBFS 通常落在 -160..0，归一到 0..1；给 0.08 底噪下限，短静音也可见条。
      final v = ((db + 160) / 160).clamp(0.0, 1.0);
      _wave.add(max(v, 0.08));
    }
  }

  /// 停止录音并返回结果；未开始 / 失败返回 null。
  Future<VoiceRecorderResult?> stop() async {
    if (!_recording) return null;
    if (kIsWeb) {
      // H5：stopRecorder 换成自研 web 录制器的 stop（返回 blob: URL，
      // 上层 XFile.readAsBytes 可直接读取上传）。size web 端拿不到，置 0。
      final url = await webrec.WebVoiceRecorder.instance.stop();
      final res = (url != null)
          ? VoiceRecorderResult(
              path: url,
              durationMs: _elapsed > 60000 ? 60000 : _elapsed,
              waveform: List<double>.from(_wave),
              sizeBytes: 0,
            )
          : null;
      await _finish();
      return res;
    }
    String? p;
    try {
      p = await _rec.stopRecorder();
    } catch (_) {
      await _finish();
      return null;
    }
    final path = p ?? _path;
    int size = 0;
    if (path != null) {
      try {
        size = await File(path).length();
      } catch (_) {}
    }
    final res = (path != null)
        ? VoiceRecorderResult(
            path: path,
            durationMs: _elapsed > 60000 ? 60000 : _elapsed,
            waveform: List<double>.from(_wave),
            sizeBytes: size,
          )
        : null;
    await _finish();
    return res;
  }

  /// 取消录制并删除临时文件（上滑取消 / 权限失败回滚）。
  Future<void> cancel() async {
    if (kIsWeb) {
      // H5：释放麦克风、丢弃 chunk（无文件可删）
      await webrec.WebVoiceRecorder.instance.cancel();
    } else if (_recording) {
      try {
        await _rec.stopRecorder();
      } catch (_) {}
      if (_path != null) {
        try {
          await File(_path!).delete();
        } catch (_) {}
      }
    }
    await _finish();
  }

  Future<void> _finish() async {
    _webTick?.cancel();
    _webTick = null;
    await _sub?.cancel();
    _sub = null;
    _recording = false;
    recording.value = false;
    cancelMode.value = false;
    _path = null;
  }

  /// UI 在指针移动中调用：dy < -50 视为进入取消区。
  void setCancelMode(bool v) => cancelMode.value = v;

  Future<void> dispose() async {
    await _sub?.cancel();
    if (_open) {
      try {
        await _rec.closeRecorder();
      } catch (_) {}
      _open = false;
    }
  }
}
