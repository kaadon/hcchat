import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/call_media.dart';
import 'webrtc_video_view.dart';
import 'webrtc_web_audio.dart';

/// WebRTC 媒体引擎（开源方案，后台 call_engine=webrtc 时启用）。
///
/// - 1v1：P2P 直连（STUN 打洞 + TURN 中继兜底）；
/// - 群组：Mesh 全互连 —— 每对成员一条 PeerConnection，上限 4-6 人；
/// - 协商规则：收到 join(X) → 我向 X 发 offer（已建连则忽略）。
///   两名新成员同时加入会双向 offer（glare），按「userId 较小者让步转应答」消解，
///   两端判定一致，不会死锁。
/// - 信令：sdp/ice/leave 经 CallService 以 type=7 透传（服务端零逻辑）。
class WebRtcCallMedia implements CallMedia {
  WebRtcCallMedia({required this.iceServers});

  /// 后台下发的 STUN/TURN 列表（webrtc_ice_servers）
  final List<Map<String, dynamic>> iceServers;

  @override
  void Function(String userId)? onRemoteJoined;
  @override
  void Function(String userId)? onRemoteLeft;
  @override
  void Function(Map<String, dynamic> sig)? onSignalOut;

  MediaStream? _local;
  final Map<String, RTCPeerConnection> _pcs = {};
  final Map<String, MediaStream> _remotes = {};

  /// 原生端语音通话：远端音频轨必须绑 headless 渲染器才出声（语音页无 UI 视频视图）
  final Map<String, RTCVideoRenderer> _headlessRenderers = {};

  /// 对端「远端描述已 set」标志：ICE 候选在 setRemoteDescription 之前到达必须缓存，
  /// 否则旧版 libwebrtc 抛错静默丢弃 → 首连丢候选、需重试才通
  final Map<String, bool> _remoteReady = {};

  /// 对端未就绪时先缓存的 ICE 候选（setRemoteDescription 后统一应用）
  final Map<String, List<RTCIceCandidate>> _pendingIce = {};

  /// 已向对方发出 offer、尚等 answer（glare 判定用）
  final Set<String> _offerPending = {};

  /// 媒体未就绪（getUserMedia/权限中）时收到的信令缓存，join 完成后重放。
  /// 2026-09-17 视频通话「只看到自己画面」根因之一：被叫广播 join 早于主叫
  /// 本地媒体就绪，旧代码在 peerJoined 里直接丢弃 → 主叫永不发 offer。
  final List<Map<String, dynamic>> _earlySigs = [];

  /// _remotes 变化计数（远端视图监听它重绑流，防流晚于视图到达时黑屏）
  final ValueNotifier<int> remoteRevision = ValueNotifier(0);

  /// 本地流就绪通知（本地预览小窗监听）
  final ValueNotifier<MediaStream?> localStreamNotifier = ValueNotifier(null);

  String _myId = '';
  bool _video = false;
  bool _joined = false;

  @override
  bool get isReal => true;

