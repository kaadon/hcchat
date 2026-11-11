import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// 原生端占位：WebRTC 视频渲染走 flutter_webrtc 的 RTCVideoView，
/// 无需 platform view（本文件仅在非 Web 编译时生效，见 webrtc_video_view.dart）。
class WebVideoPlatformView extends StatelessWidget {
  final MediaStream? stream;
  final int revision;
  final bool mirror;
  final bool muted;
  final String slotId;
  const WebVideoPlatformView({
    super.key,
    required this.slotId,
    required this.stream,
    this.revision = 0,
    this.mirror = false,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
