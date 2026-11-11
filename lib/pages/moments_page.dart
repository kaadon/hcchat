import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/moment_service.dart';
import '../services/user_cache.dart';
import '../services/wide_layout_store.dart';
import '../theme/app_theme.dart';
import '../utils/image_saver.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/app_net_image.dart';
import '../widgets/brand_loading.dart';
import 'image_viewer_page.dart';

/// 朋友圈（微信风格：封面 + 发布 + 时间线 + 点赞）
/// 数据走后端 /api/v1/moments（含小助手动态、好友动态；被屏蔽的仅自己可见）
class MomentsPage extends StatefulWidget {
  /// 指定用户 ID（好友资料页"朋友圈"入口）；为空=我的朋友圈
  final String? userId;
  final String? userName;
  const MomentsPage({super.key, this.userId, this.userName});

  @override
  State<MomentsPage> createState() => _MomentsPageState();
}

class _MomentsPageState extends State<MomentsPage> {
  final _svc = MomentService.instance;
  bool _loading = true;
  List<Map<String, dynamic>> _posts = [];

  /// 封面总高度（含状态栏，build 时按机型刷新），供工具栏变色阈值判断
  double _coverH = 190 + 48;

  /// 滚过封面后工具栏从「透明底 + 白图标」切换为「surface 底 + 深图标」
  bool _toolbarSolid = false;

  /// 个性签名：我的朋友圈取 UserCache 缓存资料；他人朋友圈走 GET /user/:id 兜底
  String _signature = '';

  /// 他人朋友圈的头像：优先用户详情接口（好友没发过动态也能拿到），
  /// 接口失败再回退其动态列表首条的头像
  String _friendAvatar = '';

