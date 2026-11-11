// WebRTC 视频渲染（条件导出）：
// Web 端用原生 <video> 元素 platform view 直接显示（webrtc_video_view_impl.dart，
// 绕开 flutter_webrtc web 抓帧渲染链的黑屏问题）；
// 原生端走 flutter_webrtc 的 RTCVideoView（占位 webrtc_video_view_stub.dart）。
export 'webrtc_video_view_stub.dart'
    if (dart.library.html) 'webrtc_video_view_impl.dart';
