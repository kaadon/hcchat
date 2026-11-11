import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../l10n/app_locale.dart';
import '../services/friend_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';
import 'friend_detail_page.dart';

/// 扫个人二维码落地页（微信逻辑）：
/// - 扫的是自己的码 → 提示后返回
/// - 已是好友 → 直接进现有好友资料页
/// - 非好友 → 显示资料卡 + 「添加到通讯录」按钮，发送好友申请
class UserQrProfilePage extends StatefulWidget {
  final String uid;

  /// 好友申请来源：1=搜索 2=扫码（默认）3=名片
  final int source;
  const UserQrProfilePage({super.key, required this.uid, this.source = 2});

  @override
  State<UserQrProfilePage> createState() => _UserQrProfilePageState();
}

class _UserQrProfilePageState extends State<UserQrProfilePage> {
  final _svc = FriendService();
  Map<String, dynamic>? _user; // 拉到的公开资料
  bool _isFriend = false;
  bool _loading = true;
  String _error = '';
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final user = await _svc.userDetail(widget.uid);
      final friends = await _svc.list();
      final me = await _svc.profile();
      if (!mounted) return;
      // 自己的码：提示后返回
      if ((me['id']?.toString() ?? '') == widget.uid) {
        AppDialogs.toast(
            context, AppLocalizations.of(context).t('userQrMyself'));
        Navigator.of(context).pop();
        return;
      }
      // 是否已是好友（顺带取好友视角的备注）
      Map<String, dynamic>? friend;
      for (final f in friends) {
        if ((f['id']?.toString() ?? '') == widget.uid) {
          friend = f;
          break;
        }
      }
      if (friend != null) {
        // 已是好友 → 直接进现有好友资料页（微信式）
        Navigator.of(context).pushReplacement(MaterialPageRoute(
            builder: (_) => FriendDetailPage(
                friend: friend!, myId: me['id']?.toString() ?? '')));
        return;
      }
      setState(() {
        _user = user;
        _isFriend = false;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  String get _name {
    final u = _user ?? const {};
    return (u['nickname'] ??
            u['account'] ??
            AppLocalizations.of(context).t('addFriendUser'))
        .toString();
  }

  Future<void> _addFriend() async {
    if (_sending || _user == null) return;
    final t = AppLocalizations.of(context).t;
    final msg = await AppDialogs.input(
      context,
      title: t('addFriendTitle'),
      hint: t('addFriendMsgHint', {'name': _name}),
      initialValue: t('addFriendDefaultMsg'),
      maxLines: 3,
      maxLength: 100,
      confirmText: t('addFriendSend'),
    );
    if (msg == null) return;
    setState(() => _sending = true);
    final err =
        await _svc.request(widget.uid, message: msg, source: widget.source);
    if (!mounted) return;
    setState(() => _sending = false);
    if (err == null) {
      AppDialogs.toast(context, t('addFriendSent'));
      Navigator.of(context).pop();
    } else {
      // 优先显示服务端真实原因（已是好友/重复申请/不可添加等）
      AppDialogs.toast(context, err.isEmpty ? t('addFriendSendFailed') : err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final cs = Theme.of(context).colorScheme;
    final user = _user ?? const {};
    final name = _name;
    final account = (user['account'] ?? '').toString();
    final avatar = AppConfig.assetUrl((user['avatar'] ?? '').toString());
    final onlineText = (user['onlineText'] ?? '').toString();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(t('friendDetailTitle')),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error.isNotEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.person_off_outlined,
                          size: 56, color: cs.onSurfaceVariant),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(_error,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 13, color: cs.onSurfaceVariant)),
                      ),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // 头部资料卡
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      decoration: BoxDecoration(
                        color: cs.surface,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            clipBehavior: Clip.antiAlias,
                            decoration: const BoxDecoration(
                              color: AppTheme.primary,
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: AppAvatar(
                              url: avatar,
                              name: name,
                              size: 64,
                              background: AppTheme.primary,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(name,
                              style: const TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Text(account,
                              style: TextStyle(
                                  fontSize: 13, color: cs.onSurfaceVariant)),
                          if (onlineText.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(onlineText,
                                style: TextStyle(
                                    fontSize: 12, color: cs.onSurfaceVariant)),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    // 添加到通讯录（微信式大按钮）
                    FilledButton(
                      onPressed: _sending ? null : _addFriend,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: _sending
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.person_add_alt_1, size: 20),
                                const SizedBox(width: 8),
                                Text(t('userQrAddBtn'),
                                    style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                    ),
                  ],
                ),
    );
  }
}