  /// 资料（签名/头像）只拉一次（下拉刷新不重复请求）
  bool _profileLoaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = widget.userId != null
          ? await _svc.listByUser(widget.userId!)
          : await _svc.list();
      if (mounted) {
        setState(() {
          _posts = ((data['list'] as List<dynamic>?) ?? [])
              .map((e) => (e as Map).cast<String, dynamic>())
              .toList();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
    _loadOwnerProfile();
  }

  /// 拉头部资料（只拉一次）：我的直接读本地缓存签名；
  /// 他人的调用户详情接口，同时取签名 + 头像（好友没发过动态也有头像），失败静默降级
  Future<void> _loadOwnerProfile() async {
    if (_profileLoaded) return;
    _profileLoaded = true;
    if (widget.userId == null) {
      final s = (UserCache.myProfileData?['signature'] ?? '').toString();
      if (mounted && s.isNotEmpty) setState(() => _signature = s);
      return;
    }
    try {
      final r = await ApiClient.instance.get('/api/v1/user/${widget.userId}');
      final body = r.data;
      if (body is Map && body['code'] == 0) {
        final d = (body['data'] as Map?)?.cast<String, dynamic>();
        final s = (d?['signature'] ?? '').toString();
        final a = (d?['avatar'] ?? '').toString();
        if (mounted && (s.isNotEmpty || a.isNotEmpty)) {
          setState(() {
            if (s.isNotEmpty) _signature = s;
            if (a.isNotEmpty) _friendAvatar = a;
          });
        }
      }
    } catch (_) {
      // 资料拉取失败不影响朋友圈主流程（头像回退动态首条 → 再回退首字占位）
    }
  }

  Future<void> _publish() async {
    final t = AppLocalizations.of(context).t;
    final ctrl = TextEditingController();
    final images = <XFile>[];
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.cs.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
              16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t('momentsPublishTitle'),
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: context.cs.onSurface)),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                maxLines: 4,
                autofocus: true,
                style: const TextStyle(fontSize: 15),
                decoration: InputDecoration(
                  hintText: t('momentsThoughtHint'),
                  hintStyle: TextStyle(color: context.cs.onSurfaceVariant),
                  filled: true,
                  fillColor: Theme.of(context).scaffoldBackgroundColor,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final f in images)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(File(f.path),
                          width: 72, height: 72, fit: BoxFit.cover),
                    ),
                  if (images.length < 9)
                    InkWell(
                      onTap: () async {
                        final x = await ImagePicker().pickImage(
                            source: ImageSource.gallery, imageQuality: 80);
                        if (x != null) setSheet(() => images.add(x));
                      },
                      child: Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: context.cs.surfaceContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(Icons.add_a_photo_outlined,
                            color: context.cs.onSurfaceVariant),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style:
                      FilledButton.styleFrom(backgroundColor: AppTheme.primary),
                  child: Text(t('momentsPublish')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    final text = ctrl.text.trim();
    if (text.isEmpty && images.isEmpty) {
      AppDialogs.toast(context, t('momentsEmptyContent'));
      return;
    }
    try {
      // 图片先上传（除网络图外逐张走 /upload）
      final urls = <String>[];
      for (final f in images) {
        final url = await _uploadImage(f);
        if (url.isNotEmpty) urls.add(url);
      }
      await _svc.publish(text, urls);
      AppDialogs.toast(context, t('momentsPublished'));
      _load();
    } catch (_) {
      AppDialogs.toast(context, t('momentsPublishFailed'));
    }
  }

  Future<String> _uploadImage(XFile f) async {
    try {
      final data =
          await ApiClient.instance.uploadXFile(f, f.name, dir: 'moments/');
      return (data['url'] ?? '').toString();
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    // 封面总高 = 原本 expandedHeight 190 + 状态栏（cover 现在从屏幕 y=0 开始铺）
    _coverH = 190 + MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      // 内容延伸到透明 AppBar 背后：封面铺到屏幕顶，返回/相机按钮悬浮其上
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor:
            _toolbarSolid ? context.cs.surface : Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          // 宽屏右栏打开时不能直接 pop（会弹掉根路由黑屏）→ closeDetail 清右栏
          onPressed: () => closeDetail(context),
          icon: Icon(Icons.arrow_back_ios_new,
              size: 20,
              color: _toolbarSolid ? context.cs.onSurface : Colors.white),
        ),
        actions: [
          // 仅「我的朋友圈」显示发布相机，查看他人时不显示
          if (widget.userId == null)
            IconButton(
              onPressed: _publish,
              icon: Icon(Icons.camera_alt_outlined,
                  color: _toolbarSolid ? context.cs.onSurface : Colors.white),
              tooltip: t('momentsPublishTitle'),
            ),
        ],
      ),
      body: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          // 封面滚过工具栏高度后切换底色（微信同款交互）
          final solid = n.metrics.pixels > _coverH - 56;
          if (solid != _toolbarSolid) setState(() => _toolbarSolid = solid);
          return false;
        },
        child: RefreshIndicator(
          onRefresh: _load,
          child: CustomScrollView(
            slivers: [
              // 封面 + 微信式悬浮头像（一半叠封面、一半悬列表区，随封面一起滚走）
              SliverToBoxAdapter(child: _coverHeader()),
              // 白色签名区：既承接头像下半截（不留灰色缝），又在头像正下方展示个性签名
              SliverToBoxAdapter(child: _signatureBlock()),
              if (_loading)
                // 骨架屏（2026-09-06）：模拟动态卡布局，替代居中转圈
                const SliverFillRemaining(
                  child: SkeletonList(style: SkeletonStyle.moments, rows: 4),
                )
              else if (_posts.isEmpty)
                SliverFillRemaining(
                  child: Center(
                    child: Text(
                        widget.userId != null
                            ? t('momentsFriendEmpty')
                            : t('momentsMyEmpty'),
                        style: TextStyle(
                            fontSize: 13, color: context.cs.onSurfaceVariant)),
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) => _postItem(_posts[i]),
                    childCount: _posts.length,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 封面 + 右下角悬浮头像/昵称（微信朋友圈样式：头像一半在封面内、一半悬在下方）。
  /// 注意：不用 FlexibleSpaceBar —— 其源码内含 ClipRect 会裁掉溢出的头像。
  Widget _coverHeader() {
    final t = AppLocalizations.of(context).t;
    final name = widget.userName ?? t('momentsMe');
    // 我的头像走 UserCache；他人朋友圈优先用户详情接口的头像（没发过动态也有），
    // 接口失败回退其动态首条头像，都拿不到则回退首字占位（与帖子头像同款双保险写法）
    var avatarUrl = '';
    if (widget.userId == null) {
      avatarUrl = (UserCache.myAvatar ?? '').toString();
    } else if (_friendAvatar.isNotEmpty) {
      avatarUrl = _friendAvatar;
    } else if (_posts.isNotEmpty) {
      avatarUrl = (_posts.first['senderAvatar'] ?? '').toString();
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        SizedBox(
          width: double.infinity,
          height: _coverH,
          child: Image.asset('assets/images/beijing.jpg',
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  Container(color: const Color(0xFF2E4A6B))),
        ),
        Positioned(
          right: 16,
          bottom: -30, // 60 高头像正好一半叠封面、一半悬列表区
          child: Row(
            children: [
              Text(name,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      shadows: [Shadow(blurRadius: 6, color: Colors.black54)])),
              const SizedBox(width: 10),
              // 白色 2px 描边 = 外层白底容器 + 内层 2px padding 的方形圆角头像
              Container(
                width: 60,
                height: 60,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: AppAvatar(
                  url: avatarUrl,
                  name: name,
                  size: 56,
                  radius: 10,
                  background: AppTheme.primary.withValues(alpha: 0.85),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 白色签名区（头像悬浮下半截落在这一块上，与封面之间无灰缝）。
  /// 微信式：签名在头像正下方、右对齐；无签名时仅保留白色留白承接头像。
  Widget _signatureBlock() {
    return Container(
      width: double.infinity,
      color: context.cs.surface,
      padding: const EdgeInsets.fromLTRB(16, 36, 16, 6),
      child: _signature.isEmpty
          ? const SizedBox.shrink()
          : Align(
              alignment: Alignment.centerRight,
              child: Text(_signature,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12, color: context.cs.onSurfaceVariant)),
            ),
    );
  }

  /// 2026-09-28：朋友圈图片九宫格（微信同款布局规则）。
  /// 最多展示 9 张；1 张=大图按原比例（限宽 62% 内容宽 / 限高 260），
  /// 2 张=一行均分各半，3 张=一行三个，4~9 张=每行三个的网格。
  Widget _momentImages(List<String> images) {
    final imgs = images.take(9).toList();
    const gap = 6.0;
    return LayoutBuilder(builder: (context, box) {
      final maxW = box.maxWidth.isFinite ? box.maxWidth : 300.0;
      if (imgs.length == 1) {
        return _MomentSingleImage(
            url: imgs.first,
            maxWidth: maxW,
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => ImageViewerPage(
                        urls: imgs, initialIndex: 0))),
            onSave: _saveImg);
      }
      // 2 张：一行均分（各占一半）；3 张及以上：每行三个（3 张恰好一行）
      final tileSize = imgs.length == 2
          ? (maxW - gap) / 2
          : (maxW - gap * 2) / 3;
      Widget tile(String url) => GestureDetector(
            // 点开全屏大图；长按保存到相册（微信式）
            // 2026-09-25：传整组图片 + 当前张序号 → 查看器内可左右滑翻本条全部图片
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => ImageViewerPage(
                        urls: imgs, initialIndex: imgs.indexOf(url)))),
            onLongPress: () => _saveImg(url),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: AppNetImage(
                  url: url,
                  width: tileSize,
                  height: tileSize,
                  cacheWidth: (tileSize * 2).round()),
            ),
          );
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final img in imgs) tile(img)],
      );
    });
  }

  Widget _postItem(Map<String, dynamic> p) {
    final name = (p['senderName'] ?? '').toString();
    final avatar = (p['senderAvatar'] ?? '').toString();
    final content = (p['content'] ?? '').toString();
    final images = ((p['images'] as List<dynamic>?) ?? [])
        .map((e) => e.toString())
        .toList();
    final likeCount = (p['likeCount'] as num?)?.toInt() ?? 0;
    final liked = p['liked'] == true;
    final hidden = p['hidden'] == true;
    final time = (p['createdAt'] ?? '').toString();
    final id = (p['id'] ?? '').toString();
    final comments = ((p['comments'] as List<dynamic>?) ?? [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    return Container(
      color: context.cs.surface,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      margin: const EdgeInsets.only(bottom: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头像（网络图或首字占位）
          AppAvatar(
            url: avatar,
            name: name,
            size: 42,
            radius: 8,
            background: AppTheme.primary.withValues(alpha: 0.85),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(name,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF3D6BA8))),
                    if (p['assistant'] == true) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppTheme.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                            AppLocalizations.of(context).t('momentsOfficial'),
                            style: const TextStyle(
                                fontSize: 10, color: AppTheme.primary)),
                      ),
                    ],
                    if (hidden) ...[
                      const Spacer(),
                      Icon(Icons.lock_outline,
                          size: 13, color: context.cs.onSurfaceVariant),
                      const SizedBox(width: 3),
                      Text(AppLocalizations.of(context).t('momentsOnlyMe'),
                          style: TextStyle(
                              fontSize: 11,
                              color: context.cs.onSurfaceVariant)),
                    ],
                  ],
                ),
                if (content.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(content,
                        style: TextStyle(
                            fontSize: 15, color: context.cs.onSurface)),
                  ),
                if (images.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    // 2026-09-28 需求：朋友圈图片九宫格微信化——最多 9 张；
                    // 1 张=大图（保持宽高比限宽限高），2 张=一行均分，
                    // 3 张=一行三个，4~9 张=每行三个网格。
                    child: _momentImages(images),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Text(time,
                          style: TextStyle(
                              fontSize: 12,
                              color: context.cs.onSurfaceVariant)),
                      const Spacer(),
                      InkWell(
                        onTap: () async {
                          try {
                            final nowLiked = await _svc.like(id);
                            if (mounted) {
                              setState(() {
                                p['liked'] = nowLiked;
                                p['likeCount'] =
                                    likeCount + (nowLiked ? 1 : -1);
                              });
                            }
                          } catch (_) {
                            AppDialogs.toast(
                                context,
                                AppLocalizations.of(context)
                                    .t('momentsActionFailed'));
                          }
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                liked ? Icons.favorite : Icons.favorite_border,
                                size: 16,
                                color: liked
                                    ? const Color(0xFFE9564E)
                                    : context.cs.onSurfaceVariant,
                              ),
                              if (likeCount > 0) ...[
                                const SizedBox(width: 4),
                                Text('$likeCount',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: context.cs.onSurfaceVariant)),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      // 评论按钮（样式与点赞一致，右侧带评论数）
                      InkWell(
                        onTap: () => _showCommentSheet(p, id),
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.mode_comment_outlined,
                                  size: 16, color: context.cs.onSurfaceVariant),
                              if (comments.isNotEmpty) ...[
                                const SizedBox(width: 4),
                                Text('${comments.length}',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: context.cs.onSurfaceVariant)),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 微信式灰底评论块（点赞/评论图标行下、Divider 上）
                if (comments.isNotEmpty)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < comments.length; i++) ...[
                          if (i > 0) const SizedBox(height: 6),
                          _commentRow(p, comments[i]),
                        ],
                      ],
                    ),
                  ),
                Divider(height: 14, color: context.cs.outlineVariant),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 保存九宫格图片到相册（结果轻提示）
  Future<void> _saveImg(String url) async {
    final t = AppLocalizations.of(context).t;
    try {
      final ok = await ImageSaver.saveNetworkImage(url);
      if (!mounted) return;
      AppDialogs.toast(
          context, ok ? t('momentsSaved') : t('momentsSaveFailed'));
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('momentsSaveFailed'));
    }
  }

  /// 评论单行：`昵称：内容`；自己的评论长按弹确认删除（服务端仅允许删自己的）
  Widget _commentRow(Map<String, dynamic> p, Map<String, dynamic> c) {
    final t = AppLocalizations.of(context).t;
    final cname = (c['senderName'] ?? '').toString();
    final ctext = (c['content'] ?? '').toString();
    final cid = (c['id'] ?? '').toString();
    final mine = c['userId']?.toString() == UserCache.myId;
    return GestureDetector(
      onLongPress: mine ? () => _deleteComment(p, cid) : null,
      child: Text.rich(
        TextSpan(children: [
          TextSpan(
              text: '$cname：',
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF3D6BA8))),
          TextSpan(
              text: ctext,
              style: TextStyle(fontSize: 13, color: context.cs.onSurface)),
        ]),
      ),
    );
  }

  /// 删除自己的评论（服务端确认 + 本地移除）
  Future<void> _deleteComment(Map<String, dynamic> p, String cid) async {
    final t = AppLocalizations.of(context).t;
    final ok = await AppDialogs.confirm(context,
        title: t('momentsDeleteComment'),
        message: t('momentsDeleteCommentConfirm'),
        danger: true);
    if (ok != true) return;
    try {
      await _svc.deleteComment(cid);
      if (!mounted) return;
      setState(() {
        p['comments'] = ((p['comments'] as List<dynamic>?) ?? [])
            .where((e) => ((e as Map)['id'] ?? '').toString() != cid)
            .toList();
      });
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('momentsActionFailed'));
    }
  }

  /// 底部评论输入条（微信式）：圆角顶 + 自动聚焦输入框 + 发送按钮
  Future<void> _showCommentSheet(Map<String, dynamic> p, String postId) async {
    final t = AppLocalizations.of(context).t;
    final ctrl = TextEditingController();
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.cs.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            12, 12, 12, MediaQuery.of(ctx).viewInsets.bottom + 12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: ctrl,
                autofocus: true,
                minLines: 1,
                maxLines: 4,
                style: const TextStyle(fontSize: 15),
                decoration: InputDecoration(
                  hintText: t('momentsCommentHint'),
                  hintStyle: TextStyle(color: context.cs.onSurfaceVariant),
                  filled: true,
                  fillColor: Theme.of(context).scaffoldBackgroundColor,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none),
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () {
                // 空内容拦截，不关面板
                if (ctrl.text.trim().isEmpty) {
                  AppDialogs.toast(ctx, t('momentsCommentEmpty'));
                  return;
                }
                Navigator.pop(ctx, true);
              },
              style: TextButton.styleFrom(foregroundColor: AppTheme.primary),
              child: Text(t('momentsCommentSend')),
            ),
          ],
        ),
      ),
    );
    if (sent != true || !mounted) return;
    final text = ctrl.text.trim();
    if (text.isEmpty) {
      AppDialogs.toast(context, t('momentsCommentEmpty'));
      return;
    }
    try {
      final data = await _svc.comment(postId, text);
      if (!mounted) return;
      setState(() {
        final list = ((p['comments'] as List<dynamic>?) ?? []).toList();
        // 服务端返回 {ID, PostID, UserID, Content, CreatedAt}（大写驼峰），
        // 组装成与列表一致的本地 comment map 追加展示
        list.add({
          'id': (data['ID'] ?? data['id'] ?? '').toString(),
          'senderName': _myName(),
          'senderAvatar': (UserCache.myAvatar ?? '').toString(),
          'content': text,
          'createdAt':
              (data['CreatedAt'] ?? data['createdAt'] ?? '').toString(),
          'userId': data['UserID']?.toString() ?? UserCache.myId ?? '',
        });
        p['comments'] = list;
      });
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('momentsCommentFailed'));
    }
  }

  /// 当前登录用户昵称（UserCache 资料 nickname 字段，me_page 同款取法）
  String _myName() {
    final prof = UserCache.myProfileData;
    final n = (prof?['nickname'] ?? prof?['name'] ?? '').toString();
    if (n.isNotEmpty) return n;
    return UserCache.myId ?? '';
  }
}

