import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_locale.dart';
import '../services/friend_service.dart';
import '../services/wide_layout_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';
import 'edit_profile_page.dart';
import 'my_qr_page.dart';
import '../widgets/transitions.dart';

/// 个人资料（设计稿：返回+更多按钮 / 120 圆头像 / 昵称+账号+ID / 信息卡）
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _svc = FriendService();
  Map<String, dynamic>? _profile;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await _svc.profile();
      if (mounted) setState(() => _profile = p);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final p = _profile;
    final name = p?['nickname']?.toString() ?? t('profileNotLoggedIn');
    final account = p?['account']?.toString() ?? '';
    final phone = p?['phone']?.toString() ?? '';
    final email = p?['email']?.toString() ?? '';
    final id = p?['id']?.toString() ?? '';
    final shortId = p?['shortId']?.toString() ?? '';
    final signature = p?['signature']?.toString() ?? '';
    // 靓号标识：short_id 来自后台靓号池（已分配）
    final isVipShort = p?['vipShortId'] == true && shortId.isNotEmpty;
    final avatar = p?['avatar']?.toString() ?? '';

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // 顶栏：返回 + 标题 + 更多
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  IconButton(
                    // 宽屏右栏打开时不能直接 pop（会弹掉根路由黑屏）→ closeDetail
                    onPressed: () => closeDetail(context),
                    icon: Icon(Icons.arrow_back_ios_new,
                        size: 20, color: context.cs.onSurface),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(t('profileTitle'),
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: context.cs.onSurface)),
                    ),
                  ),
                  IconButton(
                    onPressed: () {},
                    icon: Icon(Icons.more_horiz,
                        size: 22, color: context.cs.onSurface),
                  ),
                ],
              ),
            ),
            // 主区
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  // 头像 + 昵称
                  Column(
                    children: [
                      Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: avatar.isNotEmpty
                                ? [context.cs.surface, context.cs.surface]
                                : [
                                    AppTheme.primary,
                                    AppTheme.primary.withValues(alpha: 0.7)
                                  ],
                          ),
                          boxShadow: [
                            BoxShadow(
                                color: AppTheme.primary.withValues(alpha: 0.18),
                                blurRadius: 24,
                                offset: const Offset(0, 8)),
                          ],
                        ),
                        clipBehavior: Clip.antiAlias,
                        alignment: Alignment.center,
                        child: AppAvatar(
                          url: avatar,
                          name: name,
                          size: 100,
                          background: AppTheme.primary,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(name,
                          style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: context.cs.onSurface)),
                      const SizedBox(height: 5),
                      if (account.isNotEmpty)
                        Text(t('profileAccountWith', {'account': account}),
                            style: TextStyle(
                                fontSize: 13,
                                color: context.cs.onSurfaceVariant)),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // 信息卡
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: context.cs.surface,
                      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    ),
                    child: Builder(builder: (context) {
                      final rows = <Widget>[
                        _infoRow(t('profileAccount'), account, copy: account),
                        // 需求：ID 优先显示短 ID（靓号）；靓号时只显示红色「靓ID：xxx」徽标，不再重复显示普通 ID
                        if (shortId.isNotEmpty)
                          _infoRow('ID', shortId,
                              copy: shortId,
                              valueWidget: isVipShort
                                  ? Align(
                                      // Expanded 会把徽标拉满整行，用 Align 收紧为内容宽度
                                      alignment: Alignment.centerLeft,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 1.5),
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                              color: const Color(0xFFE5484D),
                                              width: 1),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          t('vipIdBadge', {'id': shortId}),
                                          style: const TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFFE5484D)),
                                        ),
                                      ),
                                    )
                                  : null)
                        else if (id.isNotEmpty)
                          _infoRow('ID', id, copy: id),
                        // 个性签名（编辑资料里维护，这里展示）
                        if (signature.isNotEmpty)
                          _infoRow(t('editProfileBio'), signature),
                        if (phone.isNotEmpty)
                          _infoRow(t('profilePhone'), phone, copy: phone),
                        if (email.isNotEmpty)
                          _infoRow(t('profileEmail'), email, copy: email),
                        _infoRow(t('profileMyQr'), '',
                            chevron: true, icon: Icons.qr_code_2, onTap: () {
                          Navigator.of(context).push(
                              fadeScaleRoute(const MyQrPage(), scale: true));
                        }),
                      ];
                      final children = <Widget>[];
                      for (var i = 0; i < rows.length; i++) {
                        children.add(rows[i]);
                        if (i != rows.length - 1) {
                          children.add(Divider(
                              height: 1,
                              indent: 16,
                              endIndent: 16,
                              color: context.cs.outlineVariant));
                        }
                      }
                      return Column(children: children);
                    }),
                  ),
                  const SizedBox(height: 16),
                  // 操作按钮
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child:
                              _bigAction(Icons.qr_code, t('profileMyQr'), () {
                            Navigator.of(context).push(
                                fadeScaleRoute(const MyQrPage(), scale: true));
                          }),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _bigAction(
                              Icons.edit_outlined, t('profileEditProfile'),
                              () async {
                            final changed = await Navigator.of(context)
                                .push<bool>(MaterialPageRoute(
                                    builder: (_) => const EditProfilePage()));
                            if (changed == true) _load();
                          }),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value,
      {bool chevron = false,
      VoidCallback? onTap,
      String? copy,
      IconData? icon,
      Widget? valueWidget}) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            SizedBox(
              width: 72,
              child: Text(label,
                  style: TextStyle(
                      fontSize: 14, color: context.cs.onSurfaceVariant)),
            ),
            if (icon != null) ...[
              Icon(icon, size: 18, color: AppTheme.primary),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: valueWidget ??
                  Text(value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 14, color: context.cs.onSurface)),
            ),
            if (copy != null && copy.isNotEmpty)
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: copy));
                  AppDialogs.toast(
                      context, AppLocalizations.of(context).t('profileCopied'));
                },
                child: Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.content_copy,
                      size: 17, color: context.cs.onSurfaceVariant),
                ),
              )
            else if (chevron)
              Icon(Icons.chevron_right,
                  color: context.cs.onSurfaceVariant, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _bigAction(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: context.cs.surface,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        ),
        child: Column(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(icon, color: AppTheme.primary, size: 20),
            ),
            const SizedBox(height: 8),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    color: context.cs.onSurface,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}
