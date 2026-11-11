import 'package:flutter/material.dart';

import '../pages/trtc_engine.dart';
import '../pages/webrtc_call_media.dart';
import 'livekit_call_media.dart';

/// 统一媒体引擎接口 —— TRTC / WebRTC 同一形状。
///
/// 通话页与 CallService 只依赖此抽象：
/// - 呼叫控制信令（invite/accept/hangup）在 CallService，与引擎无关；
/// - WebRTC 的媒体协商（sdp/ice）经 [onSignalOut] 外发、[onSignalIn] 注入，
///   由 CallService 以 type=7 消息透传（服务端零逻辑）；
/// - 群通话：TRTC 房间原生多人；WebRTC 走 Mesh（每对成员一条直连，上限 4-6 人）。
abstract class CallMedia {
  /// 远端成员首路流到达（群通话每人触发一次）
  void Function(String userId)? onRemoteJoined;

  /// 远端成员离开
  void Function(String userId)? onRemoteLeft;

  /// 媒体层需外发的信令（仅 WebRTC：sdp/ice），CallService 负责经 type=7 发出
  void Function(Map<String, dynamic> sig)? onSignalOut;

  bool get isReal;

  /// 进房/就绪。返回 null=成功，否则错误文案。
  /// [trtcSig] 仅 TRTC 需要（appId/userId/userSig，后端 /trtc/usersig 签发）。
  Future<String?> join({
    required String roomId,
    required String myId,
    required bool isVideo,
    Map<String, dynamic>? trtcSig,
  });

  Future<void> leave();

  Future<void> setMuted(bool muted);
  Future<void> setCameraOn(bool on);
  Future<void> switchCamera();

  /// 本地预览视图（进房前后都可安全调用，内部处理绑定时序）
  Widget localVideo();

  /// 远端成员视频视图（按 userId；语音通话不需要）
  Widget remoteVideo(String userId);

  /// 注入对端媒体信令（sdp/ice/leave），仅 WebRTC 实现，TRTC 忽略
  void onSignalIn(Map<String, dynamic> sig);

  /// 群通话：某成员媒体就绪（WebRTC mesh：向其发起 offer；TRTC 忽略）
  void peerJoined(String userId, int joinTs);

  /// 群通话：某成员退出（关闭对应通道）
  void peerLeft(String userId);
}

/// 工厂：按后台 call_engine 创建引擎
CallMedia createCallMedia({
  required String engine,
  List<Map<String, dynamic>> iceServers = const [],
}) {
  if (engine == 'webrtc') {
    return WebRtcCallMedia(iceServers: iceServers);
  }
  if (engine == 'livekit') {
    return LiveKitCallMedia();
  }
  return TrtcCallMedia();
}

/// TRTC 实现：包装现有 TrtcEngine（条件导入 native/web），viewId 绑定时序内部消化
class TrtcCallMedia implements CallMedia {
  final TrtcEngine _e = createTrtcEngine();
  bool _entered = false;
  int? _localViewId;

  @override
  void Function(String userId)? onRemoteJoined;
  @override
  void Function(String userId)? onRemoteLeft;
  @override
  void Function(Map<String, dynamic> sig)? onSignalOut;

  @override
  bool get isReal => _e.isReal;

  @override
  Future<String?> join({
    required String roomId,
    required String myId,
    required bool isVideo,
    Map<String, dynamic>? trtcSig,
  }) async {
    final sig = trtcSig ?? const {};
    _e.onRemoteUserEntered = (uid) => onRemoteJoined?.call(uid);
    _e.onRemoteUserLeft = (uid) => onRemoteLeft?.call(uid);
    final roomIdNum = int.tryParse(
            roomId.length > 8 ? roomId.substring(roomId.length - 8) : roomId) ??
        1;
    final err = await _e.enterRoom(
      sdkAppId: (sig['appId'] as num?)?.toInt() ?? 0,
      userId: sig['userId']?.toString() ?? myId,
      userSig: sig['userSig']?.toString() ?? '',
      roomId: roomIdNum,
      isVideo: isVideo,
    );
    if (err == null) {
      _entered = true;
      final id = _localViewId;
      if (id != null) await _e.startLocalPreview(id);
    }
    return err;
  }

  void _tryBindLocal() {
    final id = _localViewId;
    if (_entered && id != null) _e.startLocalPreview(id);
  }

  @override
  Future<void> leave() => _e.exitRoom();

  @override
  Future<void> setMuted(bool muted) => _e.setMuted(muted);

  /// 听筒/扬声器切换（仅 TRTC 实现；WebRTC 移动端由系统自动路由）
  Future<void> setSpeaker(bool on) => _e.setSpeaker(on);

  @override
  Future<void> setCameraOn(bool on) => _e.setCameraOn(on);

  @override
  Future<void> switchCamera() => _e.switchCamera();

  @override
  Widget localVideo() => _e.localVideoView(onViewCreated: (id) {
        _localViewId = id;
        _tryBindLocal();
      });

  @override
  Widget remoteVideo(String userId) =>
      _e.remoteVideoView(userId: userId, onViewCreated: (_) {});

  @override
  void onSignalIn(Map<String, dynamic> sig) {}

  @override
  void peerJoined(String userId, int joinTs) {}

  @override
  void peerLeft(String userId) {
    _e.stopRemoteView(userId);
    onRemoteLeft?.call(userId);
  }
}
