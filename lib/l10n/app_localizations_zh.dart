// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appName => '企业 IM';

  @override
  String get tabMessages => '消息';

  @override
  String get tabContacts => '通讯录';

  @override
  String get tabCalls => '通话';

  @override
  String get tabMe => '我的';

  @override
  String get chatTitle => '消息';

  @override
  String chatUnreadSummary(int count) {
    return '$count 个会话有未读消息';
  }

  @override
  String get chatSearchPlaceholder => '搜索同事、群组、聊天记录';

  @override
  String get chatVideoCall => '视频通话';

  @override
  String get chatVoiceCall => '语音通话';

  @override
  String get chatPinned => '置顶';

  @override
  String get chatAll => '全部消息';

  @override
  String get authLogin => '登录';

  @override
  String get authRegister => '注册';

  @override
  String get authAccount => '账号';

  @override
  String get authPassword => '密码';

  @override
  String get authInviteCode => '邀请码';

  @override
  String get authSendCode => '发送验证码';
}
