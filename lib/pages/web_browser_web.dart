import 'dart:html' as html;

/// Web（H5）实现：iframe 全屏覆盖在 Flutter 页面下方（顶部 56px 留给 AppBar 与关闭按钮）
bool isWebOverlaySupported() => true;

void openBrowserOverlay(String url) {
  WebOverlayController.open(url);
}

void closeBrowserOverlay() {
  WebOverlayController.close();
}

class WebOverlayController {
  static html.IFrameElement? _iframe;

  static void open(String url) {
    close();
    final f = html.IFrameElement()
      ..src = url
      ..style.position = 'fixed'
      ..style.top = '56px'
      ..style.left = '0'
      ..style.width = '100%'
      ..style.height = 'calc(100% - 56px)'
      ..style.border = 'none'
      ..style.zIndex = '10';
    html.document.body?.append(f);
    _iframe = f;
  }

  static void close() {
    _iframe?.remove();
    _iframe = null;
  }
}
