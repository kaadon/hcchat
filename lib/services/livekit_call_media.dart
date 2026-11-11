import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

import 'api_client.dart';
import 'call_media.dart';
import 'livekit_video_view.dart';

/// LiveKit 开源 SFU 媒体引擎（后台 call_engine=livekit 时启用，三引擎之三）。
///
/// 与 WebRTC Mesh 的区别：双方各持后端签发的 JoinToken 直连 LiveKit SFU 房间
/// （房间号 = 会话 ID），媒体由 SFU 转发 —— **不需要 sdp/ice 信令**，
/// [onSignalOut]/[onSignalIn]/[peerJoined]/[peerLeft] 全部空实现。
/// 与 TRTC 的区别：房间号直接用会话 ID（TRTC 因数字房间限制截了后 8 位），
/// participant identity = 用户 ID 字符串，对端据此渲染视频视图。
class LiveKitCallMedia implements CallMedia {
  Room? _room;
  LocalParticipant? _local;

  /// 本地摄像头轨道通知（本地预览视图监听；join 后置位）
  final ValueNotifier<VideoTrack?> _localTrack =
      ValueNotifier<VideoTrack?>(null);

  /// 远端成员的视频轨道（identity -> notifier；TrackSubscribed/Unsubscribed 维护）
  final Map<String, ValueNotifier<VideoTrack?>> _remoteTracks = {};

  @override
  void Function(String userId)? onRemoteJoined;
  @override
  void Function(String userId)? onRemoteLeft;
  @override
  void Function(Map<String, dynamic> sig)? onSignalOut;

  @override
  bool get isReal => true;

  @override
  Future<String?> join({
    required String roomId,
    required String myId,
    required bool isVideo,
    Map<String, dynamic>? trtcSig,
  }) async {
    // 1. 向后端要 url + JoinToken（HS256 JWT，2 小时有效，服务端用 apiSecret 签发）
    try {
      final r = await ApiClient.instance
          .get('/api/v1/livekit/token', query: {'room': roomId});
      final d = (r.data['data'] as Map<String, dynamic>?) ?? {};
      final url = d['url']?.toString() ?? '';
      final token = d['token']?.toString() ?? '';
      if (url.isEmpty || token.isEmpty) {
        return 'LiveKit 未配置（后台需填 livekit_url / livekit_api_key / livekit_api_secret）';
      }

      // 2. 建房间、挂事件（先挂监听再 connect，防竞态漏事件）
      final room = Room();
      _room = room;
      _wire(room);

      // 3. 连接 SFU
      await room.connect(url, token);

      // 3.5 存量成员补发（2026-09-22 源码实锤）：SDK 对「本端进房时已在房间」
      //     的对端（JoinResponse.otherParticipants）只创建对象、**不发**
      //     ParticipantConnectedEvent —— 该事件只对后续新进成员发。
      //     后果：后进房的一方（接听端）永远收不到 onRemoteJoined →
      //     通话页 _remoteUserId 恒空 → 远端视频组件从未创建 → 远端黑屏，
      //     而先进房的一方一切正常（单向黑屏）。
      //     这里手动补齐：补 onRemoteJoined + 已就绪的订阅视频轨道。
      for (final p in room.remoteParticipants.values) {
        debugPrint('[lk] pre-existing remote participant ${p.identity}');
        onRemoteJoined?.call(p.identity);
        _syncRemoteTracks(p);
      }

      // 4. 本地媒体：麦克风必开（通话底线），摄像头按通话类型；
      //    摄像头失败不放弃通话（降级纯语音 + 仅接收对方画面）
      _local = room.localParticipant;
      try {
        await _local!.setMicrophoneEnabled(true);
      } catch (e) {
        await _teardown();
        return '麦克风开启失败: $e';
      }
      if (isVideo) {
        try {
          await _local!.setCameraEnabled(true);
        } catch (_) {
          // 无摄像头/被拒 → 纯语音继续（对端画面照收）
        }
      }
      _localTrack.value = localVideoTrack();
      return null;
    } catch (e) {
      await _teardown();
      return '连接 LiveKit 房间失败: $e';
    }
  }

  /// 挂房间事件：成员进出 + 轨道订阅（视频轨道驱动远端视图）
  void _wire(Room room) {
    room.createListener()
      ..on<ParticipantConnectedEvent>((e) {
        debugPrint('[lk] participant connected ${e.participant.identity}');
        onRemoteJoined?.call(e.participant.identity);
      })
      ..on<ParticipantDisconnectedEvent>((e) {
        debugPrint('[lk] participant disconnected ${e.participant.identity}');
        _remoteTracks.remove(e.participant.identity);
        onRemoteLeft?.call(e.participant.identity);
      })
      ..on<TrackSubscribedEvent>((e) {
        debugPrint('[lk] track subscribed ${e.participant.identity} '
            'sid=${e.track.sid} video=${e.track is VideoTrack}');
        if (e.track is VideoTrack) {
          (_remoteTracks[e.participant.identity] ??=
                  ValueNotifier<VideoTrack?>(null))
              .value = e.track as VideoTrack;
        }
        // 远端音频轨道由 LiveKit SDK 自动播放，无需处理
      })
      ..on<TrackUnsubscribedEvent>((e) {
        debugPrint('[lk] track unsubscribed ${e.participant.identity} '
            'sid=${e.track.sid}');
        if (e.track is VideoTrack) {
          final n = _remoteTracks[e.participant.identity];
          if (n != null) n.value = null;
        }
      })
      ..on<RoomDisconnectedEvent>((_) {
        // 服务端断开（房间销毁/网络崩溃）：全部成员视为离开
        for (final uid in _remoteTracks.keys.toList()) {
          onRemoteLeft?.call(uid);
        }
        _remoteTracks.clear();
      });
  }

