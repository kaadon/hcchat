import 'dart:async';

import 'package:flutter/material.dart';

import '../services/conversation_service.dart';
import '../services/friend_service.dart';
import '../services/user_cache.dart';
import '../l10n/app_locale.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';
import 'chat_page.dart';

/// 添加好友：搜索用户 + 发送申请。
///
/// 十四批 #6（2026-09-15）：搜索关键字为纯数字 ID 时，后端扩展端点会同时
/// 命中 用户 / 群聊（type=2）/ 频道（type=3），结果项带 `type` 字段。
/// 本页按类型分发渲染：
/// - 用户 → 原有 ListTile + 发好友申请；
/// - 群聊 → 群卡（头像 + 群名 + ID）+「加入群聊」按钮 → joinGroup（幂等）→ 进会话；
/// - 频道 → 频道卡（头像 + 频道名 + ID）+「订阅频道」按钮 → followChannel（幂等）→ 进会话。
/// 兼容旧后端：结果项无 type 字段时全部按 user 处理（维持现状）。
/// ⚠️ 搜索响应的群/频道字段契约以 be-channel 更新后的 API.md 为准；
/// 这里做了防御式取值（conversation 嵌套或平铺、type 字符串/数字都认），
/// 字段名若与定稿不一致只需调整 `_itemKind` / `_convOf` 两个归一化函数。
class AddFriendPage extends StatefulWidget {
  const AddFriendPage({super.key});

  @override
  State<AddFriendPage> createState() => _AddFriendPageState();
}

class _AddFriendPageState extends State<AddFriendPage> {
  final _kw = TextEditingController();
  final _svc = FriendService();
  final _convSvc = ConversationService();
  List<Map<String, dynamic>> _results = [];
  bool _loading = false;
  Timer? _debounce;