  @override
  Future<String?> join({
    required String roomId,
    required String myId,
    required bool isVideo,
    Map<String, dynamic>? trtcSig,
  }) async {
    _myId = myId;
    _video = isVideo;
    try {
      _local = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': isVideo ? {'facingMode': 'user'} : false,
      });
    } catch (e) {
      // 采集整体失败（视频+音频一起请求时拒绝任一都会整体拒绝）→ 拆开降级：
      // 只采音频保住通话（仅接收对方画面 + 头像占位），音频也失败才真正报错
      debugPrint('[webrtc] getUserMedia 失败，降级纯音频: $e');
      try {
        _local = await navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': false,
        });
      } catch (e2) {
        _earlySigs.clear();
        return '采集麦克风/摄像头失败: $e2';
      }
    }
    debugPrint(
        '[webrtc] join myId=$myId video=$isVideo '
        'localTracks=${_local?.getTracks().length}');
    localStreamNotifier.value = _local;
    _joined = true;
    // 重放媒体就绪前缓存的信令（join → 发 offer；sdp/ice → 正常协商）
    if (_earlySigs.isNotEmpty) {
      final early = List<Map<String, dynamic>>.of(_earlySigs);
      _earlySigs.clear();
      for (final sig in early) {
        _dispatchSig(sig);
      }
    }
    return null;
  }

  @override
  Future<void> leave() async {
    _joined = false;
    debugPrint('[webrtc] leave');
    final pcsToClose = Map<String, RTCPeerConnection>.of(_pcs);
    final remotesToDispose = Map<String, MediaStream>.of(_remotes);
    final local = _local;
    _pcs.clear();
    _offerPending.clear();
    _pendingIce.clear();
    _earlySigs.clear();
    _remotes.clear();
    _remoteReady.clear();
    for (final hr in _headlessRenderers.values) {
      try { await hr.dispose(); } catch (_) {}
    }
    _headlessRenderers.clear();
    _local = null;
    WebRtcWebAudio.detachAll();
    // 释放顺序铁律（2026-09-21 视频通话挂断闪退修复）：必须先把流与渲染器的
    // 绑定解掉（视图监听 notifier/revision 拿到 null 后 setSrcObject(null)），
    // 再关连接，最后延迟释放原生流 —— 渲染器纹理若还引用着已释放的原生流
    // 会直接 SIGSEGV。语音页没有视频渲染器，所以此坑只在视频通话暴露。
    localStreamNotifier.value = null;
    remoteRevision.value++;
    for (final pc in pcsToClose.values) {
      try {
        await pc.close();
      } catch (_) {}
    }
    _disposeStreamsLater([...remotesToDispose.values, local]);
  }

  /// 延迟释放媒体流：给「解绑渲染器」的平台通道消息留出先被处理的窗口
  void _disposeStreamsLater(List<MediaStream?> streams) {
    unawaited(Future(() async {
      await Future.delayed(const Duration(milliseconds: 800));
      for (final s in streams) {
        try {
          await s?.dispose();
        } catch (_) {}
      }
    }));
  }

  @override
  Future<void> setMuted(bool muted) async {
    for (final t in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
  }

  @override
  Future<void> setCameraOn(bool on) async {
    for (final t in _local?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = on;
    }
  }

  @override
  Future<void> switchCamera() async {
    try {
      final video = _local?.getVideoTracks().isNotEmpty == true
          ? _local!.getVideoTracks().first
          : null;
      if (video != null) await Helper.switchCamera(video);
    } catch (_) {}
  }

  @override
  Widget localVideo() => _WebRtcVideoView(
      // key 必须区分：大小窗互换时同类型 Widget 无 key 会被 Flutter 复用旧 State，
      // 渲染器不重绑导致小窗画面卡住（2026-09-17 实测）
      key: const ValueKey('webrtc-local'),
      streamNotifier: localStreamNotifier,
      mirror: true);

  @override
  Widget remoteVideo(String userId) => _WebRtcVideoView(
      key: ValueKey('webrtc-remote-$userId'), userId: userId, media: this);

  // ============================ 信令入口 ============================

  @override
  void onSignalIn(Map<String, dynamic> sig) {
    if (!_joined) {
      // 本地媒体未就绪：先缓存，join() 完成后重放（不再静默丢弃）
      _earlySigs.add(sig);
      return;
    }
    _dispatchSig(sig);
  }

  void _dispatchSig(Map<String, dynamic> sig) {
    switch (sig['action']?.toString()) {
      case 'sdp':
        _onSdp(sig);
        break;
      case 'ice':
        _onIce(sig);
        break;
      case 'join':
        // 对端媒体就绪 → 主动向其发 offer（CallService 转发单聊/群通话 join）
        peerJoined(
          sig['userId']?.toString() ?? sig['from']?.toString() ?? '',
          (sig['ts'] as num?)?.toInt() ?? 0,
        );
        break;
      case 'leave':
        final uid = sig['userId']?.toString() ?? sig['from']?.toString() ?? '';
        if (uid.isNotEmpty) peerLeft(uid);
        break;
    }
  }

  @override
  void peerJoined(String userId, int joinTs) {
    if (!_joined || userId == _myId) return;
    if (_pcs.containsKey(userId) || _offerPending.contains(userId)) return;
    _offerTo(userId);
  }

  @override
  void peerLeft(String userId) async {
    debugPrint('[webrtc] peerLeft $userId');
    _offerPending.remove(userId);
    _pendingIce.remove(userId);
    _remoteReady.remove(userId);
    final hr = _headlessRenderers.remove(userId);
    if (hr != null) {
      try { await hr.dispose(); } catch (_) {}
    }
    WebRtcWebAudio.detach(userId);
    final stream = _remotes.remove(userId);
    final pc = _pcs.remove(userId);
    // 先解绑渲染器（视图拿到 null 后 setSrcObject(null)），再关 pc，
    // 最后延迟释放流 —— 与 leave() 同一套顺序铁律，防原生崩溃
    if (stream != null) remoteRevision.value++;
    try {
      await pc?.close();
    } catch (_) {}
    onRemoteLeft?.call(userId);
    _disposeStreamsLater([stream]);
  }

  // ============================ 内部 ============================

  Future<RTCPeerConnection> _ensurePc(String peerId) async {
    final existing = _pcs[peerId];
    if (existing != null) return existing;
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    });
    _pcs[peerId] = pc;
    _remoteReady[peerId] = false; // 远端描述尚未 set，早期 ICE 候选需缓存
    // 本地轨道加入连接
    final local = _local;
    if (local != null) {
      for (final track in local.getTracks()) {
        await pc.addTrack(track, local);
      }
    }
    pc.onTrack = (event) {
      // 原生也要留日志：2026-09-21 排查 PC→App 视频「无画面无声」需 logcat 取证
      debugPrint(
          '[webrtc] ontrack peer=$peerId kind=${event.track.kind} '
          'streams=${event.streams.length}');
      if (event.streams.isEmpty) return;
      final stream = event.streams.first;
      final isNew = !_remotes.containsKey(peerId);
      if (isNew) {
        _remotes[peerId] = stream;
        // Web 端语音通话：远端音频必须有 HTML 媒体元素承载才会出声
        //（原生端 SDK 自动播放）。视频通话远端视频元素已播音频，这里
        // 只在语音（!_video）挂载，避免双重出声（2026-09-17 H5 无声修复）。
        if (kIsWeb && !_video) {
          WebRtcWebAudio.attach(peerId, stream);
        } else if (!kIsWeb && !_video) {
          // 原生端语音通话无 UI 视频视图，远端音频轨必须绑 headless 渲染器才出声
          //（视频通话由 UI 视频视图驱动音频，不可重复绑定以免双声）
          // initialize() 幂等（并发/重复调用安全），setSrcObject 要求先 initialize 完成。
          // onTrack 是同步回调，初始化需 await → 用 async IIFE 包一层（fire-and-forget）。
          () async {
            try {
              final r = _headlessRenderers[peerId] ??= RTCVideoRenderer();
              await r.initialize();
              // 初始化期间通话已结束、渲染器已从表移除 → 立即释放避免泄漏
              if (!_headlessRenderers.containsKey(peerId)) {
                await r.dispose();
                return;
              }
              r.setSrcObject(stream: stream);
            } catch (e) {
              debugPrint('[webrtc] headless 渲染器失败 peer=$peerId: $e');
            }
          }();
        }
        onRemoteJoined?.call(peerId);
      }
      // 每个 track 事件都要广播修订号：音频/视频轨道分两个 ontrack 到达，
      // 且 dart_webrtc 每次事件都会新建流包装对象。远端视图监听修订号
      // 重绑快照，否则首绑（audio 事件）时快照里还没有 video 轨 → 黑屏
      //（2026-09-20 H5 视频通话双方无画面根因）。
      remoteRevision.value++;
    };
    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      onSignalOut?.call({
        'action': 'ice',
        'to': peerId,
        'candidate': {
          'candidate': c.candidate,
          'sdpMid': c.sdpMid,
          'sdpMLineIndex': c.sdpMLineIndex,
        },
      });
    };
    // 连接失败兜底：视为对方离开（网络崩溃等极端情况）
    pc.onConnectionState = (state) {
      // 全状态留日志：协商/ICE 卡在哪一步，logcat 一眼可见
      debugPrint('[webrtc] pc[$peerId] connectionState=$state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        peerLeft(peerId);
      }
    };
    return pc;
  }

  Future<void> _offerTo(String peerId) async {
    if (!_joined ||
        _pcs.containsKey(peerId) ||
        _offerPending.contains(peerId)) {
      return;
    }
    _offerPending.add(peerId);
    try {
      final pc = await _ensurePc(peerId);
      final offer = await pc.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': _video,
      });
      await pc.setLocalDescription(offer);
      debugPrint('[webrtc] offer -> $peerId len=${offer.sdp?.length}');
      onSignalOut?.call({
        'action': 'sdp',
        'to': peerId,
        'kind': 'offer',
        'sdp': offer.sdp,
      });
    } catch (e) {
      debugPrint('[webrtc] offer 失败 $peerId: $e');
      _offerPending.remove(peerId);
    }
  }

  Future<void> _onSdp(Map<String, dynamic> sig) async {
    if (!_joined) return;
    final from = sig['from']?.toString() ?? '';
    final kind = sig['kind']?.toString() ?? '';
    final sdp = sig['sdp']?.toString() ?? '';
    if (from.isEmpty || from == _myId || sdp.isEmpty) return;

    debugPrint('[webrtc] sdp $kind from=$from len=${sdp.length}');
    // 全程 try/catch：此前 createAnswer/setDescription 抛异常会被静默吞掉，
    // 连接永远建立不起来，表现就是「有 pc 但无声无画面」，且无从排查
    try {
      if (kind == 'offer') {
        // glare：我已向对方发过 offer 且未收到 answer。
        // 规则：userId 较小者让步（重建为应答方），较大者坚持 —— 两端判定一致。
        if (_offerPending.contains(from)) {
          if (_myId.compareTo(from) < 0) {
            _offerPending.remove(from);
            await _closePeer(from);
          } else {
            return; // 我坚持当 offerer，等对方让步
          }
        }
        final pc = await _ensurePc(from);
        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
        _remoteReady[from] = true;
        await _drainPendingIce(from);
        final answer = await pc.createAnswer({
          'offerToReceiveAudio': true,
          'offerToReceiveVideo': _video,
        });
        await pc.setLocalDescription(answer);
        debugPrint('[webrtc] answer -> $from len=${answer.sdp?.length}');
        onSignalOut?.call({
          'action': 'sdp',
          'to': from,
          'kind': 'answer',
          'sdp': answer.sdp,
        });
      } else if (kind == 'answer') {
        final pc = _pcs[from];
        if (pc == null) {
          debugPrint('[webrtc] answer 丢弃：无对应 pc from=$from');
          return;
        }
        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        _remoteReady[from] = true;
        _offerPending.remove(from);
        await _drainPendingIce(from);
      }
    } catch (e) {
      debugPrint('[webrtc] sdp 处理失败 kind=$kind from=$from: $e');
    }
  }

  Future<void> _onIce(Map<String, dynamic> sig) async {
    if (!_joined) return;
    final from = sig['from']?.toString() ?? '';
    if (from.isEmpty || from == _myId) return;
    final c = sig['candidate'];
    if (c is! Map) return;
    final candidate = RTCIceCandidate(
      c['candidate']?.toString() ?? '',
      c['sdpMid']?.toString(),
      (c['sdpMLineIndex'] as num?)?.toInt() ?? 0,
    );
    final pc = _pcs[from];
    final ready = _remoteReady[from] == true;
    if (pc != null && ready) {
      try {
        await pc.addCandidate(candidate);
      } catch (e) {
        debugPrint('[webrtc] addCandidate 失败 from=$from: $e');
      }
    } else {
      // 远端描述未 set 或 pc 未建：先缓存，setRemoteDescription 后 flush
      (_pendingIce[from] ??= []).add(candidate);
    }
  }

  Future<void> _drainPendingIce(String peerId) async {
    final pending = _pendingIce.remove(peerId);
    final pc = _pcs[peerId];
    if (pending == null || pc == null) return;
    for (final c in pending) {
      try {
        await pc.addCandidate(c);
      } catch (_) {}
    }
  }

  Future<void> _closePeer(String peerId) async {
    WebRtcWebAudio.detach(peerId);
    final stream = _remotes.remove(peerId);
    final pc = _pcs.remove(peerId);
    _remoteReady.remove(peerId);
    final hr = _headlessRenderers.remove(peerId);
    if (hr != null) {
      try { await hr.dispose(); } catch (_) {}
    }
    if (stream != null) remoteRevision.value++; // 先解绑渲染器（见 peerLeft）
    try {
      await pc?.close();
    } catch (_) {}
    _disposeStreamsLater([stream]);
  }
}

