import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import 'trtc_engine.dart';

/// Web/H5 实现：TRTC 原生插件不可用，返回模拟（UI 正常显示，提示真实通话需 App 端）
class TrtcEngineImpl implements TrtcEngine {
  @override
  ValueChanged<String>? onRemoteUserEntered;

  @override
  ValueChanged<String>? onRemoteUserLeft;

  @override
  bool get isReal => false;

  @override
  Future<String?> enterRoom({
    required int sdkAppId,
    required String userId,
    required String userSig,
    required int roomId,
    required bool isVideo,
    dynamic localView,
    dynamic remoteView,
  }) async {
    return 'H5 端暂不支持实时通话，请使用 App 端';
  }

  @override
  Future<void> exitRoom() async {}

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<void> setSpeaker(bool on) async {}

  @override
  Future<void> setCameraOn(bool on) async {}

  @override
  Future<void> switchCamera() async {}

  @override
  Widget localVideoView({required ValueChanged<int> onViewCreated}) {
    return Container(color: Colors.black);
  }

  @override
  Widget remoteVideoView(
      {required String userId, required ValueChanged<int> onViewCreated}) {
    return Container(color: Colors.black);
  }

  @override
  Future<void> startLocalPreview(int viewId) async {}

  @override
  Future<void> startRemoteView(String userId, int viewId) async {}

  @override
  Future<void> stopRemoteView(String userId) async {}
}