  /// 正在执行加入/订阅的行（防重复点击；空串 = 空闲）
  String _busyId = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _kw.dispose();
    super.dispose();
  }

  /// 最少 5 个字符才发起搜索（2026-09-17 用户要求）：
  /// 1~4 位的关键字命中一大堆无意义结果，且每敲一个键就查一次。
  static const int _minSearchLen = 5;

  void _onChange(String v) {
    _debounce?.cancel();
    final kw = v.trim();
    // 不足 5 位：不发请求，并立即收起旧结果（删字符时也即时清空）
    if (kw.length < _minSearchLen) {
      if (_results.isNotEmpty || _loading) {
        setState(() {
          _results = [];
          _loading = false;
        });
      }
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () => _doSearch(kw));
  }

  Future<void> _doSearch(String kw) async {
    kw = kw.trim();
    if (kw.length < _minSearchLen) {
      if (mounted && _results.isNotEmpty) setState(() => _results = []);
      return;
    }
    setState(() => _loading = true);
    try {
      final r = await _svc.search(kw);
      if (mounted) setState(() => _results = r);
    } catch (e) {
      if (mounted) setState(() => _results = []);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ===== 搜索结果项归一化（防御式，兼容契约微调）=====

  /// 结果类型：'user' / 'group' / 'channel'。
  /// type 字段：字符串 user/group/channel 或数字 1/2/3（与 conversation.type
  /// 对齐，同 chat_page._cardKindOf 的归一化规则）；无 type 字段按 user（旧后端）。
  String _itemKind(Map<String, dynamic> u) {
    final raw = (u['type'] ?? u['resultType'] ?? u['kind'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    switch (raw) {
      case 'group':
      case '2':
        return 'group';
      case 'channel':
      case '3':
        return 'channel';
      default:
        return 'user';
    }
  }

  /// 群/频道的会话数据：搜索项可能把 Conversation 嵌套在 `conversation` 里，
  /// 也可能直接平铺在结果项上（以 be-channel 定稿为准），两种都取。
  Map<String, dynamic> _convOf(Map<String, dynamic> u) {
    final c = u['conversation'];
    if (c is Map) return Map<String, dynamic>.from(c);
    return u;
  }

  /// 群/频道会话 ID（雪花，JSON 中为字符串）
  String _convIdOf(Map<String, dynamic> u, Map<String, dynamic> conv) =>
      (u['conversationId'] ?? u['id'] ?? conv['id'] ?? '').toString();

  /// 群/频道名：nameZh 优先（与 GroupJoinConfirmPage 同一取值链）
  String _convNameOf(Map<String, dynamic> conv, String fallback) =>
      (conv['nameZh'] ?? conv['nameEn'] ?? conv['name'] ?? fallback).toString();

  /// 自定义频道 ID（十七批）：搜索结果/频道详情随会话下发 shortId；
  /// 防御式取值（结果项平铺或 conversation 嵌套都认），无字段回退雪花 ID
  String _shortIdOf(Map<String, dynamic> u, Map<String, dynamic> conv) =>
      (u['shortId'] ?? conv['shortId'] ?? '').toString();

  // ===== 加入群聊 / 订阅频道 =====

  /// 群与频道共用骨架：调加入方法 → toast → pushReplacement 进会话
  ///（与扫码进群 pushReplacement(ChatPage) 同款导航）。
  Future<void> _joinConv(Map<String, dynamic> u,
      Future<Map<String, dynamic>> Function(String id) action,
      {required bool isChannel}) async {
    final t = AppLocalizations.of(context).t;
    final conv = _convOf(u);
    final convId = _convIdOf(u, conv);
    if (convId.isEmpty || _busyId.isNotEmpty) return;
    setState(() => _busyId = convId);
    try {
      final joined = await action(convId); // join/follow 均幂等
      final name = joined['nameZh']?.toString() ??
          joined['nameEn']?.toString() ??
          _convNameOf(conv, '');
      final item = ConvItem.fromJson(
          {'conversation': joined, 'conversationName': name});
      if (!mounted) return;
      AppDialogs.toast(
          context,
          isChannel
              ? t('searchChannelFollowedToast')
              : t('searchGroupJoinedToast'));
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => ChatPage(conv: item, myId: UserCache.myId ?? '')));
    } catch (e) {
      if (mounted) {
        // 优先显示服务端真实原因（私密频道不可自助关注/人数已满等，
        // ApiException.toString() 即后端 message）；网络类异常只给笼统提示
        final detail = e is ApiException ? e.message : '';
        AppDialogs.toast(context, detail.isEmpty
            ? t('searchJoinFailed')
            : '${t('searchJoinFailed')}：$detail');
      }
    } finally {
      if (mounted) setState(() => _busyId = '');
    }
  }

  Future<void> _request(Map<String, dynamic> u) async {
    final t = AppLocalizations.of(context).t;
    final name =
        (u['nickname'] ?? u['account'] ?? t('addFriendUser')).toString();
    final msg = await AppDialogs.input(
      context,
      title: t('addFriendTitle'),
      hint: t('addFriendMsgHint', {'name': name}),
      initialValue: t('addFriendDefaultMsg'),
      maxLines: 3,
      maxLength: 100,
      confirmText: t('addFriendSend'),
    );
    if (msg == null) return;
    final err = await _svc.request(u['id']?.toString() ?? '', message: msg);
    if (mounted) {
      if (err == null) {
        AppDialogs.toast(context, t('addFriendSent'));
        Navigator.of(context).pop();
      } else {
        // 优先显示服务端真实原因（已是好友/重复申请/不可添加等）
        AppDialogs.toast(context, err.isEmpty ? t('addFriendSendFailed') : err);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(t('addFriendTitle')),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        elevation: 0,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: TextField(
              controller: _kw,
              onChanged: _onChange,
              decoration: AppTheme.authInput(
                  hint: t('addFriendSearchHint'), icon: Icons.search),
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.person_search_outlined,
                            size: 64, color: context.cs.onSurfaceVariant),
                        const SizedBox(height: 12),
                        Text(
                            _kw.text.trim().isEmpty
                                ? t('addFriendInputKeyword')
                                : (_kw.text.trim().length < _minSearchLen
                                    ? t('addFriendMinChars')
                                    : t('addFriendNoUser')),
                            style: TextStyle(
                                color: context.cs.onSurfaceVariant,
                                fontSize: 14)),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: _results.length,
                    separatorBuilder: (_, __) => Divider(
                        height: 1,
                        indent: 76,
                        endIndent: 16,
                        color: context.cs.outlineVariant),
                    itemBuilder: (_, i) {
                      final u = _results[i];
                      final kind = _itemKind(u);
                      if (kind == 'user') {
                        return _userTile(u);
                      }
                      // 群/频道卡：头像（圆角方形，与群聊语义一致）+ 名称 + ID + 动作按钮
                      final conv = _convOf(u);
                      final convId = _convIdOf(u, conv);
                      final name = _convNameOf(conv, t('groupJoinUnnamed'));
                      // 副标题：自定义频道 ID 优先，无 shortId 回退雪花 ID
                      final shortId = _shortIdOf(u, conv);
                      final displayId =
                          shortId.isNotEmpty ? shortId : convId;
                      final avatar = (conv['avatar'] ?? '').toString();
                      final isChannel = kind == 'channel';
                      final followed = u['followed'] == true;
                      final busy = _busyId == convId;
                      return ListTile(
                        leading: AppAvatar(
                            url: avatar,
                            name: name,
                            size: 44,
                            radius: 12,
                            background: AppTheme.primary,
                            emptyText: t('myChannelsInitial')),
                        title: Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w500)),
                        // 副标题展示 ID（shortId 优先）：按 ID 加入的场景下便于核对目标
                        subtitle: Text('ID: $displayId',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                color: context.cs.onSurfaceVariant)),
                        trailing: busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2))
                            : TextButton(
                                onPressed: () => _joinConv(
                                    u,
                                    isChannel
                                        ? _convSvc.followChannel
                                        : _convSvc.joinGroup,
                                    isChannel: isChannel),
                                child: Text(
                                    isChannel
                                        ? (followed
                                            ? t('searchEnterChannelBtn')
                                            : t('searchSubscribeChannelBtn'))
                                        : t('groupJoinConfirmButton'),
                                    style: const TextStyle(
                                        fontSize: 13,
                                        color: AppTheme.primary)),
                              ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// 用户结果行（原有渲染，原样保留）
  Widget _userTile(Map<String, dynamic> u) {
    final t = AppLocalizations.of(context).t;
    final name =
        (u['nickname'] ?? u['account'] ?? t('addFriendUser')).toString();
    final avatar = (u['avatar'] ?? '').toString();
    return ListTile(
      onTap: () => _request(u),
      // 需求8：搜索结果显示用户头像（无头像回退首字母）
      leading: CircleAvatar(
        backgroundColor: AppTheme.primary,
        backgroundImage: avatar.isNotEmpty ? NetworkImage(avatar) : null,
        child: avatar.isEmpty
            ? Text(name.isEmpty ? '?' : name.characters.first,
                style: const TextStyle(color: Colors.white))
            : null,
      ),
      title: Text(name,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
      subtitle: Text(
          (u['account'] ?? u['email'] ?? u['phone'] ?? '').toString(),
          style: TextStyle(
              fontSize: 12, color: context.cs.onSurfaceVariant)),
      trailing: const Icon(Icons.person_add_alt_1,
          color: AppTheme.primary, size: 20),
    );
  }
}
