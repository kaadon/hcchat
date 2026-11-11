import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tencent_trtc_cloud/tencent_trtc_cloud.dart';

import 'trtc_engine.dart';
import '../l10n/app_locale.dart';

/// native 实现：腾讯云 TRTC 官方 Flutter 插件（SDK 2.9.x API）
/// 群通话：远端成员按 userId 管理（多远端），不再只跟踪单个人
class TrtcEngineImpl implements TrtcEngine {
  TRTCCloud? _cloud;
  bool _inRoom = false;
  int? _localViewId;

  /// 远端成员：userId -> 视频流是否可用（onUserVideoAvailable 驱动）
  final Set<String> _videoAvailable = {};

  /// 远端成员：userId -> 已绑定的渲染 viewId（视图先建、流后到，双向就绪即绑定）
  final Map<String, int> _remoteViewIds = {};

  @override
  ValueChanged<String>? onRemoteUserEntered;

  @override
  ValueChanged<String>? onRemoteUserLeft;

  @override
  bool get isReal => true;

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
    try {
      final cloud = await TRTCCloud.sharedInstance();
      if (cloud == null) {
        return AppLocalizations.instance.t('trtcInitNoInstance');
      }
      _cloud = cloud;
      // 监听远端画面与房间事件（群通话：每个成员独立回调）
      cloud.registerListener((type, params) {
        switch (type) {
          case TRTCCloudListener.onRemoteUserEnterRoom:
            final uid = params['userId']?.toString() ?? '';
            debugPrint('[TRTC] remote user enter: $params');
            break;
          case TRTCCloudListener.onUserVideoAvailable:
            // 官方流程：远端视频流可用（available=true）时才调用 startRemoteView，
            // 否则即使进房也拿不到画面（视频通话"只显示自己"的根因）
            final uid = params['userId']?.toString() ?? '';
            final available = params['available'] == true;
            debugPrint(
                '[TRTC] user video available: uid=$uid available=$available');
            if (uid.isEmpty) break;
            if (available) {
              _videoAvailable.add(uid);
              onRemoteUserEntered?.call(uid);
              final viewId = _remoteViewIds[uid];
              if (viewId != null) startRemoteView(uid, viewId);
            } else {
              _videoAvailable.remove(uid);
              final viewId = _remoteViewIds[uid];
              if (viewId != null) stopRemoteView(uid);
              onRemoteUserLeft?.call(uid);
            }
            break;
          case TRTCCloudListener.onRemoteUserLeaveRoom:
            final uid = params['userId']?.toString() ?? '';
            if (uid.isNotEmpty) {
              _videoAvailable.remove(uid);
              _remoteViewIds.remove(uid);
              onRemoteUserLeft?.call(uid);
            }
            debugPrint('[TRTC] remote user leave: $params');
            break;
          case TRTCCloudListener.onFirstVideoFrame:
            debugPrint('[TRTC] first video frame: $params');
            break;
          default:
            break;
        }
      });
      // 进房参数
      final params = TRTCParams(
        sdkAppId: sdkAppId,
        userId: userId,
        userSig: userSig,
        roomId: roomId,
        role: TRTCCloudDef.TRTCRoleAnchor,
      );
      // 2.9.x：enterRoom(param, scene)，scene 传视频/音频通话场景
      final scene = isVideo
          ? TRTCCloudDef.TRTC_APP_SCENE_VIDEOCALL
          : TRTCCloudDef.TRTC_APP_SCENE_AUDIOCALL;
      await cloud.enterRoom(params, scene);
      _inRoom = true;
      // 采集音频（默认音质）
      await cloud.startLocalAudio(TRTCCloudDef.TRTC_AUDIO_QUALITY_DEFAULT);
      // 视频通话：若调用方已传入本地 viewId，则直接开启预览。
      // 采集失败（无摄像头/权限被拒）不挂掉进房：继续留在房里收对方画面与声音
      if (isVideo && localView is int) {
        _localViewId = localView;
        try {
          await cloud.startLocalPreview(true, localView);
        } catch (e) {
          debugPrint('[TRTC] 本地摄像头采集失败（降级为仅接收）: $e');
        }
      }
      return null;
    } catch (e) {
      return AppLocalizations.instance.t('trtcInitFailed', {'err': '$e'});
    }
  }

  @override
  Future<void> exitRoom() async {
    _videoAvailable.clear();
    _remoteViewIds.clear();
    if (_cloud != null && _inRoom) {
      try {
        await _cloud!.stopLocalAudio();
        await _cloud!.exitRoom();
      } catch (_) {}
      _inRoom = false;
    }
    if (_cloud != null) {
      TRTCCloud.destroySharedInstance();
      _cloud = null;
    }
  }

  @override
  Future<void> setMuted(bool muted) async {
    try {
      await _cloud?.muteLocalAudio(muted);
    } catch (_) {}
  }

  @override
  Future<void> setSpeaker(bool on) async {
    // 2.9.x：扬声器切换走设备管理器（int 常量）
    try {
      final dev = _cloud?.getDeviceManager();
      if (dev != null) {
        await dev.setAudioRoute(on
            ? TRTCCloudDef.TRTC_AUDIO_ROUTE_SPEAKER
            : TRTCCloudDef.TRTC_AUDIO_ROUTE_EARPIECE);
      }
    } catch (_) {}
  }

  @override
  Future<void> setCameraOn(bool on) async {
    try {
      if (on) {
        // 必须有业务层设置的小窗 viewId，否则 startLocalPreview(null) 会全屏渲染本地画面
        if (_localViewId == null) return;
        await _cloud?.startLocalPreview(true, _localViewId);
      } else {
        await _cloud?.stopLocalPreview();
      }
    } catch (_) {}
  }

  @override
  Future<void> switchCamera() async {
    try {
      final dev = _cloud?.getDeviceManager();
      if (dev != null) await dev.switchCamera(false);
    } catch (_) {}
  }

  @override
  Widget localVideoView({required ValueChanged<int> onViewCreated}) {
    return TRTCCloudVideoView(
      onViewCreated: (id) {
        _localViewId = id;
        onViewCreated(id);
      },
    );
  }

  @override
  Widget remoteVideoView(
      {required String userId, required ValueChanged<int> onViewCreated}) {
    return TRTCCloudVideoView(
      onViewCreated: (id) {
        _remoteViewIds[userId] = id;
        onViewCreated(id);
        // 若该成员视频流已可用，立即绑定画面
        if (_videoAvailable.contains(userId)) {
          startRemoteView(userId, id);
        }
      },
    );
  }

  @override
  Future<void> startLocalPreview(int viewId) async {
    _localViewId = viewId;
    try {
      await _cloud?.startLocalPreview(true, viewId);
    } catch (_) {}
  }

  @override
  Future<void> startRemoteView(String userId, int viewId) async {
    _remoteViewIds[userId] = viewId;
    try {
      await _cloud?.startRemoteView(
        userId,
        TRTCCloudDef.TRTC_VIDEO_STREAM_TYPE_BIG,
        viewId,
      );
    } catch (_) {}
  }

  @override
  Future<void> stopRemoteView(String userId) async {
    try {
      await _cloud?.stopRemoteView(
        userId,
        TRTCCloudDef.TRTC_VIDEO_STREAM_TYPE_BIG,
      );
    } catch (_) {}
  }
}
