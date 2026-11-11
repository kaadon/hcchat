import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';
import '../services/conversation_service.dart';
import '../services/friend_service.dart';
import '../l10n/app_locale.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';
import 'chat_page.dart';

/// 新建群组（2026-09-29 按用户图4 Telegram 风格重做，单页直创）：
/// 顶栏 取消 | 新建群组 | 创建；相机头像 + 群组名称；公开/私密群组（真实生效）；
/// 搜索好友 + 刷新好友；选择成员多选。
/// 兼容旧语义：仅勾选 1 人时点「创建」= 建单聊（保留原入口行为）。
class NewConversationPage extends StatefulWidget {
  final String myId;
  const NewConversationPage({super.key, required this.myId});

  @override
  State<NewConversationPage> createState() => _NewConversationPageState();
}

class _NewConversationPageState extends State<NewConversationPage> {
  final _svc = FriendService();
  final _convSvc = ConversationService();
  final _nameCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  List<Map<String, dynamic>> _friends = [];
  final Set<String> _selected = {};
  bool _loading = true;
  bool _creating = false;
  bool _isPublic = true; // 群组类型：true=公开（默认） false=私密（仅受邀）
  String _avatarUrl = ''; // 上传后的头像 URL
  // 2026-09-29 编译修复：Image.memory 参数类型是 Uint8List（readAsBytes 本就返回它）
  Uint8List? _avatarPreview; // 本地预览字节（§32：web 兼容用 Image.memory）
  bool _uploadingAvatar = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final friends = await _svc.list();
      if (mounted) {
        setState(() {
          _friends = friends;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _name(Map<String, dynamic> u) {
    final r = u['remark']?.toString() ?? '';
    if (r.isNotEmpty) return r;
    return (u['nickname'] ??
            u['account'] ??
            AppLocalizations.of(context).t('newConvUser'))
        .toString();
  }

  Future<void> _pickAvatar() async {
    if (_uploadingAvatar) return;
    final t = AppLocalizations.of(context).t;
    final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85);
    if (picked == null || !mounted) return;
    setState(() => _uploadingAvatar = true);
    try {
      // §32 惯例：本地预览读字节（web 兼容），上传走统一 uploadXFile
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      setState(() => _avatarPreview = bytes);
      final up = await ApiClient.instance.uploadXFile(
          picked, picked.name.isEmpty ? 'group_avatar.jpg' : picked.name,
          dir: 'avatar/');
      if (!mounted) return;
      _avatarUrl = (up['url'] ?? '').toString();
    } catch (_) {
      if (mounted) {
        setState(() => _avatarPreview = null);
        AppDialogs.toast(context, t('newConvAvatarFailed'));
      }
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  Future<void> _create() async {
    if (_creating) return;
    final t = AppLocalizations.of(context).t;
    // 兼容旧语义：仅勾选 1 人 = 建单聊（名称/类型不适用）
    if (_selected.length == 1) {
      final friend =
          _friends.firstWhere((u) => (u['id']?.toString()) == _selected.first);
      try {
        final conv = await _convSvc.createDirect(_selected.first);
        _openChat(conv, _name(friend));
      } catch (e) {
        if (mounted) {
          _toast(AppLocalizations.of(context).t('newConvCreateFailed',
              {'reason': e.toString().replaceFirst('Exception: ', '')}));
        }
      }
      return;
    }
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _toast(t('newConvGroupNameRequired'));
      return;
    }
    setState(() => _creating = true);
    try {
      final conv = await _convSvc.createGroup(name, _selected.toList(),
          avatar: _avatarUrl, isPublic: _isPublic);
      _openChat(conv, name);
    } catch (e) {
      if (mounted) {
        _toast(AppLocalizations.of(context).t('newConvCreateFailed',
            {'reason': e.toString().replaceFirst('Exception: ', '')}));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  void _openChat(Map<String, dynamic> conv, String title) {
    if (!mounted) return;
    final item =
        ConvItem.fromJson({'conversation': conv, 'conversationName': title});
    Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => ChatPage(conv: item, myId: widget.myId)));
  }

  void _toast(String msg) => AppDialogs.toast(context, msg);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _topBar(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  // 2026-09-29 统一返回图标口径：本页为「取消」文字键（图4），无返回箭头
  Widget _topBar() {
    final t = AppLocalizations.of(context).t;
    return Container(
      color: context.cs.surface,
      height: 52,
      padding: const EdgeInsets.only(left: 4, right: 8),
      child: Row(
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: Text(t('commonCancel'),
                style: TextStyle(
                    fontSize: 15.5, color: context.cs.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(t('newConvGroupTitle'),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: context.cs.onSurface)),
          ),
          TextButton(
            onPressed: _creating ? null : _create,
            child: Text(t('newConvCreate'),
                style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    color: _creating
                        ? context.cs.onSurfaceVariant
                        : AppTheme.primary)),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final t = AppLocalizations.of(context).t;
    final q = _searchCtrl.text.toLowerCase();
    final filtered = q.isEmpty
        ? _friends
        : _friends
            .where((u) => ('${_name(u)} ${u['account'] ?? ''}')
                .toLowerCase()
                .contains(q))
            .toList();
    return CustomScrollView(
      slivers: [
        // ---- 相机头像 + 群组名称（图4 第一屏）----
        SliverToBoxAdapter(child: _headSection()),
        // ---- 公开/私密群组（真实生效：私密=不可被搜索仅受邀）----
        SliverToBoxAdapter(child: _typeSection()),
        // ---- 搜索好友 ----
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (_) => setState(() {}),
              decoration: AppTheme.authInput(
                  hint: t('newConvSearchFriends'), icon: Icons.search),
            ),
          ),
        ),
        // ---- 提示行 + 刷新好友 ----
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(t('newConvSearchFriendsHint'),
                      style: TextStyle(
                          fontSize: 12, color: context.cs.onSurfaceVariant)),
                ),
                TextButton(
                  onPressed: _loading ? null : _load,
                  child: Text(t('newConvRefreshFriends'),
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.primary)),
                ),
              ],
            ),
          ),
        ),
        // ---- 选择成员 ----
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
            child: Text(t('newConvSelectMembers'),
                style: TextStyle(
                    fontSize: 12.5, color: context.cs.onSurfaceVariant)),
          ),
        ),
        if (_loading)
          const SliverToBoxAdapter(
              child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator())))
        else if (filtered.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(t('newConvNoContacts'),
                    style: TextStyle(color: context.cs.onSurfaceVariant)),
              ),
            ),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (ctx, i) {
                if (i.isOdd) {
                  return Divider(
                      height: 1,
                      indent: 68,
                      endIndent: 16,
                      color: context.cs.outlineVariant);
                }
                return _memberRow(filtered[i ~/ 2]);
              },
              childCount: filtered.length * 2 - 1,
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _headSection() {
    final t = AppLocalizations.of(context).t;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          GestureDetector(
            onTap: _pickAvatar,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    width: 64,
                    height: 64,
                    color: context.cs.surfaceContainerHighest,
                    child: _avatarPreview != null
                        ? Image.memory(_avatarPreview!,
                            fit: BoxFit.cover,
                            gaplessPlayback: true)
                        : _uploadingAvatar
                            ? const Center(
                                child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2)))
                            : Icon(Icons.photo_camera_outlined,
                                size: 28, color: context.cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: TextField(
              controller: _nameCtrl,
              maxLength: 30,
              style: TextStyle(fontSize: 16, color: context.cs.onSurface),
              decoration: InputDecoration(
                counterText: '',
                filled: true,
                fillColor: context.cs.surfaceContainerHighest,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 14),
                hintText: t('newConvGroupNameHint'),
                hintStyle:
                    TextStyle(fontSize: 15, color: context.cs.onSurfaceVariant),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _typeSection() {
    // 2026-09-29 编译修复：补上漏写的 AppLocalizations 取 t
    final t = AppLocalizations.of(context).t;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: context.cs.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            _typeRow(
              icon: Icons.public_outlined,
              title: t('groupTypePublic'),
              subtitle: t('groupTypePublicSub'),
              selected: _isPublic,
              onTap: () => setState(() => _isPublic = true),
            ),
            Divider(
                height: 1, indent: 64, endIndent: 16, color: context.cs.outlineVariant),
            _typeRow(
              icon: Icons.lock_outline,
              title: t('groupTypePrivate'),
              subtitle: t('groupTypePrivateSub'),
              selected: !_isPublic,
              onTap: () => setState(() => _isPublic = false),
            ),
          ],
        ),
      ),
    );
  }

  Widget _typeRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: context.cs.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 21, color: context.cs.onSurface),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w500,
                          color: context.cs.onSurface)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12, color: context.cs.onSurfaceVariant)),
                ],
              ),
            ),
            Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 22,
              color: selected
                  ? context.cs.onSurface
                  : context.cs.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Widget _memberRow(Map<String, dynamic> u) {
    final id = (u['id'] ?? '').toString();
    final selected = _selected.contains(id);
    final name = _name(u);
    final avatar = (u['avatar'] ?? '').toString();
    final online = u['online'] == true;
    return ListTile(
      onTap: () => setState(() {
        selected ? _selected.remove(id) : _selected.add(id);
      }),
      leading: AppAvatar(
        url: avatar,
        name: name,
        size: 42,
        background: AppTheme.primary,
      ),
      title: Text(name,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
      subtitle: Text(
          online
              ? AppLocalizations.of(context).t('newConvOnline')
              : AppLocalizations.of(context).t('newConvLastSeen'),
          style: TextStyle(
              fontSize: 12,
              color: online ? AppTheme.green : context.cs.onSurfaceVariant)),
      trailing: Icon(
        selected ? Icons.check_circle : Icons.radio_button_unchecked,
        color: selected ? context.cs.onSurface : context.cs.onSurfaceVariant,
        size: 22,
      ),
    );
  }
}
