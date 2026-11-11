import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 全局语音播放状态，气泡据此高亮进度条 / 切换播放-暂停图标。
class VoicePlaybackState {
  final String? msgId; // 正在播放的消息 id（null = 空闲）
  final int positionMs;
  final int durationMs;
  final bool playing;

  const VoicePlaybackState({
    this.msgId,
    this.positionMs = 0,
    this.durationMs = 0,
    this.playing = false,
  });
}

/// 语音播放服务（单例）：同一时刻只播一条；点击正在播放的同一条则停止。
///
/// 2026-09-19 播放引擎从 flutter_sound 换成 audioplayers（iOS 语音修复）。
/// 原实现的两个 iOS 专属问题：
/// 1. **没声音**：flutter_sound 9.x 的 Dart 层没有任何音频会话控制，其原生
///    核心把会话固定在 PlayAndRecord（为录音设计）——iOS 上该类别默认走
///    **听筒**出声，录完/通话后再点播放，声音进了听筒，扬声器听不到；
///    Android 的 MediaPlayer 没有这种路由模型，所以安卓正常。
/// 2. **没动画**：其 startPlayer 对远程 URL 靠扩展名推断编解码，失败直接
///    抛异常被 toggle 的 catch 吃掉复位，气泡闪一下就回待播态，感知「点了没反应」。
/// 3. **首播延迟 7~8 秒**（2026-09-19 实测第二阶段）：远程 URL 交给 AVPlayer
///    流式播放，受服务器 Range/缓冲行为影响起播极慢——语音文件只有几十 KB，
///    改为**先下载到临时文件再本地播放**（秒起），并按 URL 缓存（重播瞬时）、
///    切换/停止时取消在途下载。
///
/// audioplayers 的解法：
/// - 每次播放前显式把 iOS 会话设为 playback（扬声器出声）；
/// - 原生端下载后播本地文件（AVAudioPlayer 路径），起播零等待；
/// - H5 不下载，直接 URL 播（HTML5 Audio 自身处理，webm/opus 也能放）；
/// - 播放异常照样复位，但路径收敛且可预期。
class VoicePlayerService {
  VoicePlayerService._();
  static final instance = VoicePlayerService._();

  final AudioPlayer _player = AudioPlayer();
  final Dio _dl = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 20),
  ));
  final Map<String, String> _fileCache = {}; // url → 本地缓存路径
  CancelToken? _cancel; // 在途下载的取消令牌（切走/停止时取消）
  int _seq = 0; // 操作代序：下载回来时用户可能已经切到别条/停止
  String? _curMsgId;
  int _durationMs = 0;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<void>? _doneSub;
  bool _streamsBound = false;

  /// 当前播放状态（气泡订阅）。
  final ValueNotifier<VoicePlaybackState> state =
      ValueNotifier(const VoicePlaybackState());

  /// 进度/完成流是广播流，生命周期内只绑一次。
  void _bindStreams() {
    if (_streamsBound) return;
    _streamsBound = true;
    _posSub = _player.onPositionChanged.listen(_onPosition);
    _doneSub = _player.onPlayerComplete.listen((_) => _reset());
  }

  void _onPosition(Duration d) {
    if (_curMsgId == null) return;
    state.value = VoicePlaybackState(
      msgId: _curMsgId,
      playing: true,
      durationMs: _durationMs,
      positionMs: d.inMilliseconds,
    );
  }

  /// 点击气泡：同一 msgId 正在播 → 停止；否则切到该条从头播。
  /// [durationMs] 传消息自带的时长（波形进度条用，比播放器探测更快更稳）。
  Future<void> toggle(String url, String msgId, {int durationMs = 0}) async {
    _bindStreams();
    if (state.value.playing && _curMsgId == msgId) {
      await _stop();
      return;
    }
    await _stop(); // 播着别的条：先停（stop 顺带复位状态 + 取消在途下载）
    final seq = ++_seq;
    _curMsgId = msgId;
    _durationMs = durationMs;
    state.value =
        VoicePlaybackState(msgId: msgId, playing: true, durationMs: durationMs);
    try {
      // iOS：显式把会话切到 playback——flutter_sound 录音留下的
      // PlayAndRecord 会话会把输出路由到听筒，这里强制回扬声器。
      await _player.setAudioContext(AudioContext(
        iOS: AudioContextIOS(category: AVAudioSessionCategory.playback),
      ));
      Source source = UrlSource(url);
      if (!kIsWeb) {
        // 原生端：先下载再播本地文件。远程 URL 直接给 AVPlayer 起播要
        // 缓冲 7~8 秒（实测），语音只有几十 KB，下载秒级完成。
        final ct = CancelToken();
        _cancel = ct;
        final path = await _download(url, ct);
        _cancel = null;
        if (seq != _seq) return; // 下载期间用户已切走/停止：丢弃本次结果
        source = DeviceFileSource(path);
      }
      await _player.play(source);
    } catch (_) {
      // 下载失败 / 拉流失败 / 解码不支持（如 H5 录的 webm 在 iOS 原生端）：
      // 复位，气泡回到待播态。用户切走导致的取消不计（状态已被 stop 复位）。
      if (seq == _seq) _reset();
    }
  }

  /// 下载语音到临时文件（按 URL 缓存，命中且文件还在直接复用）。
  Future<String> _download(String url, CancelToken ct) async {
    final hit = _fileCache[url];
    if (hit != null && File(hit).existsSync()) return hit;
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/voice_${DateTime.now().microsecondsSinceEpoch}${_extOf(url)}';
    final r = await _dl.download(url, path, cancelToken: ct);
    if (r.statusCode == 200) {
      _fileCache[url] = path;
      return path;
    }
    throw Exception('voice download http ${r.statusCode}');
  }

  /// 从 URL 推断文件扩展名（iOS AVAudioPlayer 按扩展名识别格式；
  /// MinIO 带签名参数时先剥掉 query 再取）。
  static String _extOf(String url) {
    final clean = url.split('?').first.toLowerCase();
    final dot = clean.lastIndexOf('.');
    if (dot < 0) return '.m4a';
    final e = clean.substring(dot);
    return RegExp(r'^\.[a-z0-9]{2,5}$').hasMatch(e) ? e : '.m4a';
  }

  Future<void> _stop() async {
    _cancel?.cancel();
    _cancel = null;
    try {
      await _player.stop();
    } catch (_) {}
    _reset();
  }

  void _reset() {
    _curMsgId = null;
    _durationMs = 0;
    state.value = const VoicePlaybackState();
  }

  Future<void> dispose() async {
    await _posSub?.cancel();
    await _doneSub?.cancel();
    _posSub = null;
    _doneSub = null;
    _streamsBound = false;
    try {
      await _player.dispose();
    } catch (_) {}
  }
}
