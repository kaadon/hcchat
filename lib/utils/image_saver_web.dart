import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

/// Web 端保存图片。
///
/// 优先级（实测 2026-09-22：iOS Safari 的 <a download> 只进「文件」，
/// Chrome iOS 只能选网盘 —— 要直接进相册必须走 Web Share API）：
/// ① 移动端（maxTouchPoints>0）：navigator.share({files:[File]}) ——
///    iOS/Android 分享面板自带「存储图像/保存到相册」，直落系统相册。
///    dart:html 未声明 share（dynamic 传 Dart Map 也不会转 JS 对象），
///    故用 Script 桥接：字节转 data URL 放 DOM 属性 → 桥内 atob 还原
///    File 后调用；桥失败自动回退。
/// ② 桌面端 / 桥失败：Blob + <a download>（桌面浏览器落下载目录）。
/// ③ 字节拿不到（跨域无 CORS 头）：新标签页打开原图，长按存储图像。
Future<bool> saveImageBytes(
    Uint8List? bytes, String fileName, String url) async {
  if (bytes != null && bytes.isNotEmpty) {
    final mime = _mimeFromName(fileName);
    // ① 移动端：Web Share 带文件分享 → 系统相册
    if ((html.window.navigator.maxTouchPoints ?? 0) > 0) {
      final ok = await _shareViaScript(bytes, fileName, mime);
      if (ok) return true;
    }
    // ② Blob + <a download>
    if (await _downloadViaBlob(bytes, fileName)) return true;
  }
  // ③ 新标签页兜底：长按图片选「存储图像」
  try {
    html.window.open(url, '_blank');
    return true;
  } catch (_) {
    return false;
  }
}

/// Script 桥接调 navigator.share({files})。
/// 结果写回 helper 元素的 data-result 属性，Dart 侧轮询读取：
///   ok / unsupported / err:<name>
Future<bool> _shareViaScript(Uint8List bytes, String fileName, String mime) async {
  final helper = html.DivElement()
    ..id = '__lk_save_helper'
    ..style.display = 'none'
    ..attributes['data-name'] = fileName;
  html.document.body?.append(helper);
  try {
    helper.attributes['data-src'] = 'data:$mime;base64,${base64Encode(bytes)}';
    final script = html.ScriptElement()
      ..text = """
(function(){
  var el = document.getElementById('__lk_save_helper');
  var done = function(v){ el.setAttribute('data-result', v); };
  try {
    if (!navigator.share) { done('unsupported'); return; }
    var parts = el.getAttribute('data-src').split(',');
    var mime = parts[0].match(/:(.*?);/)[1];
    var bstr = atob(parts[1]);
    var n = bstr.length, u8 = new Uint8Array(n);
    while (n--) u8[n] = bstr.charCodeAt(n);
    var file = new File([u8], el.getAttribute('data-name'), {type: mime});
    var data = { files: [file] };
    if (navigator.canShare && !navigator.canShare(data)) { done('unsupported'); return; }
    navigator.share(data).then(function(){ done('ok'); },
      function(e){ done('err:' + ((e && e.name) || 'unknown')); });
  } catch (e) { done('err:' + ((e && e.name) || 'unknown')); }
})();
""";
    html.document.body?.append(script);
    script.remove();
    // 轮询结果；分享面板可能停留很久，给足 5 分钟
    for (var i = 0; i < 3000; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      final r = helper.attributes['data-result'];
      if (r == null) continue;
      return r == 'ok';
    }
    return false;
  } catch (_) {
    return false;
  } finally {
    try {
      helper.remove();
    } catch (_) {}
  }
}

/// Blob + <a download>：桌面浏览器直接落下载目录；
/// iOS Safari 会进「文件 - 下载」（作为分享失败时的兜底）。
Future<bool> _downloadViaBlob(Uint8List bytes, String fileName) async {
  try {
    final blob = html.Blob([bytes]);
    final objectUrl = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.AnchorElement(href: objectUrl)
      ..download = fileName
      ..style.display = 'none';
    html.document.body?.children.add(anchor);
    anchor.click();
    anchor.remove();
    // 不能立刻 revoke，给 Safari 发起下载留时间
    Timer(const Duration(seconds: 10), () {
      try {
        html.Url.revokeObjectUrl(objectUrl);
      } catch (_) {}
    });
    return true;
  } catch (_) {
    return false;
  }
}

String _mimeFromName(String name) {
  final n = name.toLowerCase();
  if (n.endsWith('.png')) return 'image/png';
  if (n.endsWith('.gif')) return 'image/gif';
  if (n.endsWith('.webp')) return 'image/webp';
  if (n.endsWith('.bmp')) return 'image/bmp';
  return 'image/jpeg';
}