/// 2026-09-28：朋友圈单图大图（微信同款）——按原图宽高比展示，
/// 限宽 62% 内容宽、限高 260，超限等比缩到框内。尺寸拿不到（加载失败/超时）
/// 按 4:3 兜底，避免占位卡死。
class _MomentSingleImage extends StatelessWidget {
  final String url;
  final double maxWidth;
  final VoidCallback onTap;
  final void Function(String) onSave;
  const _MomentSingleImage({
    required this.url,
    required this.maxWidth,
    required this.onTap,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final boxW = maxWidth * 0.62;
    const maxH = 260.0;
    return GestureDetector(
      onTap: onTap,
      onLongPress: () => onSave(url),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: FutureBuilder<Size?>(
          future: resolveMomentImageSize(url),
          builder: (context, snap) {
            final size = snap.data;
            final ratio =
                (size != null && size.height > 0) ? size.width / size.height : 4 / 3;
            double w = boxW, h = w / ratio;
            if (h > maxH) {
              h = maxH;
              w = h * ratio;
            }
            return AppNetImage(
                url: url,
                width: w,
                height: h,
                fit: BoxFit.cover,
                cacheWidth: (w * 2).round());
          },
        ),
      ),
    );
  }
}

/// 解析网络图片固有尺寸（native 走 CachedNetworkImageProvider 命中磁盘缓存，
/// web 走 NetworkImage），3 秒兜底超时返回 null（调用方按 4:3 处理）。
Future<Size?> resolveMomentImageSize(String url) async {
  final u = url.trim();
  if (u.isEmpty) return null;
  final ImageProvider provider = kIsWeb
      ? NetworkImage(u)
      : CachedNetworkImageProvider(u);
  final completer = Completer<Size?>();
  late ImageStreamListener listener;
  final stream = provider.resolve(const ImageConfiguration());
  listener = ImageStreamListener((info, _) {
    if (!completer.isCompleted) {
      completer.complete(
          Size(info.image.width.toDouble(), info.image.height.toDouble()));
    }
  }, onError: (_, __) {
    if (!completer.isCompleted) completer.complete(null);
  });
  stream.addListener(listener);
  Timer(const Duration(seconds: 3), () {
    if (!completer.isCompleted) completer.complete(null);
  });
  try {
    return await completer.future;
  } catch (_) {
    return null;
  }
}
