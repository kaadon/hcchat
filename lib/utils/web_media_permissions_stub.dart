/// 原生端空占位：麦克风/摄像头运行时权限由 permission_handler
///（CallPermissions）在动作时申请，不走浏览器 getUserMedia。
typedef WebMediaPermissionsResult = ({bool mic, bool cam});

class WebMediaPermissions {
  static Future<bool> mic() async => true;
  static Future<WebMediaPermissionsResult> micCam() async =>
      (mic: true, cam: true);
}
