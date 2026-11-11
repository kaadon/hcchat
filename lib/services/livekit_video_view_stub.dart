import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

/// 原生端占位：LiveKit 视频渲染走 VideoTrackRenderer（texture），
/// 本文件仅在非 Web 编译时生效（见 livekit_video_view.dart）。
class LiveKitVideoPlatformView extends StatelessWidget {
  final VideoTrack track;
  final bool mirror;
  final String slotId;
  const LiveKitVideoPlatformView({
    super.key,
    required this.track,
    required this.slotId,
    this.mirror = false,
  });

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
