// LiveKit 视频 Web 渲染（条件导出）：
// Web 端用原生 <video> 元素 platform view + 自建 MediaStream(jsTrack) 直渲染
// （livekit_video_view_impl.dart，绕开 flutter_webrtc 抓帧链黑屏 + 远端收流
// 包装对象在 Safari 的不确定性）；原生端走 VideoTrackRenderer（占位 stub）。
export 'livekit_video_view_stub.dart'
    if (dart.library.html) 'livekit_video_view_impl.dart';
