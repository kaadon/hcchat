import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../config/app_config.dart';
import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/conversation_service.dart';
import '../services/friend_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/v2_kit.dart';
import '../widgets/v2_seal_badge.dart';
import '../widgets/v2_settings.dart'; // V2SetCard / V2SetSwitch / context.setXxx
import 'group/group_media_page.dart';
import 'group_members_page.dart';
import 'group_qr_page.dart';
import 'search_page.dart';
import 'user_qr_profile_page.dart';
import '../widgets/transitions.dart';

// ============================================================================
// 群资料页（参考截图 Screenshot_2026_0914_183445.jpg / 1260×5331 / DPR 3）
//
// 逻辑宽基准 420（= 物理宽 1260 / DPR 3），与项目 `v2Scale` 基准一致，
// 所以下面所有实测逻辑 px 直接 `* v2Scale(context)` 落地。
// 逐元素「实测值 / 落地值 / 不确定项」见 `UI-ref/measure/audit_group_friend.md`。
//
// 页面结构（自上而下，均为本页实测）：
//   ① 顶部白条：< + …（无标题）                      高 = 状态栏 + 56
//   ② 白底头块：圆角方形群头像 128（圆角 31）+ 群名 30.6/粗 + 星徽 26
//      + 「741 位成员」19.3 + 三个 72×72 圆角方瓦片（静音/搜索/公告）+ 标签 15.35
//      白底总高 = 状态栏 + 56 + 384.3
//   ③ 卡1（高 201.3）：群简介正文 21.7 / 行距 31.3 → 「描述」15.7 → 分隔线
//      → @群组号 22 → 「群组号」15.7
//   ④ 卡2（高 381.8）：5 行 × 75.8：照片和视频 / 文件 / 共享链接 / 语音消息 / 群二维码
//   ⑤ 「成员」15.9（ink 左 **41.7**，逐页实测，不套用其它页）+ 右侧成员数 + 放大镜
//   ⑥ 成员卡：行高 77.1，头像 51（圆角 9.3）+ 昵称 21.7（群主绿 #66C7A3）
//      + 角色徽章（创建者 = #DCDCDC 底 + 近黑字；管理员 = #E5F3E6 底 + 绿字）
//      + 「离线」16.2
//
// 与参考截图的差异（后端没这些字段，**不硬编假值**，详见报告「未接后端」）：
//   1. 群简介：Conversation 无 description 字段 → 读 `descriptionZh`/`description`；
//      为空时显示 l10n「暂无群简介」占位，不编假文案。
//   2. 群组号：无群号/短号字段 → 回落显示会话 ID（真实值）。
//   3. 卡2 数字：只有「照片和视频」「文件」能取到真值（群文件接口的 total）；
//      「共享链接」「语音消息」后端无聚合接口 → 不显示数字。
// ============================================================================

// ---------- 实测尺寸（逻辑 px） ----------
/// 白底头块（状态栏 + 顶部条 56 **之外**）的总高
const double _kHeadH = 384.3;

/// 头像距顶部条底边 8.3；群头像 128 方、圆角拟合 31.1
const double _kAvatarTop = 8.3;
const double _kAvatarD = 128.0;
const double _kAvatarR = 31.0;

const double _kNameSize = 30.6; // 7 字 ink 211.4 ⇒ 逐字 30.6
const double _kSealSize = 26.0; // 星徽 ink 26.0
const double _kSealGap = 10.6;
const double _kCountSize = 19.3; // 「位成员」逐字 19.3

/// 三个操作瓦片：72×72、圆角拟合 20.5、瓦片间距 40.7、标签 15.35
const double _kTileD = 72.0;
const double _kTileR = 20.5;
const double _kTileGap = 40.7;
const double _kTileLabelSize = 15.35;
const double _kTileLabelGap = 14.5;

/// 卡1：正文 21.7 / 行距 31.3；两个小标签 15.7；群组号 22
const double _kDescSize = 21.7;
const double _kDescLine = 31.3;
const double _kMiniLabelSize = 15.7;
const double _kGroupIdSize = 22.0;
const double _kCardTextLeft = 22.6; // 正文 ink 左 43.3 - 卡左 20.7
const double _kCardLabelLeft = 23.0; // 「描述」ink 左 43.7 - 卡左 20.7

/// 卡2：行高 75.8（卡高 381.8 = 5 行 + 4 条 0.7 分隔线）
/// 图标 ink 左 54.7（卡左 + 34.0）、文字 ink 左 108.0（卡左 + 87.3）
const double _kRowH = 75.8;
const double _kRowIconLeft = 34.0;
const double _kRowIconBox = 22.0;
const double _kRowTextLeft = 87.3;
const double _kRowTextSize = 21.0;
const double _kRowNumSize = 17.0;
const double _kChevronRight = 21.75; // 使 chevron ink 中心落在 365.2

/// 「成员」分组标题：ink 左 41.7、字号 15.9；右侧成员数 17 + 放大镜 22
const double _kSecTitleLeft = 41.7;
const double _kSecTitleSize = 15.9;
const double _kSecCountSize = 17.0;
const double _kSecIconSize = 22.0;

/// 成员行：行高 77.1、头像 51（圆角 9.3、距卡左 20.6）、昵称 21.7、副标题 16.2
const double _kMemRowH = 77.1;
const double _kMemAvatarD = 51.0;
const double _kMemAvatarR = 9.3;
const double _kMemAvatarLeft = 20.6;
const double _kMemTextLeft = 88.0; // 昵称 ink 左 108.7 - 卡左 20.7
const double _kMemNameSize = 21.7;
const double _kMemSubSize = 16.2;

/// 角色徽章：57×23、圆角 5、字号 13.5、左右内边距 8
const double _kTagH = 23.0;
const double _kTagR = 5.0;
const double _kTagSize = 13.5;
const double _kTagPadX = 8.0;

/// 卡片节奏：头块→卡1 25.4；卡1→卡2 23.3；卡2→「成员」标题 45.0；标题→成员卡 23.4
const double _kHeadToCard = 25.4;
const double _kCardGap = 23.3;
const double _kSecTop = 45.0;
const double _kSecBottom = 23.4;

/// 顶部条：内容高 56（返回/「…」ink 垂直中心落在状态栏 + 28.2，实测 87.2）
/// 返回用 `arrow_back_ios_new` @31（ink ≈ 10.3×20.7，ink 左缘 = 13.0 + 10.3 = 23.3）
const double _kTopBarH = 56.0;
const double _kBackSize = 31.0;
const double _kBackLeft = 13.0;
const double _kBackTop = 12.7;
const double _kDotsTop = 14.3;

// ---------- 实测颜色（深浅色各自适配） ----------
const Color _kOwnerName = Color(0xFF66C7A3); // 群主昵称绿（实测 #66C7A3/#69C7A3）
const Color _kOwnerTagBg = Color(0xFFDCDCDC);
const Color _kOwnerTagFg = Color(0xFF141517);
const Color _kAdminTagBg = Color(0xFFE5F3E6);
const Color _kAdminTagFg = Color(0xFF559857);
const Color _kOffline = Color(0xFF9B9B9B);
const Color _kNumColor = Color(0xFF989EA7);
const Color _kMiniLabel = Color(0xFF9CA0A8);
const Color _kTileFill = Color(0xFFF1F2F6);
const Color _kTileIcon = Color(0xFF23272F);
const Color _kTileLabel = Color(0xFF141517);

Color _ownerNameColor(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF5FC79B) : _kOwnerName;
Color _ownerTagBg(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF3A3A3C) : _kOwnerTagBg;
Color _ownerTagFg(BuildContext c) =>
    c.v2IsDark ? const Color(0xFFF2F2F7) : _kOwnerTagFg;
Color _adminTagBg(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF1F3A22) : _kAdminTagBg;
Color _adminTagFg(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF6ECB74) : _kAdminTagFg;
Color _offlineColor(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF8E8E93) : _kOffline;
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

