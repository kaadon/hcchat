import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../config/app_config.dart';
import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/conversation_service.dart';
import '../services/friend_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/v2_kit.dart';
import '../widgets/v2_settings.dart'; // V2SetCard / V2SetDangerButton / context.setXxx
import 'forward_picker_page.dart';
import 'media_filter_page.dart';
import 'search_page.dart';

// ============================================================================
// 频道资料页（2026-09-15 第二十批，参考截图 Screenshot_2026_0914_183516.jpg）
//
// 与群资料页 `group_manage_page.dart`（参考图 Screenshot_2026_0914_183445.jpg
// 同一系列）同一套实测视觉规格：白底头块（头像 128 圆角方 r31 / 频道名 30.6
// w600 / 订阅数 19.3 / 72×72 圆角方瓦片）+ 卡1 简介 + 卡2 媒体四行 + 卡3 分享。
//
// 与参考图的差异（**不硬编假值**）：
//   1. 参考图频道名旁有蓝色认证勾 —— 后端无「频道认证」字段，不展示（有数据再上）。
//   2. 卡2 数字：只有「照片和视频」「文件」能取到真值（群文件接口 total）；
//      「共享链接」「语音消息」后端无聚合接口 → 不显示数字（与群资料页同口径）。
//   3. **没有「举报」项**（用户明确：频道资料不要举报）。
//   4. 参考图未含「退出频道」，但这是既有必备功能 → 保留在页尾危险区；
//      「清空聊天记录」收进右上「…」菜单。
//
// 业务保留清单（自 ConvSettingsPage 频道分支迁移，改前有 → 改后仍有）：
//   频道 ID 显示+复制（shortId 优先）/ 消息免打扰（静音瓦片）/ 清空聊天记录（…菜单）/
//   退出频道（页尾）/ 分享频道名片（原「…」转发名片，kind=channel 契约不变）
// ============================================================================

// ---------- 实测尺寸（逻辑 px，与 group_manage_page 同源） ----------
const double _kAvatarTop = 8.3;
const double _kAvatarD = 128.0;
const double _kAvatarR = 31.0;
const double _kNameSize = 30.6;
const double _kCountSize = 19.3;
const double _kTileD = 72.0;
const double _kTileR = 20.5;
const double _kTileGap = 40.7;
const double _kTileLabelSize = 15.35;
const double _kTileLabelGap = 14.5;
const double _kDescSize = 21.7;
const double _kDescLine = 31.3;
const double _kMiniLabelSize = 15.7;
const double _kChannelIdSize = 22.0;
const double _kCardTextLeft = 22.6;
const double _kCardLabelLeft = 23.0;
const double _kRowH = 75.8;
const double _kRowIconLeft = 34.0;
const double _kRowIconBox = 22.0;
const double _kRowTextLeft = 87.3;
const double _kRowTextSize = 21.0;
const double _kRowNumSize = 17.0;
const double _kChevronRight = 21.75;
const double _kHeadToCard = 25.4;
const double _kCardGap = 23.3;
const double _kTopBarH = 56.0;
const double _kBackSize = 31.0;
const double _kBackLeft = 13.0;
const double _kBackTop = 12.7;
const double _kDotsTop = 14.3;

// ---------- 实测颜色（深浅色各自适配） ----------
const Color _kNumColor = Color(0xFF989EA7);
const Color _kMiniLabel = Color(0xFF9CA0A8);
const Color _kTileFill = Color(0xFFF1F2F6);
const Color _kTileIcon = Color(0xFF23272F);
const Color _kTileLabel = Color(0xFF141517);

Color _numColor(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF8E8E93) : _kNumColor;
Color _miniLabelColor(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF8E8E93) : _kMiniLabel;
Color _tileFillColor(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF2C2C2E) : _kTileFill;
Color _tileIconColor(BuildContext c) =>
    c.v2IsDark ? const Color(0xFFF2F2F7) : _kTileIcon;
Color _tileLabelColor(BuildContext c) =>
    c.v2IsDark ? const Color(0xFFF2F2F7) : _kTileLabel;

