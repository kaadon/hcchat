/// H5 端麦克风/摄像头权限申请（条件导出入口）：
/// Web 端用 getUserMedia 在「动作发生时」申请（发语音消息/拨打音视频通话
/// 先请求、授权成功再继续），授权在会话内缓存（浏览器同源也会记住）；
/// 原生端为空占位（系统权限走 permission_handler，见 CallPermissions）。
export 'web_media_permissions_stub.dart'
    if (dart.library.html) 'web_media_permissions_web.dart';