  /// 把远端成员「已订阅且就绪」的视频轨道同步进 notifier（补发用）。
  /// TrackSubscribedEvent 兜底后续到达的订阅，两边幂等。
  void _syncRemoteTracks(RemoteParticipant p) {
    for (final pub in p.videoTrackPublications) {
      final track = pub.track;
      debugPrint('[lk] pre-existing track ${p.identity} '
          'sid=${pub.sid} subscribed=${pub.subscribed} '
          'isVideo=${track is VideoTrack}');
      if (pub.subscribed && track is VideoTrack) {
        (_remoteTracks[p.identity] ??= ValueNotifier<VideoTrack?>(null))
            .value = track;
      }
    }
  }

  VideoTrack? localVideoTrack() {
    final pub = _local?.getTrackPublicationBySource(TrackSource.camera);
    final track = pub?.track;
    // VideoTrack 是 mixin（LocalVideoTrack/RemoteVideoTrack 均 with 它），
    // 这里显式 as 转型（is 判空后的隐式提升在部分分析器版本不生效）
    if (track is VideoTrack) return track as VideoTrack;
    return null;
  }

  Future<void> _teardown() async {
    _local = null;
    _localTrack.value = null;
    _remoteTracks.clear();
    try {
      await _room?.disconnect();
    } catch (_) {}
    _room = null;
  }

  @override
  Future<void> leave() async {
    await _teardown();
  }

  @override
  Future<void> setMuted(bool muted) async {
    try {
      await _local?.setMicrophoneEnabled(!muted);
    } catch (_) {}
  }

  @override
  Future<void> setCameraOn(bool on) async {
    try {
      await _local?.setCameraEnabled(on);
      _localTrack.value = localVideoTrack();
    } catch (_) {}
  }

  @override
  Future<void> switchCamera() async {
    try {
      final track = localVideoTrack();
      if (track is! LocalVideoTrack) return;
      final opts = track.currentOptions;
      if (opts is! CameraCaptureOptions) return;
      // 前后翻转：按当前朝向取反，restartTrack 换源（SDK 官方推荐路径）
      final newPos = opts.cameraPosition == CameraPosition.front
          ? CameraPosition.back
          : CameraPosition.front;
      await track.setCameraPosition(newPos);
      _localTrack.value = localVideoTrack();
    } catch (_) {}
  }

  @override
  Widget localVideo() => _LiveKitVideoView(notifier: _localTrack, mirror: true);

  @override
  Widget remoteVideo(String userId) {
    if (!_remoteTracks.containsKey(userId)) {
      debugPrint('[lk] remoteVideo view created for $userId');
    }
    final n = _remoteTracks[userId] ??= ValueNotifier<VideoTrack?>(null);
    return _LiveKitVideoView(notifier: n);
  }

  @override
  void onSignalIn(Map<String, dynamic> sig) {}

  @override
  void peerJoined(String userId, int joinTs) {}

  @override
  void peerLeft(String userId) {
    // SFU 模式：成员离开由房间事件驱动，这里只清视图兜底
    _remoteTracks.remove(userId);
    onRemoteLeft?.call(userId);
  }
}

/// LiveKit 视频渲染视图：监听轨道 notifier，有轨道就渲染，
/// 没有就透明占位（底层由通话页铺「彩色底+首字」缺省头像）。
///
/// Web 端走原生 <video> 元素 platform view（WebVideoPlatformView，与
/// webrtc 引擎同一修复件）——VideoTrackRenderer 在 web 用的 flutter_webrtc
/// 抓帧渲染链在本项目实测黑屏（2026-09-21 上午同款问题）；muted=true：
/// 远端音频由 LiveKit SDK 自己的隐藏 <audio> 播放，video 元素只出画面，
/// 静音还能免掉自动播放手势限制。
class _LiveKitVideoView extends StatefulWidget {
  final ValueNotifier<VideoTrack?> notifier;
  final bool mirror;
  const _LiveKitVideoView({required this.notifier, this.mirror = false});

  @override
  State<_LiveKitVideoView> createState() => _LiveKitVideoViewState();
}

class _LiveKitVideoViewState extends State<_LiveKitVideoView> {
  // 稳定 slotId：platformViewRegistry 同 viewType 只能注册一次，
  // 按 notifier 实例生成一次，跨 ValueListenableBuilder 重建复用
  late final String _slot =
      'lk-${identityHashCode(widget.notifier)}-${widget.mirror ? 1 : 0}-lkv${_seq++}';
  static int _seq = 0;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoTrack?>(
      valueListenable: widget.notifier,
      builder: (context, track, _) {
        if (track == null) return const SizedBox.shrink();
        if (kIsWeb) {
          // Web：原生 <video> + 自建 MediaStream(jsTrack) 直渲染
          // （远端收流包装在 iOS Safari 不可靠，详见 livekit_video_view_impl.dart）
          return LiveKitVideoPlatformView(
            slotId: _slot,
            track: track,
            mirror: widget.mirror,
          );
        }
        return VideoTrackRenderer(
          track,
          fit: VideoViewFit.cover,
          mirrorMode: widget.mirror
              ? VideoViewMirrorMode.mirror
              : VideoViewMirrorMode.auto,
        );
      },
    );
  }
}