/// 群资料页（从会话设置页「群聊资料」推入）。
///
/// 构造签名 `GroupManagePage({required ConvItem conv})` 被
/// `conv_settings_page.dart:439` 使用，**不可更改**。
class GroupManagePage extends StatefulWidget {
  final ConvItem conv;
  const GroupManagePage({super.key, required this.conv});

  @override
  State<GroupManagePage> createState() => _GroupManagePageState();
}

class _GroupManagePageState extends State<GroupManagePage> {
  final _svc = ConversationService();
  final _friendSvc = FriendService();

  List<Map<String, dynamic>> _members = [];
  bool _loading = true;
  bool _mute = false;
  int _memberTotal = 0;
  // 2026-09-29 成员分页：只拉前 20 个，超出走「加载更多成员」手动增量拉取，
  // 避免万人大群一进群资料页就全量拉成员（包体/渲染双省）
  static const int _kMemberPageSize = 20;
  bool _loadingMore = false;
  // 2026-09-28（晚）图2 成员操作面板：设置快照 + 我的角色（隐私隐藏成员卡/菜单权限判定）
  Map<String, dynamic> _settings = {};
  String _myId = '';
  int _myRole = 0;

  /// 卡2 的数字：photo/file 为 null = 接口不可用 → 不显示数字（不编 0）；
  /// link/voice 走 /message/media-count 真值（二十三批）。
  int? _photoCount;
  int? _fileCount;
  int _linkCount = 0;
  int _voiceCount = 0;

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

  String get _announcement =>
      conv.conversation['announcementZh']?.toString() ?? '';

  /// 群组号：后端暂无群号字段 → 回落会话 ID（真实值，不是编的）
  String get _groupId {
    final v =
        conv.conversation['shortId'] ?? conv.conversation['groupNo'] ?? '';
    final s = v.toString().trim();
    return s.isEmpty ? _convId : s;
  }

  @override
  void initState() {
    super.initState();
    _mute = conv.mute;
    _memberTotal = conv.memberCount;
    _load();
  }

