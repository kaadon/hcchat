// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'Enterprise IM';

  @override
  String get tabMessages => 'Messages';

  @override
  String get tabContacts => 'Contacts';

  @override
  String get tabCalls => 'Calls';

  @override
  String get tabMe => 'Me';

  @override
  String get chatTitle => 'Messages';

  @override
  String chatUnreadSummary(int count) {
    return '$count conversations unread';
  }

  @override
  String get chatSearchPlaceholder => 'Search people, groups, messages';

  @override
  String get chatVideoCall => 'Video Call';

  @override
  String get chatVoiceCall => 'Voice Call';

  @override
  String get chatPinned => 'Pinned';

  @override
  String get chatAll => 'All Messages';

  @override
  String get authLogin => 'Login';

  @override
  String get authRegister => 'Register';

  @override
  String get authAccount => 'Account';

  @override
  String get authPassword => 'Password';

  @override
  String get authInviteCode => 'Invite Code';

  @override
  String get authSendCode => 'Send Code';
}
