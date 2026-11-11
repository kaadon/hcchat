import 'dart:html' as html;

/// Web 端实现：在动作发生时用 getUserMedia 申请设备权限
///（2026-09-21 用户明确：点击发语音/拨打音视频时先请求，成功再继续；
/// 不做进首页预热——浏览器后台开设备+弹窗会拖慢首页点击）。
///
/// 行为：
/// - 音视频一起请求 → 浏览器合并为一个授权框，一次点完；
/// - 整体被拒 → 拆开尽力而为：麦克风是通话底线，摄像头尽力；
/// - 拿到授权立即 stop 轨道释放设备（摄像头灯不常亮）；
/// - 会话内缓存授权结果：浏览器同源授权被记住后，后续 getUserMedia
///   虽不再弹窗但仍要开一次设备（百毫秒级），缓存后重复点击零开销；
/// - 用户拒绝后 Chrome 本会话不再弹窗（后续调用直接 reject）→ 返回
///   false，由调用方走既有「需要权限」提示，不静默重试。
typedef WebMediaPermissionsResult = ({bool mic, bool cam});

class WebMediaPermissions {
  static bool? _micGranted;
  static bool? _camGranted;

  static Future<html.MediaStream?> _gum(Map<String, dynamic> c) =>
      html.window.navigator.mediaDevices?.getUserMedia(c) ??
      Future<html.MediaStream?>.value(null);

  static void _stop(html.MediaStream? s) =>
      s?.getTracks().forEach((t) => t.stop());

  /// 请求麦克风，返回是否授权成功
  static Future<bool> mic() async {
    if (_micGranted == true) return true;
    try {
      _stop(await _gum({'audio': true}));
      _micGranted = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 请求麦克风+摄像头，拆分返回授权结果（摄像头被拒可降级纯语音）
  static Future<WebMediaPermissionsResult> micCam() async {
    if (_micGranted == true && _camGranted == true) {
      return (mic: true, cam: true);
    }
    // 先整体请求（一个授权框搞定两项）
    try {
      _stop(await _gum({'audio': true, 'video': true}));
      _micGranted = true;
      _camGranted = true;
      return (mic: true, cam: true);
    } catch (_) {}
    // 整体被拒/失败：麦克风是底线，单独再要一次
    final micOk = await mic();
    var cam = _camGranted == true;
    if (!cam) {
      try {
        _stop(await _gum({'video': true}));
        _camGranted = true;
        cam = true;
      } catch (_) {}
    }
    return (mic: micOk, cam: cam);
  }
}
