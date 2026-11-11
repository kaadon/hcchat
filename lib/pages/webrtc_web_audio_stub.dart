/// 原生端空实现：flutter_webrtc 原生会自动播放远端音频轨道，无需挂载元素。
class WebRtcWebAudio {
  static void attach(String peerId, dynamic stream) {}
  static void detach(String peerId) {}
  static void detachAll() {}
}
