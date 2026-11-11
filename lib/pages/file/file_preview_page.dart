// 文件预览页（功能 A）。
//
// 采用与 web_view_page 一致的条件导入模式：
// 移动端走 [file_preview_page_io]（photo_view 图片 + pdfx 文档），
// Web 端走 [file_preview_page_web]（webview_flutter/pdfx/photo_view 不支持 Web，降级为系统浏览器打开）。
// 这样保证 `flutter build web` 不会因引入 pdfx / photo_view 而编译失败。
export 'file_preview_page_io.dart'
    if (dart.library.html) 'file_preview_page_web.dart';
