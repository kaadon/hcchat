// Web 远端音频挂载器（条件导出）：
// 原生端 flutter_webrtc 自动播放远端音频，无需任何操作；
// Web 端（flutter_webrtc web 实现）必须有 HTML 媒体元素承载音频流才会出声。
// 语音通话页没有视频渲染组件 → H5 接听后无声（2026-09-17 用户实测）。
export 'webrtc_web_audio_stub.dart'
    if (dart.library.html) 'webrtc_web_audio_impl.dart';
