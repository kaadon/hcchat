import 'dart:async';

import 'package:flutter/material.dart';

// 条件导入：native 用腾讯云官方插件，Web/H5 用模拟实现
// 避免 H5 编译时加载 native 插件
import 'trtc_engine_io.dart' if (dart.library.html) 'trtc_engine_web.dart';

/// 工厂：创建 TRTC 引擎实例（条件导入自动选 native/web 实现）
TrtcEngine createTrtcEngine() => TrtcEngineImpl();

/// TRTC 引擎抽象（需求11：腾讯云实时音视频，不自己造轮子）
abstract class TrtcEngine {
  /// 远端用户进入房间回调（业务层收到后可绑定远端画面）
  ValueChanged<String>? onRemoteUserEntered;

  /// 远端用户离开房间回调
  ValueChanged<String>? onRemoteUserLeft;

  /// 初始化并进房。roomId 房间号（数字），userId/userSig 后端签发
  /// 返回 null 表示成功，否则返回错误文案
  Future<String?> enterRoom({
    required int sdkAppId,
    required String userId,
    required String userSig,
    required int roomId,
    required bool isVideo,
    dynamic localView, // 本地画面容器（native: viewId / web: 忽略）
    dynamic remoteView,
  });

  /// 退出房间并销毁
  Future<void> exitRoom();

  /// 静音切换
  Future<void> setMuted(bool muted);

  /// 扬声器切换
  Future<void> setSpeaker(bool on);

  /// 摄像头开关
  Future<void> setCameraOn(bool on);

  /// 切换前后摄像头
  Future<void> switchCamera();

  /// 本地预览视图组件（native: TRTCCloudVideoView；web: 占位）
  Widget localVideoView({required ValueChanged<int> onViewCreated});

  /// 远端视频视图组件（native: TRTCCloudVideoView；web: 占位）
  /// [userId] 群通话多远端：按成员绑定各自的渲染视图
  Widget remoteVideoView(
      {required String userId, required ValueChanged<int> onViewCreated});

  /// 将本地视频画面绑定到指定 viewId
  Future<void> startLocalPreview(int viewId);

  /// 将远端视频画面绑定到指定 viewId
  Future<void> startRemoteView(String userId, int viewId);

  /// 停止订阅远端视频
  Future<void> stopRemoteView(String userId);

  bool get isReal; // 是否真实 TRTC（false = 模拟）
}
