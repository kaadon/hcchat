import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/call_media.dart';
import '../services/call_service.dart';
import '../services/sound_service.dart';
import '../theme/app_theme.dart';
import '../utils/call_permissions.dart';
import '../widgets/app_avatar.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'webrtc_call_media.dart';

/// 语音通话页（单聊）：模糊背景 + 大头像 + 对方姓名 + 通话时长 + 底部按钮栏。
/// 媒体引擎按后台 call_engine 选择（TRTC / WebRTC），页面不感知差异。
class VoiceCallPage extends StatefulWidget {
  final String peerName;
  final String peerAvatar;
  final String? convId; // 会话 ID（房间号）
  const VoiceCallPage(
      {super.key, required this.peerName, this.peerAvatar = '', this.convId});

  @override
  State<VoiceCallPage> createState() => _VoiceCallPageState();
}

class _VoiceCallPageState extends State<VoiceCallPage> {
  int _seconds = 0;
  bool _muted = false;
  bool _speaker = true;
  bool _connecting = true;
  String _status = '正在连接…';
  Timer? _timer;
  CallMedia? _media;
  StreamSubscription<CallEvent>? _sub;

  bool _enteredRoom = false;
  bool _engineReady = false;
  bool _prepared = false;
  bool _pendingAccept = false;
  bool _ringStarted = false; // 主叫回铃音是否已启动

  /// 取本地化文案（未挂载时回退为 key，避免访问失效 context）
  String _t(String key, [Map<String, String>? params]) =>
      mounted ? AppLocalizations.of(context).t(key, params) : key;

  @override
  void initState() {
    super.initState();
    _sub = CallService.instance.events.listen(_onCallEvent);
    _prepare();
  }

  void _onCallEvent(CallEvent e) {
    if (e.convId != widget.convId) return;
    switch (e.action) {
      case CallAction.accept:
        _pendingAccept = true;
        _maybeEnter();
        break;
      case CallAction.reject:
        _finish(_t('voiceCallPeerRejected'));
        break;
      case CallAction.hangup:
        _finish(_t('voiceCallEnded'));
        break;
      case CallAction.cancel:
        _finish(_t('voiceCallPeerCancelled'));
        break;
    }
  }

  Future<void> _prepare() async {
    try {
      final cfg = await CallService.instance.ensureConfig();
      if (cfg.trtcUsable || cfg.webrtcUsable || cfg.livekitUsable) {
        _engineReady = true;
        _media = createCallMedia(
          engine: cfg.engine,
          iceServers: cfg.iceServers,
        );
        _media!.onSignalOut =
            (sig) => CallService.instance.sendMediaSignal(sig);
        CallService.instance.mediaSignalHandler =
            (sig) => _media?.onSignalIn(sig);
      }
      _prepared = true;
      _maybeEnter();
    } catch (e) {
      _prepared = true;
      _setStatus(_t('voiceCallStartFailed', {'error': '$e'}));
    }
  }

  void _maybeEnter() {
    final phase = CallService.instance.state.value?.phase;
    if (phase == CallPhase.connected || _pendingAccept) {
      _enterRoom();
    } else {
      _setStatus(_t('voiceCallWaitingAnswer'));
      if (!_ringStarted) {
        _ringStarted = true;
        SoundService.instance.startRingback(); // 主叫回铃音（嘟嘟声）
      }
    }
  }

  Future<void> _enterRoom() async {
    if (_enteredRoom || !mounted) return;
    if (!_prepared) return;
    if (!_engineReady) {
      setState(() => _status = _t('voiceCallUserSigFailed'));
      _startTimer();
      return;
    }
    _enteredRoom = true;
    try {
      final granted = await CallPermissions.ensureForVoice();
      if (!granted) {
        _setStatus(_t('voiceCallNeedPermissions'));
        return;
      }
      final media = _media!;
      final err = await media.join(
        roomId: widget.convId ?? '1',
        myId: CallService.instance.myId,
        isVideo: false,
        trtcSig: CallService.instance.config?.trtcSig,
      );
      if (err != null) {
        _setStatus(err);
        return;
      }
      setState(() {
        _connecting = false;
        _status = _t('voiceCallInProgress');
      });
      SoundService.instance.stopRingback(); // 停止回铃音
      SoundService.instance.playCallConnected(); // 接通提示音
      _startTimer();
      await CallService.instance.notifyMediaJoined();
    } catch (e) {
      _setStatus(_t('voiceCallEnterRoomFailed', {'error': '$e'}));
    }
  }