/// 频道资料页（chat_page「…」对频道会话推入，替代 ConvSettingsPage 频道分支）。
class ChannelProfilePage extends StatefulWidget {
  final ConvItem conv;
  const ChannelProfilePage({super.key, required this.conv});

  @override
  State<ChannelProfilePage> createState() => _ChannelProfilePageState();
}

class _ChannelProfilePageState extends State<ChannelProfilePage> {
  final _svc = ConversationService();
  final _friendSvc = FriendService();
  bool _mute = false;
  int _photoCount = 0; // 照片和视频 = image + video（消息类型计数）
  int _fileCount = 0;
  int _linkCount = 0;
  int _voiceCount = 0;
  String? _myId; // 分享名片用（ForwardPickerPage 排除自己）

  ConvItem get conv => widget.conv;
  String get _convId => conv.id;

  String get _name {
    final n = conv.conversationName.trim();
    if (n.isNotEmpty) return n;
    final zh = conv.conversation['nameZh']?.toString().trim() ?? '';
    if (zh.isNotEmpty) return zh;
    return conv.conversation['nameEn']?.toString().trim() ?? '';
  }

  String get _avatarUrl => AppConfig.assetUrl(conv.avatarUrl);

  /// 频道简介：/conversation/list 随 Conversation 下发 announcementZh/En
  /// （chat_list_page.dart:787 同一取值口径），按当前语言取值、en 空回退 zh。
  String get _description {
    final lc = Localizations.localeOf(context).languageCode;
    final zh = conv.conversation['announcementZh']?.toString().trim() ?? '';
    final en = conv.conversation['announcementEn']?.toString().trim() ?? '';
    return lc == 'zh' ? zh : (en.isNotEmpty ? en : zh);
  }

  /// 频道 ID：shortId（自定义 ID）优先，为空回退雪花 ID（conv_settings_page 同口径）
  String get _channelId {
    final v = conv.conversation['shortId'] ?? '';
    final s = v.toString().trim();
    return s.isEmpty ? _convId : s;
  }

  @override
  void initState() {
    super.initState();
    _mute = conv.mute;
    _loadCounts();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    try {
      final p = await _friendSvc.profile();
      if (mounted) setState(() => _myId = p['id']?.toString());
    } catch (_) {}
  }

  /// 卡2 的数字（2026-09-15 二十三批改口径）：改用 `/message/media-count`
  /// 按消息类型统计——原读群文件接口 total，但 conv_file 集合只在文件消息
  /// 落库时写入，图片/视频消息从不进集合 → 计数恒 0。四种类型现在都是真值。
  Future<void> _loadCounts() async {
    Future<int> count(String type) async {
      try {
        final r = await ApiClient.instance.dio.get(
          '/api/v1/message/media-count',
          queryParameters: {'conversationId': _convId, 'type': type},
          options: Options(headers: {
            'Authorization': 'Bearer ${await ApiClient.instance.readToken()}'
          }),
        );
        final body = r.data as Map<String, dynamic>;
        if (((body['code'] as num?)?.toInt() ?? 0) != 0) return 0;
        final d = body['data'];
        if (d is Map) return (d['count'] as num?)?.toInt() ?? 0;
        return 0;
      } catch (_) {
        return 0;
      }
    }

    final img = await count('image');
    final vid = await count('video');
    final doc = await count('file');
    final link = await count('link');
    final voice = await count('voice');
    if (!mounted) return;
    setState(() {
      _photoCount = img + vid;
      _fileCount = doc;
      _linkCount = link;
      _voiceCount = voice;
    });
  }

  // ---------------------------------------------------------------- 顶部条

