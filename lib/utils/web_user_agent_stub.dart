/// 非 Web 平台桩：恒返回空串（不引 dart:html，保证 native 可编译）
String webUserAgent() => '';