  void _startTimer() {
    _timer?.cancel();
    if (!mounted) return;
    setState(() => _connecting = false);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
      CallService.instance.syncCallSeconds(_seconds);
    });
  }

  void _setStatus(String s) {
    if (!mounted) return;
    setState(() {
      _status = s;
      _connecting = true;
    });
  }

  void _finish(String msg) {
    if (!mounted) return;
    _timer?.cancel();
    SoundService.instance.stopRingback(); // 停止回铃音
    SoundService.instance.playHangup(); // 通话结束提示音
    setState(() {
      _status = msg;
      _connecting = true;
    });
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    CallService.instance.mediaSignalHandler = null;
    _media?.leave();
    SoundService.instance.stopRingback(); // 兜底：离开页面确保回铃停止
    super.dispose();
  }

  String get _timeText {
    final m = (_seconds ~/ 60).toString().padLeft(2, '0');
    final s = (_seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _hangup() async {
    _timer?.cancel();
    SoundService.instance.stopRingback(); // 停止回铃音
    SoundService.instance.playHangup(); // 主动挂断提示音
    await CallService.instance.hangup();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _toggleMute() async {
    setState(() => _muted = !_muted);
    await _media?.setMuted(_muted);
  }

  Future<void> _toggleSpeaker() async {
    setState(() => _speaker = !_speaker);
    if (_media is TrtcCallMedia) {
      await (_media as TrtcCallMedia).setSpeaker(_speaker);
    } else if (_media is WebRtcCallMedia) {
      // 原生端 flutter_webrtc 扬声器/听筒切换
      await Helper.setSpeakerphoneOn(_speaker);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        color: Colors.black,
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 2),
              _avatar(),
              const SizedBox(height: 24),
              Text(widget.peerName,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Text(
                  _connecting ? _status : (_seconds == 0 ? _status : _timeText),
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.65),
                      fontSize: 14)),
              const Spacer(flex: 3),
              Padding(
                padding: const EdgeInsets.fromLTRB(40, 0, 40, 56),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _actionBtn(
                      icon: _muted ? Icons.mic_off : Icons.mic,
                      label: _muted
                          ? _t('voiceCallMuted')
                          : _t('voiceCallMicrophone'),
                      color: Colors.white.withValues(alpha: 0.2),
                      iconColor: Colors.white,
                      onTap: _toggleMute,
                    ),
                    _actionBtn(
                      icon: Icons.call_end,
                      label: _t('voiceCallHangUp'),
                      color: AppTheme.danger,
                      iconColor: Colors.white,
                      onTap: _hangup,
                    ),
                    _actionBtn(
                      icon: _speaker ? Icons.volume_up : Icons.hearing,
                      label: _speaker
                          ? _t('voiceCallSpeaker')
                          : _t('voiceCallEarpiece'),
                      color: Colors.white.withValues(alpha: 0.2),
                      iconColor: Colors.white,
                      onTap: _toggleSpeaker,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _avatar() {
    return Container(
      width: 128,
      height: 128,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppTheme.primary,
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withValues(alpha: 0.45),
            blurRadius: 32,
            spreadRadius: 6,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: AppAvatar(
        url: widget.peerAvatar,
        name: widget.peerName,
        size: 128,
        background: AppTheme.primary,
      ),
    );
  }

  Widget _actionBtn({
    required IconData icon,
    required String label,
    required Color color,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkResponse(
          onTap: onTap,
          radius: 44,
          child: Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: iconColor, size: 30),
          ),
        ),
        const SizedBox(height: 10),
        Text(label,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85), fontSize: 13)),
      ],
    );
  }
}
