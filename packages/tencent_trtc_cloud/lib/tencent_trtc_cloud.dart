/// 腾讯云 TRTC Flutter SDK 主入口（本地化插件：re-export 全部公开 API）
///
/// 本地化原因：删除 web 平台声明，避免 flutter build web 编译其 web 实现
/// 报 platformViewRegistry 未定义（Flutter 3.44+ 已移至 dart:ui_web）。
/// 此文件为官方主入口的等价物。
library tencent_trtc_cloud;

export 'trtc_cloud.dart';
export 'trtc_cloud_def.dart';
export 'trtc_cloud_listener.dart';
export 'trtc_cloud_video_view.dart';
export 'deprecated_trtc_cloud.dart';
export 'tx_audio_effect_manager.dart';
export 'tx_beauty_manager.dart';
export 'tx_device_manager.dart';
