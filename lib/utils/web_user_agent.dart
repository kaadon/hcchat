/// 条件导出：Web 环境返回浏览器 UA，native 返回空串。
/// device_page 用它区分「手机网页 / 电脑网页」（dart:html 不能进 native 编译，
/// 必须经条件导入隔离，见 voice_recorder 同款做法）。
export 'web_user_agent_stub.dart' if (dart.library.html) 'web_user_agent_web.dart';