  Future<void> _load() async {
    try {
      // 2026-09-28（晚）：先取我的 id + 群设置，再拉成员并定位我的角色
      try {
        final p = await _friendSvc.profile();
        _myId = p['id']?.toString() ?? '';
      } catch (_) {}
      try {
        _settings = await _svc.groupSettings(_convId);
      } catch (_) {}
      // 2026-09-29：分页拉取，只取第一页 20 个（owner/管理员按 role 排最前，
      // 角色识别不受影响）；memberCount 恒为全量总数
      final m = await _svc.members(_convId, page: 1, size: _kMemberPageSize);
      if (!mounted) return;
      int myRole = 0;
      for (final it in m) {
        final uid = it['id']?.toString() ?? it['userId']?.toString() ?? '';
        if (uid == _myId) {
          myRole = (it['role'] as num?)?.toInt() ?? 3;
          break;
        }
      }
      setState(() {
        _members = m;
        _myRole = myRole;
        if (_svc.lastMembersCount > 0) _memberTotal = _svc.lastMembersCount;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
    _loadCounts();
  }

  /// 2026-09-28（晚）需求：群主开启「成员隐私」后，群资料页**整卡隐藏**成员区
  ///（普通成员视角；角色未知 0 时放行对齐群成员页口径）
  bool get _hideMembers =>
      _settings['privacyEnabled'] == true && _myRole == 3;

  bool get _isManager => _myRole == 1 || _myRole == 2;

  /// 卡2 的数字（2026-09-15 二十三批改口径）：改用 `/message/media-count`
  /// 按消息类型统计——原读群文件接口 total，但 conv_file 集合只在文件消息
  /// 落库时写入，图片/视频消息从不进集合 → 照片计数恒 0。四种类型现在都是真值。
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
          // 返回「<」（实测 ink 11.3 × 19.7、ink 左缘 23.7、ink 中心 y 87.2）
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
          // 「…」（实测 ink 19.7 × 4.0、右缘 399.0、ink 中心 y 87.3）
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

  // ------------------------------------------------------- 白底头块

  Widget _profileHead(double s) {
    final t = AppLocalizations.of(context).t;
    return Container(
      color: context.setCard,
      height: _kHeadH * s,
      child: Column(
        children: [
          SizedBox(height: _kAvatarTop * s),
          AppAvatar(
            url: _avatarUrl,
            name: _name,
            size: _kAvatarD * s,
            radius: _kAvatarR * s,
          ),
          SizedBox(height: 21.55 * s),
          // 群名 + 星徽（整组居中：实测 86.3..334.3，中心 210.3）
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
              SizedBox(width: _kSealGap * s),
              V2SealBadge(size: _kSealSize, color: context.setTitle),
            ],
          ),
          SizedBox(height: 16.4 * s),
          // 「741 位成员」
          Text(
            t('gmpMemberCount', {'count': '$_memberTotal'}),
            style: TextStyle(
              fontSize: _kCountSize * s,
              height: 1.0,
              color: _offlineColor(context),
            ),
          ),
          SizedBox(height: 29.15 * s),
          _actionTiles(s),
        ],
      ),
    );
  }

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
            // 2026-09-29 会话内搜索：只搜本群聊天记录
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SearchPage(
                    convId: _convId,
                    convName: conv.conversationName)))),
        SizedBox(width: _kTileGap * s),
        _tile(s,
            icon: Icons.campaign_outlined,
            labelKey: 'gmpAnnounce',
            onTap: _showAnnouncement),
      ],
    );
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
    // 2026-09-29 用户口径：此卡从「群简介」改为展示**群公告**
    //（announcementZh，编辑群组页同一数据源），空态显示「暂无群公告」
    final desc = _announcement;
    return V2SetCard(rows: [
      // 2026-09-29 修复内容不靠左：V2SetCard 外层 Column 默认 crossAxisAlignment=center，
      // 内层 Column 收缩到内容宽度后被整体居中 → 包 SizedBox(width: infinity) 撑满卡宽。
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
                // 群公告（2026-09-29 从群简介改口径）；为空显示占位文案（不编假数据）
                desc.isEmpty ? t('gmpNoAnnouncement') : desc,
                style: TextStyle(
                  fontSize: _kDescSize * s,
                  height: _kDescLine / _kDescSize,
                  color:
                      desc.isEmpty ? _miniLabelColor(context) : context.setTitle,
                ),
              ),
              SizedBox(height: 5.7 * s),
              Text(
                // 2026-09-29 口径：小标签「群公告」（原「描述」）
                t('convSetGroupAnnouncement'),
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
      SizedBox(
        width: double.infinity,
        child: Padding(
          padding: EdgeInsets.only(
              left: _kCardLabelLeft * s,
              right: _kCardLabelLeft * s,
              top: 19.85 * s,
              bottom: 18.95 * s),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '@$_groupId',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: _kGroupIdSize * s,
                  height: 1.0,
                  color: context.setTitle,
                ),
              ),
              SizedBox(height: 9.3 * s),
              Text(
                t('gmpGroupNo'),
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
    ]);
  }

  // ------------------------------------------------------------------ 卡 2

  Widget _mediaCard(double s) {
    return V2SetCard(rows: [
      _mediaRow(s,
          icon: Icons.image_outlined,
          labelKey: 'gmpPhotosVideos',
          count: _photoCount,
          // 2026-09-29 查看媒体改按消息扫描（GroupMediaPage），原群文件云盘页查不到聊天图片
          onTap: () => _openMedia(0)),
      _mediaRow(s,
          icon: Icons.insert_drive_file_outlined,
          labelKey: 'chatDrawerFile',
          count: _fileCount,
          onTap: () => _openMedia(2)),
      _mediaRow(s,
          icon: Icons.link_rounded,
          labelKey: 'gmpSharedLinks',
          count: _linkCount,
          onTap: () => _openMedia(3)),
      _mediaRow(s,
          icon: Icons.mic_none,
          labelKey: 'gmpVoiceMessages',
          count: _voiceCount,
          onTap: () => _openMedia(4)),
      _mediaRow(s,
          icon: Icons.qr_code_2,
          labelKey: 'groupQrSection',
          count: null,
          onTap: () => Navigator.of(context)
              .push(fadeScaleRoute(GroupQrPage(conv: conv), scale: true))),
    ]);
  }

  /// 2026-09-29：媒体卡落地页改为按消息扫描的 GroupMediaPage
  /// （tab：0 照片 / 1 视频 / 2 文件 / 3 链接 / 4 语音，与群资料页四行计数同源）
  void _openMedia(int tab) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => GroupMediaPage(
            convId: _convId, convName: _name, initialTab: tab)));
  }

  Widget _mediaRow(double s,
      {required IconData icon,
      required String labelKey,
      required int? count,
      required VoidCallback onTap}) {
    return SizedBox(
      height: _kRowH * s,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
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
                      height: 1.0,
                      color: context.setTitle),
                ),
              ),
              // 只有拿到真实统计的项才显示数字（后端无接口的项不编 0）
              if (count != null)
                Text(
                  '$count',
                  style: TextStyle(
                      fontSize: _kRowNumSize * s,
                      height: 1.0,
                      color: _numColor(context)),
                ),
              SizedBox(width: 21.7 * s),
              Padding(
                padding: EdgeInsets.only(right: _kChevronRight * s),
                child: Icon(Icons.chevron_right,
                    size: 24 * s, color: context.setChevron),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------- 成员区

  Widget _membersHeader(double s) {
    return Padding(
      padding: EdgeInsets.only(left: _kSecTitleLeft * s, right: 15.9 * s),
      child: SizedBox(
        height: _kSecIconSize * s,
        child: Row(
          children: [
            Text(
              AppLocalizations.of(context).t('chatMember'),
              style: TextStyle(
                  fontSize: _kSecTitleSize * s,
                  height: 1.0,
                  color: context.setLabel),
            ),
            const Spacer(),
            Text(
              _loading ? '' : '${_members.length}',
              style: TextStyle(
                  fontSize: _kSecCountSize * s,
                  height: 1.0,
                  color: _numColor(context)),
            ),
            SizedBox(width: 15.2 * s),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openMembers,
              child: Icon(Icons.search_rounded,
                  size: _kSecIconSize * s, color: context.setTitle),
            ),
          ],
        ),
      ),
    );
  }

  void _openMembers() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => GroupMembersPage(conv: conv)))
        .then((_) {
      if (mounted) _load();
    });
  }

  Widget _membersCard(double s) {
    if (_loading) {
      return const V2SetCard(rows: [SizedBox(height: 120)]);
    }
    if (_members.isEmpty) {
      return V2SetCard(rows: [
        SizedBox(
          height: _kMemRowH * s,
          child: Center(
            child: Text(
              AppLocalizations.of(context).t('convSetNoMembers'),
              style:
                  TextStyle(fontSize: _kMemSubSize * s, color: context.setSub),
            ),
          ),
        ),
      ]);
    }
    return V2SetCard(rows: [
      for (final m in _members) _memberRow(s, m),
      // 2026-09-29 分页：未拉全时显示「加载更多成员」（手动点按增量拉取）
      if (_members.length < _memberTotal) _loadMoreRow(s),
    ]);
  }

  /// 「加载更多成员」行（2026-09-29）：显示已加载/总数，点击拉下一页
  Widget _loadMoreRow(double s) {
    final t = AppLocalizations.of(context).t;
    return SizedBox(
      height: _kMemRowH * s,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _loadingMore ? null : _loadMoreMembers,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_loadingMore) ...[
                SizedBox(
                    width: 14 * s,
                    height: 14 * s,
                    child: const CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 8 * s),
              ],
              Text(
                '${t('loadMoreMembers')} (${_members.length}/$_memberTotal)',
                style: TextStyle(
                    fontSize: _kMemSubSize * s, color: context.setSub),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 手动加载更多成员（追加，按 id 去重防重复行；失败静默保留现状）
  Future<void> _loadMoreMembers() async {
    if (_loadingMore || _members.length >= _memberTotal) return;
    _loadingMore = true;
    try {
      final next = await _svc.members(_convId,
          page: _members.length ~/ _kMemberPageSize + 1,
          size: _kMemberPageSize);
      if (!mounted) return;
      setState(() {
        final seen = _members.map(_uidOf).toSet();
        for (final it in next) {
          if (seen.add(_uidOf(it))) _members.add(it);
        }
      });
    } catch (_) {
      // 静默失败：保留已加载内容，用户可再次点按重试
    } finally {
      _loadingMore = false;
      if (mounted) setState(() {});
    }
  }

  Widget _memberRow(double s, Map<String, dynamic> m) {
    final t = AppLocalizations.of(context).t;
    final realName = (m['nickname']?.toString().trim().isNotEmpty ?? false)
        ? m['nickname'].toString()
        : (m['account']?.toString() ?? t('contactsUser'));
    final remark = m['remark']?.toString() ?? '';
    // 2026-09-28（晚）：群昵称优先（后端新增 groupNickname）→ 好友备注 → 用户昵称
    final groupNick = m['groupNickname']?.toString().trim() ?? '';
    final name = groupNick.isNotEmpty
        ? groupNick
        : (remark.isNotEmpty ? remark : realName);
    final role = (m['role'] as num?)?.toInt() ?? 3;
    final isOwner = role == 1;
    final isAdmin = role == 2;
    final uid = m['id']?.toString() ?? m['userId']?.toString() ?? '';

    return SizedBox(
      height: _kMemRowH * s,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          // 2026-09-28（晚）图2：群主/管理员点成员弹操作面板；
          // 普通成员直接看资料
          onTap: () {
            if (_isManager) {
              _showMemberSheet(m);
            } else {
              Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => UserQrProfilePage(uid: uid)));
            }
          },
          child: Row(
            children: [
              SizedBox(width: _kMemAvatarLeft * s),
              AppAvatar(
                url: AppConfig.assetUrl(m['avatar']?.toString() ?? ''),
                name: name,
                size: _kMemAvatarD * s,
                radius: _kMemAvatarR * s,
              ),
              SizedBox(
                  width: (_kMemTextLeft - _kMemAvatarLeft - _kMemAvatarD) * s),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: _kMemNameSize * s,
                              height: 1.0,
                              // 群主昵称绿色（实测 #66C7A3），其余近黑
                              color: isOwner
                                  ? _ownerNameColor(context)
                                  : context.setTitle,
                            ),
                          ),
                        ),
                        if (isOwner || isAdmin) ...[
                          SizedBox(width: 8.7 * s),
                          _roleTag(
                              s,
                              isOwner ? 'gmpRoleCreator' : 'groupRoleAdmin',
                              isOwner),
                        ],
                      ],
                    ),
                    SizedBox(height: 10.7 * s),
                    Text(
                      (m['online'] == true)
                          ? t('chatStatusOnline')
                          : t('convSetOffline'),
                      style: TextStyle(
                          fontSize: _kMemSubSize * s,
                          height: 1.0,
                          color: _offlineColor(context)),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.only(right: _kChevronRight * s),
                child: Icon(Icons.chevron_right,
                    size: 24 * s, color: context.setChevron),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 角色徽章：创建者 = 灰底近黑字；管理员 = 浅绿底绿字（均为参考包实测）
  Widget _roleTag(double s, String labelKey, bool owner) {
    return Container(
      height: _kTagH * s,
      padding: EdgeInsets.symmetric(horizontal: _kTagPadX * s),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: owner ? _ownerTagBg(context) : _adminTagBg(context),
        borderRadius: BorderRadius.circular(_kTagR * s),
      ),
      child: Text(
        AppLocalizations.of(context).t(labelKey),
        style: TextStyle(
          fontSize: _kTagSize * s,
          height: 1.0,
          color: owner ? _ownerTagFg(context) : _adminTagFg(context),
        ),
      ),
    );
  }

  // ==================== 成员操作面板（2026-09-28（晚）图2 复刻） ====================

  String _uidOf(Map<String, dynamic> m) =>
      m['id']?.toString() ?? m['userId']?.toString() ?? '';

  bool _isMuted(Map<String, dynamic> m) {
    final until = (m['speakMutedUntil'] as num?)?.toInt() ?? 0;
    return until > DateTime.now().millisecondsSinceEpoch ~/ 1000;
  }

  String _memberName(Map<String, dynamic> m) {
    final t = AppLocalizations.of(context).t;
    final groupNick = m['groupNickname']?.toString().trim() ?? '';
    final remark = m['remark']?.toString() ?? '';
    final realName = (m['nickname']?.toString().trim().isNotEmpty ?? false)
        ? m['nickname'].toString()
        : (m['account']?.toString() ?? t('contactsUser'));
    return groupNick.isNotEmpty
        ? groupNick
        : (remark.isNotEmpty ? remark : realName);
  }

  /// 面板单行：通栏白底、文字居中（图2）；danger=true 红字
  /// 面板条目（2026-09-29 美化：左侧图标 + 左对齐文字，替代原纯文字居中）
  Widget _sheetItem(BuildContext ctx, String label, VoidCallback onTap,
      {bool danger = false, IconData? icon}) {
    final s = v2Scale(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(vertical: 14 * s),
        child: Row(
          children: [
            SizedBox(width: 22 * s),
            if (icon != null) ...[
              Icon(icon,
                  size: 20 * s,
                  color: danger ? context.setDanger : context.setSub),
              SizedBox(width: 12 * s),
            ],
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 16 * s,
                  height: 1.0,
                  color: danger ? context.setDanger : context.setTitle,
                ),
              ),
            ),
            SizedBox(width: 22 * s),
          ],
        ),
      ),
    );
  }

  void _showMemberSheet(Map<String, dynamic> m) {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    final uid = _uidOf(m);
    final role = (m['role'] as num?)?.toInt() ?? 3;
    final isSelf = uid == _myId;
    // 可管理：非自己 + 我是群主/管理员 + 对方非群主 + 管理员不能动管理员
    final canManage = !isSelf && _isManager && role != 1 && !(_myRole == 2 && role == 2);
    // 2026-09-28（晚）需求修订：「允许管理员添加成员」关闭时，管理员点成员的
    // 面板只保留 禁言四档/移出群组（去掉 查看资料/修改群昵称）；开启（默认）
    // 恢复完整面板。群主不受该开关影响。取不到设置时按开启（!=false）放行。
    final adminRestricted =
        _myRole == 2 && _settings['adminCanInvite'] == false;
    final name = _memberName(m);

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.setCard,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(14 * s))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: 16 * s),
            // 图2 顶部：头像 + 成员群昵称（2026-09-29 美化）
            AppAvatar(
              url: AppConfig.assetUrl(m['avatar']?.toString() ?? ''),
              name: name,
              size: 42 * s,
              radius: 21 * s,
            ),
            SizedBox(height: 8 * s),
            Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13 * s, color: context.setSub)),
            SizedBox(height: 6 * s),
            // 受限管理员不显示「查看资料」（2026-09-28 晚需求修订）
            if (!adminRestricted)
              _sheetItem(ctx, t('memberSheetViewProfile'), () {
                Navigator.of(ctx).pop();
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => UserQrProfilePage(uid: uid)));
              }, icon: Icons.visibility_outlined),
            if ((canManage || isSelf) && !adminRestricted)
              _sheetItem(ctx, t('memberSheetEditNick'),
                  () => _editNick(ctx, m),
                  icon: Icons.edit_outlined),
            if (_myRole == 1 && role == 3)
              _sheetItem(ctx, t('memberSheetSetAdmin'),
                  () => _setAdmin(ctx, m, true),
                  icon: Icons.admin_panel_settings_outlined),
            if (_myRole == 1 && role == 2)
              _sheetItem(ctx, t('memberSheetUnsetAdmin'),
                  () => _setAdmin(ctx, m, false),
                  icon: Icons.admin_panel_settings_outlined),
            if (_myRole == 1 && !isSelf)
              _sheetItem(ctx, t('memberSheetTransfer'),
                  () => _transferOwner(ctx, m),
                  icon: Icons.swap_horiz,
                  danger: true),
            if (canManage)
              _sheetItem(ctx, t('memberSheetMute'),
                  () => _showMuteSheet(ctx, m),
                  icon: Icons.volume_off_outlined),
            if (canManage)
              _sheetItem(ctx, t('memberSheetRemove'),
                  () => _removeMember(ctx, m),
                  icon: Icons.person_remove,
                  danger: true),
            SizedBox(height: 6 * s),
            Container(height: 0.6, color: context.setHair),
            _sheetItem(ctx, t('commonCancel'), () => Navigator.of(ctx).pop(),
                icon: Icons.close),
          ],
        ),
      ),
    );
  }

  /// 修改群昵称（群主/管理员改他人；成员改自己；空串=清除）
  Future<void> _editNick(BuildContext ctx, Map<String, dynamic> m) async {
    Navigator.of(ctx).pop();
    final t = AppLocalizations.of(context).t;
    final current = m['groupNickname']?.toString() ?? '';
    final result = await AppDialogs.input(context,
        title: t('groupNickEditTitle'),
        hint: t('groupNickEditTitle'),
        maxLines: 1,
        maxLength: 32,
        initialValue: current);
    if (result == null || result.trim() == current) return;
    try {
      await _svc.setGroupNickname(_convId, _uidOf(m), result.trim());
      if (mounted) {
        AppDialogs.toast(context, t('groupNickSaved'));
        _load();
      }
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('groupNickFailed'));
    }
  }

  /// 设为/撤销管理员（仅群主）
  Future<void> _setAdmin(
      BuildContext ctx, Map<String, dynamic> m, bool admin) async {
    Navigator.of(ctx).pop();
    final t = AppLocalizations.of(context).t;
    try {
      await _svc.setGroupAdmin(_convId, _uidOf(m), admin);
      if (mounted) {
        AppDialogs.toast(
            context, t(admin ? 'groupSetAdminSuccess' : 'groupUnsetAdminSuccess'));
        _load();
      }
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('groupSetAdminFailed'));
    }
  }

  /// 转让群主（仅群主；确认后调用，成功后原群主降为管理员）
  Future<void> _transferOwner(BuildContext ctx, Map<String, dynamic> m) async {
    Navigator.of(ctx).pop();
    final t = AppLocalizations.of(context).t;
    final name = _memberName(m);
    final ok = await AppDialogs.confirm(context,
        title: t('transferOwnerTitle'),
        message: t('transferOwnerMsg', {'name': name}),
        confirmText: t('memberSheetTransfer'),
        danger: true);
    if (ok != true || !mounted) return;
    try {
      await _svc.transferOwner(_convId, _uidOf(m));
      if (mounted) {
        AppDialogs.toast(context, t('transferOwnerDone'));
        _load();
      }
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('transferOwnerFailed'));
    }
  }

  /// 禁言时长选择（图2 口径：10分钟 / 1小时 / 1天 / 永久；已禁言追加「解除禁言」）
  Future<void> _showMuteSheet(BuildContext ctx, Map<String, dynamic> m) async {
    final t = AppLocalizations.of(context).t;
    final muted = _isMuted(m);
    final picked = await showModalBottomSheet<int>(
      context: ctx,
      backgroundColor: context.setCard,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Text(t('groupMutePickTitle'),
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 4),
            ...[
              (10, t('groupMute10m')),
              (60, t('groupMute1h')),
              (1440, t('groupMute1d')),
              (-1, t('groupMuteForever')), // 负数=永久（服务端约定）
            ].map((e) => InkWell(
                  onTap: () => Navigator.of(c).pop(e.$1),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    alignment: Alignment.center,
                    child: Text(e.$2,
                        style: const TextStyle(fontSize: 16.5)),
                  ),
                )),
            if (muted)
              InkWell(
                onTap: () => Navigator.of(c).pop(0),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  alignment: Alignment.center,
                  child: Text(t('groupMuteLift'),
                      style: const TextStyle(fontSize: 16.5)),
                ),
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    try {
      if (picked == 0) {
        await _svc.muteMember(_convId, _uidOf(m), false);
        if (mounted) AppDialogs.toast(context, t('groupUnmuteSuccess'));
      } else {
        await _svc.muteMember(_convId, _uidOf(m), true, minutes: picked);
        if (mounted) AppDialogs.toast(context, t('groupMuteSuccess'));
      }
      if (mounted) _load();
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('groupMuteFailed'));
    }
  }

  /// 移出群组（先确认）
  Future<void> _removeMember(BuildContext ctx, Map<String, dynamic> m) async {
    Navigator.of(ctx).pop();
    final t = AppLocalizations.of(context).t;
    final name = _memberName(m);
    final confirmed = await AppDialogs.confirm(context,
        title: t('groupRemoveConfirmTitle'),
        message: t('groupRemoveConfirmMsg', {'name': name}),
        confirmText: t('groupRemoveConfirmBtn'),
        danger: true);
    if (confirmed != true || !mounted) return;
    try {
      await _svc.removeMember(_convId, _uidOf(m));
      if (mounted) {
        AppDialogs.toast(context, t('groupRemoveSuccess'));
        _load();
      }
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('groupRemoveFailed'));
    }
  }

  // -------------------------------------------------------------- 交互

  Future<void> _toggleMute() async {
    final t = AppLocalizations.of(context).t;
    final next = !_mute;
    setState(() => _mute = next);
    final ok = await _svc.setMute(_convId, next);
    if (!mounted) return;
    if (!ok) {
      setState(() => _mute = !next); // 失败回滚
      AppDialogs.toast(context, t('groupSettingsSaveFailed'));
      return;
    }
    conv.conversation['mute'] = next;
    AppDialogs.toast(context, next ? t('gmpMuteOn') : t('gmpMuteOff'));
  }

  void _showAnnouncement() {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.setCard,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16 * s))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20.7 * s, 18 * s, 20.7 * s, 20 * s),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t('convSetGroupAnnouncement'),
                  style: TextStyle(
                      fontSize: 17 * s,
                      fontWeight: FontWeight.w600,
                      color: ctx.setTitle)),
              SizedBox(height: 14 * s),
              Text(
                _announcement.isEmpty
                    ? t('convSetNoAnnouncement')
                    : _announcement,
                style: TextStyle(
                    fontSize: 16 * s,
                    height: 1.5,
                    color: _announcement.isEmpty ? ctx.setSub : ctx.setTitle),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 右上「…」：群管理设置 / 群二维码（保留原有全部入口）
  void _showMoreSheet() {
    final s = v2Scale(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.setCard,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16 * s))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: 8 * s),
            ListTile(
              leading: Icon(Icons.settings_outlined,
                  size: 22 * s, color: ctx.setTitle),
              title: Text(AppLocalizations.of(ctx).t('convSetGroupAdmin'),
                  style: TextStyle(fontSize: 16 * s, color: ctx.setTitle)),
              onTap: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => _GroupSettingsPage(conv: conv)));
              },
            ),
            ListTile(
              leading: Icon(Icons.qr_code_2, size: 22 * s, color: ctx.setTitle),
              title: Text(AppLocalizations.of(ctx).t('groupQrTitle'),
                  style: TextStyle(fontSize: 16 * s, color: ctx.setTitle)),
              onTap: () {
                Navigator.of(ctx).pop();
                Navigator.of(context)
                    .push(fadeScaleRoute(GroupQrPage(conv: conv), scale: true));
              },
            ),
            SizedBox(height: 8 * s),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final top = MediaQuery.paddingOf(context).top;
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
                // 2026-09-28（晚）：群主开启「成员隐私」时普通成员不显示成员区（整卡隐藏）
                if (!_hideMembers) ...[
                  SizedBox(height: _kSecTop * s),
                  _membersHeader(s),
                  SizedBox(height: _kSecBottom * s),
                  _membersCard(s),
                ],
                SizedBox(height: 40 * s + MediaQuery.paddingOf(context).bottom),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 群管理设置（原 `group_manage_page` 的全部业务：二维码进群 / 成员隐私 /
