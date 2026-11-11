/// Web 实现：读 navigator.userAgent
import 'dart:html' as html;

String webUserAgent() {
  try {
    return html.window.navigator.userAgent;
  } catch (_) {
    return '';
  }
}
