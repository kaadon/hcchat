// 应用内 WebView 页面（链接卡片蓝边态点击进入）。
//
// 采用与现有 web_view_io/web_view_web 一致的条件导入模式：
// 移动端走 [web_view_page_io]（webview_flutter 真机 WebView），
// Web 端走 [web_view_page_web]（webview_flutter 不支持 Web，降级为系统浏览器打开）。
// 这样保证 `flutter build web` 不会因引入 webview_flutter 而编译失败。
export 'web_view_page_io.dart' if (dart.library.html) 'web_view_page_web.dart';