// 全员禁言 / 允许成员邀请 / 显示群成员开关 / 群管理员增删 / 群成员管理入口），
// 现由群资料页右上「…」进入。接口调用、乐观更新、失败回滚逻辑与原实现一致。
// ============================================================================

/// 需求4（2026-09-22）：群管理设置页公开导航入口——
/// 「聊天信息页 ⋯ 菜单 → 群管理」（转发名片旁，仅群主可见）跳转用
Future<void> openGroupSettingsPage(BuildContext context, ConvItem conv) async {
  await Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => _GroupSettingsPage(conv: conv)));
}

class _GroupSettingsPage extends StatefulWidget {
  final ConvItem conv;
  const _GroupSettingsPage({required this.conv});

  @override
  State<_GroupSettingsPage> createState() => _GroupSettingsPageState();
}

class _GroupSettingsPageState extends State<_GroupSettingsPage> {
  final _svc = ConversationService();
  Map<String, dynamic> _settings = {};
  List<Map<String, dynamic>> _members = [];
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await _svc.groupSettings(widget.conv.id);
      final m = await _svc.members(widget.conv.id);
      if (mounted) {
        setState(() {
          _settings = s;
          _members = m;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggle(String key, bool v) async {
    if (_saving) return;
    final t = AppLocalizations.of(context).t;
    setState(() {
      _settings = {..._settings, key: v}; // 乐观更新
      _saving = true;
    });
    try {
      switch (key) {
        case 'muteAll':
          await _svc.setGroupSettings(widget.conv.id, muteAll: v);
        case 'privacyEnabled':
          await _svc.setGroupSettings(widget.conv.id, privacyEnabled: v);
        case 'allowMemberInvite':
          await _svc.setGroupSettings(widget.conv.id, allowInvite: v);
        case 'qrJoinEnabled':
          await _svc.setGroupSettings(widget.conv.id, qrJoin: v);
        // 需求5（2026-09-22）：显示群成员人数/在线人数
        case 'showMembers':
          await _svc.setGroupSettings(widget.conv.id, showMembers: v);
      }
      if (mounted) AppDialogs.toast(context, t('groupSettingsSaved'));
    } catch (_) {
      if (mounted) {
        setState(() => _settings = {..._settings, key: !v}); // 失败回滚
        AppDialogs.toast(context, t('groupSettingsSaveFailed'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 添加管理员：从普通成员中单选
  Future<void> _addAdmin() async {
    final t = AppLocalizations.of(context).t;
    final candidates =
        _members.where((m) => (m['role'] as num?)?.toInt() == 3).toList();
    if (candidates.isEmpty) {
      AppDialogs.toast(context, t('groupNoAdminCandidate'));
      return;
    }
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                    color: ctx.cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(t('groupAddAdminPick'),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: candidates.length,
                itemBuilder: (_, i) {
                  final m = candidates[i];
                  final name = m['nickname']?.toString() ??
                      m['account']?.toString() ??
                      '';
                  return ListTile(
                    leading: AppAvatar(
                        url: AppConfig.assetUrl(m['avatar']?.toString() ?? ''),
                        name: name,
                        size: 36),
                    title: Text(name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.of(ctx).pop(m),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    try {
      await _svc.setGroupAdmin(
          widget.conv.id, picked['id']?.toString() ?? '', true);
      if (mounted) {
        AppDialogs.toast(context, t('groupSetAdminSuccess'));
        _load();
      }
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('groupSetAdminFailed'));
    }
  }

  Future<void> _removeAdmin(Map<String, dynamic> m) async {
    final t = AppLocalizations.of(context).t;
    try {
      await _svc.setGroupAdmin(
          widget.conv.id, m['id']?.toString() ?? '', false);
      if (mounted) {
        AppDialogs.toast(context, t('groupUnsetAdminSuccess'));
        _load();
      }
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('groupSetAdminFailed'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    final admins =
        _members.where((m) => (m['role'] as num?)?.toInt() == 2).toList();
    if (_loading) {
      return V2SetScaffold(
        title: t('convSetGroupAdmin'),
        children: const [Center(child: CircularProgressIndicator())],
      );
    }
    return V2SetScaffold(
      title: t('convSetGroupAdmin'),
      children: [
        V2SetCard(rows: [
          V2SetRow(
            title: t('groupSwitchQrJoin'),
            subtitle: t('groupSwitchQrJoinSub'),
            trailing: V2SetSwitch(
                value: _settings['qrJoinEnabled'] == true,
                onChanged: (v) => _toggle('qrJoinEnabled', v)),
          ),
          V2SetRow(
            title: t('groupSwitchPrivacy'),
            subtitle: t('groupSwitchPrivacySub'),
            trailing: V2SetSwitch(
                value: _settings['privacyEnabled'] == true,
                onChanged: (v) => _toggle('privacyEnabled', v)),
          ),
          V2SetRow(
            title: t('groupSwitchMuteAll'),
            subtitle: t('groupSwitchMuteAllSub'),
            trailing: V2SetSwitch(
                value: _settings['muteAll'] == true,
                onChanged: (v) => _toggle('muteAll', v)),
          ),
          V2SetRow(
            title: t('groupSwitchAllowInvite'),
            subtitle: t('groupSwitchAllowInviteSub'),
            trailing: V2SetSwitch(
                value: _settings['allowMemberInvite'] == true,
                onChanged: (v) => _toggle('allowMemberInvite', v)),
          ),
          V2SetRow(
            // 需求5（2026-09-22）：显示群成员人数/在线人数。默认开
            // （null/缺字段视为开，对齐老服务端行为）；关闭 → 群聊标题下方
            // 不显示「N 成员, M 在线」、聊天信息页不显示成员卡片
            title: t('groupSwitchShowMembers'),
            subtitle: t('groupSwitchShowMembersSub'),
            trailing: V2SetSwitch(
                value: _settings['showMembers'] != false,
                onChanged: (v) => _toggle('showMembers', v)),
          ),
        ]),
        const V2SetGap.beforeLabel(),
        V2SetSectionLabel(t('groupAdminsSection')),
        const V2SetGap.afterLabel(),
        V2SetCard(rows: [
          for (final m in admins)
            V2SetRow(
              title: m['nickname']?.toString() ??
                  m['account']?.toString() ??
                  t('contactsUser'),
              leading: AppAvatar(
                  url: AppConfig.assetUrl(m['avatar']?.toString() ?? ''),
                  name: m['nickname']?.toString() ?? '',
                  size: 40 * s,
                  radius: 9 * s),
              trailing: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _removeAdmin(m),
                child: Text(t('groupRemoveAdmin'),
                    style:
                        TextStyle(fontSize: 14 * s, color: context.setDanger)),
              ),
            ),
          V2SetRow(
            title: t('groupAddAdmin'),
            leading: Icon(Icons.person_add_alt_1,
                size: 22 * s, color: context.setTitle),
            showChevron: true,
            onTap: _addAdmin,
          ),
        ]),
        const V2SetGap.beforeLabel(),
        V2SetSectionLabel(t('convSetGroupMembers')),
        const V2SetGap.afterLabel(),
        V2SetCard(rows: [
          V2SetRow(
            title: t('groupMembersManageEntry'),
            leading: Icon(Icons.group_outlined,
                size: 22 * s, color: context.setTitle),
            showChevron: true,
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => GroupMembersPage(conv: widget.conv)));
              if (mounted) _load();
            },
          ),
        ]),
      ],
    );
  }
}


// ============ 管理群组页（2026-09-28（晚）按用户 UI 图1「编辑群组」复刻重做） ============
//
// 版式（图1，Telegram Edit 风格）：
//   顶栏：X（放弃返回）｜编辑群组｜完成（保存全部脏字段后 pop）
//   ① 头像（右下相机徽章，点击换头像）+ 群名输入（灰底圆角，同行）
//   ② 群公告：灰底多行输入 + 0/255 计数（用户既定口径：简介区落群公告）
//   ③ 群组类型：公开群组（可搜索/扫码加入）｜私密群组（仅受邀，不可被搜索）——真实生效
//   ④ 群组号：说明文字 + @ 前缀输入（5-32 位字母/数字/下划线，完成时校验保存）
//   ⑤ 权限/成员开关（V2Set 卡片，即时保存）+ 危险区（解散群组）
//
// pop 返回值：`String 新群名`（改群名成功，聊天页标题即时跟随）/ `'disbanded'` / null。
class GroupEditPage extends StatefulWidget {
  final ConvItem conv;
  const GroupEditPage({super.key, required this.conv});

  @override
  State<GroupEditPage> createState() => _GroupEditPageState();
}

class _GroupEditPageState extends State<GroupEditPage> {
  final _svc = ConversationService();
  final _nameCtrl = TextEditingController();
  final _announceCtrl = TextEditingController();
  final _shortIdCtrl = TextEditingController();
  Map<String, dynamic> _settings = {};
  bool _loading = true;
  bool _saving = false; // 「完成」保存中
  bool _uploadingAvatar = false;
  bool _isPublic = true; // 群组类型（完成时保存）
  late String _avatar;
  String _origName = ''; // 完成时判脏用
  String _origAnnounce = '';
  String _origShortId = '';

  ConvItem get conv => widget.conv;

  @override
  void initState() {
    super.initState();
    _origName = conv.conversationName;
    _nameCtrl.text = _origName;
    _origAnnounce = conv.conversation['announcementZh']?.toString() ?? '';
    _announceCtrl.text = _origAnnounce;
    _origShortId = conv.conversation['shortId']?.toString() ?? '';
    _shortIdCtrl.text = _origShortId;
    _avatar = conv.conversation['avatar']?.toString() ?? '';
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _announceCtrl.dispose();
    _shortIdCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await _svc.groupSettings(conv.id);
      if (mounted) {
        setState(() {
          _settings = s;
          _isPublic = s['isPublic'] != false; // 缺省视为公开（历史行为）
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggle(String key, bool v) async {
    if (_saving) return;
    final t = AppLocalizations.of(context).t;
    setState(() {
      _settings = {..._settings, key: v};
      _saving = true;
    });
    try {
      switch (key) {
        case 'muteAll':
          await _svc.setGroupSettings(conv.id, muteAll: v);
        case 'privacyEnabled':
          await _svc.setGroupSettings(conv.id, privacyEnabled: v);
        case 'allowMemberInvite':
          await _svc.setGroupSettings(conv.id, allowInvite: v);
        case 'qrJoinEnabled':
          await _svc.setGroupSettings(conv.id, qrJoin: v);
        case 'showMembers':
          await _svc.setGroupSettings(conv.id, showMembers: v);
        // 2026-09-28 四项新权限（发送媒体/链接、成员置顶、查看相册）
        case 'sendMediaAllowed':
          await _svc.setGroupSettings(conv.id, sendMedia: v);
        case 'sendLinkAllowed':
          await _svc.setGroupSettings(conv.id, sendLink: v);
        case 'memberPinAllowed':
          await _svc.setGroupSettings(conv.id, memberPin: v);
        case 'albumViewAllowed':
          await _svc.setGroupSettings(conv.id, albumView: v);
        // 2026-09-28（晚）图1 新增：允许管理员添加成员
        case 'adminCanInvite':
          await _svc.setGroupSettings(conv.id, adminCanInvite: v);
        // 2026-09-29 新成员历史限制（新增 case 时漏掉导致开关保存不上）
        case 'newMemberHistoryLimited':
          await _svc.setGroupSettings(conv.id, historyLimited: v);
      }
      if (mounted) AppDialogs.toast(context, t('groupSettingsSaved'));
    } catch (_) {
      if (mounted) {
        setState(() => _settings = {..._settings, key: !v});
        AppDialogs.toast(context, t('groupSettingsSaveFailed'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 更换群头像（相册选图 → 上传 → PUT /conversation/:id）
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
    final old = _avatar;
    try {
      final up = await ApiClient.instance.uploadXFile(
          picked, picked.name.isEmpty ? 'group_avatar.jpg' : picked.name,
          dir: 'avatar/');
      if (!mounted) return;
      final url = (up['url'] ?? '').toString();
      final ok = await _svc.updateGroupInfo(conv.id, avatar: url);
      if (!mounted) return;
      if (ok) {
        setState(() => _avatar = url);
        // 2026-09-29：就地同步 conv（群资料页同一引用，头像即时刷新）
        conv.conversation['avatar'] = url;
        AppDialogs.toast(context, t('groupSettingsSaved'));
      } else {
        AppDialogs.toast(context, t('groupSettingsSaveFailed'));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _avatar = old);
        AppDialogs.toast(context, t('groupSettingsSaveFailed'));
      }
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  /// 「完成」：按序保存脏字段（群组号 → 群名 → 公告 → 群组类型），
  /// 任一步唯一性/格式失败则留在本页提示；全部成功后 pop 新群名（或 null）
  Future<void> _saveDone() async {
    if (_saving || _loading) return;
    final t = AppLocalizations.of(context).t;
    setState(() => _saving = true);
    try {
      // 1) 群组号（唯一列，冲突最可能失败 → 放最前）
      final sid = _shortIdCtrl.text.trim();
      if (sid != _origShortId) {
        if (sid.isNotEmpty && !RegExp(r'^[A-Za-z0-9_]{5,32}$').hasMatch(sid)) {
          if (mounted) {
            AppDialogs.toast(context, t('groupShortIdInvalid'));
          }
          return;
        }
        final code = await _svc.setGroupShortId(conv.id, sid);
        if (code != 0) {
          if (mounted) {
            AppDialogs.toast(context,
                code == 3008 ? t('groupShortIdTaken') : t('groupShortIdInvalid'));
          }
          return;
        }
        _origShortId = sid;
        // 2026-09-29：就地更新 conv（与群资料页同一引用），返回即见新群组号
        conv.conversation['shortId'] = sid;
      }
      // 2) 群名
      final name = _nameCtrl.text.trim();
      if (name.isNotEmpty && name != _origName) {
        final ok = await _svc.updateGroupInfo(conv.id, name: name);
        if (!ok) {
          if (mounted) AppDialogs.toast(context, t('groupSettingsSaveFailed'));
          return;
        }
        _origName = name;
      }
      // 3) 群公告（空=清除；后端 2026-09-29 起无条件全量覆盖）
      final ann = _announceCtrl.text.trim();
      if (ann != _origAnnounce) {
        final ok = await _svc.updateAnnouncement(conv.id, ann, ann);
        if (!ok) {
          if (mounted) AppDialogs.toast(context, t('groupSettingsSaveFailed'));
          return;
        }
        _origAnnounce = ann;
        // 2026-09-29 修复：就地更新 conv（与群资料页同一引用），清空后返回立即生效
        conv.conversation['announcementZh'] = ann;
        conv.conversation['announcementEn'] = ann;
      }
      // 4) 群组类型
      if ((_settings['isPublic'] ?? true) != _isPublic) {
        await _svc.setGroupSettings(conv.id, isPublic: _isPublic);
      }
      if (mounted) {
        final nameChanged = _origName != conv.conversationName;
        Navigator.of(context).pop(nameChanged ? _origName : null);
      }
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('groupSettingsSaveFailed'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 解散群组（复用现有确认文案与服务端解散接口）
  Future<void> _disband() async {
    final t = AppLocalizations.of(context).t;
    final ok = await AppDialogs.confirm(context,
        title: t('convSetDisbandGroupTitle'),
        message: t('convSetDisbandGroupMsg'),
        confirmText: t('convSetDisbandConfirm'),
        danger: true);
    if (ok != true) return;
    final done = await _svc.disband(conv.id);
    if (!mounted) return;
    if (done) {
      Navigator.of(context).pop('disbanded');
    } else {
      AppDialogs.toast(context, t('groupSettingsSaveFailed'));
    }
  }

  // ---------------------------------------------------------------- UI（图1）

  /// 灰底圆角输入填充色（浅色 #F1F2F6 / 深色跟随）
  Color get _fieldFill =>
      context.v2IsDark ? const Color(0xFF2C2C2E) : const Color(0xFFF1F2F6);

  Widget _topBar(double top, double s) {
    final t = AppLocalizations.of(context).t;
    // 2026-09-29 修复标题重合：原 Stack 放在默认 crossAxisAlignment=center 的
    // Column 里，非 flex 的 Stack 收缩到标题宽度，X/标题/完成 全叠在一起。
    // 改 Row + Expanded 布局（宽度撑满，永不重叠）；标题按图1 用「编辑群组」。
    return Container(
      color: context.setCard,
      height: top + 52 * s,
      padding: EdgeInsets.only(top: top, left: 4 * s, right: 8 * s),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.close, size: 24 * s, color: context.setTitle),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Text(t('groupEditTitle'),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 17 * s,
                    fontWeight: FontWeight.w600,
                    color: context.setTitle)),
          ),
          TextButton(
            onPressed: _saving ? null : _saveDone,
            child: Text(t('groupEditDone'),
                style: TextStyle(
                    fontSize: 16.5 * s,
                    fontWeight: FontWeight.w600,
                    color: context.setTitle)),
          ),
        ],
      ),
    );
  }

  /// ① 头像（相机徽章）+ 群名输入（图1 第一屏）
  /// 2026-09-29 样式统一：由通栏白条改为与下方一致的 V2SetCard 圆角白卡
  Widget _headSection(double s) {
    return V2SetCard(rows: [
      Padding(
        padding: EdgeInsets.all(14 * s),
        child: Row(
        children: [
          GestureDetector(
            onTap: _pickAvatar,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                _uploadingAvatar
                    ? SizedBox(
                        width: 64 * s,
                        height: 64 * s,
                        child: Center(
                            child: SizedBox(
                                width: 22 * s,
                                height: 22 * s,
                                child: const CircularProgressIndicator(
                                    strokeWidth: 2))))
                    : AppAvatar(
                        url: AppConfig.assetUrl(_avatar),
                        name: _nameCtrl.text.trim(),
                        size: 64 * s,
                        radius: 12 * s),
                Positioned(
                  right: -3 * s,
                  bottom: -3 * s,
                  child: Container(
                    width: 22 * s,
                    height: 22 * s,
                    decoration: BoxDecoration(
                      color: const Color(0xFF3C3C3E),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: context.setCard, width: 1.5 * s),
                    ),
                    child: Icon(Icons.photo_camera,
                        size: 12 * s, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 14 * s),
          Expanded(
            child: TextField(
              controller: _nameCtrl,
              maxLength: 32,
              style: TextStyle(fontSize: 16.5 * s, color: context.setTitle),
              decoration: InputDecoration(
                counterText: '',
                filled: true,
                fillColor: _fieldFill,
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 14 * s, vertical: 14 * s),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12 * s),
                    borderSide: BorderSide.none),
              ),
            ),
          ),
        ],
      ),
      ),
    ]);
  }

  /// ② 群公告（简介区落群公告，用户既定口径）：灰底多行 + 0/255 计数
  /// 2026-09-29 样式统一：灰字分区标题 + V2SetCard 圆角白卡（对齐下方卡片）
  Widget _announceSection(double s) {
    final t = AppLocalizations.of(context).t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        V2SetSectionLabel(t('convSetGroupAnnouncement')),
        const V2SetGap.afterLabel(),
        V2SetCard(rows: [
          Padding(
            padding: EdgeInsets.all(12 * s),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _announceCtrl,
                  maxLength: 255,
                  maxLines: 4,
                  onChanged: (_) => setState(() {}),
                  style: TextStyle(fontSize: 15 * s, color: context.setTitle),
                  decoration: InputDecoration(
                    counterText: '',
                    filled: true,
                    fillColor: _fieldFill,
                    isDense: true,
                    contentPadding: EdgeInsets.all(12 * s),
                    hintText: t('groupEditAnnounceHint'),
                    hintStyle: TextStyle(
                        fontSize: 15 * s, color: context.setSub),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12 * s),
                        borderSide: BorderSide.none),
                  ),
                ),
                SizedBox(height: 6 * s),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '${_announceCtrl.text.length}/255',
                    style: TextStyle(fontSize: 12.5 * s, color: context.setSub),
                  ),
                ),
              ],
            ),
          ),
        ]),
      ],
    );
  }

  /// 群组类型单选行（图1：左侧圆圈，选中实心；标题+灰底说明）
  Widget _typeRow(double s,
      {required bool isPublic,
      required String title,
      required String subtitle}) {
    final selected = _isPublic == isPublic;
    return InkWell(
      onTap: () => setState(() => _isPublic = isPublic),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16 * s, vertical: 13 * s),
        child: Row(
          children: [
            Container(
              width: 21 * s,
              height: 21 * s,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border:
                    Border.all(color: context.setSub, width: 1.6 * s),
              ),
              child: selected
                  ? Center(
                      child: Container(
                        width: 11 * s,
                        height: 11 * s,
                        decoration: const BoxDecoration(
                            shape: BoxShape.circle, color: Color(0xFF141517)),
                      ),
                    )
                  : null,
            ),
            SizedBox(width: 13 * s),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 15.5 * s,
                          fontWeight: FontWeight.w600,
                          color: context.setTitle)),
                  SizedBox(height: 3 * s),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 12.5 * s, color: context.setSub)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// ③ 群组类型（公开=可搜索/扫码加入；私密=仅受邀，不可被搜索）
  Widget _typeSection(double s) {
    final t = AppLocalizations.of(context).t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        V2SetSectionLabel(t('groupEditType')),
        const V2SetGap.afterLabel(),
        V2SetCard(rows: [
          _typeRow(s,
              isPublic: true,
              title: t('groupTypePublic'),
              subtitle: t('groupTypePublicSub')),
          _typeRow(s,
              isPublic: false,
              title: t('groupTypePrivate'),
              subtitle: t('groupTypePrivateSub')),
        ]),
      ],
    );
  }

  /// ④ 群组号：说明 + @ 前缀输入（5-32 位，完成时校验）
  /// 2026-09-29 样式统一：灰字分区标题 + V2SetCard 圆角白卡
  Widget _shortIdSection(double s) {
    final t = AppLocalizations.of(context).t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        V2SetSectionLabel(t('groupEditShortId')),
        const V2SetGap.afterLabel(),
        V2SetCard(rows: [
          Padding(
            padding: EdgeInsets.all(12 * s),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('groupShortIdDesc'),
                    style:
                        TextStyle(fontSize: 12.5 * s, color: context.setSub)),
                SizedBox(height: 10 * s),
                TextField(
                  controller: _shortIdCtrl,
                  maxLength: 32,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9_]')),
                  ],
                  style:
                      TextStyle(fontSize: 15.5 * s, color: context.setTitle),
                  decoration: InputDecoration(
                    counterText: '',
                    filled: true,
                    fillColor: _fieldFill,
                    isDense: true,
                    prefixText: '@ ',
                    prefixStyle: TextStyle(
                        fontSize: 15.5 * s,
                        fontWeight: FontWeight.w600,
                        color: context.setTitle),
                    contentPadding: EdgeInsets.symmetric(
                        horizontal: 14 * s, vertical: 13 * s),
                    hintText: t('groupEditShortId'),
                    hintStyle: TextStyle(
                        fontSize: 14.5 * s, color: context.setSub),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12 * s),
                        borderSide: BorderSide.none),
                  ),
                ),
                SizedBox(height: 6 * s),
                Text(t('groupShortIdHint'),
                    style:
                        TextStyle(fontSize: 11.5 * s, color: context.setSub)),
              ],
            ),
          ),
        ]),
      ],
    );
  }

  /// 开关行（V2SetSwitch，即时保存）
  Widget _switchRow(String titleKey, String subKey, String settingKey,
      {bool defaultOn = true}) {
    return V2SetRow(
      title: AppLocalizations.of(context).t(titleKey),
      subtitle: AppLocalizations.of(context).t(subKey),
      trailing: V2SetSwitch(
          value: _settings[settingKey] != false && (defaultOn || _settings[settingKey] == true),
          onChanged: (v) => _toggle(settingKey, v)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final t = AppLocalizations.of(context).t;
    final top = MediaQuery.paddingOf(context).top;
    if (_loading) {
      return V2SetScaffold(
        title: t('groupEditTitle'),
        children: const [Center(child: CircularProgressIndicator())],
      );
    }
    return Scaffold(
      backgroundColor: context.setPageBg,
      body: Column(
        children: [
          _topBar(top, s),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                // 2026-09-29 首卡与顶栏留白（原贴住标题）
                SizedBox(height: 12 * s),
                _headSection(s),
                SizedBox(height: 20 * s),
                _announceSection(s),
                SizedBox(height: 20 * s),
                _typeSection(s),
                SizedBox(height: 20 * s),
                _shortIdSection(s),
                SizedBox(height: 20 * s),
                // ---- 群权限卡（四项 + 允许管理员添加成员）----
                V2SetCard(rows: [
                  _switchRow('permSendMedia', 'permSendMediaSub',
                      'sendMediaAllowed'),
                  _switchRow(
                      'permSendLink', 'permSendLinkSub', 'sendLinkAllowed'),
                  _switchRow(
                      'permMemberPin', 'permMemberPinSub', 'memberPinAllowed'),
                  _switchRow(
                      'permAlbumView', 'permAlbumViewSub', 'albumViewAllowed'),
                  _switchRow('permAdminInvite', 'permAdminInviteSub',
                      'adminCanInvite'),
                ]),
                const V2SetGap.beforeLabel(),
                V2SetSectionLabel(t('groupSwitchSection')),
                const V2SetGap.afterLabel(),
                // ---- 成员权限卡（既有五项，群管理页能力并入）----
                V2SetCard(rows: [
                  _switchRow(
                      'groupSwitchQrJoin', 'groupSwitchQrJoinSub', 'qrJoinEnabled'),
                  _switchRow('groupSwitchPrivacy', 'groupSwitchPrivacySub',
                      'privacyEnabled',
                      defaultOn: false),
                  // 2026-09-29 新成员历史限制：新进群的普通成员只能查看入群后的消息
                  _switchRow('permNewMemberHistory', 'permNewMemberHistorySub',
                      'newMemberHistoryLimited',
                      defaultOn: false),
                  _switchRow(
                      'groupSwitchMuteAll', 'groupSwitchMuteAllSub', 'muteAll',
                      defaultOn: false),
                  _switchRow('groupSwitchAllowInvite', 'groupSwitchAllowInviteSub',
                      'allowMemberInvite'),
                  _switchRow('groupSwitchShowMembers', 'groupSwitchShowMembersSub',
                      'showMembers'),
                ]),
                const V2SetGap.beforeLabel(),
                V2SetSectionLabel(t('groupDangerSection')),
                const V2SetGap.afterLabel(),
                // ---- 危险区：解散群组（红字）----
                V2SetCard(rows: [
                  V2SetRow(
                    title: t('convSetDisbandGroupTitle'),
                    titleColor: context.setDanger,
                    showChevron: true,
                    onTap: _disband,
                  ),
                ]),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