/// WebRTC 视频渲染视图。
/// - 本地：监听 localStreamNotifier（流晚于视图就绪也能自动绑上）；
/// - 远端：由 media._remotes 取流（onRemoteJoined 触发后页面才建视图，一般已就绪）。
class _WebRtcVideoView extends StatefulWidget {
  final ValueNotifier<MediaStream?>? streamNotifier;
  final String? userId;
  final WebRtcCallMedia? media;
  final bool mirror;
  const _WebRtcVideoView(
      {super.key,
      this.streamNotifier,
      this.userId,
      this.media,
      this.mirror = false});

  @override
  State<_WebRtcVideoView> createState() => _WebRtcVideoViewState();
}

class _WebRtcVideoViewState extends State<_WebRtcVideoView> {
  /// 原生端渲染器；Web 端不走（见 build 的 kIsWeb 分支——绕开
  /// flutter_webrtc web 抓帧渲染链黑屏问题，用原生 video 元素显示）
  RTCVideoRenderer? _renderer;
  MediaStream? _bound;

  /// 已绑流当时的 video 轨道数（远端轨道分批到达时据此重绑）
  int _boundVideoCount = -1;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    if (!kIsWeb) {
      final r = RTCVideoRenderer();
      _renderer = r;
      await r.initialize();
      if (!mounted) return;
    }
    _bind();
    widget.streamNotifier?.addListener(_bind);
    // 远端视图：流晚于视图到达（时序竞争）时也能自动补绑
    if (widget.streamNotifier == null && widget.media != null) {
      widget.media!.remoteRevision.addListener(_bind);
    }
  }

  void _bind() {
    MediaStream? s;
    if (widget.streamNotifier != null) {
      s = widget.streamNotifier!.value;
    } else {
      s = widget.media?._remotes[widget.userId];
    }
    if (s == null) {
      // 流已被移除（对端离开/通话结束）：必须先把渲染器与流的绑定解掉，
      // 媒体层才会延迟 dispose 流 —— 否则原生层释放流时渲染器纹理还在
      // 引用它，直接原生崩溃（2026-09-21 视频挂断闪退修复的一半）。
      if (_bound != null) {
        _bound = null;
        _boundVideoCount = -1;
        try {
          _renderer?.setSrcObject(stream: null);
        } catch (_) {}
        if (mounted) setState(() {});
      }
      return;
    }
    // 重绑条件 = 流对象变化 或 video 轨道数变化。
    // flutter_webrtc web 的渲染器在 setSrcObject 时对轨道做快照；远端流
    // 首绑发生在 audio ontrack 事件、此刻 video 轨道可能尚未加入，仅靠
    // identical 判重会导致快照永远缺 video 轨 → 视频元素空流黑屏。
    //（MediaStreamWeb.getVideoTracks() 是对原生流的实时代理，能感知
    // 轨道后到。）
    final videoCount = s.getVideoTracks().length;
    if (kIsWeb && kDebugMode) {
      debugPrint(
          '[webrtc][web] bind ${widget.streamNotifier != null ? 'local' : widget.userId}: '
          'audio=${s.getAudioTracks().length} video=$videoCount');
    }
    if (identical(s, _bound) && videoCount == _boundVideoCount) return;
    _bound = s;
    _boundVideoCount = videoCount;
    _renderer?.setSrcObject(stream: s);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.streamNotifier?.removeListener(_bind);
    widget.media?.remoteRevision.removeListener(_bind);
    _renderer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      // Web 端：原生 <video> 元素 platform view 直渲染。
      // muted 语义：本地预览静音防回声；远端不静音——视频通话的远端音频
      // 由这个元素承载（此时不挂 WebRtcWebAudio，不会双重出声）。
      // revision 用 video 轨道数，轨道后到时触发 didUpdateWidget 重新挂流。
      return WebVideoPlatformView(
        slotId:
            widget.streamNotifier != null ? 'local' : 'remote-${widget.userId}',
        stream: _bound,
        revision: _boundVideoCount,
        mirror: widget.mirror,
        muted: widget.streamNotifier != null,
      );
    }
    return RTCVideoView(
      _renderer!,
      mirror: widget.mirror,
      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      placeholderBuilder: (_) => Container(color: const Color(0xFF1A1A1A)),
    );
  }
}