  Widget _topBar(double top, double s) {
    return Container(
      color: context.setCard,
      height: top + _kTopBarH * s,
      padding: EdgeInsets.only(top: top),
      child: Stack(
        children: [
          // 返回「<」（与群资料页同款：arrow_back_ios_new @31）
          Positioned(
            left: _kBackLeft * s,
            top: _kBackTop * s,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).maybePop(),
              child: SizedBox(
                width: _kBackSize * s,
                height: _kBackSize * s,
                child: Icon(Icons.arrow_back_ios_new,
                    size: _kBackSize * s, color: context.setTitle),
              ),
            ),
          ),
          // 「…」：清空聊天记录（分享频道已升级为页内独立卡，不再走菜单）
          Positioned(
            right: 16.0 * s,
            top: _kDotsTop * s,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _showMoreSheet,
              child: SizedBox(
                width: 30 * s,
                height: 30 * s,
                child: Icon(Icons.more_horiz,
                    size: 30 * s, color: context.setTitle),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showMoreSheet() {
    final t = AppLocalizations.of(context).t;
    AppDialogs.actionSheet(
      context,
      actions: [
        DialogAction(
          label: t('convSetClearHistoryTitle'),
          icon: Icons.delete_outline,
          onTap: _clearHistory,
        ),
      ],
    );
  }

  void _clearHistory() async {
    final t = AppLocalizations.of(context).t;
    final ok = await AppDialogs.confirm(context,
        title: t('convSetClearHistoryTitle'),
        message: t('convSetClearHistoryMsg'),
        confirmText: t('convSetClearHistoryConfirm'),
        danger: true);
    if (ok == true && mounted) {
      AppDialogs.toast(context, t('convSetHistoryCleared'));
    }
  }

  // ---------------------------------------------------------------- 白底头块

  Widget _profileHead(double s) {
    final t = AppLocalizations.of(context).t;
    return Container(
      color: context.setCard,
      padding: EdgeInsets.only(top: _kAvatarTop * s, bottom: 24 * s),
      child: Column(
        children: [
          AppAvatar(url: _avatarUrl, name: _name, size: _kAvatarD * s, radius: _kAvatarR * s),
          SizedBox(height: 21.55 * s),
          // 频道名（参考图旁有蓝色认证勾 —— 后端无认证字段，不展示）
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  _name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: _kNameSize * s,
                    fontWeight: FontWeight.w600,
                    height: 1.0,
                    color: context.setTitle,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 16.4 * s),
          // 「{count} 人订阅」（与 chat_page 顶栏同一词条口径）
          Text(
            t('chatSubSubscribers', {'count': '${conv.memberCount}'}),
            style: TextStyle(
              fontSize: _kCountSize * s,
              height: 1.0,
              color: _numColor(context),
            ),
          ),
          SizedBox(height: 29.15 * s),
          _actionTiles(s),
        ],
      ),
    );
  }

  /// 两个操作瓦片：静音 / 搜索（参考图无「公告」瓦片，比群资料页少一个）
  Widget _actionTiles(double s) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _tile(s,
            icon: Icons.notifications_off_outlined,
            labelKey: 'gmpMute',
            onTap: _toggleMute),
        SizedBox(width: _kTileGap * s),
        _tile(s,
            icon: Icons.search_rounded,
            labelKey: 'gmpSearch',
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SearchPage()))),
      ],
    );
  }

  Future<void> _toggleMute() async {
    final t = AppLocalizations.of(context).t;
    final next = !_mute;
    final ok = await _svc.setMute(_convId, next);
    if (ok && mounted) {
      setState(() => _mute = next);
      AppDialogs.toast(context, t(next ? 'gmpMuteOn' : 'gmpMuteOff'));
    }
  }

  Widget _tile(double s,
      {required IconData icon,
      required String labelKey,
      required VoidCallback onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: _kTileD * s,
            height: _kTileD * s,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _tileFillColor(context),
              borderRadius: BorderRadius.circular(_kTileR * s),
            ),
            child: Icon(icon, size: 30 * s, color: _tileIconColor(context)),
          ),
          SizedBox(height: _kTileLabelGap * s),
          Text(
            AppLocalizations.of(context).t(labelKey),
            style: TextStyle(
              fontSize: _kTileLabelSize * s,
              height: 1.0,
              color: _tileLabelColor(context),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 卡 1

  Widget _descCard(double s) {
    final t = AppLocalizations.of(context).t;
    final desc = _description;
    return V2SetCard(rows: [
      // V2SetCard 内部 Column 默认 center：块宽度是内容固有宽会被水平居中
      // （二十二批 #2：用户实测「暂无简介/描述」居中了）→ 两块都强制满宽，
      // 文字由内部 Column 的 crossAxisAlignment.start 靠左。
      SizedBox(
        width: double.infinity,
        child: Padding(
          padding: EdgeInsets.only(
              left: _kCardTextLeft * s,
              right: _kCardTextLeft * s,
              top: 14.7 * s,
              bottom: 16.1 * s),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              // 简介为空显示占位文案（不编假数据）
              desc.isEmpty ? t('chpNoBio') : desc,
              style: TextStyle(
                fontSize: _kDescSize * s,
                height: _kDescLine / _kDescSize,
                color:
                    desc.isEmpty ? _miniLabelColor(context) : context.setTitle,
              ),
            ),
            SizedBox(height: 5.7 * s),
            Text(
              t('gmpDescription'),
              style: TextStyle(
                fontSize: _kMiniLabelSize * s,
                height: 1.0,
                color: _miniLabelColor(context),
              ),
            ),
          ],
          ),
        ),
      ),
      // 频道 ID（可复制）：自定义 shortId 优先，回退雪花 ID。
      // 十七批需求保留项：显示+复制不因换页丢失。
      SizedBox(
        width: double.infinity,
        child: InkWell(
          onTap: _copyChannelId,
          onLongPress: _copyChannelId,
          child: Padding(
            padding: EdgeInsets.only(
                left: _kCardLabelLeft * s,
                right: _kCardLabelLeft * s,
                top: 19.85 * s,
                bottom: 18.95 * s),
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      '@$_channelId',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: _kChannelIdSize * s,
                        height: 1.0,
                        color: context.setTitle,
                      ),
                    ),
                  ),
                  SizedBox(width: 6 * s),
                  Icon(Icons.copy, size: 16 * s, color: _miniLabelColor(context)),
                ],
              ),
              SizedBox(height: 9.3 * s),
              Text(
                t('chpChannelIdLabel'),
                style: TextStyle(
                  fontSize: _kMiniLabelSize * s,
                  height: 1.0,
                  color: _miniLabelColor(context),
                ),
              ),
            ],
            ),
          ),
        ),
      ),
    ]);
  }

  void _copyChannelId() {
    if (_channelId.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _channelId));
    AppDialogs.toast(
        context, AppLocalizations.of(context).t('convSetChannelIdCopied'));
  }

  // ------------------------------------------------------------------ 卡 2

  Widget _mediaCard(double s) {
    return V2SetCard(rows: [
      _mediaRow(s,
          icon: Icons.image_outlined,
          labelKey: 'gmpPhotosVideos',
          count: _photoCount,
          type: 'image'),
      _mediaRow(s,
          icon: Icons.insert_drive_file_outlined,
          labelKey: 'chatDrawerFile',
          count: _fileCount,
          type: 'file'),
      _mediaRow(s,
          icon: Icons.link_rounded,
          labelKey: 'gmpSharedLinks',
          count: _linkCount,
          type: 'link'),
      _mediaRow(s,
          icon: Icons.mic_none,
          labelKey: 'gmpVoiceMessages',
          count: _voiceCount,
          type: 'voice'),
    ]);
  }

  Widget _mediaRow(double s,
      {required IconData icon,
      required String labelKey,
      required int? count,
      required String type}) {
    return SizedBox(
      height: _kRowH * s,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => MediaFilterPage(
                  title: AppLocalizations.of(context).t(labelKey),
                  convId: _convId,
                  type: type))),
          child: Row(
            children: [
              SizedBox(width: _kRowIconLeft * s),
              SizedBox(
                width: _kRowIconBox * s,
                child: Icon(icon, size: 26 * s, color: context.setTitle),
              ),
              SizedBox(
                  width: (_kRowTextLeft - _kRowIconLeft - _kRowIconBox) * s),
              Expanded(
                child: Text(
                  AppLocalizations.of(context).t(labelKey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: _kRowTextSize * s,
                    color: context.setTitle,
                  ),
                ),
              ),
              if (count != null)
                Padding(
                  padding: EdgeInsets.only(right: 10 * s),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontSize: _kRowNumSize * s,
                      color: _numColor(context),
                    ),
                  ),
                ),
              Padding(
                padding: EdgeInsets.only(right: _kChevronRight * s),
                child: Icon(Icons.chevron_right,
                    size: 26 * s, color: _miniLabelColor(context)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 卡 3

  /// 分享频道（参考图卡3；原 ConvSettingsPage「…」转发名片的频道分支迁移，
  /// kind=channel 名片契约与十六批解析侧完全一致）
  Widget _shareCard(double s) {
    final t = AppLocalizations.of(context).t;
    return V2SetCard(rows: [
      SizedBox(
        height: _kRowH * s,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _shareChannel,
            child: Row(
              children: [
                SizedBox(width: _kRowIconLeft * s),
                SizedBox(
                  width: _kRowIconBox * s,
                  child:
                      Icon(Icons.share_outlined, size: 26 * s, color: context.setTitle),
                ),
                SizedBox(
                    width: (_kRowTextLeft - _kRowIconLeft - _kRowIconBox) * s),
                Expanded(
                  child: Text(
                    t('chpShareChannel'),
                    style: TextStyle(
                      fontSize: _kRowTextSize * s,
                      color: context.setTitle,
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.only(right: _kChevronRight * s),
                  child: Icon(Icons.chevron_right,
                      size: 26 * s, color: _miniLabelColor(context)),
                ),
              ],
            ),
          ),
        ),
      ),
    ]);
  }

  /// 分享频道名片：选会话 → 发 type=10 名片消息
  /// content=JSON {"kind":"channel","id","name","avatar"}（雪花 ID 全程字符串）
  Future<void> _shareChannel() async {
    final t = AppLocalizations.of(context).t;
    final picked = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => ForwardPickerPage(myId: _myId ?? '')),
    );
    if (picked == null || !mounted) return;
    final targetId = picked['id']?.toString() ?? '';
    if (targetId.isEmpty) return;
    try {
      // 好友 → 先 createDirect 拿会话 id（字符串）；群/频道 → 直接用会话 id
      String convId;
      if (picked['kind'] == 'group') {
        convId = targetId;
      } else {
        final c = await _svc.createDirect(targetId);
        convId = c['id']?.toString() ?? '';
      }
      if (convId.isEmpty) throw Exception('empty conversation id');
      final content = jsonEncode({
        'kind': 'channel',
        'id': _convId,
        'name': _name,
        'avatar': conv.avatarUrl,
      });
      await _svc.sendRaw(convId, 10, content,
          clientMsgId:
              '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(99999)}');
      if (!mounted) return;
      AppDialogs.toast(context, t('forwardCardDone'));
    } catch (e) {
      if (mounted) {
        AppDialogs.toast(context, t('convSetStartConvFailed', {'error': '$e'}));
      }
    }
  }

  // ------------------------------------------------------------------ 卡 4

  Widget _exitCard(double s) {
    final t = AppLocalizations.of(context).t;
    return V2SetCard(rows: [
      V2SetDangerButton(
        label: t('convSetExitChannelTitle'),
        onTap: _exitChannel,
        filled: false,
      ),
    ]);
  }

  /// 退出频道：确认后走会话退出接口（pop(true) → chat_page 退出会话，
  /// 与 ConvSettingsPage._exitChannel 行为一致）
  Future<void> _exitChannel() async {
    final t = AppLocalizations.of(context).t;
    final ok = await AppDialogs.confirm(context,
        title: t('convSetExitChannelTitle'),
        message: t('convSetExitChannelMsg'),
        confirmText: t('convSetExitChannelConfirm'),
        danger: true);
    if (ok == true) {
      final done = await _svc.quit(_convId);
      if (done && mounted) Navigator.of(context).pop(true);
    }
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final top = MediaQuery.paddingOf(context).top; // aspect 订阅，防全页 rebuild
    return Scaffold(
      backgroundColor: context.setPageBg,
      body: Column(
        children: [
          _topBar(top, s),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _profileHead(s),
                SizedBox(height: _kHeadToCard * s),
                _descCard(s),
                SizedBox(height: _kCardGap * s),
                _mediaCard(s),
                SizedBox(height: _kCardGap * s),
                _shareCard(s),
                SizedBox(height: _kCardGap * s),
                _exitCard(s),
                SizedBox(height: 40 * s + MediaQuery.paddingOf(context).bottom),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
