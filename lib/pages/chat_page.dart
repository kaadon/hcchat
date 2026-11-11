import 'dart:async';
import 'dart:convert';
import 'dart:io' show File; // 自定义聊天背景（Image.file；与 moments_page 等页同口径）
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'; // ScrollDirection（判断用户滚动方向）
import 'package:flutter/services.dart';
import '../services/storage_compat.dart'; // 置顶/公告关闭标记持久化（第十三批问题 4）
import 'package:file_picker/file_picker.dart';
import 'package:cached_network_image/cached_network_image.dart'; // 聊天图片磁盘缓存（2026-09-26：Image.network 冷启动全量重拉+失败不重试 → 气泡缺省/查看器黑屏）
import 'package:flutter/foundation.dart'
    show kIsWeb; // H5 分支（file_picker withData / uploadBytes）
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_thumbnail/video_thumbnail.dart'; // 视频消息封面抽帧（2026-09-17）
import 'package:wechat_assets_picker/wechat_assets_picker.dart'; // 聊天相册：微信式应用内相册（2026-09-17）

import '../l10n/app_locale.dart';
import '../config/app_config.dart';
import '../services/api_client.dart';
import '../services/call_service.dart';
import '../services/conversation_service.dart';
import '../services/feature_flags.dart';
import '../services/friend_service.dart'; // 单聊对方客服勾：/user/:id 取 role
import '../services/local_store.dart';
import '../services/msg_height_cache.dart';
import '../services/user_cache.dart';
import '../services/moment_service.dart';
import '../services/wallet_store.dart';
import '../widgets/read_detail_sheet.dart'; // L1 群已读详情面板
import '../services/ws_service.dart';
import '../services/voice_recorder_service.dart'; // 语音录制（type=4 语音消息，2026-09-17）
import '../services/voice_player_service.dart'; // 语音播放（全局状态供气泡订阅）
import '../services/e2ee_service.dart'; // E2EE 端到端加密（type=13，2026-09-18 §36）
import 'location_picker_page.dart'; // 位置消息选点页（type=14，2026-09-21 需求1）
import 'package:permission_handler/permission_handler.dart'; // 进入语音模式提前申请麦克风权限
import '../utils/call_permissions.dart'; // 通话权限申请（拨打前申请摄像头/麦克风，2026-09-19）
import 'package:cross_file/cross_file.dart'; // XFile（语音本地文件上传）
import '../constants/message_type.dart';
import '../services/group_file_service.dart';
import '../services/settings_service.dart';
import '../services/sound_service.dart';
import '../services/translate_service.dart';
import '../theme/app_theme.dart';
import '../utils/breakpoints.dart';
import '../widgets/app_avatar.dart';
import '../widgets/transitions.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/e2ee_unlock_sheet.dart'; // E2EE 解锁弹窗（§36）
import '../widgets/app_net_image.dart';
import '../widgets/link_card.dart';
import '../widgets/v2_tags.dart'; // CertBadge（客服认证勾公共判定）
import '../widgets/v2_seal_badge.dart'; // V2SealBadge（客服蓝盾勾，四入口统一）
import 'chat_settings_page.dart'; // kChatBgPresets / kChatBubblePresets（聊天设置 → 聊天窗口生效）
import 'group_manage_page.dart'; // 2026-09-28 群资料页（标题点击进入）
import 'group_members_page.dart'; // 群⋯菜单「邀请成员」直达选人
import 'group/group_media_page.dart'; // 2026-09-29 群媒体页（菜单「查看媒体」，按消息扫描）
import 'favorites_page.dart'; // 2026-09-28 菜单「收藏」
import 'search_page.dart'; // 2026-09-28 菜单「搜索」
import 'channel_profile_page.dart';
import 'friend_detail_page.dart';
import 'file/file_preview_page.dart';
import 'forward_picker_page.dart';
import 'group_call_page.dart';
import 'group_join_confirm_page.dart'; // 群/频道名片：preview 二次确认页
import 'merge_forward_detail_page.dart';
import 'group_member_picker_page.dart';
import 'image_viewer_page.dart';
import 'pay_pwd_setup_page.dart';
import 'red_packet_detail_page.dart';
import 'red_packet_page.dart';
import 'transfer_page.dart';
import 'user_qr_profile_page.dart';
import 'video_call_page.dart';
import 'voice_call_page.dart';
import '../widgets/pay_pwd_input_sheet.dart';

/// 消息本地状态
enum MsgStatus { sending, sent, read, failed }

/// 取异常里的**后端原始提示**（去掉 Dart 的 "Exception: " 前缀），失败时兜底用 fallback。
/// 资金类操作（领红包 / 收转账）必须把真实原因告诉用户，不能笼统说"失败了"。
String _errMsg(Object e, String fallback) {
  var s = e.toString().trim();
  if (s.startsWith('Exception:')) s = s.substring('Exception:'.length).trim();
  if (s.startsWith('DioException')) s = fallback; // 网络层错误换成用户能看懂的文案
  return s.isEmpty ? fallback : s;
}

/// 名片 kind 归一化（2026-09-15 十四批）：字符串 user/group/channel 或数字
/// 1/2/3（与 conversation.type 对齐）都认；认不出按 user（兼容旧个人名片，
/// 旧消息 content={"userId","nickname","avatar"} 无 kind 字段）。
String _cardKindOf(Map<String, dynamic> d) {
  final raw = (d['kind'] ?? d['cardType'] ?? d['type'] ?? '')
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

/// 群/频道名片 → 先看资料再加入/订阅（2026-09-15 十四批；契约已由 be-channel
/// 定稿写入 API.md「名片契约」节）：
/// - 群：GET /conversation/:id/preview（任何登录用户可调）→ GroupJoinConfirmPage
///   二次确认 → joinGroup（POST /conversation/:id/join，幂等：已是成员按跳过）；
/// - 频道：GET /channel/:id（公开频道任何人可见，私密非成员 4001）→ 确认页
///   文案换「订阅频道 / N 人订阅」→ followChannel（POST /channel/:id/follow，
///   仅公开频道，不走 /join；已关注幂等）。
/// 两条链路都不在气泡上直接加，确认后 pushReplacement 进会话。
Future<void> _openGroupLikeCard(BuildContext context, String convId,
    {bool isChannelCard = false}) async {
  final t = AppLocalizations.instance.t;
  final svc = ConversationService();
  try {
    // 频道资料结构 {conversation, followerCount,...} 摆成确认页要的
    // {conversation, memberCount} 形状（页面只读这两个键）
    final raw = isChannelCard
        ? await svc.channelDetail(convId)
        : await svc.groupPreview(convId);
    final data = isChannelCard
        ? <String, dynamic>{
            'conversation': raw['conversation'],
            'memberCount': raw['followerCount'],
          }
        : raw;
    final n = (raw['followerCount'] as num?)?.toInt() ??
        (raw['memberCount'] as num?)?.toInt() ??
        0;
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => GroupJoinConfirmPage(
            data: data,
            // 频道文案：订阅频道 / N 人订阅（存量词条，无新增 key）
            title: isChannelCard ? t('searchSubscribeChannelBtn') : null,
            confirmText: isChannelCard ? t('searchSubscribeChannelBtn') : null,
            countText:
                isChannelCard ? t('chatSubSubscribers', {'count': '$n'}) : null,
            onConfirm: () async {
              try {
                final conv = isChannelCard
                    ? await svc.followChannel(convId)
                    // 2026-09-28 需求2：搜索群号进群 → 系统消息「通过搜索群号入群」
                    : await svc.joinGroup(convId, via: 'search');
                final name = conv['nameZh']?.toString() ??
                    conv['nameEn']?.toString() ??
                    '';
                final item = ConvItem.fromJson(
                    {'conversation': conv, 'conversationName': name});
                if (!context.mounted) return;
                await Navigator.of(context).pushReplacement(MaterialPageRoute(
                    builder: (_) =>
                        ChatPage(conv: item, myId: UserCache.myId ?? '')));
              } catch (e) {
                if (context.mounted) {
                  AppDialogs.toast(
                      context,
                      t('groupQrJoinFailed',
                          {'error': _errMsg(e, t('bootLoadFailed'))}));
                }
                rethrow; // 留在确认页可重试（GroupJoinConfirmPage 约定）
              }
            })));
  } catch (e) {
    if (context.mounted) {
      AppDialogs.toast(context,
          t('groupQrJoinFailed', {'error': _errMsg(e, t('bootLoadFailed'))}));
    }
  }
}

/// 名片消息（type=10）点击分发（2026-09-15 十四批）：
/// - user（含无 kind 的旧消息）→ 二维码资料页（原路径）；
/// - group/channel → 目标会话 id 取 groupId/channelId/targetId/convId/id
///   任一 → [_openGroupLikeCard]（preview 确认页 → 加入/订阅 → 进会话）；
///   kind 是群/频道但缺目标 id 时回落 user 路径（拿到啥显示啥，不崩）。
/// 具体字段名以 be-channel 更新后的 API.md 为准，不一致只改本函数解析。
void _openCardProfile(BuildContext context, String content) {
  Map<String, dynamic> d = {};
  try {
    final j = jsonDecode(content);
    if (j is Map) d = j.cast<String, dynamic>();
  } catch (_) {}
  final kind = _cardKindOf(d);
  final targetId = (d['groupId'] ??
          d['channelId'] ??
          d['targetId'] ??
          d['convId'] ??
          d['id'] ??
          '')
      .toString();
  if (kind != 'user' && targetId.isNotEmpty) {
    _openGroupLikeCard(context, targetId, isChannelCard: kind == 'channel');
    return;
  }
  final uid = (d['userId'] ?? '').toString(); // 雪花 ID 字符串
  if (uid.isEmpty) return;
  Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => UserQrProfilePage(uid: uid, source: 3)));
}

class ChatMsg {
  String? msgId; // 非 final：本地发送成功后由响应回填
  final String clientMsgId;
  final String senderId;
  final int type; // 1 文本 / 2 图片 / 3 文件 / 8 红包 / 9 转账
  String content;
  bool recalled;
  // 2026-09-28 编辑标记（与 PC 对齐）：发送者改过自己的文本消息后为 true，
  // 气泡内时间前显示「已编辑」小字。非 final：message.edit 事件原地置位。
  bool edited;
  String? replyTo;
  // 引用快照（后端发送时冗余存 ReplySnapshot：content/senderName/senderId/type）
  final String? replySender;
  final String? replyContent;
  final int? replyType;
  int? seq;
  String? createdAt;
  String? deliveryState; // sent / read（单聊对方已读标记）
  /// 文件消息（type=3）元数据：{object, name, size, mimeType, url, fileId?}。
  /// fileId 由后端写入 conv_files 后回写，是应用内预览的入口（老消息没有）。
  /// 非 final：微信式上传进度（2026-09-17）需要在上传完成后回填完整元数据。
  Map<String, dynamic>? file;
  MsgStatus status;

  /// 上传进度（0.0-1.0，仅 status==sending 的本地占位气泡有意义；默认 1=无进度）。
  /// 微信式：图片/文件气泡在上传期间叠进度遮罩（_MsgRow._wrapUploadProgress）。
  double uploadProgress;

  ChatMsg({
    this.msgId,
    required this.clientMsgId,
    required this.senderId,
    required this.type,
    required this.content,
    this.recalled = false,
    this.edited = false,
    this.replyTo,
    this.replySender,
    this.replyContent,
    this.replyType,
    this.seq,
    this.createdAt,
    this.deliveryState,
    this.file,
    this.status = MsgStatus.sent,
    this.uploadProgress = 1.0,
  });

  factory ChatMsg.fromServer(Map<String, dynamic> m) {
    // 引用快照：后端 Message.replySnapshot = {content, senderName, senderId, type}
    Map<String, dynamic> snap = {};
    try {
      final s = m['replySnapshot'];
      if (s is Map) snap = s.cast<String, dynamic>();
    } catch (_) {}
    // 文件元数据（type=3）：后端原样回传，含回写的 fileId
    Map<String, dynamic>? fileMeta;
    try {
      final f = m['file'];
      if (f is Map) fileMeta = f.cast<String, dynamic>();
    } catch (_) {}
    return ChatMsg(
      msgId: m['msgId']?.toString(),
      clientMsgId: m['clientMsgId']?.toString() ?? '',
      senderId: m['senderId']?.toString() ?? '',
      type: (m['type'] as num?)?.toInt() ?? 1,
      content: m['content']?.toString() ?? '',
      recalled: m['recalled'] == true,
      edited: m['edited'] == true,
      replyTo: m['replyTo']?.toString(),
      replySender: snap['senderName']?.toString() ?? '',
      replyContent: snap['content']?.toString() ?? '',
      replyType: (snap['type'] as num?)?.toInt(),
      seq: (m['seq'] as num?)?.toInt(),
      createdAt: m['createdAt']?.toString(),
      deliveryState: m['deliveryState']?.toString(),
      file: fileMeta,
    );
  }

  /// 是否为有效引用（后端 replyTo 为 0/空时不算引用）
  bool get hasReply {
    final r = replyTo;
    return r != null && r.isNotEmpty && r != '0';
  }

  /// 引用卡片文案：快照有内容时显示「发送者：内容」；
  /// 被引用的是媒体/资金/通话类消息时显示类型标签，避免透出 URL/JSON
  String replyPreview(String Function(String) t) {
    final typeMap = {
      2: 'svcImage',
      3: 'svcFile',
      4: 'svcVoice',
      5: 'svcVideo',
      7: 'svcCall', // 音视频通话信令
      8: 'svcRedPacket',
      9: 'svcTransfer',
      10: 'svcCard',
      14: 'svcLocation'
    };
    String body = replyContent ?? '';
    if (replyType != null && typeMap.containsKey(replyType)) {
      body = t(typeMap[replyType]!);
    }
    body = body.replaceAll('\n', ' ').trim();
    final sender = replySender ?? '';
    if (sender.isNotEmpty && body.isNotEmpty) return '$sender：$body';
    if (body.isNotEmpty) return body;
    return t('chatQuotedMsg');
  }
}

/// 聊天页（对齐 Aura Messaging 设计稿图 4/5/6/7）
/// 顶栏 + 置顶条 + 消息列表 + 浮动↓按钮 + 输入栏 + 4×2 抽屉 + 长按全屏遮罩
class ChatPage extends StatefulWidget {
  final ConvItem conv;
  final String myId;
  final String? scrollToMsgId; // 群置顶消息点击跳转：滚动到该消息
  /// 宽屏双栏嵌入模式：顶栏隐藏返回键（返回键清右栏，由外层 PopScope 处理），
  /// 不走路由栈（由 WideChatPane 持有）。手机态 push 整页时保持 false，一切照旧。
  final bool embedded;

  /// 第十三批问题 2：调用方 push 前预热的本地缓存消息（最近一页原始 JSON）。
  /// initState 里同步填充 → 首个 build 即完整消息列表，与转场渐入同帧淡入；
  /// 不传（旧入口）则维持原异步缓存直出路径。
  final List<Map<String, dynamic>>? initialMessages;
  const ChatPage(
      {super.key,
      required this.conv,
      required this.myId,
      this.scrollToMsgId,
      this.embedded = false,
      this.initialMessages});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _svc = ConversationService();
  final _api = ApiClient.instance;
  final _friendSvc = FriendService();
  final _input = TextEditingController();

  // ===== 多图组合发送（type=2，content = url1|url2|...）=====
  // 选图 → 输入栏上方预览条（可删）→ 点发送逐张上传 → join('|') 发一条消息。
  // 渲染端 _ImageGridBubble / _parseImages 本就按 | 拆多 URL，无需新消息类型。
  // （2026-09-16：多图「选完直发」，原 _pendingImages/_pendingBytes 预览缓冲
  //   及上传进度字段已随预览条一起删除，见 _pickImage / _sendImages）

  /// 消息列表（正序：_msgs[0] 最旧，_msgs.last 最新）
  // late final：首帧落底方案——initState 里用 initialScrollOffset 创建控制器，
  // 让 ListView 第一帧就落在列表末端（超估会被首帧钳到 maxScrollExtent），
  // 消除「首帧画顶部 → 下一帧 jumpTo 底部」的可见跳动。
  late final ScrollController _scroll;

  /// 是否应保持贴底（用户意图位）。
  ///
  /// true = 跟随到底部：收到新消息 / 图片异步加载导致高度变化都会自动贴底；
  /// 用户上滑离开底部 → 由 _onScrollNotification 切回 false，停止自动贴底，
  /// 直到用户滑回底部或点"↓回到最新"。
  /// 进会话时由 _startStick() 置 true。
  bool _stickActive = false;

  // ===== 首屏裁剪（2026-09-20 进会话卡顿/跳动优化，用户规范「只看最近一屏，
  // 上面的慢慢加载」）：缓存直出/预热首屏只渲染最近 20 条，被裁掉的更早消息
  // 存 _pendingOlder，上翻到顶时由 _loadOlder 分批 prepend——进场布局量骤减
  // （贴底收敛一两帧完成、不再肉眼跳动），滚动到顶才逐步挂载历史。
  static const int _firstScreenCount = 20;
  List<ChatMsg> _pendingOlder = [];

  // 实测高度内存备忘（msgId → 行高）：渲染时测量写入，Hive 持久化跨会话复用
  final Map<String, double> _heightMemo = {};

  /// 用户是否正在拖拽 / 惯性滚动（拖拽期间暂停自动贴底，避免打断手势）
  bool _dragging = false;

  /// jumpTo 是否已排入本帧（收敛期会连续触发多次，同帧只安排一次）
  bool _jumpScheduled = false;

  List<ChatMsg> _msgs = [];
  // 窄屏聊天页复用全局 WS：在 GlobalWs 上注册的监听器取消句柄。
  // 不再每页自建一条长连接（审查 #8），dispose 时统一注销这些句柄即可，
  // 全局连接本身由 HomeShell 建立并保活，不会被聊天页关闭。
  final List<VoidCallback> _wsOffs = [];

  // ===== 补拉断点（_lastSeq）=====
  // 【修 R-05】以前 `_lastSeq` 声明即 0、_loadHistory 从不初始化、也从不落盘，
  // 于是每次进会话后的首次重连都从 seq=0 拉 —— 拉到的是**最早**的一批
  // （还会被插进列表头部造成「内容上翻」），最近的消息反而拉不到。
  // 现在：进页时用「本地持久化值 ∪ 本页历史最大 seq ∪ 服务端水位」三者取最大初始化。
  int _lastSeq = 0;
  bool _pullingGap = false; // 补拉进行中（并发保护：重连风暴时不要叠加多轮）
  Timer? _gapDebounce; // 空洞检测去抖（连续跳号只补一次）

  // ===== 发送看门狗（修 R-14/R-16 的兜底）=====
  // 任何异常路径下，乐观气泡必须在 15s 内终结（sending → sent/failed），
  // 杜绝「永久转圈」。key = clientMsgId。
  static const Duration _sendWatchdog = Duration(seconds: 15);
  final Map<String, Timer> _watchdogs = {};

  bool _loading = true;
  bool _loadFailed = false; // 历史加载最终失败（显示"重新加载"，不再无声空白）
  bool _showJumpBtn = false; // 是否显示"↓回到最新"按钮（已离开底部时）
  bool _loadingOlder = false; // 正在加载更早的历史
  String? _lastReportedReadId; // 已读上报去重：同一水位不重复打 /message/read
  // 2026-09-16 修「进聊天页哪怕一条消息也往上移一下」：初值曾为 true，
  // 直出首帧顶部先渲染 ~32px「加载更早」占位，首拉回来发现不足 80 条
  // （_hasMoreOlder=false）占位整个消失 → 正序列表内容整体上移一截。
  // 改初值 false：直出帧无占位；首拉确认 ≥80 条才显示 loader——此时视口
  // 已贴底，顶部几十像素的变化在视口外，无感。不足一屏的会话恒无占位。
  bool _hasMoreOlder = false;

  /// 当前登录用户 ID（权威来源：UserCache，避免入口页误传对方 ID 导致左右对齐反了）
  String get _myUid {
    final cached = UserCache.myId;
    return (cached != null && cached.isNotEmpty) ? cached : widget.myId;
  }

  // 群功能
  List<Map<String, dynamic>> _members = [];
  int _memberCount = 0; // 群成员人数（标题显示：群名字(9)）

  /// 单聊对方账号角色（PublicUser.role，3=客服 → 顶栏亮认证勾）。
  /// 优先会话快照携带的 peerRole（contacts 入口注入）；没有时拉
  /// GET /user/:id 兜底（UserCache 进程内缓存）。null = 未拿到，不显示。
  dynamic _peerRole;

  // ===== 第十批：置顶卡 + 群公告卡 + 顶栏成员/在线数 =====

  /// 全量置顶列表（GET /conversation/:id/pins：msgId/content/senderName/type）；
  /// 空 = 服务端无置顶（或老服务端，回落会话携带的单条 pinnedMsgContent）。
  List<Map<String, dynamic>> _pinnedMsgs = [];

  /// 当前展示的置顶段（点击卡片循环 +1，竖条对应段高亮）
  int _pinnedIndex = 0;

  /// 「×」关闭置顶卡展示（不删服务端置顶，仅本地隐藏）。
  /// 第十三批问题 4：关闭标记按会话 id 持久化（pinHidden:{convId}），
  /// 重进会话也不再显示（原先只在本次会话内记忆，重进即恢复）。
  bool _pinnedHidden = false;

  /// 「×」关闭群公告卡：与置顶同机制（announceHidden:{convId}，持久化本地隐藏）
  bool _announceHidden = false;

  /// 关闭标记是否已从本地读回：置顶/公告卡的显示条件挂上它，
  /// 避免「已关闭的会话重进时卡片先闪一帧、读回后被隐藏」的跳变
  bool _hiddenFlagsLoaded = false;

  /// 置顶/公告关闭标记（FlutterSecureStorage，与 AppSettings 同款读写方式）
  static const _hiddenFlagsStore = CompatStorage();

  /// 读回本会话的关闭标记（initState 触发；读失败按未关闭处理）
  Future<void> _restoreHiddenFlags() async {
    final id = widget.conv.id;
    if (id.isEmpty) {
      if (mounted) setState(() => _hiddenFlagsLoaded = true);
      return;
    }
    // 2026-09-20 进群卡顿优化：只写字段不 setState——置顶/公告/关闭标记
    // 三项异步各自 setState 曾造成进场 200ms 内整页重建 3~4 次（本页 build
    // 很重，叠加转场动画=卡）。统一由 initState 里的 350ms 合并刷新呈现。
    try {
      final pin = await _hiddenFlagsStore.read(key: 'pinHidden:$id');
      final ann = await _hiddenFlagsStore.read(key: 'announceHidden:$id');
      if (pin == '1') _pinnedHidden = true;
      if (ann == '1') _announceHidden = true;
      _hiddenFlagsLoaded = true;
    } catch (_) {
      _hiddenFlagsLoaded = true;
    }
  }

  /// 写关闭标记（× 点下时；写失败静默——下次重进最多再显示一次卡片）
  void _persistHiddenFlag(String prefix) {
    final id = widget.conv.id;
    if (id.isEmpty) return;
    _hiddenFlagsStore.write(key: '$prefix:$id', value: '1').catchError((_) {});
  }

  /// 群在线人数（members 端点响应顶层 onlineCount，be-channel 第十批新增，
  /// 随 _loadMembers 的既有请求返回，见 API.md）
  bool _onlineLoaded = false;
  int _onlineCount = 0;
  final Set<String> _mentionIds = {};
  ChatMsg? _quoteMsg;
  // 零钱：已领取的红包/转账 msgId（本地状态）
  final Set<String> _claimedMoneyIds = {};

  // ===== AI 翻译（「译」按钮 + 译文条）=====
  // 译文缓存：clientMsgId -> 译文（会话内内存缓存，服务端另有全局缓存）
  final Map<String, String> _translations = {};
  // 正在翻译的 clientMsgId（按钮转圈）
  final Set<String> _translating = {};
  // 自动翻译已处理过的 clientMsgId（避免重复触发扣额度）
  final Set<String> _autoTried = {};
  final _translateSvc = TranslateService();
  // 翻译功能是否开启（服务端已配置 AI apiKey）：false 时不显示「译」按钮、不做自动翻译
  bool _translateEnabled = false;

  // ===== 合并转发：多选模式 =====
  bool _selectionMode = false;
  final Set<String> _selectedClientMsgIds = {};

  // ===== 输入栏「+」功能面板 / 表情面板：悬浮卡片开关 =====
  // 悬浮在消息列表上方（右下角），不再在输入栏下方挤压展开；两者互斥
  bool _plusOpen = false;
  bool _emojiOpen = false;

  // 全员禁言 / 我的角色（禁言时输入框置灰提示；群主/管理员不受限）
  bool _muteAll = false;
  int _myRole = 3;
  // 2026-09-28 管理群组页改群名后即时跟随显示（widget.conv 是 final 不可改）
  String? _overrideName;
  // 群成员隐私：仅当服务端以 4006 明确拦我（即我是普通成员）时置 true，
  // 群主/管理员能正常拉到成员列表，_privacyOn 恒为 false，因此永不被限制。
  bool _privacyOn = false;
  // 需求5（2026-09-22）：群级开关「显示群成员人数/在线人数」（groupSettings.
  // showMembers，仅群主可切换）。关闭 → 标题下方不渲染「N 成员, M 在线」副标题
  // （聊天信息页成员卡片同步隐藏，见 conv_settings_page）
  // 需求3（2026-09-22 三批）：**默认 false**——进聊天页先不渲染，等群设置
  // 拉回来说「允许显示」再出现，修掉「一闪而过群成员数量」
  bool _showMembers = false;
  // 需求3（2026-09-22 二批）：群隐私（privacyEnabled）开启 → 群名称下方
  // 「N 成员, M 在线」整行不显示（用户明确要求不分角色都隐藏；与 _privacyOn
  // 不同：那个只对普通成员置位，用于禁点成员头像）
  bool _privacyCountOn = false;

  // 长按全屏遮罩状态
  ChatMsg? _longPressedMsg;

  /// 长按消息行的原位截图（炸开浮层里清晰还原消息内容用）。
  /// 在 setState 置高亮【之前】截图，避免截到列表行的蓝色高亮样式；
  /// 截图失败（返回 null）时浮层回落为半透明高亮框。
  ui.Image? _longPressShot;

  /// 消息行 GlobalKey（keyed by clientMsgId）：长按浮层用 RenderBox
  /// 把行矩形取出来，在遮罩上原位画高亮框 + 菜单气泡贴行定位
  final Map<String, GlobalKey> _rowKeys = {};

  /// 当前长按消息行的屏幕矩形（_showLongPressOverlay 时取一次）
  Rect? _longPressRect;

  GlobalKey _rowKeyFor(String clientMsgId) =>
      _rowKeys.putIfAbsent(clientMsgId, () => GlobalKey());

  /// 消息行的全局坐标矩形（行已滚出屏/未挂载时返回 null）
  Rect? _rowRect(String clientMsgId) {
    final ctx = _rowKeys[clientMsgId]?.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  // 头像：我方（profile 拉取）/ 群成员（按 senderId 查 _members）；单聊对方用 conv.avatarUrl
  String _myAvatar = '';

  bool get isGroup => (widget.conv.conversation['type'] as num?)?.toInt() == 2;

  /// 频道会话（type=3，chat_list_page.dart:689 同口径）：顶栏副标题只显示
  /// 「{memberCount} 人订阅」（成员数=订阅数），不显示在线数/在线状态。
  bool get isChannel =>
      (widget.conv.conversation['type'] as num?)?.toInt() == 3;

  /// 群成员人数（标题用）：优先服务端实时值，回落会话列表带的值
  int get _groupMemberCount =>
      _memberCount > 0 ? _memberCount : widget.conv.memberCount;

  /// 群聊按 senderId 查成员头像（单聊不走这里）
  String _memberAvatar(String senderId) {
    for (final m in _members) {
      final uid = m['userId']?.toString() ?? m['id']?.toString() ?? '';
      if (uid == senderId) return m['avatar']?.toString() ?? '';
    }
    return '';
  }

  String _t(String key, [Map<String, String>? params]) =>
      AppLocalizations.of(context).t(key, params);

  /// 群事件系统消息（type=6）→ 本语言文案。
  /// content 为服务端 JSON：{kind, actor, target, minutes}
  String _groupSystemText(ChatMsg m) {
    Map<String, dynamic> d = {};
    try {
      final j = jsonDecode(m.content);
      if (j is Map) d = j.cast<String, dynamic>();
    } catch (_) {}
    final kind = (d['kind'] ?? '').toString();
    final actor = (d['actor'] ?? '').toString();
    final target = (d['target'] ?? '').toString();
    final minutes = ((d['minutes'] as num?)?.toInt() ?? 0).toString();
    switch (kind) {
      case 'invite':
        return _t('groupSysInvite', {'actor': actor, 'target': target});
      case 'join':
        // 2026-09-28 需求2：按 via 区分入群方式（qrcode=扫码 / search=搜索群号）
        final via = (d['via'] ?? '').toString();
        if (via == 'search') {
          return _t('groupSysJoinSearch', {'target': target});
        }
        if (via == 'qrcode') {
          return _t('groupSysJoinQr', {'target': target});
        }
        return _t('groupSysJoin', {'target': target}); // 无 via 兜底（老消息）
      case 'quit':
        return _t('groupSysQuit', {'target': target});
      case 'kick':
        return _t('groupSysKick', {'actor': actor, 'target': target});
      case 'mute':
        // 2026-09-28（晚）：minutes=-1 为永久禁言
        if (minutes == '-1') {
          return _t('groupSysMuteForever', {'actor': actor, 'target': target});
        }
        return _t(
            'groupSysMute', {'actor': actor, 'target': target, 'm': minutes});
      case 'unmute':
        return _t('groupSysUnmute', {'actor': actor, 'target': target});
      case 'muteAllOn':
        return _t('groupSysMuteAllOn', {'actor': actor});
      case 'muteAllOff':
        return _t('groupSysMuteAllOff', {'actor': actor});
      case 'transfer':
        // 2026-09-28（晚）：转让群主
        return _t('groupSysTransfer', {'actor': actor, 'target': target});
      default:
        return m.content; // 未知系统消息原样显示
    }
  }

  /// 输入栏禁言提示（非 null 时输入框整条置灰）：
  /// 全员禁言仅普通成员受限；个人禁言按 speakMutedUntil 判断
  String? get _muteBanner {
    if (!isGroup) return null;
    if (_muteAll && _myRole != 1 && _myRole != 2) {
      return _t('chatMutedAllBanner');
    }
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (final m in _members) {
      final uid = m['userId']?.toString() ?? m['id']?.toString() ?? '';
      if (uid == _myUid) {
        final until = (m['speakMutedUntil'] as num?)?.toInt() ?? 0;
        if (until > nowSec) return _t('chatMutedBanner');
        break;
      }
    }
    return null;
  }

  /// 第十三批问题 5：频道（type=3）普通成员不可发言 → 底部输入栏整块替换为
  /// 「你已被禁言」提示条。频道主优先用会话快照 ownerId 同步判定（首帧即准，
  /// 不会先闪一帧提示条）；members 的 role（1=频道主）作兜底。群/单聊不走此逻辑。
  bool get _channelInputBlocked {
    if (!isChannel) return false;
    if ((widget.conv.conversation['ownerId']?.toString() ?? '') == _myUid) {
      return false; // 频道主
    }
    return _myRole != 1;
  }

  /// 群聊：按 senderId 查成员昵称（小助手固定名；查不到回落短 ID）
  String _senderName(String senderId) {
    if (senderId == '-1') return '小助手';
    for (final m in _members) {
      final uid = m['userId']?.toString() ?? m['id']?.toString() ?? '';
      if (uid == senderId) {
        final n = m['nickname']?.toString() ?? m['remark']?.toString() ?? '';
        if (n.isNotEmpty) return n;
      }
    }
    return senderId.length > 6
        ? '...${senderId.substring(senderId.length - 4)}'
        : senderId;
  }

  /// 被引用消息类型 → 本地化标签 key。
  ///
  /// 与 [ChatMsg.replyPreview] 里的映射保持一致（图片/文件/语音/视频/通话/红包/转账/名片），
  /// 另补 11 链接卡片 / 12 合并转发两类的标签 —— 它们的 content 是 JSON，若不映射会在
  /// 本地兜底时把 JSON 原文透出到引用条，故必须一并拦住（防泄漏意图同 replyPreview）。
  static const Map<int, String> _replyTypeLabels = {
    2: 'svcImage',
    3: 'svcFile',
    4: 'svcVoice',
    5: 'svcVideo',
    7: 'svcCall',
    8: 'svcRedPacket',
    9: 'svcTransfer',
    10: 'svcCard',
    11: 'svcLink',
    12: 'svcMerge',
    14: 'svcLocation',
  };

  /// 引用预览里的发送者昵称：自己用本机昵称，群成员按成员表昵称，单聊对方用会话名。
  /// 查不到时返回空串（由调用方回落为「只有内容」的预览）。
  String _senderNameForPreview(ChatMsg m) {
    final sid = m.senderId.trim();
    if (sid.isEmpty) return '';
    if (sid == _myUid.trim()) {
      return UserCache.myProfileData?['nickname']?.toString() ?? '';
    }
    if (isGroup) return _senderName(sid);
    return widget.conv.conversationName;
  }

  /// 由一条本地消息生成「引用预览」文案（发送者：内容 / 类型标签）。
  ///
  /// 复用与 [ChatMsg.replyPreview] 相同的类型标签映射：媒体/资金/通话/名片/链接/合并转发
  /// 只显示标签，绝不透出 URL 或 JSON 原文。这是「异步回填快照」缺失时的本地兜底来源。
  String _previewOfMsg(ChatMsg m) {
    var body = m.content;
    final labelKey = _replyTypeLabels[m.type];
    if (labelKey != null) body = _t(labelKey);
    body = body.replaceAll('\n', ' ').trim();
    final sender = _senderNameForPreview(m);
    if (sender.isNotEmpty && body.isNotEmpty) return '$sender：$body';
    if (body.isNotEmpty) return body;
    return _t('chatQuotedMsg');
  }

  /// 某条「引用消息」的引用条文案（发送方 / 接收方统一出口，见 _MsgRow.replyPreviewFor）。
  ///
  ///  ① 服务端快照存在 → 用快照（跨设备 / 本地没有被引用消息时的权威兜底）；
  ///  ② 快照尚未回填（改异步后的过渡态）但本地已有被引用消息 → 本地即时兜底，不等快照；
  ///  ③ 快照、本地都没有 → 通用文案 t('chatQuotedMsg')。
  String _replyPreviewFor(ChatMsg m) {
    // 快照「存在」的判据：content 非空，或带类型（媒体类快照 content 也可能非空，
    // 这里两者取或，避免把「有类型但 content 为空」的快照误判为缺失）。
    final hasSnap =
        (m.replyContent ?? '').trim().isNotEmpty || m.replyType != null;
    if (hasSnap) return m.replyPreview(_t);
    final replyTo = m.replyTo;
    if (replyTo != null && replyTo.isNotEmpty && replyTo != '0') {
      for (final x in _msgs) {
        if (x.msgId != null && x.msgId == replyTo) return _previewOfMsg(x);
      }
    }
    return m.replyPreview(_t);
  }

  @override
  void initState() {
    super.initState();
    // 实测高度内存层兜底预热：会话列表路径已在 push 前 await 过（幂等），
    // 这里覆盖通知栏/搜索/二维码等非列表入口（晚于首帧，但后续 build 受益）
    unawaited(MsgHeightCache.ensureLoaded());
    // ===== 第十三批问题 2：首帧同步直出（修「进聊天窗口白色气泡中途弹入」） =====
    // 根因：背景上一批已预热首帧即在，但消息列表内容要走 Hive LazyBox 异步
    // 回填（hydrateFromDisk → await box.get），1~N 帧后才 setState 弹入 ——
    // 转场渐入进行到一半时白色图片占位卡/通话记录气泡突然浮现 = 闪现。
    // 修复：列表页点行时先预热缓存并经 initialMessages 传入，这里在首个
    // build 之前同步填充，内容与页面其余部分同帧淡入，全程无弹入。
    final pre = widget.initialMessages;
    if (pre != null && pre.isNotEmpty && _msgs.isEmpty) {
      final list = pre.map(ChatMsg.fromServer).toList();
      if (list.length > _firstScreenCount) {
        _pendingOlder = list.sublist(0, list.length - _firstScreenCount);
        _msgs = list.sublist(list.length - _firstScreenCount);
      } else {
        _msgs = list;
      }
      _loading = false;
    }
    // 首帧落底：先同步预热持久化实测高度进 memo（内存层已加载，零 IO），
    // _initialScrollOffset 才能用到真实高度——否则纯估算在图片/引用多的群
    // 会低估，首帧落在真实底部上方（先见左侧旧消息再弹回 = 残余跳）。
    if (_msgs.isNotEmpty) _primeHeights();
    // 控制器带 initialScrollOffset 创建（必须在 _startStick 之前，
    // _jumpToLatest 会触碰 _scroll）。超估偏移会被首帧钳到 maxScrollExtent，
    // 第一帧画面即在最新消息。
    _scroll = ScrollController(initialScrollOffset: _initialScrollOffset());
    if (_msgs.isNotEmpty) {
      _startStick(); // _jumpToLatest 走 post-frame，initState 里调用安全
    }
    _init();
    _restoreHiddenFlags(); // 第十三批问题 4：置顶/公告关闭标记持久化读回（只写字段）
    // 2026-09-20 进群卡顿优化：置顶卡/公告卡/关闭标记三项的异步加载只写字段，
    // 由这里转场结束后一次性 setState 统一呈现——此前进场 200ms 内整页重建
    // 3~4 次（叠加转场动画=卡），卡片还分两波蹦出（观感=跳）。
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted) setState(() {});
    });
    unawaited(_loadE2eeBanner()); // E2EE（2026-09-18）：单聊顶部加密提示
    _scroll.addListener(_onScroll);
    // 聊天设置（背景 / 气泡颜色 / 字号）改动时刷新本页：设置页在本页之上 push，
    // 返回时本 State 不重建，必须自己监听 AppSettings 才能即时生效
    AppSettings.instance.addListener(_onChatSettingsChanged);
    // 功能开关（零钱）：后台实时可关，进聊天页刷新一次后重建输入栏
    FeatureFlags.instance.load().then((_) {
      if (mounted) setState(() {});
    });
    // AI 翻译可用性：服务端 usage.configured=false（未配 apiKey）→ 不显示「译」按钮
    _translateSvc.usage().then((u) {
      if (!mounted) return;
      final on = u['configured'] == true ||
          u['configured'].toString() == 'true' ||
          u['configured'].toString() == '1';
      if (on != _translateEnabled) setState(() => _translateEnabled = on);
    }).catchError((_) {
      // 查询失败（老后端/网络异常）→ 按未开启处理，不显示「译」按钮
    });
  }

  /// 聊天设置（背景 / 气泡颜色 / 字号）变更 → 整页重建，让设置即时生效
  void _onChatSettingsChanged() {
    if (mounted) setState(() {});
  }

  // ===== 第十二批问题 1：背景首帧即在（修「进聊天窗口闪一下才显示背景」） =====
  // 根因：背景层无条件挂在 Stack 首子（首帧就 build），渐变 DecoratedBox 第一帧
  // 就画；但涂鸦 Image.asset / 自定义图 Image.file 的**首次解码是异步的**，
  // 解码完成前该图层不绘制任何东西 → 先见纯渐变、解码完成后涂鸦突然浮现 = 闪。
  // 修复：① main.dart AuthGate 启动即 precache 涂鸦 asset（命中后常驻 ImageCache，
  // 任何入口进聊天首帧即有）；② 此处对本页实际生效的 provider 再 precache 一次
  // （幂等，已缓存时立即返回）；③ 自定义大图按屏幕物理宽降采样解码（cacheWidth），
  // 解码更快且防 100MB ImageCache 驱逐后「每次进入都重新解码再闪」。
  bool _bgPrecached = false;

  /// 背景图解码宽（屏幕物理像素宽）：显示与 precache 用同一 provider 参数，
  /// 保证 ImageCache key 一致（Image.file(cacheWidth:) 内部即 ResizeImage(FileImage)）。
  int get _bgDecodeWidth {
    final mq = MediaQuery.of(context);
    return (mq.size.width * mq.devicePixelRatio).round();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bgPrecached) return;
    _bgPrecached = true;
    precacheImage(const AssetImage('assets/chat_bg_doodle.png'), context); // 幂等
    final custom = AppSettings.instance.chatCustomBgPath;
    if (custom.isNotEmpty) {
      final f = File(custom);
      if (f.existsSync()) {
        precacheImage(
            ResizeImage(FileImage(f), width: _bgDecodeWidth), context);
      }
    }
    // ===== 第十三批问题 2：首屏消息图片预热 =====
    // 转场 300ms 里把最后几条图片消息解码好：气泡首帧即真图，不再先画灰白
    // 占位卡、解码完再「啪」地换成图（用户截图里闪现的白色大圆角卡片即占位）。
    // provider/参数与气泡渲染完全一致（单图无 cacheWidth / 网格 cacheWidth=360）
    // 才能命中同一个 ImageCache key。
    _precacheFirstScreenMsgImages();
  }

  bool _msgImgsPrecached = false;

  /// 预热缓存直出消息里最后几张图（type=2，content 为 `url1|url2|...`）。
  /// 只对首帧直出的缓存消息有意义（网络回来的本就晚于首帧）；budget 限 4 张防
  /// 大图批量解码反而拖慢转场。
  void _precacheFirstScreenMsgImages() {
    if (_msgImgsPrecached) return;
    _msgImgsPrecached = true;
    var budget = 4;
    for (final m in _msgs.reversed) {
      if (budget <= 0) break;
      if (m.type != 2) continue;
      final urls =
          m.content.split('|').where((s) => s.trim().isNotEmpty).toList();
      if (urls.isEmpty) continue;
      if (urls.length == 1) {
        // 单图（_SingleImage）：无 cacheWidth，命中同一个 CachedNetworkImage key
        // （2026-09-26 换 CachedNetworkImageProvider：磁盘缓存，预热即落盘，
        //   冷启动直接读盘不再走网络）
        precacheImage(
            CachedNetworkImageProvider(
                _ImageGridBubble._fixUrl(urls.first)),
            context);
        budget--;
      } else {
        // 多图叠放卡片（_ImageStack）：memCacheWidth=360（与叠放卡解码一致；
        //   磁盘文件按 URL 共享，多路解码不重复下载）
        for (final u in urls) {
          if (budget <= 0) break;
          precacheImage(
              ResizeImage(
                  CachedNetworkImageProvider(
                      _ImageGridBubble._fixUrl(u)),
                  width: 360),
              context);
          budget--;
        }
      }
    }
  }

  // ===== 聊天设置生效（chat_settings_page 的三项设置） =====

  /// 聊天窗口背景：`kChatBgPresets[chatBackground]` 的渐变打底，再叠参考图同款
  /// 白色涂鸦线稿（透明 PNG，cover 铺满；浅色渐变上近不可见，深色底还原参考质感）。
  /// （列表 / 加载态 / 失败态都是透明的，能透出它。）
  /// 设置了自定义背景图（「从相册选择」）时优先用图；文件丢失回退预设层。
  Widget _chatBackgroundLayer() {
    final custom = AppSettings.instance.chatCustomBgPath;
    if (custom.isNotEmpty) {
      return Image.file(
        File(custom),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        // 按屏幕物理宽降采样解码（didChangeDependencies 的 precache 同参数）：
        // 大相册图 4000×3000 全尺寸解码要 40MB+ 且慢 → 降采样后更快、常驻缓存
        cacheWidth: _bgDecodeWidth,
        errorBuilder: (_, __, ___) => _presetChatBg(),
      );
    }
    return _presetChatBg();
  }

  Widget _presetChatBg() {
    final i =
        AppSettings.instance.chatBackground.clamp(0, kChatBgPresets.length - 1);
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(gradient: kChatBgPresets[i].gradient),
        ),
        // 第九批返工：渐变之上叠涂鸦花纹（与气泡颜色 sheet 预览卡同一份 asset）
        Image.asset('assets/chat_bg_doodle.png', fit: BoxFit.cover),
      ],
    );
  }

  /// 距底部多少像素内算"贴底"（此时新消息自动跟进，不打扰正在翻记录的用户）
  static const double _bottomThreshold = 120;

  /// 滚到距顶部多少像素内触发上拉加载更早历史
  static const double _loadOlderThreshold = 200;

  void _onScroll() {
    final pos = _scroll.position;
    if (!pos.hasContentDimensions) return;
    final awayFromBottom = pos.maxScrollExtent - pos.pixels > _bottomThreshold;
    if (mounted && awayFromBottom != _showJumpBtn) {
      setState(() => _showJumpBtn = awayFromBottom);
    }
    // 滚到顶部（历史方向的尽头）→ 自动加载更早消息（微信式，无需手动点）
    if (_hasMoreOlder &&
        !_loadingOlder &&
        !_loading &&
        _msgs.isNotEmpty &&
        pos.pixels < _loadOlderThreshold) {
      _loadOlder();
    }
  }

  /// 当前是否贴在底部
  bool get _atBottom {
    if (!_scroll.hasClients) return true;
    final pos = _scroll.position;
    if (!pos.hasContentDimensions) return true;
    return pos.maxScrollExtent - pos.pixels <= _bottomThreshold;
  }

  /// 进入会话时调用：开启"持续贴底"意图，并立即跳到底部。
  ///
  /// 为什么能收敛到真实底部、且不再白屏/不再有固定贴底窗口：
  /// ListView.builder 首帧 maxScrollExtent 是**估算值**（只布局可见 item，其余
  /// 按平均高度外推）。这里首帧 + 下一帧各跳一次启动收敛，之后由
  /// ScrollMetricsNotification 在内容高度每次变化（懒加载布局收敛、图片**异步
  /// 加载完成**改变高度）时持续 _jumpToLatest，链式收敛到真实底部。只要用户没
  /// 主动上滑离开，就一直跟随到底部——彻底覆盖异步图片高度变化（旧版 1.5s 硬
  /// 窗口到点后图片才加载完，反而把人顶到中间）。
  /// 列表不再用 Opacity 隐藏，进入/有缓存直出时立即显示，杜绝"白屏一下"。
  void _startStick() {
    _stickActive = true;
    _dragging = false;
    _primeHeights(); // 异步把持久化的实测高度拉进 memo（cacheExtent 预算用）
    _jumpToLatest(); // 首帧 layout 后跳到当前（估算）底部
    // 下一帧再补一跳：此时懒加载已多布局一屏 item，maxScrollExtent 更接近真实
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_stickActive && !_dragging && _scroll.hasClients) _jumpToLatest();
    });
  }

  /// 滚动/尺寸通知：
  /// - 用户拖拽（UserScrollNotification）：拖拽中暂停自动贴底（_dragging），停下时
  ///   按当前位置刷新意图。注意 idle 时【只刷新意图、不 jumpTo】——
  ///   底部 120px 阈值内停手若强行吸回底部，用户会感觉"往回拉被卡住"；
  ///   真正需要贴底跟随的场景（新消息、图片加载完高度变化）由
  ///   ScrollMetricsNotification 分支负责，这里不跳不影响收敛。
  /// - 内容高度变化（ScrollMetricsNotification）：只要还想贴底就跟随到底部，
  ///   覆盖懒加载布局收敛、图片异步加载完成等场景。
  /// 泛型必须是 Notification：ScrollMetricsNotification 与 ScrollNotification
  /// 是兄弟类，不继承后者，缩窄成 ScrollNotification 收不到。
  void _onScrollNotification(Notification n) {
    if (n is UserScrollNotification) {
      if (n.direction == ScrollDirection.idle) {
        _dragging = false;
        _stickActive = _atBottom;
      } else {
        _dragging = true;
      }
      return;
    }
    // H5/Web：鼠标滚轮与触控板常不走 UserScrollNotification，只发 ScrollUpdate。
    // 若不在此解除贴底，ScrollMetricsNotification 会反复 _jumpToLatest，表现为「上滑不动」。
    if (n is ScrollUpdateNotification) {
      final d = n.scrollDelta;
      if (d != null && d != 0) {
        if (d < 0) {
          _stickActive = false;
          _dragging = true;
        } else if (_atBottom) {
          _stickActive = true;
          _dragging = false;
        }
      }
    }
    if (n is ScrollEndNotification) {
      _dragging = false;
      _stickActive = _atBottom;
    }
    if (n is ScrollMetricsNotification) {
      if (_stickActive && !_dragging && _scroll.hasClients) _jumpToLatest();
    }
  }

  Future<void> _init() async {
    // 全员禁言初值：会话快照携带（服务端 conversation.muteAll）
    _muteAll =
        ((widget.conv.conversation['muteAll'] as num?)?.toInt() ?? 0) == 1;
    _loadMyAvatar();
    // 单聊对方客服勾（2026-09-15 第十三批）：拉对方账号角色（失败静默不显示）
    if (!isGroup && !isChannel) unawaited(_loadPeerRole());
    // 断点先取本地持久化值（冷启动可续，修 R-05）
    _lastSeq = await LocalStore.loadLastSeq(widget.conv.id);
    await _loadHistory();
    // 历史到手就先报已读（不等 WS 建连）：退回列表的 _load() 会立刻读服务端
    // unread，若此时 markRead 还没发出，红点会闪现「已读变未读」。
    // 下面 _connectWs 之后再报一次是兜底（同一水位被 _lastReportedReadId 去重）。
    _reportRead();
    // 本地发件箱：把上次没发出去的消息补发/回填（杀进程不丢，修 R-13）
    unawaited(_resumeOutbox());
    // 与服务端水位对齐 + 补齐缺口（修 R-04/R-07）
    unawaited(_alignSeqWithServer());
    await _connectWs();
    _reportRead();
    if (isGroup || isChannel) {
      // 群：members 顶层带 memberCount/onlineCount（be-channel 第十批）。
      // 频道（第十二批问题 8）：只要 memberCount 当订阅数（拉取失败回落
      // 会话列表携带的 memberCount，见 _groupMemberCount），不显示在线。
      _loadMembers();
    }
    if (isGroup) {
      _loadPins(); // 第十批：全量置顶列表（点击循环切换 + 分段竖条）
    }
  }

  /// 我方头像（聊天窗口左右气泡都要显示真实头像）
  Future<void> _loadMyAvatar() async {
    // 进程内缓存命中直接用（一次登录会话只拉一次 /user/profile）
    final cached = UserCache.myAvatar;
    if (cached != null && cached.isNotEmpty) {
      if (mounted) setState(() => _myAvatar = cached);
      return;
    }
    try {
      final r = await _api.get('/api/v1/user/profile');
      final d = (r.data['data'] as Map<String, dynamic>?) ?? {};
      UserCache.setMyProfile(d);
      final av = d['avatar']?.toString() ?? '';
      if (mounted && av.isNotEmpty) setState(() => _myAvatar = av);
    } catch (_) {}
  }

  /// 上报已读（取列表最后一条**有服务端 msgId** 的消息；失败忽略）。
  /// 旧实现只看 _msgs.last：末尾是本地 sending/failed 气泡（msgId=null）时直接
  /// return、谁也不报 —— 对方永远收不到已读（「私聊文字没有已读回执」根因之一）。
  Future<void> _reportRead() async {
    String? lastId;
    for (final x in _msgs.reversed) {
      if (x.msgId != null && x.msgId!.isNotEmpty) {
        lastId = x.msgId;
        break;
      }
    }
    if (lastId == null) return;
    if (lastId == _lastReportedReadId) return; // 同一水位去重（每条新消息都会触发）
    _lastReportedReadId = lastId;
    try {
      await _svc.markRead(widget.conv.id, lastId);
    } catch (_) {}
  }

  /// 单聊对方账号角色（客服认证勾数据源，2026-09-15 第十三批）。
  /// 优先会话快照的 peerRole（contacts 入口注入，conversation/list 暂不下发）；
  /// 缺失时拉 GET /user/:id（PublicUser.role，UserCache 进程内缓存）。
  /// 拉不到保持 null → 顶栏不显示勾（不造假数据）。
  /// ⚠️ 群会话不调用：群成员的 role 是群内角色，与账号角色同名不同义。
  Future<void> _loadPeerRole() async {
    _peerRole = widget.conv.peerRoleAny;
    if (CertBadge.isKefu(_peerRole)) return;
    final peerId = widget.conv.peerId;
    if (peerId.isEmpty) return;
    try {
      final d = await _friendSvc.userDetail(peerId);
      if (!mounted) return;
      setState(() => _peerRole = d['role']);
    } catch (_) {
      // 拉不到就不显示勾（保持无徽标），不打断聊天主流程
    }
  }

  Future<void> _loadMembers() async {
    // 缓存直出（内存 → 磁盘）：首帧即有成员昵称/头像，网络回来只做静默校准。
    // 旧实现首帧 _members 为空 → 消息行显示「...短号 + 占位头像」，成员列表
    // 回来后 setState 集体翻转 = 「进群聊头像变一下 + 行高变列表跳」。
    if (_members.isEmpty) {
      var cached = ConversationService.membersCached(widget.conv.id);
      if (cached == null || cached.isEmpty) {
        cached = await LocalStore.loadGroupMembers(widget.conv.id);
        if (cached.isNotEmpty) {
          ConversationService.cacheMembers(widget.conv.id, cached);
        }
      }
      if (cached.isNotEmpty && mounted && _members.isEmpty) {
        final mem = cached; // 闭包内不走空提升，先落非空局部
        var myRole = _myRole;
        for (final m in mem) {
          final uid = m['userId']?.toString() ?? m['id']?.toString() ?? '';
          if (uid == _myUid) {
            myRole = (m['role'] as num?)?.toInt() ?? 3;
            break;
          }
        }
        setState(() {
          _members = mem;
          _myRole = myRole;
        });
      }
    }
    try {
      final list = await _svc.members(widget.conv.id);
      if (mounted) {
        var myRole = _myRole;
        for (final m in list) {
          final uid = m['userId']?.toString() ?? m['id']?.toString() ?? '';
          if (uid == _myUid) {
            myRole = (m['role'] as num?)?.toInt() ?? 3;
            break;
          }
        }
        // 群隐私：服务端现行机制是"普通成员截断 15 条"而非报 4006，
        // 因此用 群设置 privacyEnabled + 我的角色 判定：
        // 开启且我是普通成员（列表截断后查不到自己时 role 保持默认 3，同样命中）→ 禁点成员头像看资料。
        // 频道（type=3）没有群隐私设置，跳过这次额外请求。
        bool privacyEnabled = false;
        // 需求3（2026-09-22 三批）：默认 false——群设置拉取失败时保持隐藏
        // （「默认不显示，有权限显示再渲染」），拉取成功且未关闭才置 true
        bool showMembers = false;
        if (!isChannel) {
          try {
            final s = await _svc.groupSettings(widget.conv.id);
            privacyEnabled = s['privacyEnabled'] == true;
            // 需求5：显式 false 才隐藏（null/缺字段视为开启）
            showMembers = s['showMembers'] != false;
          } catch (_) {}
        }
        setState(() {
          _members = list;
          _myRole = myRole;
          _privacyOn = privacyEnabled && myRole == 3;
          _showMembers = showMembers;
          // 需求3（2026-09-22 二批）：隐私开启 → 副标题成员/在线行整行隐藏
          _privacyCountOn = privacyEnabled;
          // 隐私限量模式下列表被截断，服务端照实下发总数
          if (_svc.lastMembersCount > 0) _memberCount = _svc.lastMembersCount;
          // 第十批：顶栏「N 成员, M 在线」（members 响应顶层两字段）
          _onlineCount = _svc.lastOnlineCount;
          _onlineLoaded = true;
        });
        // 写双层缓存（成员名单变化时下一次进页即生效）
        ConversationService.cacheMembers(widget.conv.id, list);
        unawaited(LocalStore.saveGroupMembers(widget.conv.id, list));
      }
    } on ApiException catch (e) {
      // 老服务端兜底：直接以 4006 拦截成员列表（隐私必开 → 副标题行同样隐藏）
      if (e.code == 4006 && mounted) {
        setState(() {
          _privacyOn = true;
          _privacyCountOn = true;
        });
      }
    } catch (_) {}
  }

  /// 全量置顶列表（第十批）：优先 GET /conversation/:id/pins；
  /// 失败/为空时回落会话快照携带的单条置顶（老服务端兼容）。
  Future<void> _loadPins() async {
    // 缓存直出（内存 → 磁盘）：首帧即渲染置顶条，避免网络回来后置顶条
    // 突然插入把整个消息列表顶下去一格（「进群聊跳一下」的另一半根因）。
    if (_pinnedMsgs.isEmpty) {
      var cached = ConversationService.pinsCached(widget.conv.id);
      if (cached == null || cached.isEmpty) {
        cached = await LocalStore.loadConvPins(widget.conv.id);
        if (cached.isNotEmpty) {
          ConversationService.cachePins(widget.conv.id, cached);
        }
      }
      if (cached.isNotEmpty && _pinnedMsgs.isEmpty) {
        // 只写字段不 setState（进群卡顿优化：由 350ms 合并刷新统一呈现）
        _pinnedMsgs = cached;
      }
    }
    List<Map<String, dynamic>> list = [];
    var pinsOk = false;
    try {
      list = await _svc.pinnedMessages(widget.conv.id);
      pinsOk = true;
    } catch (_) {}
    if (!pinsOk) {
      // 网络失败才回落会话快照携带的单条置顶（老服务端兼容）。
      // 需求2（2026-09-22 三批）：**成功返回空 = 服务端已无置顶**（如群主
      // 取消置顶），绝不能回落旧快照/旧缓存，否则聊天窗口永远显示已取消的置顶。
      final c = widget.conv.conversation['pinnedMsgContent']?.toString() ?? '';
      final id = widget.conv.conversation['pinnedMsgId']?.toString() ?? '';
      if (c.isNotEmpty) {
        list = [
          {'msgId': id, 'content': c},
        ];
      }
    }
    if (!mounted) return;
    if (!pinsOk && list.isEmpty) {
      // 网络失败且无快照可回落 → 保留缓存直出的旧置顶条（历史行为）
      return;
    }
    if (_pinnedMsgs.isNotEmpty || list.isNotEmpty) {
      // 网络段通常在转场之后回来，这里保留 setState（单次整页重建可接受）
      setState(() {
        _pinnedMsgs = list;
        _pinnedIndex = 0;
      });
    }
    // 写双层缓存（置顶变化/清空时下一次进页即生效；空列表同样覆盖写入 = 清缓存）
    ConversationService.cachePins(widget.conv.id, list);
    unawaited(LocalStore.saveConvPins(widget.conv.id, list));
  }

  /// 点击置顶卡：循环切换到下一条置顶并滚动跳到该消息位置
  void _cyclePinned() {
    if (_pinnedMsgs.isEmpty) return;
    final next = (_pinnedIndex + 1) % _pinnedMsgs.length;
    setState(() => _pinnedIndex = next);
    // 防御：旧版服务端的 PinnedMsgBrief.MsgID 挂了 ,string tag，会把 msgId
    // 双重引号下发（值自带 \" 包裹），导致与 _msgs 永远匹配不上、恒提示
    // 「该消息已不在聊天记录中」。这里把游离引号洗掉，兼容新旧两种服务端。
    final id = _pinnedMsgs[next]['msgId']?.toString().replaceAll('"', '') ?? '';
    if (id.isNotEmpty) _jumpToPinnedMsg(id); // 先按需取数，再复用收敛跳转
  }

  /// 当前展示的置顶内容（越界兜底）。
  /// 按消息类型生成摘要：通话信令（type=7）等 content 是 JSON，直接透传会
  /// 显示 {"action":"leave"...} 原文（2026-09-17 用户实测）。媒体/资金/通话/
  /// 名片一律显示类型标签，与引用条同一套 svc* 词条文案。
  String get _pinnedCurrentContent {
    if (_pinnedMsgs.isEmpty) return '';
    final i = _pinnedIndex.clamp(0, _pinnedMsgs.length - 1);
    final p = _pinnedMsgs[i];
    final type = (p['type'] as num?)?.toInt() ?? 1;
    final raw = p['content']?.toString() ?? '';
    const typeMap = {
      2: 'svcImage',
      3: 'svcFile',
      4: 'svcVoice',
      5: 'svcVideo',
      7: 'svcCall',
      8: 'svcRedPacket',
      9: 'svcTransfer',
      10: 'svcCard',
      14: 'svcLocation',
    };
    final label = typeMap[type];
    if (label != null) {
      return AppLocalizations.of(context).t(label);
    }
    return raw.replaceAll('\n', ' ').trim();
  }

  // 点消息气泡里的头像：看资料 / 加好友（复用扫个人码落地页）
  // 群隐私开启（且我是被限制的普通成员）时拦截并提示。
  void _openMemberProfile(String uid) {
    if (uid.isEmpty || uid == '-1') return; // 空或虚拟小助手不处理
    if (isGroup && _privacyOn) {
      AppDialogs.toast(context,
          AppLocalizations.of(context).t('groupPrivacyProfileBlocked'));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => UserQrProfilePage(uid: uid)),
    );
  }

  /// 用「本页历史最大 seq」推进断点（修 R-05）。
  ///
  /// 以前 `_lastSeq` 只靠 WS 推送推进，而 `_loadHistory` 拉回的 80 条历史
  /// 从不参与 —— 于是刚进页时断点还是 0，第一次重连就会从 seq=0 拉，
  /// 拉回最早一批还会插到列表头部（表现为「内容上翻」）。
  void _initLastSeqFromHistory() {
    var maxSeq = _lastSeq;
    for (final m in _msgs) {
      final s = m.seq;
      if (s != null && s > maxSeq) maxSeq = s;
    }
    if (maxSeq > _lastSeq) {
      _lastSeq = maxSeq;
      unawaited(LocalStore.saveLastSeq(widget.conv.id, _lastSeq));
    }
  }

  /// 进页时把断点与服务端水位对齐一次。
  ///
  /// 场景：本地持久化值可能因上次异常退出而落后/超前；服务端水位也可能因为
  /// Redis 重建而回退。一次 GET 的成本可忽略，换来的是「补拉起点一定正确」。
  Future<void> _alignSeqWithServer() async {
    try {
      final server = await _svc.lastSeqOf(widget.conv.id);
      if (!mounted || server <= 0) return;
      if (server < _lastSeq) {
        // 服务端水位比我还小 → 水位回退过，交给重置流程处理
        await _handleSeqReset(server);
        return;
      }
      if (server > _lastSeq) {
        // 有缺口：直接补一轮
        unawaited(_pullGap());
      }
    } catch (_) {
      // 水位查询失败不阻断页面：补拉仍按本地断点工作
    }
  }

  Future<void> _loadHistory({int retry = 0, bool force = false}) async {
    // 缓存直出：内存有（本进程打开过）或磁盘有（Hive，上次运行留下的）
    // → 先渲染，不再菊花等待；网络回来后覆盖刷新。
    // force=true（下拉手动刷新）跳过缓存，直接全量拉服务端。
    if (!force) {
      if (_msgs.isEmpty) {
        await ConversationService.hydrateFromDisk(widget.conv.id);
      }
      final cached = ConversationService.historyCached(widget.conv.id);
      if (cached != null && cached.isNotEmpty && _msgs.isEmpty) {
        // 过滤旧版本落库的通话纯信令（accept/join/sdp…不进历史气泡）
        final cachedMsgs = cached
            .map(ChatMsg.fromServer)
            .where((x) => !(x.type == 7 && _isPureCallSignal(x.content)))
            .toList();
        setState(() {
          // 首屏裁剪：只渲染最近 20 条，更早的进 _pendingOlder（上翻分批挂载）
          if (cachedMsgs.length > _firstScreenCount) {
            _pendingOlder =
                cachedMsgs.sublist(0, cachedMsgs.length - _firstScreenCount);
            _msgs = cachedMsgs.sublist(cachedMsgs.length - _firstScreenCount);
          } else {
            _msgs = cachedMsgs;
          }
          _loading = false;
        });
        _startStick(); // 开启持续贴底（列表已直接显示，无白屏）
      }
    }
    try {
      final list = await _svc.history(widget.conv.id);
      if (mounted) {
        // 过滤旧版本落库的通话纯信令（实时帧同规则，见 _isPureCallSignal）
        final incoming = list
            .map(ChatMsg.fromServer)
            .where((x) => !(x.type == 7 && _isPureCallSignal(x.content)))
            .toList();
        // 「删除聊天记录」离线兜底（2026-09-18）：本会话有本地缓存但服务端
        // 最新窗口已返回空 → 记录已被软删位点清空（漏收 history.cleared 时
        // 唯一可能）。清空本地内存与磁盘缓存对齐服务端（空会话直出空列表）。
        if (incoming.isEmpty && _msgs.isNotEmpty) {
          setState(() {
            _msgs = [];
            _loading = false;
            _loadFailed = false;
            _hasMoreOlder = false;
          });
          ConversationService.historyCacheClearConv(widget.conv.id);
          _initLastSeqFromHistory();
          return;
        }
        // 已读标记：自己发的、deliveryState=read → 标为已读（对新增与存量都生效）
        for (final x in incoming) {
          if (x.senderId == _myUid && x.deliveryState == 'read') {
            x.status = MsgStatus.read;
          }
        }

        // ---- 2026-09-16 修「进聊天页跳一下」----
        // 缓存直出后网络回来，旧实现把 _msgs **整体替换**：替换后视口停在
        // 旧 pixels，而列表头部多出几十条更早消息 → 用户先看到偏上的旧内容，
        // 下一帧又跳回底部 = 「消息往上移一下」的跳动。
        // 改为**合并**：缓存首条在网络页中的位置 idx，之前的部分 prepend 到
        // 头部（msgId 去重），之后的增量尾部追加；prepend 后按 maxScrollExtent
        // 差值把 pixels 补偿到新底部（内容零位移、贴底意图不丢，与 _loadOlder
        // 的补偿同款）。定位不到 idx（缓存太旧超出本页窗口）才整体替换。
        final firstId = _msgs.isEmpty ? null : _msgs.first.msgId;
        final firstSeq = _msgs.isEmpty ? null : _msgs.first.seq;
        int? idx;
        if (incoming.isNotEmpty && _msgs.isNotEmpty) {
          if (firstSeq != null) {
            idx = incoming.indexWhere((m) => m.seq == firstSeq);
          }
          if (idx == null || idx < 0) {
            final i = firstId == null
                ? -1
                : incoming.indexWhere((m) => m.msgId == firstId);
            if (i >= 0) idx = i;
          }
        }

        if (_msgs.isNotEmpty && idx != null && idx >= 0) {
          final known = _msgs.map((m) => m.msgId).whereType<String>().toSet();
          final older = incoming
              .take(idx)
              .where((m) => m.msgId == null || !known.contains(m.msgId))
              .toList();
          final appended = incoming
              .skip(idx)
              .where((m) =>
                  m.msgId != null &&
                  m.msgId != firstId &&
                  !known.contains(m.msgId))
              .toList();
          final beforeExtent =
              _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
          // 声明在 setState 外：闭包外还要用它们同步缓存
          final recalledIds = <String>{};
          final removedIds = <String>{};
          setState(() {
            // 通话记录最终态刷新：同 msgId 且服务端 content 已被改写
            // （status/duration 回写）→ 覆盖本地旧内容。合并去重只认 msgId，
            // 不做这步的话重进会话仍显示「语音通话 · 点击回拨」中间态。
            final srvById = {
              for (final m in incoming)
                if (m.msgId != null) m.msgId!: m
            };
            for (final local in _msgs) {
              if (local.msgId == null) continue;
              final srv = srvById[local.msgId];
              if (srv == null) continue;
              // 撤回态同步到所有类型：此前只同步 type=7 的 content 改写，
              // 图片/视频等被撤回后缓存里还是原消息（2026-09-17 用户反馈 #4）。
              if (srv.recalled && !local.recalled) {
                local.recalled = true;
                recalledIds.add(local.msgId!);
              }
              if (local.type == 7 && srv.content != local.content) {
                local.content = srv.content;
              }
              // 已读态同步（2026-09-25）：deliveryState 只有 History 接口推导，
              // WS 实时帧与本地缓存都没有。实时 read 事件只翻上一页面实例的
              // 内存态，缓存里仍是未读——合并若不同步，重进会话永远显示
              // 缓存的未读（"对方已读、回列表再进又变未读"根因之二）。
              // 只做未读→已读的单向升级，不回退。
              if (srv.senderId == _myUid &&
                  srv.deliveryState == 'read' &&
                  local.status != MsgStatus.read) {
                local.status = MsgStatus.read;
              }
            }
            // 后台屏蔽/删除对账：服务端本页窗口内已不再下发的消息从本地移除
            //（历史/同步接口过滤 blocked，合并只增不删导致屏蔽后消息一直留着，
            // 2026-09-17 用户反馈 #3）。只对账 seq >= 本页最早 seq 的有 msgId
            // 消息，避免误删超出本页窗口的更早缓存消息与待发送的本地消息。
            final pageMinSeq = incoming.isEmpty ? null : incoming.first.seq;
            if (pageMinSeq != null) {
              _msgs.removeWhere((m) {
                if (m.msgId != null &&
                    m.seq != null &&
                    m.seq! >= pageMinSeq! &&
                    !srvById.containsKey(m.msgId)) {
                  removedIds.add(m.msgId!);
                  return true;
                }
                return false;
              });
            }
            // 2026-09-20：older（网络窗口里比首屏更早的部分）不再一次性
            // prepend——几十条突然挂载会带来一波布局卡顿。存入 _pendingOlder
            // 由 _loadOlder 上翻分批挂载（「上面的消息慢慢加载」）。
            if (older.isNotEmpty) _pendingOlder.insertAll(0, older);
            if (appended.isNotEmpty) _msgs.addAll(appended);
            _loading = false;
            _loadFailed = false;
            // 首拉返回不足一页 → 没有更早的历史了（不必再触发上拉）
            _hasMoreOlder = list.length >= 80;
          });
          // 缓存同步（setState 外，避免 build 期间写盘）：撤回态 + 屏蔽移除
          for (final id in recalledIds) {
            ConversationService.historyCacheMarkRecalled(widget.conv.id, id);
          }
          if (removedIds.isNotEmpty) {
            ConversationService.historyCacheRemoveAll(
                widget.conv.id, removedIds);
          }
          _initLastSeqFromHistory();
          // 置顶/引用跳转进入（带 scrollToMsgId）：合并完成后仍要定位目标消息
          // 2026-09-29：改走 _jumpToPinnedMsg——目标在窗口外时按需取数（含 +1 修复）
          final to = widget.scrollToMsgId;
          if (to != null && to.isNotEmpty) _jumpToPinnedMsg(to);
          if (older.isNotEmpty && beforeExtent > 0) {
            // prepend 补偿：贴底用户视口零位移（新底部 = 旧位置 + delta）
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || !_scroll.hasClients) return;
              final delta = _scroll.position.maxScrollExtent - beforeExtent;
              if (delta > 0 && _stickActive && !_dragging) {
                _scroll.jumpTo(_scroll.position.pixels + delta);
              }
            });
          }
          // 贴底意图已在缓存直出时开启，补偿后视口仍贴底，无需再 _startStick。
        } else {
          setState(() {
            _msgs = incoming;
            _loading = false;
            _loadFailed = false;
            _hasMoreOlder = list.length >= 80;
          });
          _initLastSeqFromHistory();
          // 群置顶点击跳转：滚到目标消息（否则进会话强制贴底）
          // 2026-09-29：改走 _jumpToPinnedMsg（窗口外目标按需取数 + beforeMsgId+1 修复）
          final to = widget.scrollToMsgId;
          if (to != null && to.isNotEmpty) {
            _jumpToPinnedMsg(to);
          } else {
            // 进会话：开启持续贴底。整体替换后懒加载估算高度由
            // ScrollMetricsNotification 持续收敛到真实底部（而非只跳一次）。
            _startStick();
          }
        }
      }
    } catch (e) {
      // 偶发失败（token 存储读取抖动/网络抖动）会静默变成空会话：
      // 自动重试两次；仍失败给出"重新加载"入口，不再无声空白
      if (mounted && retry < 2) {
        await Future.delayed(const Duration(milliseconds: 600));
        if (!mounted) return;
        return _loadHistory(retry: retry + 1);
      }
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
    }
  }

  /// 失败态手动重试
  void _retryLoadHistory() {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    _loadHistory();
  }

  Future<void> _connectWs() async {
    // 复用全局 WS（审查 #8）：不再每页自建一条长连接，避免同一用户进聊天页时
    // 同时存在两条连接、还各自独立重连。这里只在 GlobalWs 上挂本会话需要的
    // 监听器，dispose 时统一注销；全局连接由 HomeShell 建立并保活。
    final g = GlobalWs.instance;
    _wsOffs.add(g.onMessage((m) => _handleWs(m)));
    _wsOffs.add(g.onRecall((m) {
      // 撤回通知：本地把对应消息标为 recalled
      if (!mounted) return;
      final id = m['msgId']?.toString();
      if (id == null) return;
      setState(() {
        for (final x in _msgs) {
          if (x.msgId == id) x.recalled = true;
        }
      });
      // 同步替换内存/磁盘缓存，否则退出重进又显示原消息
      //（与 call_update 的缓存替换同款机制，2026-09-17 用户反馈 #4）。
      ConversationService.historyCacheMarkRecalled(widget.conv.id, id);
    }));
    _wsOffs.add(g.onEdited((m) {
      // 编辑实时同步（2026-09-28，与 PC 对齐）：对方改了自己发的文本消息，
      // 本地原地替换 content 并置 edited（气泡内显示「已编辑」），
      // 同步替换缓存防止重进回退旧内容。
      if (!mounted) return;
      final id = m['msgId']?.toString();
      final content = m['content']?.toString();
      if (id == null || id.isEmpty || content == null || content.isEmpty) {
        return;
      }
      setState(() {
        for (final x in _msgs) {
          if (x.msgId == id) {
            x.content = content;
            x.edited = true;
          }
        }
      });
      ConversationService.historyCacheReplaceContent(
          widget.conv.id, id, content,
          extra: const <String, dynamic>{'edited': true});
    }));
    _wsOffs.add(g.onDeleted((m) {
      // 软删除实时移除（2026-09-28，与 PC 对齐）：任一方删除后双方都不再显示，
      // 本地移除气泡并同步清缓存，否则重进会话又从缓存直出已删消息。
      if (!mounted) return;
      final id = m['msgId']?.toString();
      if (id == null || id.isEmpty) return;
      setState(() {
        _msgs.removeWhere((x) => x.msgId == id);
      });
      ConversationService.historyCacheRemoveAll(widget.conv.id, {id});
    }));
    _wsOffs.add(g.onCallUpdate((m) {
      // 通话记录改写（一通电话一条记录）：服务端把结束态写回 invite 消息后广播。
      // 本地把对应气泡的 content 原地替换，气泡随即从「语音通话 · 点击回拨」
      // 变成「语音通话 00:05 / 对方拒绝接听 / 通话未接通」。
      if (!mounted) return;
      final id = m['msgId']?.toString();
      final content = m['content']?.toString();
      if (id == null || id.isEmpty || content == null || content.isEmpty) {
        return;
      }
      setState(() {
        for (final x in _msgs) {
          if (x.msgId == id) x.content = content;
        }
      });
      // 同步替换内存/磁盘缓存里的旧 content，否则退出重进又显示中间态
      ConversationService.historyCacheReplaceContent(
          widget.conv.id, id, content);
    }));
    _wsOffs.add(g.onRead((m) {
      // 对方已读：把本地自己发的对应消息标为已读
      if (!mounted) return;
      final convId = m['conversationId']?.toString();
      if (convId != widget.conv.id) return;
      // 事件发起者必须是对手方：自己进会话也会触发服务端 MarkRead 广播（回环），
      // 不校验的话「发消息→回列表→再进会话」自己刚发的消息会被误标已读。
      final fromUid = m['userId']?.toString();
      if (fromUid == null || fromUid.isEmpty || fromUid == _myUid) return;
      final msgId = m['msgId']?.toString();
      if (msgId == null) return;
      setState(() {
        // 服务端事件只带「读到的最后一条 msgId」，比它早的所有我发的消息同样已读
        //（旧实现只精确翻转一条 → 中间那些要等重新进页刷新才变已读）。
        // 按列表位置翻转：msgId 是 18-19 位雪花字符串，不能直接比大小（H5 还会丢精度）。
        final idx = _msgs.indexWhere((x) => x.msgId == msgId);
        if (idx < 0) return;
        for (var i = 0; i <= idx; i++) {
          final x = _msgs[i];
          if (x.senderId == _myUid && x.msgId != null) {
            x.status = MsgStatus.read;
          }
        }
      });
    }));
    _wsOffs.add(g.onHistoryCleared((m) {
      // 删除聊天记录（2026-09-18）：本会话被清（仅为我 / 为双方）→
      // 实时清空本地消息与缓存，会话列表预览随下次刷新对齐服务端。
      if (!mounted) return;
      final convId = m['conversationId']?.toString();
      if (convId != widget.conv.id) return;
      setState(() {
        _msgs = [];
        _hasMoreOlder = false;
      });
      ConversationService.historyCacheClearConv(widget.conv.id);
    }));
    _wsOffs.add(g.onReconnected(() {
      // 重连后按断点补拉：**循环分页 + 每页推进断点**（旧实现只拉一页且不推进，
      // 断线积压 >200 条时第 201 条之后永远拉不到 —— R-06/R-07）。
      unawaited(_pullGap());
    }));
    try {
      await g.ensureConnected();
    } catch (_) {
      // 建连失败（网络/未登录）不阻断页面，GlobalWs 自有重连兜底
    }
  }

  void _handleWs(Map<String, dynamic> m) {
    final convId = m['conversationId']?.toString();
    if (convId != widget.conv.id) return;
    final msg = ChatMsg.fromServer(m);
    // type=7 纯信令（accept/join/sdp/ice…）不进气泡流，CallService 自己消费
    if (msg.type == 7 && _isPureCallSignal(msg.content)) return;
    final seqNow = msg.seq ?? 0;

    // ===== seq 空洞检测（修 R-12）=====
    // 事件通道（Redis Pub/Sub）+ 写缓冲都可能丢帧，客户端以前对跳号毫无察觉：
    // 收到 seq=10 而本地只到 7，中间 8/9 就永久丢了。
    // 这里发现跳号就记下来，200ms 去抖后统一补拉（连续跳号只补一次）。
    if (seqNow > _lastSeq + 1 && _lastSeq > 0) {
      _scheduleGapPull();
    }
    if (seqNow > _lastSeq) {
      _lastSeq = seqNow;
      unawaited(LocalStore.saveLastSeq(widget.conv.id, _lastSeq));
    }

    // ===== WS 回声回填乐观气泡（修 R-16）=====
    // 服务端把 senderID 也放进 receivers，所以**自己也会收到自己消息的回声**。
    // 旧实现命中 clientMsgId 去重就直接 return，于是「HTTP 响应超过 10s」时：
    // 服务端已落库成功、客户端却把气泡标了 failed，回声还被吞掉 → 气泡卡在 failed。
    // 现在：回声命中本地 sending/failed 气泡时，用服务端消息**替换并置成功**。
    final cmid = msg.clientMsgId;
    if (cmid.isNotEmpty) {
      final idx = _msgs.indexWhere((x) => x.clientMsgId == cmid);
      if (idx >= 0) {
        final local = _msgs[idx];
        if (local.status == MsgStatus.sending ||
            local.status == MsgStatus.failed) {
          if (mounted) {
            setState(() {
              _msgs[idx] = ChatMsg.fromServer(m)..status = MsgStatus.sent;
            });
            _cancelWatchdog(cmid);
            unawaited(LocalStore.removeOutbox(widget.conv.id, cmid));
            ConversationService.historyCacheAppend(widget.conv.id, m);
            if (_atBottom) _jumpToLatest();
          }
          return;
        }
        // 已是 sent/read：纯重复回声，直接丢弃
        return;
      }
    }

    // 群事件系统消息：全员禁言开关实时刷新输入栏状态
    if (msg.type == 6) {
      try {
        final j = jsonDecode(msg.content);
        if (j is Map) {
          final kind = j['kind']?.toString() ?? '';
          if (kind == 'muteAllOn' || kind == 'muteAllOff') {
            if (mounted) {
              setState(() => _muteAll = kind == 'muteAllOn' ? true : false);
            }
          }
        }
      } catch (_) {}
    }
    if (mounted) {
      // **必须在 setState 之前判断**：新消息插进去后 maxScrollExtent 会变大，
      // 此时再判 _atBottom 会把"本来就在底部"误判成"已离开底部"，
      // 结果用户收不到新消息还看不到自动滚动。
      final wasAtBottom = _atBottom;
      setState(() {
        // 幂等去重：msgId 或 clientMsgId 任一命中即跳过。
        // 只按 clientMsgId 判断有漏网场景（服务端/补拉数据不带 clientMsgId 时
        // 永远匹配不上 → 同一条消息被重复插入 → 图片消息显示两张），
        // 所以再按 msgId 兜一层。
        final dup = _msgs.any((x) =>
            (msg.msgId != null &&
                msg.msgId!.isNotEmpty &&
                x.msgId == msg.msgId) ||
            (x.clientMsgId.isNotEmpty && x.clientMsgId == msg.clientMsgId));
        if (dup) return;
        // 维持 seq 升序：二分定位插入点后插入，避免每条消息都全量 sort
        // （审查 #7：大聊天数千条时全量 sort 会明显卡顿，现降为 O(log n) 查找 + O(n) 移位）。
        // 注意键用 [_seqKey]：本地未确认气泡视为「无穷大」，始终排在末尾，
        // 否则 seq=null→0 会让它被排到最前（R-24）。
        int lo = 0, hi = _msgs.length;
        while (lo < hi) {
          final mid = (lo + hi) >> 1;
          if (_seqKey(_msgs[mid]) <= _seqKey(msg)) {
            lo = mid + 1;
          } else {
            hi = mid;
          }
        }
        _msgs.insert(lo, msg);
      });
      // 新消息来自对方：补报已读（旧实现只在进聊天页时上报一次，页面开着收到
      // 的新消息从不报已读 → 对方看到的永远是「已发送」，没有已读回执）。
      if (msg.senderId != _myUid) unawaited(_reportRead());
      // 同步进进程内历史缓存：下次打开该会话缓存直出时包含这条
      ConversationService.historyCacheAppend(widget.conv.id, m);
      // 只有用户本来就在底部才跟进（无动画）；正在翻历史就别打断他，
      // 由"↓回到最新"按钮提示有新消息
      if (wasAtBottom) _jumpToLatest();
    }
  }

  // ============================================================
  //  补拉（断点续传）与 seq 治理 —— T01 的核心
  // ============================================================

  /// 消息排序键：有 seq 用 seq；**没有 seq 的本地未确认气泡视为无穷大**。
  ///
  /// 修 R-24：旧代码一律 `(m.seq ?? 0)`，于是 sending 状态的本地气泡
  /// （服务端还没回 seq）key=0，会被 `_msgs.sort` 排到列表**最前**，
  /// 表现为「刚发的消息跑到聊天记录最上面」。且 Dart 的 `sort` **不稳定**，
  /// key 相等时顺序随机 —— 所以比较器必须给出全序（见 [_cmpMsg]）。
  // 哨兵用 2^53-1（JS Number 最大安全整数）：dart2js 无法精确表示 2^63-1 这类
  // 大字面量（build web 直接编译失败），而 seq 实际值远小于 2^53，做「无穷大」
  // 排序键语义完全等价（二十六批 H5 打包修复）。
  static const int _seqSentinel = 0x1FFFFFFFFFFFFF;
  static int _seqKey(ChatMsg m) => m.seq ?? _seqSentinel;

  /// 全序比较器（供 `_msgs.sort`）：
  ///   1. 已确认消息按 seq 升序；
  ///   2. seq 相同按 createdAt，再相同按 clientMsgId（消除 Dart sort 的不稳定性）；
  ///   3. 未确认的本地气泡（无 seq）永远排在最后。
  static int _cmpMsg(ChatMsg a, ChatMsg b) {
    final c = _seqKey(a).compareTo(_seqKey(b));
    if (c != 0) return c;
    final ta = _createdMs(a);
    final tb = _createdMs(b);
    if (ta != tb) return ta.compareTo(tb);
    return a.clientMsgId.compareTo(b.clientMsgId);
  }

  static int _createdMs(ChatMsg m) {
    final s = m.createdAt;
    if (s == null || s.isEmpty) return 0;
    return DateTime.tryParse(s)?.millisecondsSinceEpoch ?? 0;
  }

  /// 重排列表（替换所有裸 `_msgs.sort((a,b)=>(a.seq??0)...)` 调用）
  void _sortMsgs() => _msgs.sort(_cmpMsg);

  /// 空洞检测去抖：连着收到多条跳号消息时只补一次（避免 N 次补拉打爆服务端）
  void _scheduleGapPull() {
    _gapDebounce?.cancel();
    _gapDebounce = Timer(const Duration(milliseconds: 200), () {
      _gapDebounce = null;
      unawaited(_pullGap());
    });
  }

  /// 断点补拉：**循环分页，每页推进断点，直到补齐或达上限**。
  ///
  /// 旧实现（R-06/R-07）三个致命缺陷，这里逐一修掉：
  ///   1. 只拉一页 → 积压 >limit 时后面的永远拉不到；
  ///   2. 拉完不推进 `_lastSeq` → 每次重连重复拉同一批；
  ///   3. `_lastSeq` 从不初始化 → 从 0 拉，拉到的是最早一批。
  Future<void> _pullGap({bool force = false}) async {
    if (_pullingGap) return; // 重连风暴时不要叠加
    _pullingGap = true;
    try {
      // 最多 20 页 × 500 条 = 10000 条的硬上限，防死循环
      for (var page = 0; page < 20; page++) {
        if (!mounted) return;
        final start = _lastSeq;
        final r = await _svc.syncV2(widget.conv.id, start);
        if (!mounted) return;

        // 水位回退：服务端 seq 比我的断点还小 → 只能是服务端 Redis 丢过数据。
        // 这时继续按老断点拉将永远拉不到东西，必须重置。
        if (r.reset) {
          await _handleSeqReset(r.serverSeq);
          return;
        }

        if (r.list.isNotEmpty) {
          _mergeDedup(r.list);
          if (r.maxSeq > _lastSeq) _lastSeq = r.maxSeq;
        } else if (r.serverSeq > _lastSeq) {
          // 空洞里根本没有数据（seq 乱序落库，见 R-11）：
          // 服务端也没有 → 推进断点，否则每次重连都会重复探测这个永不存在的洞。
          _lastSeq = r.serverSeq;
        }
        await LocalStore.saveLastSeq(widget.conv.id, _lastSeq);

        if (!r.hasMore) break;
        if (_lastSeq <= start) break; // 没有推进 → 停，避免无限翻同一页
      }
    } catch (_) {
      // 补拉失败不影响页面（下次重连/回前台会再试）
    } finally {
      _pullingGap = false;
    }
  }

  /// 把补拉回来的原始消息合并进列表（按 msgId / clientMsgId 幂等去重）。
  /// 返回新增条数。
  int _mergeDedup(List<Map<String, dynamic>> raw) {
    if (raw.isEmpty) return 0;
    var added = 0;
    final wasAtBottom = _atBottom;
    final incoming = raw.map(ChatMsg.fromServer).toList()..sort(_cmpMsg);
    // 补拉进来的别人的新消息也要补报已读：_pullGap 覆盖「WS 丢帧/断线重连/
    // 切后台期间到达」的所有消息，这些消息只有这一条到达路径——漏报的话
    // 服务端 unread 计数不清零，退回会话列表红点又冒出来（"已读变未读"根因）。
    var peerAdded = false;
    final myUid = _myUid.trim();
    setState(() {
      for (final m in incoming) {
        final dup = _msgs.any((x) =>
            (m.msgId != null && m.msgId!.isNotEmpty && x.msgId == m.msgId) ||
            (m.clientMsgId.isNotEmpty && x.clientMsgId == m.clientMsgId));
        if (dup) continue;
        // 二分插入维持有序（列表可能上千条，插值 O(n) 挪动即可，不必全量 sort）
        var lo = 0, hi = _msgs.length;
        while (lo < hi) {
          final mid = (lo + hi) >> 1;
          if (_seqKey(_msgs[mid]) <= _seqKey(m)) {
            lo = mid + 1;
          } else {
            hi = mid;
          }
        }
        _msgs.insert(lo, m);
        added++;
        if (m.senderId.trim() != myUid) peerAdded = true;
      }
      if (added > 0) _sortMsgs();
    });
    if (added > 0 && wasAtBottom) _jumpToLatest();
    if (peerAdded) unawaited(_reportRead());
    for (final m in raw) {
      ConversationService.historyCacheAppend(widget.conv.id, m);
    }
    return added;
  }

  /// 服务端水位回退（Redis 丢数据/实例重建）→ 以服务端为准重建断点。
  ///
  /// 不做处理的话，用户会面对一个「静默不动」的会话却毫无线索。
  /// 这里重置断点并提示，让下一轮补拉从服务端真实水位继续。
  Future<void> _handleSeqReset(int serverSeq) async {
    _lastSeq = serverSeq > 0 ? serverSeq - 1 : 0;
    await LocalStore.saveLastSeq(widget.conv.id, _lastSeq);
    if (!mounted) return;
    _toast(_t('chatResyncing'));
    // 重置后再补一轮，把回退期间「客户端以为有了、服务端其实有更新」的部分拉回来
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (!mounted) return;
    unawaited(_pullGap());
  }

  // ============================================================
  //  发送看门狗 + 本地发件箱（T04：消除转圈 / 杀进程不丢）
  // ============================================================

  /// 起一个发送看门狗：15s 后若气泡仍是 sending，强制置 failed（可长按重试）。
  /// 兜住一切未知挂起（存储 hang、网络黑洞、服务端不返回……）。
  void _armWatchdog(String clientMsgId) {
    _cancelWatchdog(clientMsgId);
    _watchdogs[clientMsgId] = Timer(_sendWatchdog, () {
      _watchdogs.remove(clientMsgId);
      if (!mounted) return;
      setState(() {
        final i = _msgs.indexWhere((x) => x.clientMsgId == clientMsgId);
        if (i >= 0 && _msgs[i].status == MsgStatus.sending) {
          _msgs[i].status = MsgStatus.failed;
        }
      });
    });
  }

  void _cancelWatchdog(String clientMsgId) {
    _watchdogs.remove(clientMsgId)?.cancel();
  }

  /// 登记待确认消息到本地发件箱（杀进程后可恢复重发）。
  /// 红包/转账不入库：重发需要支付密码，只能交给用户手动重试（避免明文落盘）。
  void _trackPending(ChatMsg m) {
    if (m.type == 8 || m.type == 9) return;
    unawaited(LocalStore.appendOutbox(widget.conv.id, <String, dynamic>{
      'conversationId': widget.conv.id,
      'clientMsgId': m.clientMsgId,
      'type': m.type,
      'content': m.content,
      'replyTo': m.replyTo,
      if (m.file != null) 'file': m.file,
    }));
  }

  void _untrackPending(String clientMsgId) {
    unawaited(LocalStore.removeOutbox(widget.conv.id, clientMsgId));
  }

  /// 进页时扫描本地发件箱：把上次没发出去的消息重新提交。
  ///
  /// 复用同一个 clientMsgId → 服务端幂等：
  ///   - 已落库的：直接返回原消息 → 回填气泡为 sent（不重复插入）；
  ///   - 没落库的：真正补发一次。
  /// 这样「发送中杀进程」既不丢消息，也不会多发一条。
  Future<void> _resumeOutbox() async {
    final items = await LocalStore.loadOutbox(widget.conv.id);
    if (items.isEmpty || !mounted) return;
    for (final it in items) {
      if (!mounted) return;
      final cmid = it['clientMsgId']?.toString() ?? '';
      if (cmid.isEmpty) continue;
      if (_msgs.any((x) => x.clientMsgId == cmid)) {
        // 本地已经有了（比如上次已经画过气泡）→ 只补发
        if (!_msgs.any(
            (x) => x.clientMsgId == cmid && x.status == MsgStatus.sending)) {
          _untrackPending(cmid);
          continue;
        }
      } else {
        setState(() {
          _msgs.add(ChatMsg(
            clientMsgId: cmid,
            senderId: _myUid,
            type: (it['type'] as num?)?.toInt() ?? 1,
            content: it['content']?.toString() ?? '',
            status: MsgStatus.sending,
            replyTo: it['replyTo']?.toString(),
            file: (it['file'] is Map)
                ? (it['file'] as Map).cast<String, dynamic>()
                : null,
            createdAt: DateTime.now().toIso8601String(),
          ));
        });
      }
      _armWatchdog(cmid);
      _resendOne(cmid, it);
    }
  }

  /// 重发一条发件箱消息（幂等）
  Future<void> _resendOne(String cmid, Map<String, dynamic> it) async {
    try {
      final resp = await _svc.sendRaw(
        widget.conv.id,
        (it['type'] as num?)?.toInt() ?? 1,
        it['content']?.toString() ?? '',
        clientMsgId: cmid,
        replyTo: it['replyTo']?.toString(),
        file: (it['file'] is Map)
            ? (it['file'] as Map).cast<String, dynamic>()
            : null,
      );
      if (!mounted) return;
      _replaceLocalWithServer(resp, cmid);
    } catch (e) {
      if (!mounted) return;
      // 瞬时故障（超时/5xx/断网）保留在发件箱，下次进页再试；
      // 业务失败（禁言、非成员等）直接出箱，否则会无限重试一个注定失败的请求。
      if (!ApiClient.isTransient(e)) {
        _untrackPending(cmid);
      }
      setState(() {
        final i = _msgs.indexWhere((x) => x.clientMsgId == cmid);
        if (i >= 0 && _msgs[i].status == MsgStatus.sending) {
          _msgs[i].status = MsgStatus.failed;
        }
      });
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    // （2026-09-16：多图改为选完直发 [_pickImage → _sendImages]，
    //   「先图后文」的组合发送分支已删除，发送按钮只管文本/卡片。）
    _input.clear();

    final clientMsgId = _uuid();
    final q = _quoteMsg;
    setState(() {
      _quoteMsg = null;
      _plusOpen = false; // 发送后顺手收起「+」悬浮面板（可能开着）
      _emojiOpen = false;
    });

    // 链接转卡片（功能 B）：整段文本为单个 URL → 先拉 /link/meta，
    // 命中白名单（拿到 data）改发 type=11 卡片；403/429/网络错误降级普通文本 type=1。
    if (_isSingleUrl(text)) {
      // 裸域名（无 http:// 前缀）→ 自动补全后再请求 link_meta，
      // 否则 ssrf/whitelist.Match 都拿不到正确 host。
      final clean = text.replaceAll(_zws, '').trim();
      final url = _withProto.hasMatch(clean) ? text : 'http://$clean';
      final cardJson = await _fetchLinkCardJson(url);
      if (cardJson != null) {
        final bubble =
            _localMsg(MessageType.linkCard, cardJson, clientMsgId, q?.msgId);
        setState(() => _msgs.add(bubble));
        _armWatchdog(clientMsgId);
        _trackPending(bubble);
        _jumpToLatest(); // 自己发的消息：立即看得到（无动画）
        try {
          final resp = await _svc.sendRaw(
              widget.conv.id, MessageType.linkCard, cardJson,
              clientMsgId: clientMsgId, replyTo: q?.msgId);
          _replaceLocalWithServer(resp, clientMsgId);
        } catch (e) {
          _markLocalFailed(clientMsgId, transient: ApiClient.isTransient(e));
        }
        return;
      }
    }

    // E2EE 端到端加密（§36 定稿）：单聊 + 双方端到端就绪 → 加密为 type=13；
    // 任一条件不满足（未建钥/对方未开/后台模式非 e2ee）→ 降级普通文本 type=1。
    // 本地乐观气泡先存**明文**（渲染层对非 JSON content 直接显示），
    // 服务端回填后变密文 JSON，再由解密缓存渲染回明文。
    final convType = (widget.conv.conversation['type'] as num?)?.toInt() ?? 1;
    if (convType == 1 && !widget.conv.isAssistant) {
      final e2Content = await E2eeService.instance
          .encryptForChat(text, peerUid: widget.conv.peerId, myUid: _myUid);
      if (e2Content != null) {
        final e2Bubble =
            _localMsg(MessageType.e2Text, text, clientMsgId, q?.msgId);
        setState(() => _msgs.add(e2Bubble));
        _armWatchdog(clientMsgId);
        _trackPending(e2Bubble);
        _jumpToLatest();
        try {
          final resp = await _svc.sendRaw(
              widget.conv.id, MessageType.e2Text, e2Content,
              clientMsgId: clientMsgId, replyTo: q?.msgId);
          _replaceLocalWithServer(resp, clientMsgId, e2Plain: text);
        } catch (e) {
          _markLocalFailed(clientMsgId, transient: ApiClient.isTransient(e));
        }
        return;
      }
    }

    // 普通文本（type=1）
    final bubble = _localMsg(1, text, clientMsgId, q?.msgId);
    setState(() => _msgs.add(bubble));
    // 看门狗 + 本地发件箱：前者保证 15s 内一定终结（不永久转圈），
    // 后者保证发送中杀进程后重进能自动确认/补发（不丢消息）。
    _armWatchdog(clientMsgId);
    _trackPending(bubble);
    _jumpToLatest(); // 自己发的消息：立即看得到（无动画）
    try {
      // 引用必须带给服务端：否则服务器存的是普通消息，响应回填后引用卡片消失、
      // 对方/换设备也看不到引用（本地乐观消息只是先画出来，最终以服务端为准）
      final resp = await _svc.send(widget.conv.id, text,
          clientMsgId: clientMsgId, replyTo: q?.msgId);
      _replaceLocalWithServer(resp, clientMsgId);
    } catch (e) {
      // 失败原因要能显示真实文案（「你已被禁言」而不是笼统的「发送失败」）：
      // send/sendRaw 现在会把服务端 message 原样抛出来。
      _markLocalFailed(clientMsgId, transient: ApiClient.isTransient(e));
    }
  }

  /// 构造一条「发送中」本地乐观消息（type/content 由调用方决定）。
  ///
  /// createdAt 必填：没它的话排序比较器只能退回 clientMsgId 比较，
  /// 多条并发发送的气泡顺序会乱（见 [_cmpMsg]）。
  ChatMsg _localMsg(
          int type, String content, String clientMsgId, String? replyTo,
          {Map<String, dynamic>? file}) =>
      ChatMsg(
        clientMsgId: clientMsgId,
        senderId: _myUid,
        type: type,
        content: content,
        status: MsgStatus.sending,
        replyTo: replyTo,
        file: file,
        createdAt: DateTime.now().toIso8601String(),
      );

  /// 服务端成功响应回填：替换本地乐观消息 + 更新 seq + 落缓存 + 终结看门狗。
  void _replaceLocalWithServer(Map<String, dynamic> resp, String clientMsgId,
      {String? e2Plain}) {
    SoundService.instance.playMessageSent(); // 发送成功提示音
    _cancelWatchdog(clientMsgId);
    _untrackPending(clientMsgId);
    setState(() {
      final idx = _msgs.indexWhere((x) => x.clientMsgId == clientMsgId);
      if (idx >= 0) {
        final serverMsg = ChatMsg.fromServer(resp);
        // E2EE「无痕」（2026-09-18）：回显的密文首帧直接显示明文 ——
        // 把本地已知明文种进解密缓存，避免闪一下「加密消息 点按解锁」占位。
        final mid = serverMsg.msgId ?? '';
        if (e2Plain != null && mid.isNotEmpty) {
          E2eeService.instance.primePlain('s:$mid', e2Plain);
        }
        _msgs[idx] = serverMsg;
        final seqNow = (resp['seq'] as num?)?.toInt() ?? 0;
        if (seqNow > 0) {
          if (seqNow > _lastSeq) {
            _lastSeq = seqNow;
            unawaited(LocalStore.saveLastSeq(widget.conv.id, _lastSeq));
          }
        }
        // 修 R-24：旧写法 `(a.seq ?? 0)` 会把无 seq 的本地气泡排到最前
        _sortMsgs();
      }
    });
    ConversationService.historyCacheAppend(widget.conv.id, resp);
  }

  /// 发送失败：把本地乐观消息标记为 failed（可长按重试）。
  ///
  /// [transient] = true（网络/超时类）时**保留**在本地发件箱，下次进页自动重试；
  /// 业务失败（禁言、非成员…）则出箱，否则会反复重试一个注定失败的请求。
  void _markLocalFailed(String clientMsgId, {bool transient = true}) {
    _cancelWatchdog(clientMsgId);
    if (!transient) _untrackPending(clientMsgId);
    setState(() {
      final idx = _msgs.indexWhere((x) => x.clientMsgId == clientMsgId);
      if (idx >= 0) _msgs[idx].status = MsgStatus.failed;
    });
  }

  /// 整段文本是否为单个 URL（用于判断发送链接卡片）。
  /// 兼容三种形态：
  ///   1) 显式协议 http(s)://...（最强）
  ///   2) 裸域名 www.xxx.xxx / xxx.xxx.xxx（自动补 http:// 后再请求 link_meta）
  ///   3) 复制粘贴可能带的零宽字符（U+200B/200C/200D/FEFF），先剥再判
  static final RegExp _zws = RegExp(r'[\u200B-\u200D\uFEFF]');
  static final RegExp _withProto =
      RegExp(r'^https?://\S+$', caseSensitive: false);
  static final RegExp _bareHost = RegExp(
      r'^(?:www\.)?[a-zA-Z0-9][a-zA-Z0-9-]*(?:\.[a-zA-Z0-9][a-zA-Z0-9-]*)+$');

  bool _isSingleUrl(String s) {
    final clean = s.replaceAll(_zws, '').trim();
    if (clean.isEmpty) return false;
    return _withProto.hasMatch(clean) || _bareHost.hasMatch(clean);
  }

  /// 拉取链接元信息；命中白名单返回卡片 JSON，否则（403/429/网络错误/异常）返回 null 降级普通文本。
  Future<String?> _fetchLinkCardJson(String url) async {
    try {
      final card = await GroupFileService.instance.linkMeta(url);
      return card?.toJsonString();
    } catch (_) {
      return null;
    }
  }

  void _retry(ChatMsg m) async {
    final i = _msgs.indexOf(m);
    if (i < 0) return;
    // 文件消息元数据不完整（缺 object）时禁止重发（2026-09-24）：
    // 后端 buildConvFile 拿不到 object 不会写 conv_files → 消息能发出但
    // 没有 fileId，任何端都无封面、点开「暂不支持播放」。这种半截气泡只能
    // 删除重发（上传中断场景现已被看门狗后移消除，这里防御其他未知路径）。
    if (m.type == MessageType.file) {
      final object = ((m.file != null ? m.file!['object'] : '') ?? '')
          .toString();
      if (object.isEmpty) {
        _toast(_t('chatFileSendFailed', {'error': _t('chatFileNotSupported')}));
        return;
      }
    }
    setState(() => _msgs[i].status = MsgStatus.sending);
    _armWatchdog(m.clientMsgId);
    _trackPending(m);
    try {
      // 文本走 send（默认 type=1），其余类型（如失败重发 type=11 卡片）走 sendRaw
      final resp = m.type == 1
          ? await _svc.send(widget.conv.id, m.content,
              clientMsgId: m.clientMsgId, replyTo: m.replyTo)
          : await _svc.sendRaw(widget.conv.id, m.type, m.content,
              clientMsgId: m.clientMsgId,
              replyTo: m.replyTo,
              // 文件消息重发必须带上元数据，否则后端不写 conv_files（气泡也点不开预览）
              file: m.file);
      if (!mounted) return;
      _cancelWatchdog(m.clientMsgId);
      _untrackPending(m.clientMsgId);
      setState(() {
        if (i >= 0) _msgs[i] = ChatMsg.fromServer(resp);
      });
      ConversationService.historyCacheAppend(widget.conv.id, resp);
    } catch (e) {
      if (!mounted) return;
      _markLocalFailed(m.clientMsgId, transient: ApiClient.isTransient(e));
    }
  }

  /// 领取红包（拆红包浮层）/ 确认收款 → 记入零钱（微信交互对齐）
  Future<void> _claimMoney(ChatMsg m) async {
    final id = m.msgId;
    // 红包：先查后端详情（uniapp onRedPacketClick 同款分支）——
    // 自己领过 / 已领完 / 单聊自己发的 → 直接进详情页，不弹浮层；
    // 群聊自己发的也能领（后端允许），浮层只在可领取时出现。
    if (m.type == 8 && id != null && id.isNotEmpty) {
      Map<String, dynamic> d = {};
      try {
        d = await MomentService.instance.redPacketDetail(id);
      } catch (_) {}
      final list = ((d['list'] as List<dynamic>?) ?? []);
      final claimedCnt = (d['claimedCnt'] as num?)?.toInt() ?? 0;
      final count = (d['count'] as num?)?.toInt() ?? 1;
      final claimedByMe = list.any((c) => c['userId']?.toString() == _myUid);
      final claimedOut = claimedCnt >= count;
      final mineSent = m.senderId == _myUid;
      if (_claimedMoneyIds.contains(id) ||
          claimedByMe ||
          claimedOut ||
          (mineSent && !isGroup)) {
        _claimedMoneyIds.add(id);
        if (mounted) {
          // 上面的 redPacketDetail 已经拉过一次 → 直接透传秒开
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => RedPacketDetailPage(
                  msgId: id, initialDetail: d.isNotEmpty ? d : null)));
        }
        return;
      }
      // 可领取 → 拆红包浮层（ckao rp-mask 视觉），带上发送者/祝福语
      String note = '';
      try {
        final j = jsonDecode(m.content);
        if (j is Map) note = (j['note'] ?? '').toString();
      } catch (_) {}
      if (note.isEmpty) note = (d['note'] ?? '').toString();
      final senderName = (d['senderName'] ?? '').toString();
      final result = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierDismissible: false,
        barrierColor: Colors.white.withValues(alpha: 0.7),
        builder: (_) => _RedPacketOpenDialog(
          msgId: id,
          senderName: senderName.isNotEmpty
              ? senderName
              : _t('redPacketDetailDefaultSender'),
          senderAvatar: (d['senderAvatar'] ?? '').toString(),
          note: note,
        ),
      );
      if (!mounted || result == null) return;
      _claimedMoneyIds.add(id);
      final amt = (result['amount'] as num?)?.toDouble() ?? 0;
      // 领取接口已返回完整 detail → 透传给详情页秒开（不再转圈二次请求），
      // 钱包刷新与会话页重建挪到转场之后，消除自领红包时的掉帧卡顿
      final prefetched = (result['detail'] as Map?)?.cast<String, dynamic>();
      if (result['claimed'] == true) {
        // uniapp 同款：领取成功 toast 后进领取详情页
        AppDialogs.toast(
            context,
            _t('chatSavedToWalletAmount',
                {'amount': WalletStore.instance.fmt(amt)}));
      }
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) =>
              RedPacketDetailPage(msgId: id, initialDetail: prefetched)));
      // 重活放在转场启动之后：下一帧列表重建发生在详情页之下，不挡动画
      WalletStore.instance.refresh();
      if (mounted) setState(() {});
      return;
    }
    if (id != null && _claimedMoneyIds.contains(id)) {
      AppDialogs.toast(context, _t('chatAlreadyClaimed'));
      return;
    }
    Map<String, dynamic> data = {};
    try {
      final j = jsonDecode(m.content);
      if (j is Map) data = j.cast<String, dynamic>();
    } catch (_) {}
    final amount = (data['amount'] as num?)?.toDouble() ??
        (double.tryParse(m.content) ?? 0);
    if (amount <= 0) {
      AppDialogs.toast(context, _t('chatInvalidAmount'));
      return;
    }
    // 转账：仅收款人可领
    {
      final toId = (data['toUserId'] ?? '').toString();
      if (toId.isNotEmpty && toId != _myUid) {
        AppDialogs.toast(context, _t('chatWaitingAccept'));
        return;
      }
      if (toId.isEmpty && m.senderId == _myUid) {
        AppDialogs.toast(context, _t('chatWaitingAccept'));
        return;
      }
      final claimed = await showDialog<bool>(
        context: context,
        builder: (_) => _TransferConfirmDialog(amount: amount),
      );
      if (claimed != true || !mounted) return;
    }
    if (id != null) _claimedMoneyIds.add(id);
    // 收款改走服务端交叉校验接口（B-21）：金额由服务端按转账消息内容核算，
    // 客户端不再上报金额，也不能靠清缓存反复领同一笔转账。
    final res = await WalletStore.instance.acceptTransfer(id ?? '');
    if (!mounted) return;
    if (res == null) {
      if (id != null) _claimedMoneyIds.remove(id); // 允许重试
      // 用后端真实原因：可能是「超过 24 小时未领取已退回」「已被他人领取」等
      AppDialogs.toast(
          context,
          WalletStore.instance.lastError.isNotEmpty
              ? WalletStore.instance.lastError
              : _t('chatAcceptFailedRetry'));
      return;
    }
    final got = (res['amount'] as num?)?.toDouble() ?? amount;
    final already = res['already'] == true;
    AppDialogs.toast(
        context,
        already
            ? _t('chatTransferClaimedBefore')
            : _t('chatSavedToWalletAmount',
                {'amount': WalletStore.instance.fmt(got)}));
    await WalletStore.instance.refresh();
    setState(() {});
  }

  /// 红包/转账：独立页面（微信群流程对齐）→ 发送 type=8/9
  Future<void> _openMoneyPage(String kind) async {
    // 防御：后台已关闭零钱时，入口隐藏但历史入口仍可能触发 → 拦截
    if (!FeatureFlags.instance.walletOn.value) return;
    // 支付密码闸门（前端第一道）：未设置 → 提示去设置，不进入红包/转账页
    if (UserCache.myProfileData?['payPwdSet'] != true) {
      await _promptSetPayPwd();
      return;
    }
    final isRed = kind == 'redpacket';
    Map<String, dynamic>? payload;
    if (isRed) {
      payload = await Navigator.of(context).push<Map<String, dynamic>>(
        MaterialPageRoute(builder: (_) => RedPacketPage(isGroup: isGroup)),
      );
    } else {
      String peerName = widget.conv.conversationName;
      String? peerId;
      if (isGroup) {
        // 群聊：先选收款人
        if (_members.isEmpty) {
          try {
            _members = await _svc.members(widget.conv.id);
          } catch (_) {}
        }
        final picked = await Navigator.of(context).push<Map<String, dynamic>>(
          MaterialPageRoute(
              builder: (_) =>
                  GroupMemberPickerPage(members: _members, myId: _myUid)),
        );
        if (picked == null || !mounted) return;
        peerId = picked['id']?.toString();
        peerName = (picked['nickname'] ?? picked['name'] ?? _t('chatMember'))
            .toString();
      }
      payload = await Navigator.of(context).push<Map<String, dynamic>>(
        MaterialPageRoute(
            builder: (_) => TransferPage(peerName: peerName, peerId: peerId)),
      );
    }
    if (payload == null || !mounted) return;
    final amount = (payload['amount'] as num?)?.toDouble() ?? 0;
    if (amount <= 0) return;

    // 组装消息负载
    final contentData = <String, dynamic>{
      'kind': isRed ? 'redpacket' : 'transfer',
      'amount': amount,
      'note': payload['note'] ?? '',
    };
    if (isRed) {
      contentData['mode'] = payload['mode'] ?? 'normal';
      contentData['count'] = payload['count'] ?? 1;
    } else {
      contentData['toUserId'] = payload['toUserId'] ?? '';
      contentData['toName'] = payload['toName'] ?? '';
    }

    // ===== 交叉验证第一道：发出去之前再查一次真实余额 =====
    // 页面里填金额时看到的余额可能是几十秒前的（后台刚调整过、或刚领了个红包），
    // 所以这里必须重新拉一次再比一次。后端发消息时还会再校验一次（第二道）。
    await WalletStore.instance.refresh();
    if (!mounted) return;
    final need = isRed
        ? ((payload['mode'] == 'lucky')
            ? amount
            : amount * ((payload['count'] as num?)?.toInt() ?? 1))
        : amount;
    final bal = WalletStore.instance.balance;
    if (need > bal) {
      AppDialogs.toast(
          context,
          _t('chatInsufficientBalanceNeed', {
            'need': WalletStore.instance.fmt(need),
            'bal': WalletStore.instance.fmt(bal),
          }));
      return;
    }
    // 支付密码：优先用红包/转账页已在「当前窗口」采集的密码；
    // 兜底再在会话页弹（正常流程不会走到这里，防历史入口绕开红包/转账页）
    final payPwdTitle = _t('payPwdInputTitle');
    String? payPwd = payload['payPassword'] as String?;
    if (payPwd == null || payPwd.isEmpty) {
      payPwd = await PayPwdInputSheet.show(context, title: payPwdTitle);
    }
    if (payPwd == null || !mounted) return; // 用户取消

    // 发送（本地乐观插入）
    final clientMsgId = _uuid();
    setState(() {
      _msgs.add(ChatMsg(
        clientMsgId: clientMsgId,
        senderId: _myUid,
        type: isRed ? 8 : 9,
        content: jsonEncode(contentData),
        status: MsgStatus.sending,
        // createdAt 必填：否则无 seq 的乐观气泡在排序里退回 clientMsgId 比较
        createdAt: DateTime.now().toIso8601String(),
      ));
    });
    _armWatchdog(clientMsgId); // 红包/转账同样不能永久转圈
    _jumpToLatest(); // 自己发的红包/转账：立即看得到（无动画）

    // 循环：密码错误（4302）时重新弹窗输入重发；其他错误按原逻辑处理
    bool sent = false;
    while (!sent) {
      try {
        final resp = await _svc.sendMoney(
            widget.conv.id, isRed ? 8 : 9, contentData,
            clientMsgId: clientMsgId, payPassword: payPwd);
        if (!mounted) return;
        _cancelWatchdog(clientMsgId);
        setState(() {
          final idx = _msgs.indexWhere((x) => x.clientMsgId == clientMsgId);
          if (idx >= 0) {
            _msgs[idx] = ChatMsg.fromServer(resp);
            final seqNow = (resp['seq'] as num?)?.toInt() ?? 0;
            if (seqNow > _lastSeq) {
              _lastSeq = seqNow;
              unawaited(LocalStore.saveLastSeq(widget.conv.id, _lastSeq));
            }
            _sortMsgs(); // 修 R-24（旧写法会把无 seq 的本地气泡排到最前）
          }
        });
        // 扣款已由**后端**在消息落库前原子完成（service.SendMoneyCharge），
        // 前端绝不能再调 debit() 记一次，否则扣两次钱（B-19）。这里只刷新余额。
        WalletStore.instance.refresh();
        // 成功 toast 移到这里：确认弹窗后真正发送成功才提示（原来在发红包页
        // 一确认就弹，发送失败时也会误报成功）
        AppDialogs.toast(context, _t('rpSentToast'));
        sent = true;
      } catch (e) {
        if (!mounted) return;
        // sendMoney 现在抛 ApiException，优先用 **错误码** 判定（比匹配文案可靠）；
        // 老后端抛普通 Exception 时仍回落到文案匹配。
        final code = e is ApiException ? e.code : 0;
        final msg = e is ApiException ? e.message : e.toString();
        final wrong = code == 4302 || msg.contains('支付密码错误');
        final notSet = code == 4301 || msg.contains('请先设置支付密码');
        if (wrong) {
          // 密码错误：保留乐观气泡（仍 sending），重新弹窗输入
          final retry = await PayPwdInputSheet.show(context,
              title: payPwdTitle, error: _t('payPwdWrong'));
          if (retry == null) {
            // 用户放弃：撤掉未发出的气泡
            _revertUnsentMoney(clientMsgId);
            return;
          }
          payPwd = retry;
          continue;
        } else if (notSet) {
          // 极端情况：未设置却放行（缓存与实际不一致）→ 提示去设置
          await _promptSetPayPwd();
          _revertUnsentMoney(clientMsgId);
          return;
        }
        // 余额不足 / 参数错误等其他错误：消息根本没发出去，
        // 直接撤掉乐观插入的气泡，别留个"失败"在会话里
        final insufficient =
            code == 4101 || msg.contains('余额不足') || msg.contains('4101');
        setState(() {
          final idx = _msgs.indexWhere((x) => x.clientMsgId == clientMsgId);
          if (idx >= 0) {
            if (insufficient) {
              _msgs.removeAt(idx);
            } else {
              _msgs[idx].status = MsgStatus.failed;
            }
          }
        });
        if (insufficient) {
          AppDialogs.toast(context, _t('chatInsufficientSendFailed'));
        } else {
          AppDialogs.toast(context, _errMsg(e, _t('chatSendFailed')));
        }
        // 兜底：把后端的最新余额拉回来，避免本地还是旧值
        WalletStore.instance.refresh();
        sent = true; // 跳出循环
      }
    }
  }

  /// 撤掉尚未真正发出的红包/转账乐观气泡（用户取消输入 / 未设置支付密码）
  void _revertUnsentMoney(String clientMsgId) {
    _cancelWatchdog(clientMsgId);
    if (!mounted) return;
    setState(() {
      final idx = _msgs.indexWhere((x) => x.clientMsgId == clientMsgId);
      if (idx >= 0) _msgs.removeAt(idx);
    });
  }

  /// 未设置支付密码 → 弹窗提示并跳转到设置页
  Future<void> _promptSetPayPwd() async {
    final go = await AppDialogs.confirm(
      context,
      title: _t('payPwdNotSetTitle'),
      message: _t('payPwdNotSetTip'),
      confirmText: _t('payPwdGoSet'),
    );
    if (go == true && mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const PayPwdSetupPage()),
      );
    }
  }

  /// 无动画跳到最新一条（自己发消息、收到新消息且本来就在底部）。
  /// 用 jumpTo 而不是 animateTo —— 用户不该看到"列表自己滚一遍"。
  void _jumpToLatest() {
    // 收敛期同一帧可能触发多次（每修正一次尺寸一次），只安排一次即可
    if (_jumpScheduled) return;
    _jumpScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpScheduled = false;
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  /// 平滑滚到最新（只有用户主动点"↓回到最新"才需要动画）
  void _animateToLatest() {
    _stickActive = true; // 用户主动回到底部：恢复贴底意图
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    });
  }

  /// 上拉加载更早历史：以当前最旧一条为游标往回拉，prepend 到列表开头。
  ///
  /// 关键：正序列表 prepend 会让内容整体下移，若不补偿，用户眼前的消息会
  /// 突然跳走。这里记录加载前后的 maxScrollExtent 差值，把 pixels 加上去，
  /// 视觉位置完全不动（这就是"正序 + 补偿"相对 reverse 唯一多出来的几行）。
  Future<void> _loadOlder() async {
    if (_loadingOlder || _msgs.isEmpty) return;
    // ---- 2026-09-20 首屏裁剪配套：先挂载本地攒下的更早消息（零请求） ----
    // _pendingOlder 按旧→新排列；每次取「最新的一批」（恰好接在当前首条上面）
    // prepend，视觉连续；挂完队列空了再走服务端分页。
    if (_pendingOlder.isNotEmpty) {
      _loadingOlder = true;
      final beforeExtent =
          _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
      final n = _pendingOlder.length > _firstScreenCount
          ? _firstScreenCount
          : _pendingOlder.length;
      final batch = _pendingOlder.sublist(_pendingOlder.length - n);
      _pendingOlder.removeRange(_pendingOlder.length - n, _pendingOlder.length);
      setState(() => _msgs.insertAll(0, batch));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final delta = _scroll.position.maxScrollExtent - beforeExtent;
        if (delta > 0) _scroll.jumpTo(_scroll.position.pixels + delta);
      });
      _loadingOlder = false;
      return;
    }
    if (!_hasMoreOlder) return;
    // 游标取"最旧一条且已有服务端 msgId"的消息（乐观插入的本地消息没有 msgId）
    String? cursor;
    for (final m in _msgs) {
      final id = m.msgId;
      if (id != null && id.isNotEmpty) {
        cursor = id;
        break;
      }
    }
    if (cursor == null) return;

    setState(() => _loadingOlder = true);
    final beforeExtent =
        _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
    try {
      final list = await _svc.history(widget.conv.id, beforeMsgId: cursor);
      if (!mounted) return;
      if (list.isEmpty) {
        setState(() {
          _hasMoreOlder = false;
          _loadingOlder = false;
        });
        return;
      }
      final known = _msgs.map((m) => m.msgId).whereType<String>().toSet();
      final older = list
          .map(ChatMsg.fromServer)
          .where((m) => m.msgId == null || !known.contains(m.msgId))
          .toList();
      setState(() {
        _msgs.insertAll(0, older);
        _loadingOlder = false;
        // 服务端 limit 是 80，返回不足 80 说明到头了
        if (list.length < 80) _hasMoreOlder = false;
      });
      // 补偿偏移：让 prepend 前的那条消息仍停在同一位置
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final delta = _scroll.position.maxScrollExtent - beforeExtent;
        if (delta > 0) {
          _scroll.jumpTo(_scroll.position.pixels + delta);
        }
      });
    } catch (_) {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  /// 跳转到指定消息：多轮收敛探测。
  /// 估算 offset 不可靠（行高差异大，误差可达一屏），且 ListView 懒加载下
  /// 目标 item 未布局时拿不到坐标。所以：先按估算跳到大致范围，然后循环
  /// 探测——目标行已布局 → 用真实屏幕坐标差值法精确补滚到位；未布局 →
  /// 朝目标索引方向步进一屏继续找（最多 8 轮，覆盖数屏距离）。
  /// 引用/置顶跳转：**锚点收敛**定位（返回是否成功落位）。
  ///
  /// 难点：ListView 懒加载下远处 item 未布局，GlobalKey 拿不到坐标；
  /// 逐屏步进探测会疯狂闪烁且轮数有限、远距离永远走不到。
  /// 解法：**任何已布局的行都能用 GlobalKey 拿到精确位置** →
  /// 每轮找"离目标索引最近的已布局行"当锚点，按它反推目标位置直接跳过去。
  /// 距离无关、通常 2~3 跳收敛（首跳估算 → 锚点精修 → 差值落位），不再逐屏闪。
  Future<bool> _scrollToMsg(String msgId) async {
    if (_msgs.isEmpty || !_scroll.hasClients) return false;
    final i = _msgs.indexWhere((m) => m.msgId == msgId);
    if (i < 0) return false;
    const wantY = 120.0; // 落点：AppBar 下方 120px

    RenderBox? boxOf(int idx) {
      final ctx = _rowKeyFor(_msgs[idx].clientMsgId).currentContext;
      if (ctx == null) return null;
      final ro = ctx.findRenderObject();
      if (ro is! RenderBox || !ro.attached || !ro.hasSize) return null;
      return ro;
    }

    // 首跳：按索引估算（均高 72px），先把目标附近拉进布局树
    final est = (i * 72.0).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.jumpTo(est);

    for (var round = 0; round < 10; round++) {
      await Future.delayed(const Duration(milliseconds: 40));
      if (!mounted || !_scroll.hasClients) return false;

      // ① 目标行已布局 → 屏幕坐标差值法精确落位，结束
      final tb = boxOf(i);
      if (tb != null) {
        final screenY = tb.localToGlobal(Offset.zero).dy;
        final dest = (_scroll.offset + (screenY - wantY))
            .clamp(0.0, _scroll.position.maxScrollExtent);
        await _scroll.animateTo(dest,
            duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
        return true;
      }

      // ② 找离目标索引最近的已布局行（锚点）
      int? j;
      RenderBox? ab;
      var best = 1 << 30;
      for (var k = 0; k < _msgs.length; k++) {
        if ((k - i).abs() >= best) continue;
        final b = boxOf(k);
        if (b == null) continue;
        best = (k - i).abs();
        j = k;
        ab = b;
      }
      if (j == null || ab == null) return false;

      // 锚点精确落位到 wantY，再按索引差外推目标位置（下一轮 ① 会做最终修正）
      final anchorY = ab.localToGlobal(Offset.zero).dy;
      final dest = (_scroll.offset + (anchorY - wantY) + (i - j) * 72.0)
          .clamp(0.0, _scroll.position.maxScrollExtent);
      if ((dest - _scroll.offset).abs() < 8) return false; // 无法再收敛
      _scroll.jumpTo(dest);
    }
    return false;
  }

  /// 跳转高亮中的消息 msgId（引用条/置顶条点击 → 滚到原消息并短暂发光）
  String? _jumpHighlightId;

  /// 点击引用条：滚动到被引用消息 + 1.5s 高亮；消息不在本地时提示。
  /// 必须先解除贴底意图：点引用时用户通常正在底部（_stickActive=true），
  /// 否则 animateTo 一动就触发 ScrollMetricsNotification 被贴底逻辑拉回，
  /// 表现为"跳了一下还在原地"。
  void _jumpToReply(String msgId) {
    if (msgId.isEmpty) return;
    if (!_msgs.any((m) => m.msgId == msgId)) {
      _toast(_t('chatPinnedNotFound'));
      return;
    }
    _stickActive = false;
    // 高亮等"落位成功"再开始计时：飞行途中就开始的话，
    // 远距离跳转落位时 1.5s 高亮已过期，用户看不到发光
    _scrollToMsg(msgId).then((landed) {
      if (!mounted || !landed) return;
      setState(() => _jumpHighlightId = msgId);
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted && _jumpHighlightId == msgId) {
          setState(() => _jumpHighlightId = null);
        }
      });
    });
  }

  /// 置顶消息跳转（修复：点击置顶提示「该消息已不在聊天记录中」不跳转）。
  ///
  /// 根因：进入会话只加载最近一页历史，置顶的常是窗口之外的老消息，
  /// _jumpToReply 在内存列表找不到就直接走了「不在聊天记录」分支。
  /// 现在找不到时先以目标 msgId 为游标拉一页历史（服务端返回 ≤ 该 msgId
  /// 的最近 80 条，目标本身包含在内），去重排序合并进列表后再跳：
  /// - 目标比当前窗口更老 → 拉回的页补上缺口（含目标）；
  /// - 目标比窗口最新还新（刚被置顶、本地未同步）→ 拉回的页含目标本身。
  /// 仍找不到再补一轮增量 sync 兜底；最后才提示「该消息已不在聊天记录中」
  /// （真被删除/撤回的场景，原提示保留）。
  /// 注意：这里不走 _mergeDedup——它会在贴底时 postFrame 跳回最新，
  /// 与随后的定位跳转相互打架（收敛首跳会被覆盖）；本地合并不做吸底补偿，
  /// 因为 _jumpToReply 会同步解除贴底意图并立刻定位。
  Future<void> _jumpToPinnedMsg(String msgId) async {
    bool loaded() => _msgs.any((m) => m.msgId == msgId);
    if (loaded()) {
      _jumpToReply(msgId);
      return;
    }
    try {
      // 2026-09-29 修复根因：服务端 History 的 beforeMsgID 是 **$lt（严格小于）**，
      // 直传目标 msgId 会把目标本身排除在返回之外——注释里写的「目标包含在内」
      // 与服务端实现不符，导致老消息置顶点击必现「已不在聊天记录中」。
      // 雪花 msgId 是 int64，传 msgId+1 让 $lt 变成事实上的 ≤，目标包含。
      // （上翻加载更早历史仍用原始 beforeMsgId 的排他语义，两端约定不变）
      final bid = int.tryParse(msgId);
      final page = await _svc.history(widget.conv.id,
          beforeMsgId: bid != null ? '${bid + 1}' : msgId);
      if (mounted && page.isNotEmpty) {
        final known = _msgs.map((m) => m.msgId).whereType<String>().toSet();
        final fresh = page
            .map(ChatMsg.fromServer)
            .where((m) => m.msgId == null || !known.contains(m.msgId))
            .toList();
        if (fresh.isNotEmpty) {
          setState(() {
            _msgs.addAll(fresh);
            _sortMsgs();
            // 返回不足一页说明目标之前已无更早历史
            if (page.length < 80) _hasMoreOlder = false;
          });
        }
      }
    } catch (_) {
      // 取数失败：下面 sync 再试一次，仍失败按「不在记录」提示
    }
    if (loaded()) {
      _jumpToReply(msgId);
      return;
    }
    // 兜底：目标比本地断点还新（历史端点没给）→ 补一轮增量 sync 再找
    await _pullGap();
    if (!mounted) return;
    if (loaded()) {
      _jumpToReply(msgId);
    } else {
      _toast(_t('chatPinnedNotFound'));
    }
  }

  String _uuid() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(99999)}';

  String _time(String? iso) {
    if (iso == null) return '';
    DateTime? dt;
    try {
      // 服务端下发的是 UTC（RFC3339 带 Z），必须转本地时区再取时:分——
      // 旧实现直接取 .hour/.minute，东八区显示成 UTC 时刻（21:31 显示成 13:31）
      dt = DateTime.parse(iso).toLocal();
    } catch (_) {
      return '';
    }
    final now = DateTime.now();
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '$h:$m';
    }
    return '${dt.month}/${dt.day} $h:$m';
  }

  /// 完整时间（消息之间的时间分隔条用）
  String _fullTime(String? iso) {
    if (iso == null) return '';
    DateTime? dt;
    try {
      dt = DateTime.parse(iso).toLocal();
    } catch (_) {
      return '';
    }
    final now = DateTime.now();
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '$h:$m';
    }
    final yesterday = now.subtract(const Duration(days: 1));
    if (dt.year == yesterday.year &&
        dt.month == yesterday.month &&
        dt.day == yesterday.day) {
      return _t('chatYesterdayAt', {'time': '$h:$m'});
    }
    if (dt.year == now.year) {
      return _t('chatDateThisYear',
          {'month': '${dt.month}', 'day': '${dt.day}', 'time': '$h:$m'});
    }
    return _t('chatDateFull', {
      'year': '${dt.year}',
      'month': '${dt.month}',
      'day': '${dt.day}',
      'time': '$h:$m',
    });
  }

  /// 与上一条间隔超过 5 分钟才显示时间分隔条
  bool _needTimeDivider(int i) {
    if (i == 0) return true;
    final prev = _msgs[i - 1].createdAt;
    final cur = _msgs[i].createdAt;
    if (prev == null || cur == null) return false;
    final a = DateTime.tryParse(prev);
    final b = DateTime.tryParse(cur);
    if (a == null || b == null) return false;
    return b.difference(a).inMinutes.abs() >= 5;
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    AppSettings.instance.removeListener(_onChatSettingsChanged);
    // 注销在 GlobalWs 上注册的监听器（不关闭全局连接，它仍被会话列表等共用）
    for (final off in _wsOffs) {
      off();
    }
    _wsOffs.clear();
    // 看门狗与补拉去抖定时器必须取消：否则页面销毁后仍会触发 setState
    for (final t in _watchdogs.values) {
      t.cancel();
    }
    _watchdogs.clear();
    _gapDebounce?.cancel();
    _gapDebounce = null;
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 2026-09-28：群聊「…」弹层菜单（参考图1 Telegram 同款）。
  /// 返回语义：管理群组页 pop('disbanded') → 本页 pop(true) 退出会话；
  /// pop(新群名) → _overrideName 跟随。
  Future<void> _showGroupMenu() async {
    final t = _t;
    final rows = <Widget>[
      _groupMenuRow(Icons.person_add_alt_1_outlined, t('groupInviteBtn'), () async {
        Navigator.of(context).pop();
        await GroupMembersPage.inviteFriends(context, widget.conv);
      }),
      _groupMenuRow(Icons.photo_library_outlined, t('groupMenuMedia'), () {
        Navigator.of(context).pop();
        // 2026-09-29 查看媒体改按消息扫描（原群文件云盘页查不到聊天图片）
        Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => GroupMediaPage(
                convId: widget.conv.id,
                convName: widget.conv.conversationName)));
      }),
      _groupMenuRow(Icons.star_border, t('groupMenuFavorites'), () {
        Navigator.of(context).pop();
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const FavoritesPage()));
      }),
      _groupMenuRow(Icons.search, t('groupMenuSearch'), () async {
        Navigator.of(context).pop();
        // 2026-09-29 会话内搜索：只搜本会话聊天记录；结果点击回传 msgId 原地跳转
        final msgId = await Navigator.of(context).push<String>(
          MaterialPageRoute(
              builder: (_) => SearchPage(
                  convId: widget.conv.id,
                  convName: widget.conv.conversationName)),
        );
        if (!mounted || msgId == null || msgId.isEmpty) return;
        _jumpToPinnedMsg(msgId);
      }),
      _groupMenuRow(Icons.lock_outline, t('groupMenuProtect'), () {
        Navigator.of(context).pop();
        AppDialogs.toast(context,
            t('convSetComingSoon', {'name': t('groupMenuProtect')}));
      }),
    ];
    if (_myRole == 1) {
      rows.add(_groupMenuRow(Icons.settings_outlined, t('groupMenuManage'),
          () async {
        Navigator.of(context).pop();
        final result = await Navigator.of(context).push<String>(
          MaterialPageRoute(builder: (_) => GroupEditPage(conv: widget.conv)),
        );
        if (!mounted) return;
        if (result == 'disbanded') {
          Navigator.of(context).pop(true);
        } else if (result != null && result.isNotEmpty) {
          setState(() => _overrideName = result);
        }
      }));
    } else {
      rows.add(_groupMenuRow(Icons.logout, t('convSetExitGroupTitle'), () async {
        Navigator.of(context).pop();
        final ok = await AppDialogs.confirm(context,
            title: t('convSetExitGroupTitle'),
            message: t('convSetExitGroupMsg'),
            confirmText: t('convSetExitConfirm'),
            danger: true);
        if (ok != true || !mounted) return;
        final done = await ConversationService().quit(widget.conv.id);
        if (done && mounted) Navigator.of(context).pop(true);
      }, danger: true));
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Container(
          margin: const EdgeInsets.all(10),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: ctx.cs.surface,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: rows),
        ),
      ),
    );
  }

  /// 菜单行（图标 + 文字，TG 图1 同款；[danger] 红字）
  Widget _groupMenuRow(IconData icon, String label, VoidCallback onTap,
      {bool danger = false}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        child: Row(children: [
          Icon(icon,
              size: 22,
              color: danger ? const Color(0xFFE5484D) : context.cs.onSurface),
          const SizedBox(width: 14),
          Text(label,
              style: TextStyle(
                  fontSize: 15,
                  color: danger
                      ? const Color(0xFFE5484D)
                      : context.cs.onSurface)),
        ]),
      ),
    );
  }

  /// 右上角「…」（2026-09-15 第二十批更新）：
  /// * 单聊 → 直进 V2 好友资料页（`FriendDetailPage.fromConv`，用户要求聊天
  ///   右上角进来的是新资料页而非会话设置）；资料页内「删除好友/拉黑」成功
  ///   仍 pop(true)，聊天页收到后退出会话（与原 ConvSettingsPage 行为一致）。
  /// * 群聊 → 保持 `ConvSettingsPage`（顶部资料头已换成 V2 新资料页风格）。
  /// * 频道（二十批）→ `ChannelProfilePage`（Telegram 式频道资料页：头像/
  ///   订阅数/静音搜索瓦片/简介/媒体四行/分享频道；**无举报项**，参考图
  ///   Screenshot_2026_0914_183516.jpg）。原 ConvSettingsPage 频道分支的
  ///   能力全部保留：频道 ID 复制、清空聊天记录（…菜单）、退出频道（页尾）、
  ///   分享名片（kind=channel 契约不变）。
  Future<void> _openSettings() async {
    // 2026-09-28 需求：群聊「…」改为图1 弹层菜单（查看媒体/收藏/搜索/消息保护，
    // 群主多「管理群组」，普通成员红字「退出群聊」）；成员看群资料走标题点击。
    if (isGroup && !isChannel) {
      await _showGroupMenu();
      if (mounted && isGroup) unawaited(_loadPins());
      return;
    }
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => isChannel
            ? ChannelProfilePage(conv: widget.conv)
            : FriendDetailPage.fromConv(
                conv: widget.conv, myId: widget.myId),
      ),
    );
    if (changed == true && mounted) {
      Navigator.of(context).pop(true);
      return;
    }
    // 需求2（2026-09-22 三批）：从聊天信息页返回后重拉置顶条——群主可能
    // 在里面取消了置顶，聊天窗口的置顶条必须以服务端为准立即同步
    if (mounted && isGroup) unawaited(_loadPins());
  }

  /// 需求11：发起语音/视频通话
  /// 群聊 → startGroupCall（全员邀请，GroupCallPage 宫格）；单聊 → startCall
  /// 先发 invite 信令，再打开通话页（页面会等对方 accept 才进房）
  Future<void> _openCall(String type) async {
    if (CallService.instance.state.value != null) {
      AppDialogs.toast(context, _t('chatCallInProgress'));
      return;
    }
    // 拨打前先申请权限（2026-09-19 iOS 修复）：TRTC 插件不主动弹权限，
    // 原先进房才申请——iOS 首次弹窗被拒（永久拒绝后系统不再弹）时摄像头
    // 静默失败 = 自己没画面。提前到拨号动作时申请，被永久拒绝则引导去设置。
    if (type == 'video') {
      final perms = await CallPermissions.ensureForVideoSplit();
      if (!perms.mic) {
        if (!mounted) return;
        AppDialogs.toast(context, _t('videoCallNeedPermissions'));
        return;
      }
      if (!perms.cam) {
        if (!kIsWeb) {
          final st = await Permission.camera.status;
          if (st.isPermanentlyDenied && mounted) {
            final go = await AppDialogs.confirm(
              context,
              title: _t('callPermCamTitle'),
              message: _t('callPermCamMsg'),
              confirmText: _t('scanCamOpenSettings'),
            );
            if (go == true) await CallPermissions.openSettings();
          }
        }
        if (mounted) {
          AppDialogs.toast(context, _t('videoCallCamFallback'));
        }
      }
    } else {
      final ok = await CallPermissions.ensureForVoice();
      if (!ok) {
        if (!mounted) return;
        AppDialogs.toast(context, _t('videoCallNeedPermissions'));
        return;
      }
    }
    if (isGroup) {
      await CallService.instance.startGroupCall(
        convId: widget.conv.id,
        callType: type,
        groupName: widget.conv.conversationName,
        groupAvatar: widget.conv.avatarUrl,
      );
      if (!mounted) return;
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const GroupCallPage()));
      return;
    }
    await CallService.instance.startCall(
      convId: widget.conv.id,
      callType: type,
      peerName: widget.conv.conversationName,
      peerAvatar: widget.conv.avatarUrl,
    );
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => type == 'video'
            ? VideoCallPage(
                peerName: widget.conv.conversationName,
                peerAvatar: widget.conv.avatarUrl,
                convId: widget.conv.id)
            : VoiceCallPage(
                peerName: widget.conv.conversationName,
                peerAvatar: widget.conv.avatarUrl,
                convId: widget.conv.id)));
  }

  /// 点击通话气泡：invite 重新进入通话；已定型的通话记录（hangup/reject 等）  /// 点击**直接重拨对应类型**——视频记录→视频通话、语音记录→语音通话
  ///（2026-09-21 需求，对齐微信通话记录可回拨的交互）。
  void _openCallFromSignal(String content) {
    var type = 'voice';
    try {
      final map = jsonDecode(content);
      if (map is Map && map['callType'] == 'video') type = 'video';
    } catch (_) {}
    _openCall(type);
  }

  /// 「+」面板 → 位置（2026-09-21 需求1）：打开谷歌地图选点页，
  /// 返回 {lat,lng,name,address} 后按 type=14 发送（乐观气泡 + sendRaw）。
  Future<void> _pickLocation() async {
    final picked = await Navigator.of(context).push<Map<String, dynamic>>(
        MaterialPageRoute(builder: (_) => const LocationPickerPage()));
    if (picked == null || !mounted) return;
    final lat = (picked['lat'] as num?)?.toDouble() ??
        double.tryParse(picked['lat']?.toString() ?? '');
    final lng = (picked['lng'] as num?)?.toDouble() ??
        double.tryParse(picked['lng']?.toString() ?? '');
    if (lat == null || lng == null) return;
    final content = jsonEncode({
      'lat': lat,
      'lng': lng,
      'name': (picked['name'] ?? '').toString(),
      'address': (picked['address'] ?? '').toString(),
    });
    final clientMsgId = _uuid();
    final bubble = _localMsg(MessageType.location, content, clientMsgId, null);
    setState(() => _msgs.add(bubble));
    _armWatchdog(clientMsgId);
    _trackPending(bubble);
    _jumpToLatest();
    try {
      final resp = await _svc.sendRaw(
          widget.conv.id, MessageType.location, content,
          clientMsgId: clientMsgId);
      _replaceLocalWithServer(resp, clientMsgId);
    } catch (e) {
      _markLocalFailed(clientMsgId, transient: ApiClient.isTransient(e));
    }
  }

  void _pickMention() async {
    if (_members.isEmpty) await _loadMembers();
    if (!mounted) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(AppLocalizations.of(context).t('chatPickMention'),
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            ListTile(
              leading: CircleAvatar(
                  backgroundColor: context.cs.surface,
                  child: Icon(Icons.group)),
              title: Text(_t('chatMentionAll'),
                  style: const TextStyle(fontSize: 15)),
              // pop 出的 '@所有人' 会拼进消息内容发送给服务端，保持原样不做翻译
              onTap: () => Navigator.of(context).pop('@所有人'),
            ),
            ..._members.map((m) => ListTile(
                  leading: CircleAvatar(
                      backgroundColor: context.cs.surface,
                      child: Text(
                          (m['nickname']?.toString().characters.first ?? '?'),
                          style: const TextStyle(color: AppTheme.primary))),
                  title: Text(m['nickname']?.toString() ?? '',
                      style: const TextStyle(fontSize: 15)),
                  onTap: () => Navigator.of(context)
                      .pop(m['nickname']?.toString() ?? ''),
                )),
          ],
        ),
      ),
    );
    if (picked != null && picked.isNotEmpty) {
      final cur = _input.text;
      final insertion = '@$picked ';
      _input.text = cur + insertion;
      _input.selection = TextSelection.collapsed(offset: _input.text.length);
    }
  }

  // ====== 长按消息：全屏高亮 + 菜单气泡（微信式炸开） ======
  void _showLongPressOverlay(ChatMsg m) {
    if (m.recalled || m.msgId == null) return;
    // 旧快照先释放（换了一条消息长按的场景）
    _longPressShot?.dispose();
    _longPressShot = null;
    // 先取行矩形 + 截行快照（都必须在 setState 置高亮【之前】——
    // 置高亮后行变成蓝色高亮样式，截出来就是色块而不是消息内容）
    _longPressRect = _rowRect(m.clientMsgId);
    _captureRowShot(m.clientMsgId);
    setState(() => _longPressedMsg = m);
    HapticFeedback.lightImpact();
  }

  /// 对消息行 RepaintBoundary 原位截图（物理分辨率按设备像素比，保证清晰）。
  /// toImage 在调用瞬间捕获当前图层，这里在 setState 前调用所以截到普通样式。
  void _captureRowShot(String clientMsgId) {
    final obj = _rowKeys[clientMsgId]?.currentContext?.findRenderObject();
    if (obj is! RenderRepaintBoundary || !obj.attached || !obj.hasSize) return;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    obj.toImage(pixelRatio: dpr).then((img) {
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() => _longPressShot = img);
    }).catchError((_) {
      // 截图失败：浮层回落为半透明高亮框，不影响功能
    });
  }

  void _closeLongPressOverlay() {
    _longPressShot?.dispose();
    _longPressShot = null;
    setState(() => _longPressedMsg = null);
  }

  /// 撤回
  /// 加号「名片」：选好友/群 → 向当前会话发 type=10 名片消息。
  /// 好友 content={"userId","nickname","avatar"}；群={"kind":"group","id","name","avatar"}。
  Future<void> _pickCard() async {
    final picked = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => ForwardPickerPage(myId: widget.myId)),
    );
    if (picked == null || !mounted) return;
    final id = (picked['id'] ?? '').toString();
    if (id.isEmpty) return;
    final String content;
    if (picked['kind'] == 'group') {
      content = jsonEncode({
        'kind': 'group',
        'id': id,
        'name': (picked['nickname'] ?? '').toString(),
        'avatar': (picked['avatar'] ?? '').toString(),
      });
    } else {
      content = jsonEncode({
        'userId': id,
        'nickname': (picked['nickname'] ?? '').toString(),
        'avatar': (picked['avatar'] ?? '').toString(),
      });
    }
    final clientMsgId = _uuid();
    final bubble = _localMsg(MessageType.card, content, clientMsgId, null);
    setState(() => _msgs.add(bubble));
    _armWatchdog(clientMsgId);
    _trackPending(bubble);
    _jumpToLatest();
    try {
      final resp = await _svc.sendRaw(
          widget.conv.id, MessageType.card, content,
          clientMsgId: clientMsgId);
      _replaceLocalWithServer(resp, clientMsgId);
    } catch (e) {
      _markLocalFailed(clientMsgId, transient: ApiClient.isTransient(e));
    }
  }


  Future<void> _recall(ChatMsg m) async {
    _closeLongPressOverlay();
    if (m.msgId == null) return;
    final ok = await _svc.recall(m.msgId!);
    if (!mounted) return;
    if (ok) {
      setState(() => m.recalled = true);
      // 同步替换内存/磁盘缓存，退出重进不再显示原消息
      ConversationService.historyCacheMarkRecalled(widget.conv.id, m.msgId!);
      _toast(_t('chatRecalled'));
    } else {
      _toast(_t('chatRecallFailed'));
    }
  }

  /// 复制
  void _copy(ChatMsg m) {
    _closeLongPressOverlay();
    Clipboard.setData(ClipboardData(text: m.content));
    _toast(_t('chatCopied'));
  }

  /// 收藏
  Future<void> _favorite(ChatMsg m) async {
    _closeLongPressOverlay();
    if (m.msgId == null) return;
    final ok = await _svc.favoriteAdd(widget.conv.id, m.msgId!);
    _toast(ok ? _t('chatFavorited') : _t('chatFavoriteFailed'));
  }

  /// 引用
  void _quote(ChatMsg m) {
    _closeLongPressOverlay();
    setState(() => _quoteMsg = m);
  }

  /// 转发：选好友/群 → createDirect（好友）或直接用群会话 ID → sendRaw 原样透传
  /// 可转发：1 文本/2 图片/3 文件/4 语音/5 视频/10 名片；6/7/8/9（系统/信令/红包/转账）禁止
  Future<void> _forward(ChatMsg m) async {
    _closeLongPressOverlay();
    const forwardable = {1, 2, 3, 4, 5, 10};
    if (!forwardable.contains(m.type)) {
      _toast(_t('forwardNotAllowed'));
      return;
    }
    final picked = await Navigator.push<Map>(
      context,
      MaterialPageRoute(builder: (_) => ForwardPickerPage(myId: _myUid)),
    );
    if (picked == null || !mounted) return;
    final targetId = picked['id']?.toString() ?? ''; // 雪花 ID 字符串
    if (targetId.isEmpty) return;
    try {
      String convId;
      if (picked['kind'] == 'group') {
        convId = targetId;
      } else {
        final conv = await _svc.createDirect(targetId);
        convId = conv['id']?.toString() ?? '';
      }
      if (convId.isEmpty) throw Exception(_t('forwardNotAllowed'));
      // replyTo 透传：服务端 ReplySnapshot 快照机制保证跨会话安全
      // file 元数据：文件消息转发后目标会话也要能点开预览（后端会为它重建 conv_files）
      await _svc.sendRaw(convId, m.type, m.content,
          replyTo: m.replyTo, file: m.file);
      if (!mounted) return;
      _toast(_t('forwardSent'));
    } catch (e) {
      if (!mounted) return;
      _toast(_errMsg(e, _t('forwardNotAllowed')));
    }
  }

  /// 置顶/取消置顶消息（群主/管理员；后端已放开所有成员可置顶）
  Future<void> _pinMsg(ChatMsg m) async {
    _closeLongPressOverlay();
    final ok =
        await _svc.setPinMessage(widget.conv.id, m.msgId ?? '0', m.content);
    _toast(ok ? _t('chatPinned') : _t('chatPinFailed'));
    if (ok) {
      setState(() {
        widget.conv.conversation['pinnedMsgContent'] = m.content;
        widget.conv.conversation['pinnedMsgId'] = m.msgId ?? '';
        // 2026-09-29 修复：置顶后要退出重进才显示——就地追加置顶列表并解除隐藏，
        // 置顶条立即上屏且指向新置顶；同时清掉「× 隐藏」持久化标记
        final id = m.msgId ?? '';
        _pinnedMsgs = [
          ..._pinnedMsgs,
          {'msgId': id, 'content': m.content, 'type': m.type},
        ];
        _pinnedIndex = _pinnedMsgs.length - 1;
        _pinnedHidden = false;
        try {
          // 清「× 隐藏」持久化标记（异步失败静默，与 _persistHiddenFlag 同风格）
          _hiddenFlagsStore
              .delete(key: 'pinHidden:${widget.conv.id}')
              .catchError((_) {});
        } catch (_) {}
      });
    }
  }

  /// 置顶条「取消」：群主取消当前置顶消息（2026-09-29 需求2）。
  /// 成功后就地从列表移除；列表空了整条消失。
  Future<void> _unpinCurrentPinned() async {
    if (_pinnedMsgs.isEmpty) return;
    final i = _pinnedIndex.clamp(0, _pinnedMsgs.length - 1);
    final p = _pinnedMsgs[i];
    final id = p['msgId']?.toString().replaceAll('"', '') ?? '';
    if (id.isEmpty) return;
    final ok =
        await _svc.setPinMessage(widget.conv.id, id, '', pinned: false);
    if (!mounted) return;
    if (!ok) {
      _toast(_t('chatPinFailed'));
      return;
    }
    setState(() {
      _pinnedMsgs.removeAt(i);
      if (_pinnedIndex >= _pinnedMsgs.length) _pinnedIndex = 0;
    });
    _toast(_t('chatUnpinned'));
  }

  void _toast(String msg) => AppDialogs.toast(context, msg);

  /// 需求3（多图直发版，2026-09-16）：相册多选 → **选完直接发送**，
  /// 不再挂输入栏预览条二次确认；不设张数上限（原 9 张限制随预览条一起移除）。
  ///
  /// 上传链路复用原逐张上传逻辑（[_sendImages]）：占位气泡 → 逐张上传 →
  /// 组合 url1|url2|... 发送。失败的图直接丢弃并 toast（无预览条可重试）。
  Future<void> _pickImage() async {
    try {
      List<XFile> picked;
      if (kIsWeb) {
        // H5：浏览器沙箱打不开系统相册 App，只能弹浏览器文件框（外观上与
        // 「文件」按钮同源，这是 Web 平台限制）。改用 file_picker 的 media
        // 过滤（accept=image/*,video/*）：对话框里只出现照片+视频，且视频
        // 可选可发（旧实现 pickMultiImage 只能选图）。选完复用原生同一条
        // 发送链路：图片走 _sendImages，视频走 _sendVideoAsFile。
        final res = await FilePicker.pickFiles(
          allowMultiple: true,
          // Web 没有路径，必须把字节读进内存（与 _pickFile 的 H5 分支同因）
          withData: true,
          type: FileType.media,
        );
        picked = <XFile>[
          for (final p in res?.files ?? const <PlatformFile>[])
            if (p.bytes != null)
              XFile.fromData(p.bytes!,
                  name: p.name, mimeType: _guessMime(p.name)),
        ];
      } else {
        // 原生：微信式应用内相册选择器（2026-09-17：相册入口必须是相册界面）。
        // 根因：image_picker 的相册类调用在 Android 上走 ACTION_GET_CONTENT =
        // 系统文件选择器（其 useAndroidPhotoPicker 开关未被主包暴露，恒为
        // false），所以相册按钮弹出来的是文件管理器界面。
        // wechat_assets_picker 是应用内相册九宫格，图+视频混合多选，界面可控。
        // 图片/视频都取原始文件（与原 pickMultipleMedia 同为不压缩），
        // 选完直接发送，复用下方同一条发送链路。
        final assets = await AssetPicker.pickAssets(
          context,
          pickerConfig: const AssetPickerConfig(
            requestType: RequestType.common, // 图片 + 视频混合
            // 不设张数上限（需求3：相册多选选完直发）
          ),
        );
        if (assets == null || assets.isEmpty) return; // 用户取消选择
        picked = <XFile>[];
        for (final a in assets) {
          final f = await a.file; // 原始文件路径（视频抽帧封面依赖 path）
          if (f == null) continue;
          final name = (a.title == null || a.title!.isEmpty)
              ? 'asset_${a.id}'
              : a.title!;
          // mimeType 由扩展名兜底：保证下方 _isVideoFile 按类型正确分流
          picked.add(XFile(f.path, name: name, mimeType: _guessMime(name)));
        }
      }
      if (picked.isEmpty) return;
      // 图片照旧组合成一条 type=2 多图消息；视频逐条走文件消息链路（在线可播）
      final images = <XFile>[];
      final videos = <XFile>[];
      for (final f in picked) {
        (_isVideoFile(f) ? videos : images).add(f);
      }
      if (images.isNotEmpty) await _sendImages(images);
      for (final v in videos) {
        await _sendVideoAsFile(v);
      }
    } catch (e) {
      _toast(_t('chatImageSendFailed', {'error': e.toString()}));
    }
  }

  /// 上传所选图片并发送，组合成一条 type=2 消息（content = url1|url2|...）。
  ///
  /// 【修 R-26】旧实现三处问题，这里逐一改掉：
  ///   1. `uploadFile` 没设 sendTimeout → 大图弱网会一直占着连接，整单卡死；
  ///   2. 「全部成功才发」→ 第 8 张失败时前 7 张也一起没了（整单丢失）；
  ///   3. 乐观气泡在**上传完成后**才插入 → 上传期间用户看不到任何反馈。
  ///
  /// 现在：先插占位气泡（sending，用户立刻看到自己要发图）→ 逐张上传（带超时）
  /// → 上传完更新气泡内容 → 发送。中途失败的图**直接丢弃**（2026-09-16 起
  /// 无预览条可挂），成功的照常发出去，toast 提示部分失败。
  /// 上传进度回写（微信式，2026-09-17）：更新占位气泡的 uploadProgress。
  /// 节流：距上次 <2% 跳过 setState（onSendProgress 每块字节都回调，
  /// 不节流会全列表逐帧重建）；到达 1.0 或跨过 2% 阈值才刷新。
  void _setUploadProgress(String clientMsgId, double p) {
    if (!mounted) return;
    final i = _msgs.indexWhere((x) => x.clientMsgId == clientMsgId);
    if (i < 0) return;
    final cur = _msgs[i].uploadProgress;
    final next = p.clamp(0.0, 1.0);
    if (next < 1 && (next - cur).abs() < 0.02) return;
    if ((next - cur).abs() < 0.001) return;
    setState(() => _msgs[i].uploadProgress = next);
  }

  Future<void> _sendImages(List<XFile> files) async {
    if (files.isEmpty) return;
    final clientMsgId = _uuid();
    try {
      // 1) 先插占位气泡：上传可能要几十秒，期间用户必须看到「我在发图」
      final bubble = _localMsg(2, '', clientMsgId, null);
      setState(() => _msgs.add(bubble));
      // 看门狗后移（2026-09-24）：多图上传可能几十秒，15s 到点会误置 failed 闪「！」；
      // 上传挂起由 dio sendTimeout(60s) 兜底。发送 sendRaw 前再 arm。
      _jumpToLatest();

      // 2) 逐张上传；单张失败不中断，最后统计。
      //    微信式进度（2026-09-17）：多图合并为一条 type=2 消息，进度按
      //    「全部图片字节流水线」聚合回写占位气泡（onSendProgress 只报单张，
      //    跨张用 doneBytes 累加）。
      final urls = <String>[];
      var failed = 0;
      var doneBytes = 0;
      var totalBytes = 0;
      final sizes = <int>[];
      for (final f in files) {
        var s = 0;
        try {
          s = await f.length();
        } catch (_) {}
        sizes.add(s);
        totalBytes += s;
      }
      for (var i = 0; i < files.length; i++) {
        final f = files[i];
        try {
          // H5 适配：uploadXFile 在 Web 读字节、原生走流式（2026-09-16）
          final up = await ApiClient.instance.uploadXFile(
            f,
            f.name.isEmpty ? 'image$i.jpg' : f.name,
            onSendProgress: (sent, total) => _setUploadProgress(clientMsgId,
                totalBytes > 0 ? (doneBytes + sent) / totalBytes : 0),
          );
          final url = (up['url'] ?? '').toString();
          if (url.isEmpty) throw Exception('upload failed');
          urls.add(url);
        } catch (_) {
          failed++;
        }
        doneBytes += sizes[i];
      }
      if (urls.isEmpty) {
        // 一张都没传上去：撤掉占位气泡，提示重试
        if (mounted) {
          _cancelWatchdog(clientMsgId);
          setState(() {
            _msgs.removeWhere((x) => x.clientMsgId == clientMsgId);
          });
          _toast(
              _t('chatImageSendFailed', {'error': _t('chatUploadAllFailed')}));
        }
        return;
      }

      // 3) 更新气泡内容为已上传的 URL 组合，然后发送（进度置 1 隐藏遮罩）
      final joined = urls.join('|');
      setState(() {
        final idx = _msgs.indexWhere((x) => x.clientMsgId == clientMsgId);
        if (idx >= 0) {
          _msgs[idx].content = joined;
          _msgs[idx].uploadProgress = 1.0;
        }
      });
      // 登记发件箱：发送中杀进程也能补回（多图 URL 已拿到，重发不会重复上传）
      final idx = _msgs.indexWhere((x) => x.clientMsgId == clientMsgId);
      if (idx >= 0) _trackPending(_msgs[idx]);
      _armWatchdog(clientMsgId); // 上传已结束，发送阶段恢复 15s 看门狗
      final resp = await _svc.sendRaw(widget.conv.id, 2, joined,
          clientMsgId: clientMsgId);
      _replaceLocalWithServer(resp, clientMsgId);

      // 4) 部分失败的图已丢弃，toast 告知
      if (mounted && failed > 0) {
        _toast(_t('chatImagePartialFailed', {
          'ok': '${urls.length}',
          'fail': '$failed',
        }));
      }
    } catch (e) {
      if (mounted) {
        _markLocalFailed(clientMsgId, transient: ApiClient.isTransient(e));
        _toast(_t('chatImageSendFailed', {'error': _errMsg(e, e.toString())}));
      }
    }
  }

  /// 功能 A：+ 面板「文件」→ 选文件 → 上传 → 发送 type=3 文件消息。
  ///
  /// 流程与 [_send] / [_pickImage] 保持一致：
  /// 上传拿到元数据 → 本地乐观插入（sending）→ _jumpToLatest → sendRaw →
  /// 成功 [_replaceLocalWithServer] 回填、失败 [_markLocalFailed]。
  /// 上传失败直接 toast 终止，不留一条发不出去的空消息。
  Future<void> _pickFile() async {
    FilePickerResult? picked;
    try {
      picked = await FilePicker.pickFiles(
        allowMultiple: false,
        // 原生只拿路径走流式上传（大文件不进内存）；H5 没有路径，必须把字节读进内存
        withData: kIsWeb,
        type: FileType.any,
      );
    } catch (e) {
      _toast(_t('chatFileSendFailed', {'error': e.toString()}));
      return;
    }
    // 用户取消选择：静默返回，不提示
    if (picked == null || picked.files.isEmpty) return;
    final f = picked.files.single;
    final name = f.name.isEmpty ? 'file' : f.name;
    final size = f.size; // PlatformFile 自带 size（H5/原生都有）

    // 1) 先插占位气泡（微信式进度，2026-09-17）：上传期间气泡内叠进度遮罩
    final clientMsgId = _uuid();
    final bubble = _localMsg(MessageType.file, name, clientMsgId, null,
        file: {'name': name, 'size': size, 'mimeType': _guessMime(name)});
    setState(() {
      _msgs.add(bubble);
      _jumpToLatest();
    });
    // 看门狗后移到 _pushFileMessage（2026-09-24）：大文件上传期不再被 15s 强制置 failed

    // 上传失败/元数据缺失：撤掉占位气泡（与旧行为一致，不留一条点不开的空文件）
    void failAndRemove(String msg) {
      if (mounted) {
        _cancelWatchdog(clientMsgId);
        setState(() => _msgs.removeWhere((x) => x.clientMsgId == clientMsgId));
        _toast(msg);
      }
    }

    // 2) 上传（带进度回写）。拿不到 object 后端不会写群文件云盘，此时发消息没有意义
    // H5 适配（2026-09-16）：Web 上 PlatformFile 只有内存 bytes，走 uploadBytes；
    // 原生保持按路径流式上传
    Map<String, dynamic> up;
    try {
      if (kIsWeb) {
        final bytes = f.bytes;
        if (bytes == null) {
          failAndRemove(_t('chatFileNotSupported'));
          return;
        }
        up = await ApiClient.instance.uploadBytes(bytes, name,
            dir: 'files/',
            onSendProgress: (sent, total) =>
                _setUploadProgress(clientMsgId, total > 0 ? sent / total : 0));
      } else {
        final path = f.path;
        if (path == null || path.isEmpty) {
          failAndRemove(_t('chatFileNotSupported'));
          return;
        }
        up = await ApiClient.instance.uploadFile(path, name,
            dir: 'files/',
            onSendProgress: (sent, total) =>
                _setUploadProgress(clientMsgId, total > 0 ? sent / total : 0));
      }
    } catch (e) {
      failAndRemove(
          _t('chatFileSendFailed', {'error': _errMsg(e, e.toString())}));
      return;
    }
    final object = (up['object'] ?? '').toString();
    final url = (up['url'] ?? '').toString();
    if (object.isEmpty || url.isEmpty) {
      // 拿不到 object 后端不会写 conv_files，此时发消息等于发一条点不开的空文件
      failAndRemove(_t('chatFileNotSupported'));
      return;
    }
    // 与后端 buildConvFile 契约一致：object/name/size/mimeType/url，
    // 缺 mimeType 时按扩展名兜底（后端用它算 category，空值会退化成 other → 不支持预览）
    await _pushFileMessage(name, size, _guessMime(name), object, url,
        reuseId: clientMsgId);
  }

  /// 文件消息通用尾段（_pickFile 与 _sendVideoAsFile 共用）：
  /// 本地乐观插入 → sendRaw(type=3，file 元数据走 sendRaw 的 file 字段) → 回填/标失败。
  /// [reuseId] 非空：上传期占位气泡已由调用方插入（微信式进度，2026-09-17），
  /// 这里只回填完整元数据并复用其 clientMsgId 发送，不重复插气泡。
  Future<void> _pushFileMessage(
      String name, int size, String mime, String object, String url,
      {String thumbUrl = '', String? reuseId}) async {
    final meta = <String, dynamic>{
      'object': object,
      'name': name,
      'size': size,
      'mimeType': mime,
      'url': url,
    };
    // 视频封面（可选）：气泡按 mimeType=video/* + thumbUrl 渲染封面+播放键
    if (thumbUrl.isNotEmpty) meta['thumbUrl'] = thumbUrl;

    late final String clientMsgId;
    if (reuseId != null) {
      clientMsgId = reuseId;
      final i = _msgs.indexWhere((x) => x.clientMsgId == reuseId);
      if (i >= 0) {
        setState(() {
          _msgs[i].content = name;
          _msgs[i].file = meta;
          _msgs[i].uploadProgress = 1.0;
        });
      }
      // 元数据补齐后才登记发件箱（上传中途被杀不能拿着缺 object 的半截元数据重发）
      final bi = _msgs.indexWhere((x) => x.clientMsgId == reuseId);
      if (bi >= 0) _trackPending(_msgs[bi]);
    } else {
      clientMsgId = _uuid();
      final bubble =
          _localMsg(MessageType.file, name, clientMsgId, null, file: meta);
      setState(() {
        _msgs.add(bubble);
        _jumpToLatest();
      });
      _armWatchdog(clientMsgId);
      _trackPending(bubble);
    }

    // 上传+抽封面已结束，此时才起 15s 发送看门狗（2026-09-24：看门狗后移，
    // 避免「上传中就置 failed 闪！」；sendRaw 只是 JSON 小请求，15s 足够）
    _armWatchdog(clientMsgId);
    try {
      final resp = await _svc.sendRaw(widget.conv.id, MessageType.file, name,
          clientMsgId: clientMsgId, file: meta);
      if (!mounted) return;
      _replaceLocalWithServer(resp, clientMsgId);
    } catch (e) {
      if (!mounted) return;
      _markLocalFailed(clientMsgId, transient: ApiClient.isTransient(e));
      _toast(_t('chatFileSendFailed', {'error': _errMsg(e, e.toString())}));
    }
  }

  /// 相册混合选择时区分视频：优先 mimeType，缺失按扩展名兜底
  static bool _isVideoFile(XFile f) {
    final mime = (f.mimeType ?? '').toLowerCase();
    if (mime.startsWith('video/')) return true;
    const exts = [
      '.mp4',
      '.mov',
      '.m4v',
      '.avi',
      '.mkv',
      '.webm',
      '.3gp',
      '.flv',
      '.wmv'
    ];
    final name = f.name.toLowerCase();
    for (final e in exts) {
      if (name.endsWith(e)) return true;
    }
    return false;
  }

  /// 相册选择的视频 → 走文件消息链路发送（type=3，mimeType 标注 video/*，
  /// 预览页据此进「视频在线播放」分支：后端 preview 返回 kind=video，
  /// App 端 FilePreviewPage 用 video_player 流式播放）。
  /// 2026-09-17：发送前抽帧生成封面图上传，meta.thumbUrl 供气泡渲染封面
  /// （需求：视频文件要有封面）；抽帧失败不阻断发送（无封面退回普通文件样式）。
  Future<void> _sendVideoAsFile(XFile v) async {
    final name = v.name.isEmpty ? 'video.mp4' : v.name;
    var size = 0;
    try {
      size = await v.length(); // cross_file 没有 size getter，用 length()
    } catch (_) {}
    final mime = (v.mimeType != null && v.mimeType!.isNotEmpty)
        ? v.mimeType!
        : _guessMime(name);

    // 1) 先插占位气泡（微信式进度，2026-09-17）：上传大视频可能几十秒
    final clientMsgId = _uuid();
    final bubble = _localMsg(MessageType.file, name, clientMsgId, null,
        file: {'name': name, 'size': size, 'mimeType': mime});
    setState(() {
      _msgs.add(bubble);
      _jumpToLatest();
    });
    // 看门狗不在这里 arm（2026-09-24 修复）：大视频上传+抽封面远超 15s，
    // 旧逻辑 15s 到点把 sending 强制置 failed → 气泡闪「！」；
    // 上传挂起由 dio 的 sendTimeout(60s) 兜底，超时会走 catch 撤气泡。
    // 真正的 15s 看门狗在 _pushFileMessage 发送前再 arm。

    // 2) 上传（带进度回写）
    Map<String, dynamic> up;
    try {
      up = await ApiClient.instance.uploadXFile(v, name,
          dir: 'files/',
          onSendProgress: (sent, total) =>
              _setUploadProgress(clientMsgId, total > 0 ? sent / total : 0));
    } catch (e) {
      if (mounted) {
        _cancelWatchdog(clientMsgId);
        setState(() => _msgs.removeWhere((x) => x.clientMsgId == clientMsgId));
        _toast(_t('chatFileSendFailed', {'error': _errMsg(e, e.toString())}));
      }
      return;
    }
    final object = (up['object'] ?? '').toString();
    final url = (up['url'] ?? '').toString();
    if (object.isEmpty || url.isEmpty) {
      // 拿不到 object 后端不会写 conv_files，此时发消息等于发一条点不开的空文件
      if (mounted) {
        _cancelWatchdog(clientMsgId);
        setState(() => _msgs.removeWhere((x) => x.clientMsgId == clientMsgId));
        _toast(_t('chatFileNotSupported'));
      }
      return;
    }
    // 3) 视频封面：抽帧 → 上传 → thumbUrl。Web 端插件不支持（H5 无封面，可接受）。
    //    抽帧的是小 PNG，几秒内完成，不再单独做进度。
    String thumbUrl = '';
    if (!kIsWeb) {
      try {
        final thumb = await VideoThumbnail.thumbnailData(
          video: v.path,
          imageFormat: ImageFormat.PNG,
          quality: 60,
          maxWidth: 480, // 气泡宽约 240 逻辑像素 ×2 倍率
        );
        if (thumb != null && thumb.isNotEmpty) {
          final tu = await ApiClient.instance.uploadBytes(
              thumb, 'cover_${DateTime.now().millisecondsSinceEpoch}.png',
              dir: 'files/');
          thumbUrl = (tu['url'] ?? '').toString();
        }
      } catch (_) {
        // 封面失败不影响发送
      }
    }
    await _pushFileMessage(name, size, mime, object, url,
        thumbUrl: thumbUrl, reuseId: clientMsgId);
  }

  /// 语音消息发送（type=4）：镜像 [_sendVideoAsFile] 的占位→上传→落库三段式。
  /// content 存 JSON {"url","duration","waveform","size"}，服务端零字段改动、零 migration。
  Future<void> _sendVoice(VoiceRecorderResult v) async {
    final ext = v.path.contains('.') ? v.path.split('.').last : 'm4a';
    final name =
        'voice_${_myUid}_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final clientMsgId = _uuid();
    // 占位气泡：content 先放 duration+waveform（无 url），上传完再补 url
    final placeholder = <String, dynamic>{
      'duration': v.durationMs,
      'waveform': v.waveform,
      'size': v.sizeBytes,
    };
    final bubble = _localMsg(
        MessageType.voice, jsonEncode(placeholder), clientMsgId, null);
    setState(() {
      _msgs.add(bubble);
      _jumpToLatest();
    });
    // 看门狗后移（2026-09-24）：上传阶段由 dio sendTimeout 兜底，sendRaw 前 arm。

    Map<String, dynamic> up;
    try {
      up = await ApiClient.instance.uploadXFile(XFile(v.path), name,
          dir: 'voice/',
          onSendProgress: (sent, total) =>
              _setUploadProgress(clientMsgId, total > 0 ? sent / total : 0));
    } catch (e) {
      if (mounted) {
        _cancelWatchdog(clientMsgId);
        setState(() => _msgs.removeWhere((x) => x.clientMsgId == clientMsgId));
        _toast(_t('chatFileSendFailed', {'error': _errMsg(e, e.toString())}));
      }
      return;
    }
    final object = (up['object'] ?? '').toString();
    final url = (up['url'] ?? '').toString();
    if (object.isEmpty || url.isEmpty) {
      if (mounted) {
        _cancelWatchdog(clientMsgId);
        setState(() => _msgs.removeWhere((x) => x.clientMsgId == clientMsgId));
        _toast(_t('chatFileNotSupported'));
      }
      return;
    }
    // 拿到 url：补进 content 再 sendRaw 落库 + 回填
    placeholder['url'] = url;
    placeholder['object'] = object;
    _armWatchdog(clientMsgId); // 上传已结束，发送阶段恢复 15s 看门狗
    try {
      final resp = await _svc.sendRaw(
          widget.conv.id, MessageType.voice, jsonEncode(placeholder),
          clientMsgId: clientMsgId);
      if (!mounted) return;
      _replaceLocalWithServer(resp, clientMsgId);
    } catch (e) {
      if (!mounted) return;
      _markLocalFailed(clientMsgId, transient: ApiClient.isTransient(e));
      _toast(_t('chatFileSendFailed', {'error': _errMsg(e, e.toString())}));
    }
  }

  /// 按扩展名猜 MIME（file_picker 不给 MIME，后端靠它算文件分类）。
  /// 未命中返回 application/octet-stream。
  static String _guessMime(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    const map = <String, String>{
      'pdf': 'application/pdf',
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'bmp': 'image/bmp',
      'doc': 'application/msword',
      'docx':
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx':
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt': 'application/vnd.ms-powerpoint',
      'pptx':
          'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'txt': 'text/plain',
      'csv': 'text/csv',
      'json': 'application/json',
      'zip': 'application/zip',
      'rar': 'application/vnd.rar',
      '7z': 'application/x-7z-compressed',
      'mp4': 'video/mp4',
      'mov': 'video/quicktime',
      'avi': 'video/x-msvideo',
      'mkv': 'video/x-matroska',
      'mp3': 'audio/mpeg',
      'wav': 'audio/wav',
    };
    return map[ext] ?? 'application/octet-stream';
  }

  /// MIME → 群文件分类（image / video / doc / other），与后端 FileCategory 口径对齐。
  static String _categoryOfMime(String mime) {
    final m = mime.toLowerCase();
    if (m.startsWith('image/')) return 'image';
    if (m.startsWith('video/')) return 'video';
    if (m.startsWith('audio/')) return 'audio';
    if (m.isEmpty) return 'other';
    return 'doc';
  }

  /// 点击文件气泡 → 预览。
  ///
  /// 有 fileId（后端已写入群文件云盘）→ 应用内 [FilePreviewPage]；
  /// 老消息没有 fileId → 降级用外部浏览器打开 url；连 url 都没有 → toast。
  Future<void> _openFileBubble(ChatMsg m) async {
    final file = m.file;
    if (file == null) {
      _toast(_t('chatFileNoPreview'));
      return;
    }
    final fileId = (file['fileId'] ?? '').toString();
    if (fileId.isNotEmpty) {
      final mime = (file['mimeType'] ?? '').toString();
      final item = GroupFileItem(
        fileId: fileId,
        name: (file['name'] ?? m.content).toString(),
        size: (file['size'] as num?)?.toInt() ?? 0,
        uploaderName: _senderName(m.senderId),
        uploadedAt: m.createdAt ?? '',
        // 后端返回的 file 元数据里没有 category，按 mimeType 推（预览页据此走图片/PDF 分支）
        category: _categoryOfMime(mime),
        url: (file['url'] ?? '').toString(),
      );
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => FilePreviewPage(
              item: item,
              convId: widget.conv.id,
              convName: widget.conv.conversationName)));
      return;
    }
    final url = (file['url'] ?? '').toString();
    if (url.isEmpty) {
      _toast(_t('chatFileNoPreview'));
      return;
    }
    final uri = Uri.tryParse(url);
    bool launched = false;
    if (uri != null) {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    if (!launched) _toast(_t('chatFileNoPreview'));
  }

  // ===== 消息列表 =====

  /// E2EE（2026-09-18 需求 2）：单聊顶部「端到端加密」提示条。
  /// 条件：单聊 + 非小助手 + 后台模式=e2ee + 本人用户级开关开。
  bool _e2eeBanner = false;

  Future<void> _loadE2eeBanner() async {
    try {
      final convType = (widget.conv.conversation['type'] as num?)?.toInt() ?? 1;
      if (convType != 1 || widget.conv.isAssistant) return;
      final me = await E2eeService.instance.meInfo();
      if (!mounted) return;
      // 同步后台最新加密方式到服务缓存：后台切走「端到端」后，本会话页
      // 一打开就刷新，下一条消息即降级明文，不必等重新登录（2026-09-21 补）
      if (me != null) {
        E2eeService.instance.mode = (me['mode'] ?? '').toString();
        E2eeService.instance.e2eeOn = me['e2eeOn'] != false;
      }
      setState(() {
        _e2eeBanner =
            me != null && me['mode'] == 'e2ee' && me['e2eeOn'] != false;
      });
    } catch (_) {}
  }

  // ===== E2EE 批量重绘（2026-09-20 修「加密聊天进页面卡一下」） =====
  // 每条加密气泡解密完成都会回调 onE2Decrypted；旧实现逐条 setState 整页
  // 重绘——加密会话首屏 20 条 = 转场期间连续 20 次整页 build（本页 build
  // 很重）= 肉眼可见的卡顿。改为帧末合并：一帧内无论多少条解密完成，
  // 只安排一次重绘；解密本身是异步毫秒级，首屏通常 1~2 帧内全部完成，
  // 整页重建从 20 次降到 1~2 次。
  bool _e2RepaintQueued = false;

  void _queueE2Repaint() {
    if (_e2RepaintQueued || !mounted) return;
    _e2RepaintQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _e2RepaintQueued = false;
      if (mounted) setState(() {});
    });
  }

  Widget _buildE2eeBanner() {
    // 悬浮胶囊样式：半透明底 + 轻投影，盖在消息列表顶部（见 build 里 Positioned 分支）
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: context.cs.surfaceContainer.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(999),
                boxShadow: [
                  BoxShadow(
                    color: context.cs.shadow.withValues(alpha: 0.12),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Text(
                _t('e2Banner'),
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 消息列表（**正序**：_msgs[0] 最旧，_msgs.last 最新）
  ///
  /// 首屏贴底由进入会话时的 _startStick() 完成（首帧/下一帧跳 + ScrollMetricsNotification
  /// 持续驱动收敛到真实底部）。列表始终直接渲染，不隐藏——进入会话/有缓存直出立即显示，
  /// 杜绝"白屏一下再载入消息"。
  ///
  /// 为什么是正序而不是 reverse：列表不满一屏时正序天然靠顶部显示（微信式），
  /// 而 reverse 会靠底部，改回顶部需要自己写 RenderSliver 垫弹性空白。
  /// 代价只有一个：上拉历史 prepend 后要手动补偿 3 行偏移量（见 _loadOlder）。
  /// 首帧落底的初始滚动偏移。
  ///
  /// 高度来源分三层：本会话实测 memo → MsgHeightCache 内存层（跨会话持久化
  /// 实测，进页前 ensureLoaded 预热）→ 按类型估算。实测值只乘 1.2（本来就准）；
  /// 纯估算乘 1.8（图片/引用多的群估算普遍偏低 30%+，1.35 不够）——宁可超估
  /// （首帧 attach 钳到 maxScrollExtent = 恰好贴底）也不能低估（低估 = 首帧
  /// 停在真实底部上方，看到的先是更早的左侧消息再弹回底部 = 「右边的消息
  /// 跳到左边」的残余跳动）。
  double _initialScrollOffset() {
    double sum = 0;
    for (final m in _msgs) {
      final id = m.msgId;
      final real =
          id != null ? (_heightMemo[id] ?? MsgHeightCache.getSync(id)) : null;
      sum += real ?? (_estimateMsgHeight(m) * 1.8);
      if (real != null) sum += real * 0.2; // 实测 ×1.2
    }
    return sum + 200;
  }

  /// 按消息类型估算行高（粗估即可：只用于 cacheExtent 预算；实测值会覆盖）
  double _estimateMsgHeight(ChatMsg m) {
    double h;
    switch (m.type) {
      case 3: // 图片
      case 5: // 视频/文件封面类
        h = 200;
        break;
      case 4: // 语音条
        h = 64;
        break;
      case 7: // 通话记录
        h = 84;
        break;
      default:
        {
          final len = m.content.length;
          final lines = (len / 24).ceil().clamp(1, 12);
          h = 34 + lines * 22;
        }
    }
    // 引用条 + 时间行
    if ((m.replyContent ?? '').trim().isNotEmpty ||
        (m.replyTo ?? '').isNotEmpty) {
      h += 44;
    }
    return h + 26;
  }

  /// 消息列表 cacheExtent 预算：首屏条数少时顶到「实测缓存 + 类型估算」
  /// 总量的 1.2 倍（首帧全量布局 → maxScrollExtent 精确 → 贴底一次到位）；
  /// 消息很多（上翻累积 >40 条）时回到默认量级，不无界膨胀。
  double _computeCacheExtent() {
    if (_msgs.isEmpty) return 500;
    if (_msgs.length > 40) return 600;
    double sum = 0;
    for (final m in _msgs) {
      final id = m.msgId;
      final real =
          id != null ? (_heightMemo[id] ?? MsgHeightCache.getSync(id)) : null;
      sum += real ?? _estimateMsgHeight(m);
    }
    // 上限 4000→6000：20 条图片消息实测可达 6000px，被钳住的话首帧布局
    // 不全 → maxScrollExtent 是估算值 → 贴底落点不准（残余跳根因之一）
    return (sum * 1.2 + 120).clamp(500.0, 6000.0);
  }

  /// 把持久化实测高度拉进 memo（同步：内存层已在进页前 ensureLoaded 预热）。
  /// 供 cacheExtent 预算与 _initialScrollOffset 使用；未命中走估算兜底。
  /// 注意：所有调用点都在同帧首个 build 之前（initState / 缓存直出的
  /// setState 同帧），memo 填好后 build 自然读到——**这里禁止 setState**
  /// （initState 路径会抛「setState during initState」）。
  void _primeHeights() {
    for (final m in _msgs) {
      final id = m.msgId;
      if (id == null || _heightMemo.containsKey(id)) continue;
      final h = MsgHeightCache.getSync(id);
      if (h != null) _heightMemo[id] = h;
    }
  }

  Widget _buildMessageList() {
    // 「加载更早」指示条改为 Stack 悬浮层（2026-09-20 进群闪一下修复）。
    // 旧实现占 itemCount 一格：首拉回来 `_hasMoreOlder` false→true（≥80 条）时，
    // 正序列表顶部凭空多出 ~32px 占位行 = 全部内容被往下推一行，视口内容
    // 上跳一截、底部消息被截半，1~2 帧后才被贴底逻辑拉回（录屏帧 82-84 实锤）。
    // 悬浮层出现/消失零布局变化，触发条件（pixels<200）与 loading 态不变。
    // 2026-09-25：会话内全部图片 URL 平铺（按消息顺序，撤回的不计）。
    // 单图消息点开大图时左右滑翻看会话内其它图片（微信式）。每次列表重建算一遍。
    final convImages = _convImages();
    final list = ScrollConfiguration(
      behavior: const MaterialScrollBehavior().copyWith(
        dragDevices: {
          ui.PointerDeviceKind.touch,
          ui.PointerDeviceKind.mouse,
          ui.PointerDeviceKind.trackpad,
          ui.PointerDeviceKind.stylus,
        },
      ),
      child: ListView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
        itemCount: _msgs.length,
        itemBuilder: (_, i) => _buildMsgItem(i, convImages),
      ),
    );
    // 监听滚动/尺寸通知：首屏由 _startStick 激活贴底窗口，内容高度收敛由
    // ScrollMetricsNotification 驱动持续贴底（见 _onScrollNotification）。
    // 用 Notification 而不是 ScrollNotification —— ScrollMetricsNotification
    // 并不继承 ScrollNotification，两者是兄弟关系。
    final wrapped = NotificationListener<Notification>(
      onNotification: (n) {
        _onScrollNotification(n);
        return false; // 不拦截，继续向上冒泡
      },
      child: Stack(
        children: [
          list,
          // 顶部悬浮「加载更早」指示条：仅加载中显示，不占列表布局
          if (_loadingOlder)
            Positioned(
              top: 8,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: context.cs.surfaceContainerHighest
                        .withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    // 列表始终直接显示，不隐藏：进入会话/有缓存直出立即渲染，避免白屏。
    return wrapped;
  }

  /// 首次载入态：主色调线性进度条 + 文案（替代原来的灰色转圈）
  Widget _buildLoadingView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 140,
            child: LinearProgressIndicator(
              minHeight: 4,
              color: AppTheme.primary,
              backgroundColor: Color(0x1A007AFF),
            ),
          ),
          const SizedBox(height: 12),
          Text(AppLocalizations.of(context).t('chatLoadingMsg'),
              style:
                  TextStyle(fontSize: 13, color: context.cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  /// 顶部悬浮「加载更早」指示条（见 _buildMessageList：已改为 Stack 悬浮层，
  /// 不再占列表布局——占位行方案会在 _hasMoreOlder false→true 时顶开全部
  /// 消息造成进群闪现，2026-09-20 已废弃）。

  /// 单条消息（[i] 为正序索引）
  // ===== AI 翻译逻辑 =====

  /// 目标语种：设置里选了语种用之，否则跟随 App 界面语言
  String _translateTargetLang() {
    final pref = AppSettings.instance.aiTranslateLang;
    if (pref.isNotEmpty) return pref;
    final lc = AppLocalizations.of(context).locale.languageCode;
    switch (lc) {
      case 'en':
        return 'en';
      case 'ja':
        return 'ja';
      default:
        // zh 区分简繁：界面是 zhT 时翻成繁体
        return Localizations.localeOf(context).toString().contains('zhT')
            ? 'zhT'
            : 'zh';
    }
  }

  /// 点击「译」按钮：调翻译接口（手动额度），结果常驻显示（不收起）
  Future<void> _translateMsg(ChatMsg m) async {
    final key = m.clientMsgId;
    if (_translating.contains(key) || _translations.containsKey(key)) return;
    setState(() => _translating.add(key));
    try {
      final out = await _translateSvc
          .translate(m.content, _translateTargetLang(), auto: false);
      if (!mounted) return;
      setState(() {
        _translations[key] = out;
        _translating.remove(key);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _translating.remove(key));
      AppDialogs.toast(
          context,
          e.toString().replaceFirst('Exception: ', '').isEmpty
              ? '翻译失败'
              : e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// 自动翻译：开关开启时，对外来文本消息自动触发（走自动额度，服务端限额）。
  /// 同语言消息服务端 AI 会原样返回且缓存，客户端再加一道脚本启发式：
  /// 目标语为中文时，消息本身已是中日文为主则跳过，避免无谓消耗额度。
  bool _looksForeign(ChatMsg m) {
    final lang = _translateTargetLang();
    final cjk =
        RegExp(r'[\u3040-\u30ff\u4e00-\u9fff]').allMatches(m.content).length;
    final latin = RegExp(r'[A-Za-z]').allMatches(m.content).length;
    if (lang == 'zh' || lang == 'zhT') return latin > cjk; // 目标中文：英文为主才翻
    return cjk > 0 || latin > 0; // 目标英/日：含文字就翻（服务端 AI 兜底原样返回）
  }

  /// 在消息列表构建时调用：为需要自动翻译的消息触发后台翻译（去重）
  void _maybeAutoTranslate(ChatMsg m) {
    if (!_translateEnabled) return; // 服务端未开启翻译：不显示按钮也不自动翻
    if (!AppSettings.instance.aiAutoTranslate) return;
    if (m.type != 1 || m.recalled) return;
    if (m.senderId.trim() == _myUid.trim()) return; // 只自动翻别人的消息
    final key = m.clientMsgId;
    if (_translations.containsKey(key) ||
        _translating.contains(key) ||
        _autoTried.contains(key)) {
      return;
    }
    if (!_looksForeign(m)) return;
    _autoTried.add(key);
    // 延迟到 build 完成后再触发（内部会 setState，build 期间调用会报错）
    Future(() => _translateMsgAuto(m));
  }

  Future<void> _translateMsgAuto(ChatMsg m) async {
    final key = m.clientMsgId;
    // 注意：不要在请求开始时 setState（不进 _translating、按钮不转圈——
    // 用户没点按钮）。滚动中每条外来消息两次整页 setState 会造成掉帧，
    // 这里只在译文回来（或失败）时各 setState 一次。
    try {
      final out = await _translateSvc
          .translate(m.content, _translateTargetLang(), auto: true);
      if (!mounted) return;
      setState(() => _translations[key] = out);
    } catch (_) {
      // 自动翻译失败静默（不打扰用户，可手动点「译」重试）
      if (!mounted) return;
      _autoTried.remove(key);
    }
  }

  // ===== 合并转发：多选模式 =====

  void _enterSelectionMode(ChatMsg first) {
    setState(() {
      _selectionMode = true;
      _selectedClientMsgIds
        ..clear()
        ..add(first.clientMsgId);
      _longPressedMsg = null; // 关长按遮罩
      _plusOpen = false; // 关悬浮功能面板
    });
    HapticFeedback.lightImpact();
  }

  /// 「+」悬浮功能面板开关（打开时收起键盘、关掉表情面板）
  void _togglePlusPanel() {
    setState(() {
      _plusOpen = !_plusOpen;
      if (_plusOpen) _emojiOpen = false;
    });
    if (_plusOpen) FocusScope.of(context).unfocus();
  }

  /// 表情悬浮面板开关（打开时收起键盘、关掉「+」面板）
  void _toggleEmojiPanel() {
    setState(() {
      _emojiOpen = !_emojiOpen;
      if (_emojiOpen) _plusOpen = false;
    });
    if (_emojiOpen) FocusScope.of(context).unfocus();
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedClientMsgIds.clear();
    });
  }

  void _toggleSelect(ChatMsg m) {
    setState(() {
      if (!_selectedClientMsgIds.remove(m.clientMsgId)) {
        _selectedClientMsgIds.add(m.clientMsgId);
      }
    });
  }

  /// 多选模式行首勾选框（未选空心圈 / 已选 primary 实心勾）
  Widget _selectCheckbox(ChatMsg m) {
    final checked = _selectedClientMsgIds.contains(m.clientMsgId);
    return GestureDetector(
      onTap: () => _toggleSelect(m),
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: checked ? AppTheme.primary : Colors.transparent,
          border: Border.all(
            color: checked
                ? AppTheme.primary
                : context.cs.onSurfaceVariant.withValues(alpha: 0.45),
            width: 1.5,
          ),
        ),
        child: checked
            ? const Icon(Icons.check, size: 15, color: Colors.white)
            : null,
      ),
    );
  }

  /// 打开合并转发消息的聊天记录详情页
  Future<void> _openMergeDetail(ChatMsg m) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MergeForwardDetailPage(
          content: m.content,
          myId: _myUid,
          // 旧合并消息 items 里没有头像/昵称时，用当前会话实时解析兜底
          nameOf: _mergeNameOf,
          avatarOf: _mergeAvatarOf,
          // 会话上下文：文件点击走应用内预览（FilePreviewPage）用
          convId: widget.conv.id,
          convName: widget.conv.conversationName,
          // 旧合并消息 items 缺 file 元数据时，按 msgId 从当前会话消息反查兜底
          fileResolver: (mid) async {
            for (final mm in _msgs) {
              if (mm.msgId != null && mm.msgId == mid) return mm.file;
            }
            return null;
          },
        ),
      ),
    );
  }

  /// 多选模式底部操作栏（合并转发 / 逐条转发 / 收藏 / 取消）
  Widget _selectionActionBar() {
    final t = AppLocalizations.of(context).t;
    final count = _selectedClientMsgIds.length;
    return Container(
      color: context.cs.surface,
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        top: 6,
        bottom: 6 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Row(
        children: [
          Expanded(
            child: TextButton(
              onPressed: count >= 2 ? _mergeForwardSelected : null,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                visualDensity: VisualDensity.compact,
              ),
              child: Text(t('chatActionMergeForward'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14)),
            ),
          ),
          Expanded(
            child: TextButton(
              onPressed: count >= 1 ? _forwardEachSelected : null,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                visualDensity: VisualDensity.compact,
              ),
              child: Text(t('chatActionForwardEach'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14)),
            ),
          ),
          Expanded(
            child: TextButton(
              onPressed: count >= 1 ? _favoriteSelected : null,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                visualDensity: VisualDensity.compact,
              ),
              child: Text(t('chatActionFavorite'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14)),
            ),
          ),
          Expanded(
            child: TextButton(
              onPressed: _exitSelectionMode,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                visualDensity: VisualDensity.compact,
              ),
              child: Text(t('cancel'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14)),
            ),
          ),
          // L1 群已读详情：仅群/频道且单选时可用（单聊已有双勾，无需此入口）
          if (isGroup)
            Expanded(
              child: TextButton(
                onPressed: count == 1 ? _openReadDetailForSelected : null,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(t('chatActionReadDetail'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14)),
              ),
            ),
        ],
      ),
    );
  }

  /// L1 群已读详情：对当前单选的消息拉取已读名单 + 人数，弹 bottom sheet 展示。
  /// 复用会话已加载的 _members 解析昵称（回落 ID 尾号）。
  /// 群消息「已读详情」：针对某一条消息弹出 ReadDetailSheet。
  /// 长按菜单与多选栏共用，避免两处重复构造 bottom sheet。
  Future<void> _openReadDetailForMsg(ChatMsg m) async {
    if (m.msgId == null) return;
    final msgId = m.msgId.toString();
    if (!mounted) return;
    // 关闭长按炸开浮层：否则详情 sheet 关闭后会回落回菜单，而非回到聊天界面
    if (_longPressedMsg != null) {
      setState(() => _longPressedMsg = null);
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ReadDetailSheet(
        convId: widget.conv.id,
        msgId: msgId,
        myId: _myUid,
        memberNameOf: _readDetailNameOf,
      ),
    );
  }

  Future<void> _openReadDetailForSelected() async {
    final sel = _msgs
        .where((m) =>
            _selectedClientMsgIds.contains(m.clientMsgId) &&
            !m.recalled &&
            m.msgId != null)
        .toList();
    if (sel.length != 1) return;
    await _openReadDetailForMsg(sel.first);
  }

  /// 已读名单昵称解析：优先群成员昵称，回落 ID 尾号
  String _readDetailNameOf(String userId) {
    final u = userId.trim();
    if (u == _myUid.trim()) {
      final n = UserCache.myProfileData?['nickname']?.toString() ?? '';
      return n.isNotEmpty ? n : u;
    }
    for (final mm in _members) {
      if (mm['userId']?.toString() == u) {
        final n = mm['nickname']?.toString() ?? '';
        if (n.isNotEmpty) return n;
      }
    }
    return u;
  }

  /// 合并消息里发送者的显示名：我 → 我的昵称（不显示「我」）；
  /// 单聊对方 → 会话名；群聊 → 群成员昵称（解析不到回落 ID 尾号）
  String _mergeNameOf(String senderId) {
    final u = senderId.trim();
    if (u == _myUid.trim()) {
      final n = UserCache.myProfileData?['nickname']?.toString() ?? '';
      return n.isNotEmpty ? n : _senderName(u);
    }
    if (!isGroup) {
      final n = widget.conv.conversationName;
      return n.isNotEmpty ? n : _senderName(u);
    }
    return _senderName(u);
  }

  /// 合并消息里发送者的头像 URL：我 → 我的头像；单聊对方 → 会话头像；群聊 → 成员头像
  String _mergeAvatarOf(String senderId) {
    final u = senderId.trim();
    if (u == _myUid.trim()) return _myAvatar;
    if (!isGroup) return widget.conv.avatarUrl;
    return _memberAvatar(u);
  }

  /// 合并转发选中消息 → 选目标会话 → 发 type=12 消息
  Future<void> _mergeForwardSelected() async {
    if (_selectedClientMsgIds.length < 2) return;
    // 按消息列表顺序取（保持时间线）
    final sel = _msgs
        .where(
            (m) => _selectedClientMsgIds.contains(m.clientMsgId) && !m.recalled)
        .toList();
    if (sel.length < 2) return;
    final picked = await Navigator.push<Map>(
      context,
      MaterialPageRoute(builder: (_) => ForwardPickerPage(myId: _myUid)),
    );
    if (picked == null || !mounted) return;
    final targetId = picked['id']?.toString() ?? '';
    if (targetId.isEmpty) return;
    try {
      String convId;
      if (picked['kind'] == 'group') {
        convId = targetId;
      } else {
        final conv = await _svc.createDirect(targetId);
        convId = conv['id']?.toString() ?? '';
      }
      if (convId.isEmpty) throw Exception(_t('forwardNotAllowed'));
      final users = <String>[];
      final items = sel.map((m) {
        final name = _mergeNameOf(m.senderId);
        if (!users.contains(name)) users.add(name);
        return {
          'senderId': m.senderId,
          'senderName': name,
          'senderAvatar': _mergeAvatarOf(m.senderId),
          'type': m.type,
          'content': m.content,
          'time': _time(m.createdAt),
          'file': m.file, // 文件/视频元数据（url/size）→ 详情页渲染真实内容用
          'msgId': m.msgId ?? '', // 原消息 msgId → 详情页 file 缺失时反查兜底
        };
      }).toList();
      final content = jsonEncode({
        'v': 1,
        'count': sel.length,
        'users': users.join('、'),
        'items': items,
      });
      await _svc.sendRaw(convId, MessageType.mergeForward, content);
      if (!mounted) return;
      _exitSelectionMode();
      _toast(_t('forwardSent'));
    } catch (e) {
      if (!mounted) return;
      _toast(_errMsg(e, _t('forwardNotAllowed')));
    }
  }

  /// 逐条转发：选一次目标，按顺序逐条原样转发（不可转发类型自动跳过）
  Future<void> _forwardEachSelected() async {
    const forwardable = {1, 2, 3, 4, 5, 10, 12};
    final sel = _msgs
        .where((m) =>
            _selectedClientMsgIds.contains(m.clientMsgId) &&
            !m.recalled &&
            forwardable.contains(m.type))
        .toList();
    if (sel.isEmpty) return;
    final picked = await Navigator.push<Map>(
      context,
      MaterialPageRoute(builder: (_) => ForwardPickerPage(myId: _myUid)),
    );
    if (picked == null || !mounted) return;
    final targetId = picked['id']?.toString() ?? '';
    if (targetId.isEmpty) return;
    try {
      String convId;
      if (picked['kind'] == 'group') {
        convId = targetId;
      } else {
        final conv = await _svc.createDirect(targetId);
        convId = conv['id']?.toString() ?? '';
      }
      if (convId.isEmpty) throw Exception(_t('forwardNotAllowed'));
      for (final m in sel) {
        await _svc.sendRaw(convId, m.type, m.content,
            replyTo: m.replyTo, file: m.file);
      }
      if (!mounted) return;
      _exitSelectionMode();
      _toast(_t('forwardSent'));
    } catch (e) {
      if (!mounted) return;
      _toast(_errMsg(e, _t('forwardNotAllowed')));
    }
  }

  /// 批量收藏选中的消息（有服务端 msgId 的才收）
  Future<void> _favoriteSelected() async {
    final targets = _msgs
        .where((m) =>
            _selectedClientMsgIds.contains(m.clientMsgId) &&
            !m.recalled &&
            m.msgId != null)
        .toList();
    var ok = 0;
    for (final m in targets) {
      if (await _svc.favoriteAdd(widget.conv.id, m.msgId!)) ok++;
    }
    if (!mounted) return;
    _exitSelectionMode();
    _toast(ok == targets.length && targets.isNotEmpty
        ? _t('chatFavorited')
        : _t('chatFavoriteFailed'));
  }

  /// 会话内全部图片 URL 平铺（按消息顺序，撤回不计）——单图消息点开大图时
  /// 左右滑翻看其它图片用（2026-09-25，微信式）
  List<String> _convImages() {
    final out = <String>[];
    for (final m in _msgs) {
      if (m.type == 2 && !m.recalled) out.addAll(_parseImages(m.content));
    }
    return out;
  }

  Widget _buildMsgItem(int i, List<String> convImages) {
    final m = _msgs[i];
    _maybeAutoTranslate(m); // 自动翻译（内部去重 + 延迟到 build 后触发）
    return Column(
      children: [
        // 距上一条超过 5 分钟 → 居中时间分隔条
        if (_needTimeDivider(i))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: context.cs.onSurfaceVariant.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                ),
                child: Text(
                  _fullTime(m.createdAt),
                  style: TextStyle(
                      fontSize: 11, color: context.cs.onSurfaceVariant),
                ),
              ),
            ),
          ),
        // 群事件系统提示（type=6）：灰色居中小字条（微信式）
        if (m.type == 6 && !m.recalled)
          Padding(
            padding: const EdgeInsets.fromLTRB(48, 4, 48, 6),
            child: Text(_groupSystemText(m),
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: context.cs.onSurfaceVariant)),
          )
        else
          GestureDetector(
            // 多选模式：整行点按 = 选中/取消（内部手势被 AbsorbPointer 屏蔽）
            onTap: _selectionMode ? () => _toggleSelect(m) : null,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (_selectionMode) ...[
                  const SizedBox(width: 12),
                  _selectCheckbox(m),
                ],
                Expanded(
                  child: AbsorbPointer(
                    absorbing: _selectionMode,
                    child: RepaintBoundary(
                      key: _rowKeyFor(m.clientMsgId),
                      child: _MsgRow(
                        msg: m,
                        colors: _bubbleColors,
                        myId: _myUid,
                        isMine: m.senderId.trim() == _myUid.trim(),
                        senderName: _senderName(m.senderId),
                        showSenderName: isGroup,
                        // 头像：单聊（含小助手）用对方会话头像，群聊按成员查
                        myAvatar: _myAvatar,
                        peerAvatar: widget.conv.avatarUrl,
                        senderAvatar: _memberAvatar(m.senderId),
                        convImageUrls: convImages,
                        highlighted: _longPressedMsg?.clientMsgId ==
                                m.clientMsgId ||
                            (m.msgId != null && m.msgId == _jumpHighlightId),
                        onLongPress: _selectionMode
                            ? () {}
                            : () => _showLongPressOverlay(m),
                        timeText: _time(m.createdAt),
                        onRetry: m.status == MsgStatus.failed
                            ? () => _retry(m)
                            : null,
                        onCallTap: () => _openCallFromSignal(m.content),
                        moneyClaimed: _claimedMoneyIds.contains(m.msgId),
                        onMoneyTap: () => _claimMoney(m),
                        onAvatarTap: (uid) => _openMemberProfile(uid),
                        onReplyJump: _jumpToReply,
                        // 引用条文案：发送方 / 接收方同一出口；快照缺失时本地兜底（R-10）
                        replyPreviewFor: _replyPreviewFor,
                        onFileTap: () => _openFileBubble(m),
                        // AI 翻译：文本消息显示「译」按钮 + 译文条
                        translateEnabled: _translateEnabled,
                        translation: _translations[m.clientMsgId],
                        translating: _translating.contains(m.clientMsgId),
                        onTranslate: () => _translateMsg(m),
                        onMergeTap: () => _openMergeDetail(m),
                        // E2EE：某条加密气泡解密完成/解锁成功 → 帧末合并重绘
                        onE2Decrypted: _queueE2Repaint,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // 群公告：按当前语言选 zh/en（en 为空回退 zh）
    String announcementText = '';
    if (isGroup) {
      final lc = Localizations.localeOf(context).languageCode;
      final zh = widget.conv.conversation['announcementZh']?.toString() ?? '';
      final en = widget.conv.conversation['announcementEn']?.toString() ?? '';
      announcementText = lc == 'zh' ? zh : (en.isNotEmpty ? en : zh);
    }

    // 系统通知栏（状态栏）颜色跟随标题栏：顶栏是 context.cs.surface，
    // 状态栏区域原本露出的是 scaffoldBackgroundColor（灰色），不一致 → 锁成同色
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final topBarColor = context.cs.surface;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: topBarColor, // Android 状态栏背景 = 标题栏颜色
        statusBarIconBrightness:
            isDark ? Brightness.light : Brightness.dark, // 图标反色
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light, // iOS
        systemNavigationBarColor: Theme.of(context).scaffoldBackgroundColor,
        systemNavigationBarIconBrightness:
            isDark ? Brightness.light : Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        // bottom: false —— 底部安全区交给最底部区域自己处理（让 surface 背景能铺到屏幕底、
        // 且子级能读到真实 MediaQuery.padding.bottom 来避开系统导航栏）
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              // ===== 顶栏 =====
              _topBar(),
              // ===== 消息列表 + 浮动↓按钮 + 「+」悬浮功能面板 =====
              // 置顶消息卡 / 群公告卡已改为 Stack 内的悬浮层（不占布局）：
              // 出现/消失（首次返回、× 关闭）都不再把列表顶下去 = 界面零跳动。
              Expanded(
                child: Stack(
                  children: [
                    // 聊天设置 → 聊天窗口背景（渐变预设，铺在消息区最底层）
                    // 第十四批问题 3：背景层包 RepaintBoundary —— 键盘弹出
                    // resize 期间消息列表/输入栏的频繁重绘不再连带这层全屏
                    // 大图（降采样位图 ~10MB）每帧重新栅格化（Davey 主源之一）
                    Positioned.fill(
                        child: RepaintBoundary(child: _chatBackgroundLayer())),
                    // 点消息区收键盘 + 收面板（2026-09-19 需求 1）：
                    // translucent 不拦截列表自身手势——点消息行（预览/图片等）由
                    // 内层手势赢，点空白处（列表间隙/背景）才触发这里收键盘。
                    GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: () {
                        if (_plusOpen || _emojiOpen) {
                          setState(() {
                            _plusOpen = false;
                            _emojiOpen = false;
                          });
                        }
                        FocusScope.of(context).unfocus();
                      },
                      child: _loading
                          ? _buildLoadingView()
                          : _loadFailed
                              ? _buildLoadFailed()
                              : RefreshIndicator(
                                  // 下拉 = 加载更早的消息（不再全量刷新）：
                                  // 头部插入 + 滚动位置补偿见 _loadOlder；
                                  // 没有更早历史时立即完成，指示器直接收回
                                  color: AppTheme.primary,
                                  onRefresh: _loadOlder,
                                  child: _buildMessageList(),
                                ),
                    ),
                    // ===== 置顶消息卡 + 群公告卡（悬浮层）：叠在列表上方，不占布局。
                    // 单个 Positioned 包 Column —— 两卡永远纵向排列，绝不重叠；
                    // 出现/消失（首次返回、× 关闭）都不再把列表顶下去 = 零跳动。 =====
                    if (_hiddenFlagsLoaded &&
                        ((!_pinnedHidden && _pinnedCurrentContent.isNotEmpty) ||
                            (!_announceHidden && announcementText.isNotEmpty)))
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        // 出现时 200ms 淡入：卡片悬浮不占布局，淡入只动透明度，
                        // 零布局变化（此前硬蹦出来盖住消息顶部=观感跳）
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: 1),
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                          builder: (_, opacity, child) =>
                              Opacity(opacity: opacity, child: child),
                          child: Column(
                            children: [
                              if (!_announceHidden &&
                                  announcementText.isNotEmpty)
                                _announceCard(announcementText),
                              if (!_pinnedHidden &&
                                  _pinnedCurrentContent.isNotEmpty)
                                _pinnedCard(),
                            ],
                          ),
                        ),
                      ),
                    // ===== E2EE 单聊加密提示（2026-09-18 改悬浮）：盖在列表顶部，
                    // 不占布局、不拦截点击（IgnorePointer），消息列表滚动零影响 =====
                    if (_e2eeBanner)
                      Positioned(
                        top: 6,
                        left: 0,
                        right: 0,
                        child: IgnorePointer(child: _buildE2eeBanner()),
                      ),
                    // （功能/表情面板收起已并入上方消息区点按手势，原 Positioned.fill 拦截层删除）
                    // ===== 表情面板：宽屏=右下角悬浮小卡片；窄屏=输入栏上方全宽抽屉 =====
                    if (_emojiOpen && Breakpoints.isWide(context))
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: _EmojiPane(controller: _input),
                      ),
                    // ===== 「+」功能面板：宽屏=悬浮卡片；窄屏在输入栏上方渲染 =====
                    if (_plusOpen && Breakpoints.isWide(context))
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: _PlusDrawer(
                          onMention: isGroup ? _pickMention : null,
                          showMoney: FeatureFlags.instance.walletOn.value,
                          onItem: (name) {
                            setState(() => _plusOpen = false);
                            // 需求11：语音/视频通话入口（TRTC）
                            // 抽屉项按词典 key 匹配（name 为 key，显示文案由 _PlusDrawer 翻译）
                            if (name == 'chatDrawerVoiceCall') {
                              _openCall('voice');
                            } else if (name == 'chatDrawerVideoCall') {
                              _openCall('video');
                            } else if (name == 'chatDrawerAlbum') {
                              // 需求3：相册选图发送
                              _pickImage();
                            } else if (name == 'chatDrawerFile') {
                              // 功能 A：选本地文件 → 上传 → type=3 文件消息
                              _pickFile();
                            } else if (name == 'chatDrawerRedPacket') {
                              _openMoneyPage('redpacket');
                            } else if (name == 'chatDrawerTransfer') {
                              _openMoneyPage('transfer');
                            } else if (name == 'chatDrawerCard') {
                              _pickCard();
                            } else if (name == 'chatDrawerLocation') {
                              // 位置消息（2026-09-21 需求1，原「收藏」入口替换）
                              _pickLocation();
                            } else {
                              AppDialogs.toast(context,
                                  _t('chatComingSoon', {'name': _t(name)}));
                            }
                          },
                        ),
                      ),
                    // ===== 浮动↓按钮 =====
                    if (_showJumpBtn && !_plusOpen && !_emojiOpen)
                      Positioned(
                        bottom: 16,
                        right: 16,
                        child: _JumpToBottomBtn(
                          onTap: _animateToLatest, // 用户主动点 → 用动画
                        ),
                      ),
                  ],
                ),
              ),
              // ===== 底部区域：多选/静音/输入栏 + 弹出面板 =====
              // 统一 surface 背景 + 底部安全区 padding：背景连续铺到屏幕底（无灰色空带），
              // 内容整体上移避开系统导航栏
              Container(
                color: context.cs.surface,
                // 第十四批问题 3：必须用 paddingOf（aspect 订阅）而非 MediaQuery.of ——
                // 后者依赖整个 MediaQueryData，键盘弹出时 IME 动画每帧更新
                // viewInsets → 本 State 整页每帧全量 rebuild（ListView 可见消息
                // 行、顶栏、输入栏全重建）= 主线程 skipped frames + raster Davey。
                // paddingOf 只订阅 padding 字段，viewInsets 变化不再触发 rebuild。
                padding: EdgeInsets.only(
                    bottom: MediaQuery.paddingOf(context).bottom),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_selectionMode)
                      _selectionActionBar()
                    else if (_channelInputBlocked)
                      // 第十三批问题 5：频道普通成员不可发言 → 输入栏整块替换为
                      // 居中提示条（灰底细字，与禁言横幅同款风格；禁 emoji）
                      Container(
                        height: 64,
                        color: context.cs.surfaceContainerHighest
                            .withValues(alpha: 0.6),
                        alignment: Alignment.center,
                        child: Text(
                          _t('chatChannelMuted'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 14, color: context.cs.onSurfaceVariant),
                        ),
                      )
                    else if (_muteBanner != null)
                      Container(
                        height: 64,
                        color: context.cs.surfaceContainerHighest
                            .withValues(alpha: 0.6),
                        alignment: Alignment.center,
                        child: Text(
                          _muteBanner!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 14, color: context.cs.onSurfaceVariant),
                        ),
                      )
                    else
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _InputBar(
                            controller: _input,
                            quoteMsg: _quoteMsg,
                            onClearQuote: () =>
                                setState(() => _quoteMsg = null),
                            onSend: _send,
                            plusOpen: _plusOpen,
                            onTogglePlus: _togglePlusPanel,
                            emojiOpen: _emojiOpen,
                            onToggleEmoji: _toggleEmojiPanel,
                            onVoiceSend: _sendVoice,
                          ),
                        ],
                      ),
                    // 窄屏面板弹出动画：微信式从底部滑入/收起（AnimatedSize 平滑过渡高度）
                    // 背景与输入栏同用 surface（外层 Container 已铺底），底部安全区由外层 padding 承担
                    if (!Breakpoints.isWide(context) &&
                        (_plusOpen || _emojiOpen))
                      AnimatedSize(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.topCenter,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_plusOpen)
                              _PlusDrawer(
                                wide: false,
                                onMention: isGroup ? _pickMention : null,
                                showMoney: FeatureFlags.instance.walletOn.value,
                                onItem: (name) {
                                  setState(() => _plusOpen = false);
                                  if (name == 'chatDrawerVoiceCall') {
                                    _openCall('voice');
                                  } else if (name == 'chatDrawerVideoCall') {
                                    _openCall('video');
                                  } else if (name == 'chatDrawerAlbum') {
                                    _pickImage();
                                  } else if (name == 'chatDrawerFile') {
                                    _pickFile();
                                  } else if (name == 'chatDrawerRedPacket') {
                                    _openMoneyPage('redpacket');
                                  } else if (name == 'chatDrawerTransfer') {
                                    _openMoneyPage('transfer');
                                  } else if (name == 'chatDrawerCard') {
                                    _pickCard();
                                  } else if (name == 'chatDrawerLocation') {
                                    _pickLocation();
                                  } else {
                                    AppDialogs.toast(
                                        context,
                                        _t('chatComingSoon',
                                            {'name': _t(name)}));
                                  }
                                },
                              ),
                            if (_emojiOpen)
                              _EmojiPane(controller: _input, wide: false),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ], // close main Column children
          ),
        ),
        // ===== 长按全屏遮罩 =====
        bottomSheet: _longPressedMsg == null
            ? null
            : _LongPressOverlay(
                msg: _longPressedMsg!,
                myId: _myUid,
                rowRect: _longPressRect,
                snapshot: _longPressShot,
                colors: _bubbleColors,
                onClose: _closeLongPressOverlay,
                onCopy: () => _copy(_longPressedMsg!),
                onQuote: () => _quote(_longPressedMsg!),
                onRecall: () => _recall(_longPressedMsg!),
                onFavorite: () => _favorite(_longPressedMsg!),
                onForward: () => _forward(_longPressedMsg!),
                onPin: () => _pinMsg(_longPressedMsg!),
                onMultiSelect: () => _enterSelectionMode(_longPressedMsg!),
                onReadDetail: (isGroup &&
                        _longPressedMsg!.senderId == _myUid &&
                        _longPressedMsg!.msgId != null)
                    ? () => _openReadDetailForMsg(_longPressedMsg!)
                    : null,
              ),
      ),
    );
  }

  /// 顶栏：← 返回 + 居中（标题 + 在线状态） + 右侧 ··· 三点
  /// 历史加载最终失败：给"重新加载"入口（不再无声空白）
  Widget _buildLoadFailed() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined,
              size: 40, color: context.cs.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(_t('chatHistoryLoadFailed'),
              style:
                  TextStyle(fontSize: 13, color: context.cs.onSurfaceVariant)),
          const SizedBox(height: 14),
          TextButton(
            onPressed: _retryLoadHistory,
            child: Text(_t('chatRetryLoad'),
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primary)),
          ),
        ],
      ),
    );
  }

  /// 顶栏副标题「N 成员, M 在线」（第十批，参考图实测：字号 14、
  /// 成员灰墨 #5E6876、在线数绿 #00AA3A；M 取 members 端点顶层 onlineCount）
  Widget _memberSubtitle() {
    final members = _t('chatSubMembers', {'count': '$_groupMemberCount'});
    final online = _t('chatSubOnline', {'count': '$_onlineCount'});
    const gray = Color(0xFF5E6876);
    const green = Color(0xFF00AA3A);
    TextStyle st(Color c) => TextStyle(fontSize: 14, height: 1.0, color: c);
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: members, style: st(gray)),
        if (_onlineLoaded) ...[
          TextSpan(text: ', ', style: st(gray)),
          TextSpan(text: online, style: st(green)),
        ],
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _topBar() {
    // 在线状态：从会话数据读取（后端 peerOnline + peerOnlineDev）
    final isGroupType = isGroup;
    final peerOnline = widget.conv.peerOnline;
    final peerDev = widget.conv.peerOnlineDev;
    final hasMobile = peerDev.any((d) => d == 'ios' || d == 'android');
    // 小助手永远在线（官方账号）；频道（type=3）不显示在线状态
    final statusText = (isGroupType || isChannel)
        ? ''
        : (widget.conv.isAssistant
            ? _t('chatStatusOnline')
            : (peerOnline
                ? (hasMobile
                    ? _t('chatStatusMobileOnline')
                    : _t('chatStatusDesktopOnline'))
                : _t('chatStatusOffline')));
    return Container(
      decoration: BoxDecoration(
          color: context.cs.surface,
          border: Border(
              bottom:
                  BorderSide(color: context.cs.outlineVariant, width: 0.5))),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Row(
        children: [
          // 宽屏双栏嵌入：无返回键（返回键 = 清右栏，外层 PopScope 处理）
          if (!widget.embedded)
            IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              // 2026-09-29 统一返回图标：全 App 回到 arrow_back_ios_new（V2 细雪佛龙）
              icon: Icon(Icons.arrow_back_ios_new,
                  size: 26, color: context.cs.onSurface),
            )
          else
            const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 标题 + 客服认证勾（2026-09-15 第十三批：单聊对方
                // 账号角色=客服时亮 V 盾，样式与通讯录/消息列表一致；
                // 群/频道不显示 —— 群成员 role 是群内角色，勿混用）
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      // 2026-09-28 需求1：群聊点击标题（群名）进 TG 风格群资料页
                      // GroupManagePage（成员/群主同页：头像块/简介/媒体/成员区）
                      child: GestureDetector(
                        onTap: isGroupType
                            ? () async {
                                await Navigator.of(context).push(
                                    MaterialPageRoute(
                                        builder: (_) => GroupManagePage(
                                            conv: widget.conv)));
                                if (mounted && isGroup) unawaited(_loadPins());
                              }
                            : null,
                        child: Text(
                            // 第十批：群名不再拼人数（人数移到副标题「N 成员, M 在线」）
                            // 2026-09-28：管理群组页改群名后 _overrideName 即时跟随
                            _overrideName ?? widget.conv.conversationName,
                            style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                                color: context.cs.onSurface)),
                      ),
                    ),
                    if (!isGroupType &&
                        !isChannel &&
                        CertBadge.isKefu(_peerRole)) ...[
                      const SizedBox(width: 4),
                      // 蓝盾勾与好友资料页/消息列表同款（二十六批：四入口统一）
                      const V2SealBadge(size: 20, color: Color(0xFF4FA4EE)),
                    ],
                  ],
                ),
                // 需求5（2026-09-22）：群级开关 showMembers 关闭时不渲染
                // 「N 成员, M 在线」副标题；需求3（2026-09-22 二批）：群隐私
                // 开启时同样不渲染（用户实测反馈）
                if (isGroupType &&
                    _showMembers &&
                    !_privacyCountOn &&
                    _groupMemberCount > 0) ...[
                  const SizedBox(height: 2),
                  _memberSubtitle(),
                ],
                // 频道（第十二批问题 8）：副标题只显示「N 人订阅」，
                // 不显示在线数/在线状态；members 拉取失败时 _groupMemberCount
                // 自动回落会话列表携带的 memberCount，仍为 0 则隐藏整行。
                if (isChannel && _groupMemberCount > 0) ...[
                  const SizedBox(height: 2),
                  Text(
                      _t('chatSubSubscribers', {'count': '$_groupMemberCount'}),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, height: 1.0, color: Color(0xFF5E6876))),
                ],
                if (!isGroupType && !isChannel && statusText.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(statusText,
                      style: TextStyle(
                          fontSize: 11,
                          color: peerOnline
                              ? AppTheme.primary
                              : context.cs.onSurfaceVariant)),
                ],
              ],
            ),
          ),
          IconButton(
            onPressed: _openSettings,
            icon: Icon(Icons.more_horiz, size: 24, color: context.cs.onSurface),
          ),
        ],
      ),
    );
  }

  // ===== 第十批：置顶消息卡 + 群公告卡 =====
  // 第十二批问题 10 紧凑化：标题+内容同行单行卡（高 36），两卡总高 76 ≤
  // 紧凑前单卡高 80.1（用户要求「群公告+置顶消息 2 个加起来不能有一个卡片
  // 高度」）；竖条相应缩为高 20。其余几何沿用第十批实测口径（参考图
  // clipboard-...198Z，451px ⇒ logical=px/1.0738）：竖条宽 5.6、距卡左 22.3、
  // 标题 15/w600 #0C0D12、内容 15 灰 #8F97A0、× 20 #616B83 右缩 17.1。

  /// 卡片主体（置顶/公告共用样式）：标题与内容同行；[onClose] 为 null 时无 ×。
  Widget _pinStyleCard({
    required String title,
    required String content,
    required double marginTop,
    int segments = 1,
    int currentSegment = 0,
    VoidCallback? onTap,
    VoidCallback? onClose,
    VoidCallback? onUnpin, // 2026-09-29 置顶条群主专用「取消置顶」（× 左侧）
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 36.0,
        margin: EdgeInsets.only(left: 16.8, right: 13.0, top: marginTop),
        padding: const EdgeInsets.only(left: 22.3),
        decoration: BoxDecoration(
          color: context.cs.surface,
          borderRadius: BorderRadius.circular(14),
          // 悬浮层投影：消息从卡片底下滚过时有「浮」的层次（不再贴在通栏里）
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0C0D12).withValues(alpha: 0.10),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            _pinBarSegments(segments, currentSegment),
            const SizedBox(width: 16),
            Text(title,
                maxLines: 1,
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    height: 1.0,
                    color: Color(0xFF0C0D12))),
            const SizedBox(width: 10),
            Expanded(
              child: Text(content,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15, height: 1.0, color: Color(0xFF8F97A0))),
            ),
            if (onUnpin != null)
              // 2026-09-29：「取消」文字按钮，位于 × 左侧（群主可见）
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onUnpin,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8, right: 4),
                  child: Text(_t('commonCancel'),
                      style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF616B83))),
                ),
              ),
            if (onClose != null)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onClose,
                child: const Padding(
                  // × ink 右缩 17.1，含 8 点击热区
                  padding: EdgeInsets.only(left: 8, right: 17.1),
                  child: Icon(Icons.close, size: 20, color: Color(0xFF616B83)),
                ),
              )
            else
              const SizedBox(width: 17.1),
          ],
        ),
      ),
    );
  }

  /// 左侧黑色竖条：N 条置顶时平分为 N 段（段间 2px 缝），当前段黑、其余浅灰
  Widget _pinBarSegments(int n, int current) {
    return SizedBox(
      width: 5.6,
      height: 20.0,
      child: Column(
        children: [
          for (var i = 0; i < n; i++) ...[
            if (i > 0) const SizedBox(height: 2),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: i == current
                      ? const Color(0xFF0C0D12)
                      : const Color(0xFFD9DCE1),
                  borderRadius: BorderRadius.circular(2.8),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 置顶消息卡：点击循环切换下一条并滚动跳到该消息位置；
  /// × = 本地隐藏（第十三批问题 4：按会话持久化，重进不再显示）
  Widget _pinnedCard() {
    final n = _pinnedMsgs.length;
    return _pinStyleCard(
      title: _t('chatPinnedBarTitle'),
      content: _pinnedCurrentContent,
      marginTop: 8.0,
      segments: n < 1 ? 1 : n,
      currentSegment: _pinnedIndex.clamp(0, n - 1),
      onTap: _cyclePinned,
      // 2026-09-29 需求2：群主在 × 左侧加「取消」，可直接取消该消息置顶
      onUnpin: _myRole == 1 ? _unpinCurrentPinned : null,
      onClose: () {
        setState(() => _pinnedHidden = true);
        _persistHiddenFlag('pinHidden');
      },
    );
  }

  /// 群公告卡：单段黑竖条；× = 本地隐藏（与置顶同机制，持久化按会话）
  Widget _announceCard(String text) {
    return _pinStyleCard(
      title: _t('chatAnnounceBarTitle'),
      content: text,
      // 紧凑双卡间的缝隙由本 margin 提供（4 < 竖条段缝观感，两卡近似一体的上下两行）
      marginTop: 4.0,
      onClose: () {
        setState(() => _announceHidden = true);
        _persistHiddenFlag('announceHidden');
      },
    );
  }

  // 头像色板统一走主题，保证与其它页面一致
  static const _bubbleColors = AppTheme.avatarColors;
}

// ======================= 消息行（支持多种类型气泡 + 长按高亮） =======================

// ---- 聊天设置生效（chat_settings_page 的气泡颜色 / 字体大小两项） ----

/// 当前气泡配色（收/发成对，见 kChatBubblePresets，0..9，越界兜底）
ChatBubblePreset _chatBubblePresetOf() {
  final i = AppSettings.instance.chatBubbleColor
      .clamp(0, kChatBubblePresets.length - 1);
  return kChatBubblePresets[i];
}

/// 对方消息的气泡颜色：预设的「收到的浅色」。
/// 深色模式不吃浅色预设——浅色底配浅色字会看不清，回退主题表面色。
Color _chatPeerBubbleColor(BuildContext context) {
  if (Theme.of(context).brightness == Brightness.dark) {
    return Theme.of(context).colorScheme.surface;
  }
  return _chatBubblePresetOf().recv;
}

/// 我的消息气泡颜色：预设的「发送的彩色」（默认 #EFFDDE，TG 同款浅绿）。
/// 深色模式保持主色——pastel 浅色底在深色背景下观感差。
Color _chatMyBubbleColor(BuildContext context) {
  if (Theme.of(context).brightness == Brightness.dark) {
    return AppTheme.primary;
  }
  return _chatBubblePresetOf().sent;
}

/// 我的气泡文字颜色：preset 全是 pastel 浅色底 ⇒ 浅色模式用深色墨迹
/// （与参考预览卡气泡文字一致）；深色模式仍白字。
Color _chatMyBubbleTextColor(BuildContext context) {
  if (Theme.of(context).brightness == Brightness.dark) {
    return Colors.white;
  }
  return const Color(0xFF1C1C1C);
}

/// type=7 通话信令是否为「纯信令」（不进气泡流）：
/// 一通电话一条记录（2026-09-16 第二轮）：**只有 invite 是通话记录气泡**，
/// 结束态（时长/拒绝/未接通）由服务端把 invite 消息原地改写后经 call_update
/// 事件下发；accept/cancel/reject/join/leave/sdp/ice 是纯实时信令。旧版本
/// 服务端曾把 hangup 也单独落库（一次接现 2 条记录），历史加载同样按此过滤。
bool _isPureCallSignal(String content) {
  try {
    final j = jsonDecode(content);
    if (j is Map) {
      final a = j['action']?.toString() ?? '';
      return a != 'invite';
    }
  } catch (_) {}
  return false;
}

/// 语音气泡（type=4）：波形条 + 时长 + 播放/暂停图标，宽度随时长线性变化；
/// 订阅 [VoicePlayerService] 全局状态高亮"已播"进度。content 为 JSON：
/// {"url","duration","waveform","size"}。url 空（上传中）时点击无效。
class _VoiceBubble extends StatelessWidget {
  final String content;
  final bool isMine;
  final String? msgId;
  const _VoiceBubble({required this.content, required this.isMine, this.msgId});

  static Map<String, dynamic> _decode(String c) {
    try {
      final m = jsonDecode(c);
      if (m is Map) return Map<String, dynamic>.from(m);
    } catch (_) {}
    return {};
  }

  /// 微信式宽度：1s→最小，60s→最大，线性插值。
  /// minW 84（2026-09-20 溢出修复：原 76 扣掉 padding 后刚好被
  /// 图标+时长占满，毫无余量，字体放大档直接撑爆 Row 右侧 18px）。
  static double _width(int durMs) {
    const minW = 84.0, maxW = 220.0;
    final sec = (durMs / 1000).clamp(0, 60).toDouble();
    return (minW + (sec / 60) * (maxW - minW)).clamp(minW, maxW);
  }

  @override
  Widget build(BuildContext context) {
    final d = _decode(content);
    final durMs = (d['duration'] as num?)?.toInt() ?? 0;
    final url = (d['url'] as String?) ?? '';
    final wave =
        (d['waveform'] as List?)?.map((e) => (e as num).toDouble()).toList() ??
            [];
    final sec = (durMs / 1000).round();
    final bg =
        isMine ? _chatMyBubbleColor(context) : _chatPeerBubbleColor(context);
    final fg = isMine ? Colors.white : context.cs.onSurface;

    return ValueListenableBuilder<VoicePlaybackState>(
      valueListenable: VoicePlayerService.instance.state,
      builder: (ctx, st, _) {
        final isPlaying = st.msgId == msgId && st.playing;
        final progress = (st.msgId == msgId && st.durationMs > 0)
            ? (st.positionMs / st.durationMs).clamp(0.0, 1.0)
            : 0.0;
        final icon =
            isPlaying ? Icons.graphic_eq_rounded : Icons.play_arrow_rounded;
        final bars = _WaveBars(
            values: wave, progress: progress, playing: isPlaying, color: fg);
        // 时长文字固定字号不跟随聊天字体档缩放（2026-09-20 溢出修复）：
        // 气泡宽度是按档 2 算的固定值，文字被全局 textScaler 放大后
        // Row 右侧溢出（真机竖排红字 RIGHT OVERFLOWED BY 18 PIXELS）。
        final durText = Text('$sec"',
            textScaler: TextScaler.noScaling,
            style: TextStyle(fontSize: 13, color: fg.withValues(alpha: 0.85)));
        // 微信布局：mine 时长在左、图标在右；peer 图标在左、时长在右。
        final children = isMine
            ? <Widget>[
                durText,
                const SizedBox(width: 8),
                Expanded(child: bars),
                const SizedBox(width: 6),
                Icon(icon, size: 20, color: fg),
              ]
            : <Widget>[
                Icon(icon, size: 20, color: fg),
                const SizedBox(width: 6),
                Expanded(child: bars),
                const SizedBox(width: 8),
                durText,
              ];
        final t = AppLocalizations.of(ctx).t;
        return Semantics(
          label: t('voiceMessage'),
          child: GestureDetector(
            onTap: url.isEmpty
                ? null
                : () => VoicePlayerService.instance
                    .toggle(url, msgId ?? '', durationMs: durMs),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: _width(durMs),
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.max,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: children,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 波形条：把归一化振幅画成竖条；progress 左侧（已播部分）实色，右侧半透明。
class _WaveBars extends StatelessWidget {
  final List<double> values;
  final double progress;
  final bool playing;
  final Color color;
  const _WaveBars(
      {required this.values,
      required this.progress,
      required this.playing,
      required this.color});

  @override
  Widget build(BuildContext context) {
    const int target = 28; // 目标显示条数（宽度够时）
    // 基线振幅序列（长度不定：空=占位平条；超出目标先均值降采样到 target）
    final List<double> raw;
    if (values.isEmpty) {
      raw = List.filled(target, 0.25);
    } else if (values.length >= target) {
      raw = _downsample(values, target);
    } else {
      raw = values.map((e) => e.clamp(0.08, 1.0)).toList();
    }
    return LayoutBuilder(
      builder: (ctx, bc) {
        // 2026-09-20 溢出修复（第二处根因）：每条最小 1.5px + 间距 2px 是
        // 硬下限，28 条最少要 96px——短语音（2''）气泡宽度 84，扣掉时长和
        // 播放键后 Expanded 只剩个位数像素，波形条挤成一坨向右溢出（白色
        // 方块状残影）。改为按可用宽度收缩条数，永远不再溢出。
        final w = bc.maxWidth.isFinite ? bc.maxWidth : 60.0;
        const gap = 2.0;
        final maxBars = ((w + gap) / (1.5 + gap)).floor().clamp(1, target);
        final v = raw.length > maxBars ? _downsample(raw, maxBars) : raw;
        final bw = ((w - gap * (v.length - 1)) / v.length).clamp(1.5, 6.0);
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(v.length, (i) {
            final played = (i / v.length) <= progress;
            final h = (4 + v[i] * 22).clamp(4.0, 26.0);
            return Container(
              width: bw,
              height: h,
              decoration: BoxDecoration(
                color: color.withValues(alpha: played ? 1.0 : 0.4),
                borderRadius: BorderRadius.circular(bw / 2),
              ),
            );
          }),
        );
      },
    );
  }

  /// 均值降采样：把 values 压缩到 target 个（每窗口取均值，振幅钳 0.08~1.0）
  static List<double> _downsample(List<double> values, int target) {
    final out = <double>[];
    final step = values.length / target;
    for (int i = 0; i < target; i++) {
      final s = (i * step).floor();
      final e = ((i + 1) * step).ceil();
      double sum = 0;
      for (int j = s; j < e && j < values.length; j++) sum += values[j];
      out.add((sum / (e - s).clamp(1, 1 << 30)).clamp(0.08, 1.0));
    }
    return out;
  }
}

class _MsgRow extends StatelessWidget {
  final ChatMsg msg;
  final List<Color> colors;
  final String myId;
  final bool isMine;
  final bool highlighted;
  final VoidCallback onLongPress;
  final String timeText;
  final VoidCallback? onRetry;
  final VoidCallback? onCallTap; // 通话邀请气泡点击（接听）
  final String senderName; // 群聊显示发送者昵称
  final bool showSenderName;
  final bool moneyClaimed; // 红包/转账已领取
  final VoidCallback? onMoneyTap; // 红包/转账点击领取
  final ValueChanged<String>? onAvatarTap; // 点头像看资料/加好友（群隐私拦截在外层）
  final ValueChanged<String>? onReplyJump; // 点引用条：携带被引用消息 msgId
  /// 引用条文案解析器（含本地兜底）：由 ChatPage 注入（_ChatPageState._replyPreviewFor）。
  /// 为 null 时回落 ChatMsg 自带的快照逻辑，保持本组件可独立复用。
  final String Function(ChatMsg)? replyPreviewFor;
  final VoidCallback? onFileTap; // 文件气泡点击（进预览页 / 外部打开）
  final String myAvatar; // 我方头像 URL
  final String peerAvatar; // 单聊对方头像 URL（含小助手后台配置头像）
  final String senderAvatar; // 群聊该消息发送者头像 URL

  /// 会话内全部图片 URL（2026-09-25）：图片气泡点开大图时左右滑翻看用
  final List<String>? convImageUrls;

  // ===== AI 翻译 =====
  final String? translation; // 已翻译的译文（null = 未翻译，不显示译文条）
  final bool translating; // 正在翻译（按钮转圈）
  final VoidCallback? onTranslate; // 点「译」按钮

  final VoidCallback? onMergeTap; // 合并转发气泡点击（进聊天记录详情页）

  // E2EE（§36）：占位气泡解密完成/解锁成功后由行内回调 → 父级 setState 重绘
  final VoidCallback? onE2Decrypted;

  // AI 翻译是否开启（服务端已配置）：false 时不显示「译」按钮
  final bool translateEnabled;

  const _MsgRow({
    super.key,
    required this.msg,
    required this.colors,
    required this.myId,
    required this.isMine,
    required this.highlighted,
    required this.onLongPress,
    required this.timeText,
    this.onRetry,
    this.onCallTap,
    this.senderName = '',
    this.showSenderName = false,
    this.moneyClaimed = false,
    this.onMoneyTap,
    this.onAvatarTap,
    this.onReplyJump, // 点引用条 → 跳到被引用消息
    this.replyPreviewFor, // 引用条文案解析（含本地兜底）
    this.onFileTap,
    this.myAvatar = '',
    this.peerAvatar = '',
    this.senderAvatar = '',
    this.convImageUrls,
    this.translation,
    this.translating = false,
    this.onTranslate,
    this.onMergeTap,
    this.onE2Decrypted,
    this.translateEnabled = false,
  });

  /// 微信式上传进度（2026-09-17）：sending 且进度<1 的图片/文件气泡，
  /// 叠半透明遮罩 + 百分比 + 细进度条。文字等其他类型不走这里（发送即达）。
  Widget _wrapUploadProgress(Widget child) {
    if (msg.status != MsgStatus.sending || msg.uploadProgress >= 1) {
      return child;
    }
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: _UploadOverlay(progress: msg.uploadProgress),
        ),
      ],
    );
  }

  /// E2EE（§36）：type=13 同步取明文。缓存命中直接返回；未命中显示占位并
  /// 异步解密（完成后 [onE2Decrypted] → 父级 setState 重绘）。
  /// 本地乐观明文（非 JSON）原样返回，发送侧无感。
  String _e2PlainOf(String Function(String) t) {
    final mid = msg.msgId ?? '';
    final key = mid.isNotEmpty ? 's:$mid' : 'c:${msg.clientMsgId}';
    return E2eeService.instance.plainFor(
      msg.content,
      key,
      lockedText: t('e2Locked'),
      failedText: t('e2DecryptFail'),
      onDone: (_) => onE2Decrypted?.call(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final colorIdx = msg.senderId.hashCode.abs() % colors.length;
    final senderColor = colors[colorIdx];
    // 小助手（虚拟 uid -1）头像显示"助"
    final senderText = msg.senderId == '-1'
        ? '助'
        : (msg.senderId.length > 6
            ? msg.senderId.substring(msg.senderId.length - 2)
            : msg.senderId);

    // 2026-09-28 需求：文本/E2EE 文本气泡把 meta（已编辑+时间+已读未读勾）内联
    // 到气泡内文字末尾（单行跟在文字后、多行落末行行尾，与 PC 端 bubbleMeta 一致）；
    // 专用卡片（图片/文件/语音/红包/转账/通话/名片/链接/合并/位置）保持气泡下 meta。
    final isTextBubble = !msg.recalled &&
        (msg.type == MessageType.text || msg.type == MessageType.e2Text);

    Widget bubble;
    if (msg.recalled) {
      // 撤回态统一覆盖所有消息类型：图片/文件(视频)/红包等分支此前不检查
      // recalled，撤回后气泡照旧渲染、视频仍可播放下载（2026-09-17 用户反馈）。
      bubble = Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(t('chatMsgRecalled'),
            style: TextStyle(fontSize: 13, color: context.cs.onSurfaceVariant)),
      );
    } else
      switch (msg.type) {
        case 4: // 语音（content=JSON {"url","duration","waveform","size"}）
          bubble = _wrapUploadProgress(_VoiceBubble(
            content: msg.content,
            isMine: isMine,
            msgId: msg.msgId,
          ));
          break;
        case 2: // 图片
          bubble = _wrapUploadProgress(_ImageGridBubble(
            urls: _parseImages(msg.content),
            convImages: convImageUrls,
          ));
          break;
        case 3: // 文件
          final uploading =
              msg.status == MsgStatus.sending && msg.uploadProgress < 1;
          bubble = _wrapUploadProgress(_FileBubble(
            name: msg.content,
            file: msg.file,
            size: (msg.file?['size'] as num?)?.toInt() ?? 0,
            // 上传中点预览必然失败（object 还没拿到）：上传期间禁点
            onTap: uploading ? () {} : (onFileTap ?? () {}),
          ));
          break;
        case 8: // 红包（content=JSON {kind,amount,note}）
          bubble = _MoneyBubble(
            content: msg.content,
            isRed: true,
            mine: isMine,
            claimed: moneyClaimed,
            onTap: onMoneyTap ?? () {},
          );
          break;
        case 9: // 转账
          bubble = _MoneyBubble(
            content: msg.content,
            isRed: false,
            mine: isMine,
            claimed: moneyClaimed,
            onTap: onMoneyTap ?? () {},
          );
          break;
        case 7: // 通话邀请（TRTC 信令）
          bubble = _CallBubble(
            content: msg.content,
            onTap: onCallTap ?? () {},
          );
          break;
        case 10: // 名片（content=JSON {"userId","nickname","avatar"}）
          bubble = _CardBubble(
            content: msg.content,
            colors: colors,
            onTap: () => _openCardProfile(context, msg.content),
          );
          break;
        case 11: // 链接卡片（content=JSON LinkCardData，见 link_card.dart）
          bubble = LinkCardWidget(content: msg.content, isMine: isMine);
          break;
        case MessageType.location: // 位置（content=JSON {lat,lng,name,address}）
          bubble = _LocationBubble(content: msg.content, isMine: isMine);
          break;
        case MessageType
              .mergeForward: // 合并转发（content=JSON {v,count,users,items}）
          bubble = _MergeBubble(
            content: msg.content,
            isMine: isMine,
            onTap: onMergeTap ?? () {},
          );
          break;
        case MessageType.e2Text: // 端到端加密文本：走与文本相同的渲染（解密见 _e2PlainOf）
        default:
          if (msg.recalled) {
            bubble = Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(t('chatMsgRecalled'),
                  style: TextStyle(
                      fontSize: 13, color: context.cs.onSurfaceVariant)),
            );
          } else {
            // type=13：同步取明文（缓存命中），未命中显示占位并异步解密重绘；
            // 解锁后 E2eeService.invalidateCache() + setState 即可刷新。
            final plainText =
                msg.type == MessageType.e2Text ? _e2PlainOf(t) : msg.content;
            bubble = Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isMine
                    ? _chatMyBubbleColor(context) // 聊天设置 → 气泡颜色（发送侧）
                    : _chatPeerBubbleColor(context), // 聊天设置 → 气泡颜色（接收侧）
                borderRadius: BorderRadius.circular(AppTheme.radiusBubble),
                border: null,
                boxShadow: [
                  if (highlighted)
                    BoxShadow(
                      color: AppTheme.primary.withValues(alpha: 0.18),
                      blurRadius: 16,
                      offset: const Offset(0, 0),
                    ),
                ],
              ),
              constraints: const BoxConstraints(maxWidth: 280),
              child: Column(
                crossAxisAlignment:
                    isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  if (msg.hasReply)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        final id = msg.replyTo ?? '';
                        if (id.isNotEmpty && id != '0') onReplyJump?.call(id);
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: isMine
                              ? Colors.white24
                              : context.cs.surfaceContainer,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                  replyPreviewFor?.call(msg) ??
                                      msg.replyPreview(t),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: context.cs.onSurfaceVariant)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  // 2026-09-28：meta（已编辑+时间+已读未读勾）用 WidgetSpan 内联到
                  // 文字末尾——单行跟在文字后、多行自然落末行行尾（气泡内右下角，
                  // 与 PC 端 bubbleMeta 行为一致）；颜色跟随正文色 55% 透明，
                  // 自己的自定义气泡色（含浅色）下也可读。
                  Builder(builder: (context) {
                    final metaColor = (isMine
                            ? _chatMyBubbleTextColor(context)
                            : context.cs.onSurface)
                        .withValues(alpha: 0.55);
                    return Text.rich(
                      TextSpan(
                        text: plainText,
                        style: TextStyle(
                            // 字体大小档位已改为 MaterialApp 全局 textScaler（main.dart），
                            // 这里固定基准字号 15，避免「档位 × 气泡映射」双重缩放
                            fontSize: 15.0,
                            color: isMine
                                ? _chatMyBubbleTextColor(context)
                                : context.cs.onSurface),
                        children: [
                          if (timeText.isNotEmpty) ...[
                            const TextSpan(text: '\u2009\u2009'),
                            WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (msg.edited)
                                    Padding(
                                      padding:
                                          const EdgeInsets.only(right: 4),
                                      child: Text(t('chatMsgEdited'),
                                          style: TextStyle(
                                              fontSize: 10.5,
                                              fontStyle: FontStyle.italic,
                                              color: metaColor)),
                                    ),
                                  Text(timeText,
                                      style: TextStyle(
                                          fontSize: 10.5,
                                          color: metaColor)),
                                  if (isMine) ...[
                                    const SizedBox(width: 4),
                                    // 状态位固定 13x13 居中：sending 转圈 /
                                    // read 双勾（主色）/ sent 单勾 / failed 可点重试
                                    SizedBox(
                                      width: 13,
                                      height: 13,
                                      child: Center(
                                        child: msg.status == MsgStatus.sending
                                            ? SizedBox(
                                                width: 9,
                                                height: 9,
                                                child:
                                                    CircularProgressIndicator(
                                                        strokeWidth: 1.2,
                                                        color: metaColor))
                                            : msg.status == MsgStatus.read
                                                ? const Icon(Icons.done_all,
                                                    size: 12,
                                                    color: AppTheme.primary)
                                                : msg.status == MsgStatus.sent
                                                    ? Icon(Icons.check,
                                                        size: 12,
                                                        color: metaColor)
                                                    : msg.status ==
                                                            MsgStatus.failed
                                                        ? InkWell(
                                                            onTap: onRetry,
                                                            child: const Icon(
                                                                Icons
                                                                    .error_outline,
                                                                size: 12,
                                                                color: AppTheme
                                                                    .danger))
                                                        : const SizedBox
                                                            .shrink(),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  }),
                ],
              ),
            );
          }
      }

    final bubbleWidget = GestureDetector(
      // type=13 且本机未就绪（未建钥/未解锁）：点按弹解锁窗（输登录密码恢复私钥），
      // 成功后回调父级重绘（所有占位气泡重新解密）
      onTap: msg.type == MessageType.e2Text && !E2eeService.instance.isReady
          ? () async {
              final ok = await E2eeUnlockSheet.show(context);
              if (ok) onE2Decrypted?.call();
            }
          : null,
      onLongPress: msg.recalled ? null : onLongPress,
      child: bubble,
    );

    // 只对文本消息（type=1）显示「译」按钮；撤回/空内容/翻译未开启不显示
    final showTranslateBtn = translateEnabled &&
        !msg.recalled &&
        msg.type == 1 &&
        msg.content.trim().isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        mainAxisAlignment:
            isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMine) ...[
            GestureDetector(
              onTap: () => onAvatarTap?.call(msg.senderId),
              child: _avatar(senderColor, senderText),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment:
                  isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                // 群聊：显示发送者昵称
                if (showSenderName && !isMine && !msg.recalled)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Text(senderName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: context.cs.onSurfaceVariant)),
                  ),
                // AI 翻译：「译」小圆钮常驻气泡外侧（对方消息在右、我的在左）
                if (showTranslateBtn)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (isMine) _translateButton(context),
                      Flexible(child: bubbleWidget),
                      if (!isMine) _translateButton(context),
                    ],
                  )
                else if (!isTextBubble && !msg.recalled)
                  // 2026-09-28 优化：卡片消息（图片/文件/语音/红包/转账/通话/名片/
                  // 链接/合并/位置）的时间/已读未读从「气泡下方独立行」移入「气泡
                  // 右下角内侧」——Stack 角标叠层 + 半透明深色胶囊底（任意卡片底色
                  // 可读），与 PC 端 .message-meta-in 同款视觉。
                  Stack(
                    children: [
                      bubbleWidget,
                      Positioned(
                        bottom: 5,
                        right: 7,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.30),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (timeText.isNotEmpty)
                                Text(timeText,
                                    style: const TextStyle(
                                        fontSize: 10.5, color: Colors.white)),
                              if (isMine) ...[
                                const SizedBox(width: 5),
                                SizedBox(
                                  width: 14,
                                  height: 13,
                                  child: Center(
                                    child: msg.status == MsgStatus.sending
                                        ? const SizedBox(
                                            width: 11,
                                            height: 11,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 1.5,
                                                color: Colors.white),
                                          )
                                        : msg.status == MsgStatus.read
                                            ? const Icon(Icons.done_all,
                                                size: 12,
                                                color: AppTheme.primary)
                                            : msg.status == MsgStatus.sent
                                                ? const Icon(Icons.check,
                                                    size: 12,
                                                    color: Colors.white)
                                                : msg.status == MsgStatus.failed
                                                    ? InkWell(
                                                        onTap: onRetry,
                                                        child: const Icon(
                                                            Icons
                                                                .error_outline,
                                                            size: 13,
                                                            color: AppTheme
                                                                .danger),
                                                      )
                                                    : const SizedBox.shrink(),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  )
                else
                  bubbleWidget,
                // 译文条：灰底常驻显示（不做收起）
                if (translation != null) ...[
                  const SizedBox(height: 3),
                  _translationBar(context),
                ],
                // 2026-09-28：非撤回卡片的时间/已读未读已移入气泡右下角内侧（上方
                // Stack 角标），此处下方 meta 行仅剩撤回气泡（recalled）保留。
                if (!isTextBubble && msg.recalled) ...[
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (timeText.isNotEmpty)
                        Text(timeText,
                            style: TextStyle(
                                fontSize: 11,
                                color: context.cs.onSurfaceVariant)),
                      if (isMine) ...[
                        const SizedBox(width: 6),
                        // 状态位固定尺寸（宽 14 / 高 15，居中）：sending 转圈 12、
                        // sent 勾 13、read 文字高约 15，各状态行高不同——
                        // WS 已读回执到达时行高变化 + 底锚定会让整列上移一次。
                        // 包进固定 SizedBox 后无论哪种状态（含无状态）行高恒定，
                        // 状态变化不再改变行高。
                        SizedBox(
                          width: 14,
                          height: 15,
                          child: Center(
                            child: msg.status == MsgStatus.sending
                                ? SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 1.5,
                                        color: context.cs.onSurfaceVariant),
                                  )
                                : msg.status == MsgStatus.read
                                    // 已读 = 双勾（微信式）；单勾=已发送。蓝色高亮已读（二十八批）
                                    ? Icon(Icons.done_all,
                                        size: 13, color: AppTheme.primary)
                                    : msg.status == MsgStatus.sent
                                        ? Icon(Icons.check,
                                            size: 13,
                                            color: context.cs.onSurfaceVariant)
                                        : msg.status == MsgStatus.failed
                                            ? InkWell(
                                                onTap: onRetry,
                                                child: const Icon(
                                                    Icons.error_outline,
                                                    size: 14,
                                                    color: AppTheme.danger),
                                              )
                                            : const SizedBox.shrink(),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (isMine) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => onAvatarTap?.call(myId),
              child: _avatar(senderColor, senderText),
            ),
          ],
        ],
      ),
    );
  }

  // ===== AI 翻译小组件 =====

  /// 「译」小圆钮：常驻气泡外侧；未翻译灰字、已翻译淡蓝底、翻译中转圈
  Widget _translateButton(BuildContext context) {
    final done = translation != null;
    return GestureDetector(
      onTap: (translating || done) ? null : onTranslate,
      child: Container(
        width: 21,
        height: 21,
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: done
              ? AppTheme.primary.withValues(alpha: 0.12)
              : context.cs.surface,
          border: Border.all(
            color: done
                ? Colors.transparent
                : context.cs.onSurfaceVariant.withValues(alpha: 0.35),
          ),
        ),
        alignment: Alignment.center,
        child: translating
            ? SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: AppTheme.primary),
              )
            : Text('译',
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color:
                        done ? AppTheme.primary : context.cs.onSurfaceVariant)),
      ),
    );
  }

  /// 译文条：灰底小字，常驻显示（按设计不做收起）
  Widget _translationBar(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: context.cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(isMine ? 10 : 4),
          topRight: Radius.circular(isMine ? 4 : 10),
          bottomLeft: const Radius.circular(10),
          bottomRight: const Radius.circular(10),
        ),
      ),
      child: Text.rich(
        TextSpan(children: [
          TextSpan(
              text: '译 ',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: context.cs.onSurface)),
          TextSpan(
              text: translation ?? '',
              style: TextStyle(
                  fontSize: 12.5,
                  height: 1.5,
                  color: context.cs.onSurfaceVariant)),
        ]),
      ),
    );
  }

  Widget _avatar(Color color, String text) {
    // 真实头像：我方 / 单聊对方（含小助手）/ 群成员，有 URL 就显示；
    // 加载中 / 失败 / 无 URL 统一显示「彩色底 + 首字」占位（AppAvatar），不再是白色空头像
    // （群聊标记 showSenderName 由父级按 isGroup 传入）
    final url = AppConfig.assetUrl(
        isMine ? myAvatar : (showSenderName ? senderAvatar : peerAvatar));
    return AppAvatar(
      url: url,
      name: text,
      size: 36,
      background: color,
    );
  }
}

// ============================== 各种消息气泡 widget ==============================

// 图片 bubble 用 content 当作 URL 列表（多 URL 用 | 分隔）。
// 2026-09-25 提升为顶层函数：_ChatPageState._convImages 与 _MsgRow 都要用，
// 原先挂在 _MsgRow 下导致 _ChatPageState 跨类调用编译失败。
List<String> _parseImages(String content) {
  final parts = content.split('|').where((s) => s.trim().isNotEmpty).toList();
  if (parts.isNotEmpty) return parts;
  // 没真实数据，按设计稿渲染 4 张占位 + 第 5 张 +N
  return const [];
}

/// 拆红包浮层（ckao open-red-packet 同款：白蒙层 + 红包盒 + 金边大圆 + rotateY「開」钮）
class _RedPacketOpenDialog extends StatefulWidget {
  final String msgId;
  final String senderName;
  final String senderAvatar;
  final String note;
  const _RedPacketOpenDialog({
    required this.msgId,
    required this.senderName,
    required this.senderAvatar,
    required this.note,
  });

  @override
  State<_RedPacketOpenDialog> createState() => _RedPacketOpenDialogState();
}

class _RedPacketOpenDialogState extends State<_RedPacketOpenDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  bool _opening = false; // 请求中（「開」钮 rotateY 往复动画）
  bool _popped = false; // 防止重复 pop 把底下的聊天页也关掉
  final _svc = MomentService.instance;

  /// 统一出口：只允许关一次（请求在途时用户用 × 关掉后，
  /// 迟到的领取结果不能再 pop 第二次，否则会把聊天页一起弹掉）
  void _finish(Map<String, dynamic>? result) {
    if (_popped || !mounted) return;
    _popped = true;
    _ctrl.stop();
    Navigator.pop(context, result);
  }

  String _t(String key, [Map<String, String>? params]) =>
      AppLocalizations.of(context).t(key, params);

  @override
  void initState() {
    super.initState();
    // uniapp rp-flip：1.5s 往复（0°→180°→0°）；仅请求中旋转
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1500));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    if (_opening || widget.msgId.isEmpty) return;
    setState(() => _opening = true);
    _ctrl.repeat();
    try {
      final detail = await _svc.redPacketClaim(widget.msgId);
      final amount = (detail['amount'] as num?)?.toDouble() ??
          (detail['myAmount'] as num?)?.toDouble() ??
          0;
      if (!mounted) return;
      _ctrl.stop();
      // 把领取接口返回的完整 detail 一起带回：详情页可直接秒开，不用二次请求
      _finish({'claimed': true, 'amount': amount, 'detail': detail});
    } catch (e) {
      if (!mounted) return;
      _ctrl.stop();
      setState(() => _opening = false);
      // 用后端真实原因区分：领完 → toast「手慢了」+ 进详情；已领取 → 直接进详情
      final msgText = e.toString();
      final gone = msgText.contains('领完') || msgText.contains('4202');
      final already = msgText.contains('已领取') || msgText.contains('4204');
      if (gone) AppDialogs.toast(context, _t('rpDetailAllGone'));
      if (gone || already) {
        _finish({'gotoDetail': true});
      } else {
        AppDialogs.toast(context, _errMsg(e, _t('chatRedPacketGone')));
        _finish(null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    // 白 70% 蒙层上：居中红包盒（290×500）→ 下方关闭 ×
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      child: SizedBox.expand(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // ===== 红包盒：#F35D4C，圆角 10，盒内大圆 #EF4A3A 带金边 #F8CA75 =====
            Container(
              width: 290,
              height: 500,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: const Color(0xFFF35D4C),
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 24,
                      offset: const Offset(0, 10)),
                ],
              ),
              child: Column(
                children: [
                  SizedBox(
                    height: 400,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // 大圆封底：600×550，圆形溢出盒顶（宽度方向溢出由盒裁剪）
                        Positioned(
                          left: -155,
                          right: -155,
                          bottom: 0,
                          child: Container(
                            width: 600,
                            height: 550,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFFEF4A3A),
                              border: Border.all(
                                  color: const Color(0xFFF8CA75), width: 3),
                            ),
                          ),
                        ),
                        // 发送者头像 + 「XX 发出的红包」#FAE1AA
                        Positioned(
                          left: 0,
                          right: 0,
                          top: 45,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 20,
                                height: 20,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                clipBehavior: Clip.antiAlias,
                                alignment: Alignment.center,
                                // 首字占位常驻底层，头像加载成功后覆盖 → 加载期间不空白
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Center(
                                      child: Text(
                                        widget.senderName.characters.first,
                                        style: const TextStyle(
                                            color: Color(0xFFD8961B),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700),
                                      ),
                                    ),
                                    if (widget.senderAvatar.isNotEmpty)
                                      Image.network(
                                        AppConfig.assetUrl(widget.senderAvatar),
                                        width: 20,
                                        height: 20,
                                        fit: BoxFit.cover,
                                        frameBuilder:
                                            (ctx, child, frame, wasSync) =>
                                                (wasSync || frame != null)
                                                    ? child
                                                    : const SizedBox.shrink(),
                                        errorBuilder: (_, __, ___) =>
                                            const SizedBox.shrink(),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  t('rpOverlayFrom',
                                      {'name': widget.senderName}),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Color(0xFFFAE1AA), fontSize: 15),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // 祝福语 #FAE1AA
                        Positioned(
                          left: 20,
                          right: 20,
                          top: 95,
                          child: Text(
                            widget.note.isEmpty
                                ? t('redPacketDetailDefaultNote')
                                : widget.note,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Color(0xFFFAE1AA), fontSize: 18),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 金色「開」圆钮：直径 90，#ECCC99，rotateY 往复动画。
                  // 用布局子项 + Transform.translate 上移 45px，骑跨红盒内分界线；
                  // 【不能】用 Positioned bottom:-45 溢出 Stack——Flutter 命中测试
                  // 在 SizedBox 边界截断，按钮下半截（含视觉中心）会变成点不动的死区，
                  // 表现就是"一直点都没提示"（uniapp/Web 溢出可点，Flutter 不行）
                  Transform.translate(
                    offset: const Offset(0, -45),
                    child: SizedBox(
                      height: 90,
                      child: Center(
                        child: AnimatedBuilder(
                          animation: _ctrl,
                          builder: (ctx, _) {
                            final v = _ctrl.value;
                            // 0°→180°→0°（正弦往复，对齐 uniapp rp-flip 关键帧）
                            // dart:math 以无前缀导入，直接用 sin/pi（本文件无 `as math` 别名）
                            final angle = _opening ? sin(v * pi) * pi : 0.0;
                            return Transform(
                              alignment: Alignment.center,
                              transform: Matrix4.rotationY(angle),
                              child: GestureDetector(
                                onTap: _open,
                                child: Container(
                                  width: 90,
                                  height: 90,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Color(0xFFECCC99),
                                    boxShadow: [
                                      BoxShadow(
                                          color: Color(0x33000000),
                                          blurRadius: 3,
                                          offset: Offset(0, 1)),
                                    ],
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(t('rpOverlayOpenChar'),
                                      style: const TextStyle(
                                          color: Color(0xFF8A6A2F),
                                          fontSize: 36,
                                          fontWeight: FontWeight.w700)),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // ===== 盒下方关闭 ×（#D3AD73）：请求中也允许关（迟到结果由 _finish 挡重复）=====
            GestureDetector(
              onTap: _popped ? null : () => _finish(null),
              child: Container(
                margin: const EdgeInsets.only(top: 30),
                width: 35,
                height: 35,
                alignment: Alignment.center,
                child: const Text('×',
                    style: TextStyle(
                        color: Color(0xFFD3AD73),
                        fontSize: 28,
                        height: 1,
                        fontWeight: FontWeight.w300)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 转账收款确认弹窗
class _TransferConfirmDialog extends StatelessWidget {
  final double amount;
  const _TransferConfirmDialog({required this.amount});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final fmt = WalletStore.instance.fmt(amount);
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 280,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: context.cs.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                  color: Color(0xFFF5A623), shape: BoxShape.circle),
              child:
                  const Icon(Icons.currency_yen, color: Colors.white, size: 28),
            ),
            const SizedBox(height: 12),
            Text(t('chatFriendTransfer'),
                style: TextStyle(
                    fontSize: 13, color: context.cs.onSurfaceVariant)),
            const SizedBox(height: 8),
            Text('¥$fmt',
                style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                    color: context.cs.onSurface)),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: FilledButton(
                onPressed: () => Navigator.pop(context, true),
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFFA9D3B)),
                child: Text(t('chatConfirmAccept'),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 红包/转账气泡（type=8/9，content=JSON {kind,amount,note}）
/// 红包：ckao m-redPacket 同款（#FA9E3B 橙卡 235 宽 / 白色信封图标 / 祝福语白色加粗 /
/// 分隔线 / 脚注「開啟紅包」/ 已领取 #FDE2C4 米色），含旋转方块小尾巴；
/// 转账：保持原橙黄卡片（图标 + 大金额 + 说明）。
class _MoneyBubble extends StatelessWidget {
  final String content;
  final bool isRed;
  final bool mine;
  final bool claimed;
  final VoidCallback onTap;
  const _MoneyBubble({
    required this.content,
    required this.isRed,
    required this.mine,
    required this.claimed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    double amount = 0;
    String note = isRed ? t('chatRedPacketGreeting') : '';
    try {
      final j = jsonDecode(content);
      if (j is Map) {
        amount = (j['amount'] as num?)?.toDouble() ?? 0;
        final n = j['note']?.toString() ?? '';
        if (n.isNotEmpty) note = n;
      }
    } catch (_) {
      // 兼容旧格式：content 直接是金额
      amount = double.tryParse(content) ?? 0;
    }
    if (isRed) return _buildRedCard(context, t, note);
    // ===== 转账卡（保持原样式）=====
    final bg = claimed ? const Color(0xFFD5D2CD) : const Color(0xFFF5A623);
    final iconTint =
        claimed ? const Color(0xFF9E9B96) : const Color(0xFFF5A623);
    final mainText = '¥${WalletStore.instance.fmt(amount)}';
    final subText = claimed ? t('chatAccepted') : t('chatAppTransfer');
    return GestureDetector(
      onTap: onTap,
      child: Container(
        // 与红包卡同宽（微信里两张卡同尺寸，2026-09-17）
        width: 208,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.currency_yen, color: iconTint, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(mainText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                  const SizedBox(height: 3),
                  Text(subText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.85))),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                size: 16, color: Colors.white.withValues(alpha: 0.9)),
            const SizedBox(width: 2),
          ],
        ),
      ),
    );
  }

  /// 红包卡：ckao .rp-card 同款视觉（470rpx 宽 / #FA9E3B / 10rpx 圆角 / 小尾巴）
  Widget _buildRedCard(BuildContext context,
      String Function(String, [Map<String, String>?]) t, String note) {
    // 配色：未领 #FA9E3B 橙 / 已领 #FDE2C4 米色（文字 #A4703F）
    final bg = claimed ? const Color(0xFFFDE2C4) : const Color(0xFFFA9E3B);
    final noteColor = claimed ? const Color(0xFFA4703F) : Colors.white;
    final subColor = claimed ? const Color(0xFFC09A6B) : null;
    final dividerColor = claimed
        ? const Color(0x40A4703F) // rgba(164,112,63,0.25)
        : const Color(0x66FFFFFF); // rgba(255,255,255,0.4)
    final footColor = claimed
        ? const Color(0xFFC09A6B)
        : const Color(0xE6FFF6D6); // rgba(255,246,214,0.9)
    final footText = claimed ? t('chatClaimed') : t('rpBubbleOpen');
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 旋转方块小尾巴（左侧未领 / 右侧自己发的，rotate 45°）
          Positioned(
            top: 11,
            left: mine ? null : -3,
            right: mine ? -3 : null,
            child: Transform.rotate(
              angle: pi / 4,
              child: Container(width: 8, height: 8, color: bg),
            ),
          ),
          Container(
            // 尺寸对齐微信聊天里的红包卡：约 208 宽 / 90 高（2026-09-17）
            width: 208,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(4),
            ),
            padding: const EdgeInsets.fromLTRB(13, 10, 13, 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 主行：白色信封图标 + 祝福语
                SizedBox(
                  height: 50,
                  child: Row(
                    children: [
                      // 信封切图（ckao 同款：未领 envelope_open / 已领 envelope_opened，
                      // 整图铺满，无白底容器，对齐 uniapp rp-icon）
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.asset(
                          claimed
                              ? 'assets/images/redpacket/envelope_opened.png'
                              : 'assets/images/redpacket/envelope_open.png',
                          width: 34,
                          height: 40,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(note,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: noteColor)),
                            if (claimed) ...[
                              const SizedBox(height: 2),
                              Text(t('chatClaimed'),
                                  maxLines: 1,
                                  style:
                                      TextStyle(fontSize: 11, color: subColor)),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // 分隔线
                Container(
                  margin: const EdgeInsets.only(top: 8, bottom: 2),
                  height: 0.5,
                  color: dividerColor,
                ),
                // 脚注：「開啟紅包」/「已领取」
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(footText,
                      maxLines: 1,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w300,
                          color: footColor)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 位置消息气泡（type=14，2026-09-21 需求1）：静态地图缩略图 + 地名/地址，
/// 点击跳外部地图（优先地图 App、回落浏览器网页版）。缩略图按后台地图引擎
///（2026-09-22 需求1：map_engine）分流——谷歌 Static Maps / 高德静态地图 API
///（key 与选点页同源 /auth/config 下发，对应 key 为空时回落纯文字卡）。
class _LocationBubble extends StatelessWidget {
  final String content;
  final bool isMine;
  const _LocationBubble({required this.content, required this.isMine});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    var lat = 0.0;
    var lng = 0.0;
    var name = '';
    var address = '';
    try {
      final map = jsonDecode(content);
      if (map is Map) {
        lat = (map['lat'] as num?)?.toDouble() ?? 0;
        lng = (map['lng'] as num?)?.toDouble() ?? 0;
        name = (map['name'] ?? '').toString();
        address = (map['address'] ?? '').toString();
      }
    } catch (_) {}
    final title = name.isNotEmpty
        ? name
        : (address.isNotEmpty ? address : t('chatLocationUntitled'));
    final sub = (address.isNotEmpty && address != title) ? address : '';
    return InkWell(
      onTap: () => _openExternalMap(lat, lng, name),
      borderRadius: BorderRadius.circular(AppTheme.radiusBubble),
      child: Container(
        width: 190,
        decoration: BoxDecoration(
          color: context.cs.surface,
          borderRadius: BorderRadius.circular(AppTheme.radiusBubble),
          border: Border.all(color: context.cs.outlineVariant, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 静态地图缩略图（按引擎取对应 key，未配置时显示浅色地图占位）
            FutureBuilder<MapConfig>(
              future: MapConfig.get(),
              builder: (context, snap) {
                final cfg = snap.data ?? const MapConfig();
                final key = cfg.staticKey;
                Widget child;
                if (key.isNotEmpty && (lat != 0 || lng != 0)) {
                  // 高德静态图：location/markers 为 lng,lat 序、size 用 * 分隔；
                  // 谷歌静态图：center/markers 为 lat,lng 序（坐标系各自一致）
                  final thumb = cfg.isAmap
                      ? 'https://restapi.amap.com/v3/staticmap'
                          '?location=$lng,$lat&zoom=15&size=380*220&scale=2'
                          '&markers=mid,0xEA4335,:$lng,$lat&key=$key'
                      : 'https://maps.googleapis.com/maps/api/staticmap'
                          '?center=$lat,$lng&zoom=15&size=380x220&scale=2'
                          '&markers=color:0xEA4335%7C$lat,$lng&key=$key';
                  child = Image.network(
                    thumb,
                    fit: BoxFit.cover,
                    height: 100,
                    errorBuilder: (_, __, ___) => _mapPlaceholder(),
                  );
                } else {
                  child = _mapPlaceholder();
                }
                return SizedBox(height: 100, child: child);
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(9, 6, 9, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  if (sub.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color: context.cs.onSurfaceVariant)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mapPlaceholder() {
    return Container(
      color: const Color(0xFFE8EAED),
      alignment: Alignment.center,
      child: Icon(Icons.location_on_outlined,
          size: 34, color: Colors.grey.shade600),
    );
  }

  /// 点击打开外部地图：优先拉起设备上的地图 App（系统接管 https 链接），
  /// 失败/未安装回落浏览器网页版。链接按后台地图引擎分流（2026-09-22 需求1）：
  /// 高德走 uri.amap.com marker 页（坐标系 GCJ-02，与选点存值一致）；
  /// 谷歌走 maps.google.com 搜索页。
  Future<void> _openExternalMap(double lat, double lng, String name) async {
    if (lat == 0 && lng == 0) return;
    final cfg = await MapConfig.get();
    final web = cfg.isAmap
        ? Uri.parse('https://uri.amap.com/marker?position=$lng,$lat'
            '&name=${Uri.encodeComponent(name)}')
        : Uri.parse(
            'https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    try {
      await launchUrl(web, mode: LaunchMode.externalNonBrowserApplication);
      return;
    } catch (_) {}
    try {
      await launchUrl(web, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }
}

/// 通话邀请气泡（TRTC 信令 type=7）
class _CallBubble extends StatelessWidget {
  final String content;
  final VoidCallback onTap;
  const _CallBubble({required this.content, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    // 解析信令：一通电话一条记录 —— invite + status 即最终态。
    // 所有通话气泡都可点：invite 回拨/接听，已定型记录直接重拨对应类型。
    var isVideo = false;
    var status = '';
    var duration = 0;
    try {
      final map = jsonDecode(content);
      if (map is Map) {
        if (map['callType'] == 'video') isVideo = true;
        status = map['status']?.toString() ?? '';
        duration = int.tryParse((map['duration'] ?? 0).toString()) ?? 0;
      }
    } catch (_) {}
    final callType = t(isVideo ? 'chatCallVideo' : 'chatCallVoice');
    final durText =
        '${(duration ~/ 60).toString().padLeft(2, '0')}:${(duration % 60).toString().padLeft(2, '0')}';
    // 最终态文案：done=带时长 / rejected=对方拒绝接听 / missed=通话未接通
    final Map<String, List<String>> records = {
      'done': [
        t('chatCallWithDuration', {'type': callType, 'duration': durText}),
        t('chatCallLog')
      ],
      'rejected': [t('chatCallRejected'), t('chatCallLog')],
      'missed': [t('chatCallMissed'), t('chatCallLog')],
    };
    final record = records[status];
    final String title;
    final String sub;
    if (record != null) {
      title = record[0];
      sub = record[1];
    } else {
      // 通话进行中/尚未定型的 invite：中性「{type}通话 · 点击回拨」
      title = t('chatCallDefault', {'type': callType});
      sub = t('chatTapToAnswer');
    }
    // 全部可点：进行中的 invite 可回拨，定型记录点击直接重拨对应类型
    // 状态色：未接/被拒 → 红；接通/进行中 → 品牌蓝。卡片用同色系淡底+描边，
    // 圆形图标底 → 让通话记录在聊天流里一眼可辨（用户反馈原卡片不明显）。
    final Color statusColor = (status == 'missed' || status == 'rejected')
        ? context.cs.error
        : AppTheme.primary;
    final IconData icon = isVideo ? Icons.videocam : Icons.call;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusBubble),
      child: Container(
        width: 170,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 9),
        decoration: BoxDecoration(
          // 实底（surface 上叠 7% 状态色）：纯 7% 透明底在自定义聊天背景上
          // 会让文字看不清（2026-09-17 用户反馈）
          color: Color.alphaBlend(
              statusColor.withValues(alpha: 0.07), context.cs.surface),
          borderRadius: BorderRadius.circular(AppTheme.radiusBubble),
          border: Border.all(color: statusColor.withValues(alpha: 0.22)),
        ),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: statusColor.withValues(alpha: 0.16),
              ),
              child: Icon(icon, size: 15, color: statusColor),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: context.cs.onSurface)),
                  const SizedBox(height: 3),
                  Text(sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11,
                          color: statusColor.withValues(alpha: 0.85))),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_rounded,
                size: 14, color: statusColor.withValues(alpha: 0.7)),
          ],
        ),
      ),
    );
  }
}

/// 单图气泡：宽度固定 170（2026-09-17 用户反馈整体缩小，与多图叠卡对齐），
/// 高度按图片真实比例自适应（不裁剪不变形）。
/// 解码拿到宽高前先占位 170×140，随后按比例重排；高度 clamp 85~225，
/// 防超长图撑爆聊天页。ImageStream 只为拿比例，图片本体仍由 build 里渲染。
class _SingleImage extends StatefulWidget {
  final String url;

  /// 会话内全部图片（2026-09-25）：≥2 张时点开大图可左右滑翻看会话内其它图
  final List<String>? allUrls;
  const _SingleImage({required this.url, this.allUrls});

  @override
  State<_SingleImage> createState() => _SingleImageState();
}

class _SingleImageState extends State<_SingleImage> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  double? _ratio; // 图片宽 / 高

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _SingleImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _resolve();
  }

  void _resolve() {
    final old = _listener;
    if (_stream != null && old != null) _stream!.removeListener(old);
    final listener = ImageStreamListener((info, _) {
      final r = info.image.width / info.image.height;
      if (!mounted || r == _ratio) return;
      setState(() => _ratio = r);
    });
    _listener = listener;
    // 2026-09-26：换 CachedNetworkImageProvider——与气泡渲染（AppNetImage →
    // CachedNetworkImage）同一下载/磁盘缓存通道，比例侦听不再单独走裸 NetworkImage
    _stream = CachedNetworkImageProvider(_ImageGridBubble._fixUrl(widget.url))
        .resolve(createLocalImageConfiguration(context));
    _stream!.addListener(listener);
  }

  @override
  void dispose() {
    final old = _listener;
    if (_stream != null && old != null) _stream!.removeListener(old);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const w = 170.0;
    final h = _ratio == null ? 140.0 : (w / _ratio!).clamp(85.0, 225.0);
    return GestureDetector(
      // 点击查看大图（淡入 + Hero 缩放展开到全屏，关闭原路返回）。
      // 2026-09-25：会话内有多张图时传整组 + 定位当前张 → 查看器内可左右滑（微信式）
      onTap: () {
        final fixedAll = (widget.allUrls == null || widget.allUrls!.length <= 1)
            ? null
            : widget.allUrls!.map(_ImageGridBubble._fixUrl).toList();
        final fixedCur = _ImageGridBubble._fixUrl(widget.url);
        Navigator.of(context).push(fadeScaleRoute(
          (fixedAll != null && fixedAll.contains(fixedCur))
              ? ImageViewerPage(
                  urls: fixedAll,
                  initialIndex: fixedAll.indexOf(fixedCur),
                )
              : ImageViewerPage(url: fixedCur),
        ));
      },
      // Hero 源端：缩略图矩形 → 大图预览缩放定位（2026-09-20 动效规范 3）
      child: Hero(
        tag: 'hero-chat-img-${_ImageGridBubble._fixUrl(widget.url)}',
        child: Container(
          width: w,
          height: h,
          // 无背景卡片（用户要求）：留白直接露聊天背景
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: AppNetImage(
            url: _ImageGridBubble._fixUrl(widget.url),
            fit: BoxFit.contain, // 完整显示：不裁剪不变形
            iconSize: 24,
          ),
        ),
      ),
    );
  }
}

/// 上传进度遮罩（微信式，2026-09-17）：黑色半透明底 + 白字百分比 + 细进度条，
/// 叠在图片/文件气泡上（_MsgRow._wrapUploadProgress）。
class _UploadOverlay extends StatelessWidget {
  final double progress; // 0.0 - 1.0
  const _UploadOverlay({required this.progress});

  @override
  Widget build(BuildContext context) {
    final p = progress.clamp(0.0, 1.0);
    return Container(
      color: Colors.black.withValues(alpha: 0.45),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${(p * 100).toStringAsFixed(0)}%',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  height: 1.0)),
          const SizedBox(height: 7),
          SizedBox(
            width: 76,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: p,
                minHeight: 4,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation(Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageGridBubble extends StatelessWidget {
  final List<String> urls;

  /// 会话内全部图片 URL（2026-09-25）：单图/多图消息点开大图时左右滑翻看
  /// 会话内其它图片（微信式）；null/空 → 回退本消息自己的图片集
  final List<String>? convImages;
  const _ImageGridBubble({required this.urls, this.convImages});

  /// localhost/127.0.0.1 的 MinIO URL 换成 API 同域主机
  /// （原用 Uri.base 在移动端是设备本机无效 → 统一走 AppConfig.assetUrl）
  static String _fixUrl(String u) => AppConfig.assetUrl(u);

  @override
  Widget build(BuildContext context) {
    // 单图：宽 170、高度按图片真实比例自适应（不裁剪不变形，加载后重排）
    if (urls.length == 1) {
      return _SingleImage(url: urls.first, allUrls: convImages);
    }

    // 无 URL（content 为空的异常图片消息）：单个灰色占位，不再铺 4 个空格子
    if (urls.isEmpty) {
      return Container(
        width: 200,
        height: 200,
        decoration: BoxDecoration(
          color: context.cs.surface,
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: Container(
          color: const Color(0xFFE9ECEF),
          alignment: Alignment.center,
          child:
              Icon(Icons.photo, color: context.cs.onSurfaceVariant, size: 28),
        ),
      );
    }

    // 多图（≥2 张）：扑克式叠放（2026-09-15 用户指定，替代九宫格）——
    // 当前图全显在最上，身后最多两张斜着叠（绕底部中心 ±6°，像一叠扑克，
    // 参考微信多图组合样式）；左右滑切换上一张/下一张（循环），
    // 点当前图打开大图（定位到当前张）。固定 145×175 竖卡 + cover：加载零跳动。
    return _ImageStack(urls: urls, convImages: convImages);
  }
}

/// 多图消息「扑克叠放」气泡（2026-09-15，用户指定替代九宫格）：
/// 当前图全显，身后最多露两张斜叠卡（2 张消息只露 1 张，避免背后重复自己）。
/// 卡片固定 145×175 竖卡 + cover 裁剪 + cacheWidth=310（与首屏预热同一 ImageCache key）。
/// （2026-09-16 用户反馈太宽：240×180 横卡收窄为 170×205 竖卡。
///  2026-09-17 用户反馈特殊卡片整体缩小 1/3：170×205 再收至 145×175。）
///
/// 2026-09-16 交互升级（用户要求）：顶卡**可拖拽**——1:1 跟手并带轻微倾斜，
/// 拖过卡宽四成（或快速一甩）松手即飞出，**插入到队尾**，下一张从背卡槽位
/// 平滑滑上顶卡（translate/rotate 隐式动画补位）；没拖够阈值则回弹原位。
/// 点图仍打开大图并定位当前张。
class _ImageStack extends StatefulWidget {
  final List<String> urls;

  /// 会话内全部图片（2026-09-25）：点开大图时优先用它翻看会话内所有图
  final List<String>? convImages;
  const _ImageStack({required this.urls, this.convImages});

  @override
  State<_ImageStack> createState() => _ImageStackState();
}

class _ImageStackState extends State<_ImageStack> {
  static const double _w = 145.0;
  static const double _h = 175.0;
  static const double _fan = 12.0; // 斜叠卡向下露出的高度（气泡总高加高量）

  /// 浏览顺序（可变内容）：_deck[0] = 当前顶卡。拖走一张 → removeAt(0) 再 add
  /// 到末尾（用户要求「拖出去一半，插入到最后」），后面的卡依次顶上。
  late final List<String> _deck = List<String>.of(widget.urls);

  Offset _drag = Offset.zero; // 拖拽中的实时位移（水平为主，垂直跟 0.4 倍）
  bool _dragging = false;
  int _flyDir = 0; // 0=无；±1 = 顶卡飞出方向（飞出动画进行中）

  bool get _animating => _flyDir != 0;

  void _onDragStart(DragStartDetails d) {
    if (_animating) return;
    _dragging = true;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_animating) return;
    setState(() {
      _drag = Offset(
        _drag.dx + d.delta.dx,
        (_drag.dy + d.delta.dy * 0.4).clamp(-40.0, 40.0),
      );
    });
  }

  void _onDragEnd(DragEndDetails d) {
    if (_animating) return;
    _dragging = false;
    final v = d.primaryVelocity ?? 0;
    final dx = _drag.dx;
    // 拖过卡宽四成，或快速一甩 → 飞出插入队尾；否则回弹原位
    if (dx.abs() > _w * 0.4 || v.abs() > 800) {
      final dir = dx != 0 ? (dx > 0 ? 1 : -1) : (v > 0 ? 1 : -1);
      setState(() => _flyDir = dir); // 顶卡 target 切到屏外 → 飞出动画
    } else {
      setState(() {}); // target 回 Offset.zero → 回弹动画
    }
  }

  /// 飞出动画结束：当前卡插入队尾，后面的卡平滑补位（TweenAnimationBuilder）
  void _onFlyEnd() {
    if (_flyDir == 0 || !mounted) return;
    setState(() {
      _deck.add(_deck.removeAt(0));
      _flyDir = 0;
      _drag = Offset.zero;
    });
  }

  /// 槽位参数：0=顶卡 / 1=背卡1 / 2=背卡2。
  /// 槽位变化（重排补位）由 TweenAnimationBuilder + AnimatedRotation
  /// 隐式动画平滑过渡；Stack clipBehavior=none，旋转探出上缘成扇形轮廓。
  Widget _deckCard(String url, int slot) {
    final dy = slot == 0 ? 0.0 : (slot == 1 ? _fan / 2 : _fan);
    final rad = slot == 0 ? 0.0 : (slot == 1 ? 0.105 : -0.105);
    final img = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AppNetImage(
        url: _ImageGridBubble._fixUrl(url),
        width: _w,
        height: _h,
        fit: BoxFit.cover,
        cacheWidth: 310,
        iconSize: 24,
      ),
    );
    Widget card = TweenAnimationBuilder<Offset>(
      tween: Tween(end: Offset(0, dy)),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      builder: (_, off, child) =>
          Transform.translate(offset: off, child: child),
      child: AnimatedRotation(
        turns: rad / (2 * 3.1415926535897932),
        duration: const Duration(milliseconds: 220),
        alignment: Alignment.bottomCenter,
        child: img,
      ),
    );
    if (slot == 0) {
      // 顶卡：拖拽中 duration=zero → 1:1 跟手；松手后 target 切到
      // 飞出终点（或回弹零点）走 220ms 动画。TweenAnimationBuilder
      // 始终挂载，target 变化自动从当前位置起播，无需记录起点。
      final target = _animating ? Offset(_flyDir * (_w + 90), 0) : _drag;
      card = TweenAnimationBuilder<Offset>(
        tween: Tween(end: target),
        duration: _dragging ? Duration.zero : const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        onEnd: _animating ? _onFlyEnd : null,
        builder: (_, off, child) => Transform.translate(
          offset: off,
          child: Transform.rotate(
            angle: off.dx * 0.0012, // 拖动越远倾斜越大，tinder 式手感
            alignment: Alignment.center,
            child: child,
          ),
        ),
        child: card,
      );
    }
    return card;
  }

  @override
  Widget build(BuildContext context) {
    final n = _deck.length;
    final top = _deck[0];
    final back1 = _deck[1];
    final back2 = n > 2 ? _deck[2] : null;
    // 计数角标/查看器定位：当前顶卡在原始 urls 中的序号
    var orderIdx = widget.urls.indexOf(top);
    if (orderIdx < 0) orderIdx = 0;

    return GestureDetector(
      // 拖拽顶卡（水平为主）；与列表的纵向滚动在手势竞技场自然竞争
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      // 点击查看大图（全屏预览：双指/双击缩放 + 左右滑切换），定位当前张。
      // 2026-09-25：优先用会话全量图片集（左右滑翻整个会话的图，微信式），
      // 当前张不在集内（撤回/发送中等）→ 回退本消息自己的图片集。
      onTap: () {
        final self =
            widget.urls.map(_ImageGridBubble._fixUrl).toList();
        final fixedAll = (widget.convImages != null &&
                widget.convImages!.length > 1 &&
                widget.convImages!.contains(top))
            ? widget.convImages!.map(_ImageGridBubble._fixUrl).toList()
            : self;
        final idx = fixedAll.indexOf(_ImageGridBubble._fixUrl(top));
        Navigator.of(context).push(fadeScaleRoute(
          ImageViewerPage(
            urls: fixedAll,
            initialIndex:
                (idx >= 0 ? idx : orderIdx).clamp(0, fixedAll.length - 1),
          ),
        ));
      },
      child: SizedBox(
        width: _w,
        height: _h + _fan,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (back2 != null)
              Positioned(top: 0, left: 0, child: _deckCard(back2, 2)),
            if (n > 1) Positioned(top: 0, left: 0, child: _deckCard(back1, 1)),
            Positioned(top: 0, left: 0, child: _deckCard(top, 0)),
            // 计数角标「当前/总数」：压在当前张右下角（微信式深色半透明胶囊）
            Positioned(
              right: 8,
              bottom: _fan + 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.45),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${orderIdx + 1}/$n',
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.0,
                    color: Colors.white,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 视频封面图：优先用发送端生成的本地封面（localThumb），否则按 fileId 从服务端
/// 懒加载首帧（大视频由服务端 ffmpeg 抽帧生成，微信式）。加载中/失败 → 显示 placeholder。
/// 首帧按 fileId 进程内缓存，避免同一视频重复请求。
class _VideoThumbImage extends StatefulWidget {
  final String fileId;
  final String? localThumb;
  final double width;
  final double height;
  final BoxFit fit;
  final Widget placeholder;

  const _VideoThumbImage({
    required this.fileId,
    this.localThumb,
    required this.width,
    required this.height,
    this.fit = BoxFit.cover,
    required this.placeholder,
  });

  @override
  State<_VideoThumbImage> createState() => _VideoThumbImageState();
}

class _VideoThumbImageState extends State<_VideoThumbImage> {
  static final Map<String, String> _cache = {};
  String? _url;
  bool _loading = false;
  int _attempts = 0;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  void _resolve() {
    if (widget.localThumb != null && widget.localThumb!.isNotEmpty) {
      _url = widget.localThumb;
      return;
    }
    final cached = _cache[widget.fileId];
    if (cached != null) {
      _url = cached;
      return;
    }
    if (_loading || widget.fileId.isEmpty) return;
    _loading = true;
    GroupFileService.instance
        .thumbUrl(widget.fileId)
        .then((u) async {
          if (u.isNotEmpty) {
            _cache[widget.fileId] = u;
            if (mounted) setState(() => _url = u);
            return;
          }
          // 发送后服务端异步抽帧：空封面时短暂重试，避免一直黑块
          if (_attempts < 6 && mounted) {
            _attempts++;
            await Future<void>.delayed(Duration(milliseconds: 800 * _attempts));
            if (!mounted) return;
            _loading = false;
            _resolve();
          }
        })
        .catchError((_) {})
        .whenComplete(() {
          if (_attempts == 0 || _url != null) _loading = false;
        });
  }

  @override
  Widget build(BuildContext context) {
    if (_url != null && _url!.isNotEmpty) {
      return AppNetImage(
        url: _url!,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
      );
    }
    return widget.placeholder;
  }
}

/// 文件气泡（type=3）：文件名 + 大小，点击进预览页（[onTap]）。
class _FileBubble extends StatelessWidget {
  final String name;
  final Map<String, dynamic>? file; // 文件元数据（含 url / fileId）
  final int size; // 字节，0 = 未知（不显示）
  final VoidCallback onTap;

  const _FileBubble({
    required this.name,
    required this.onTap,
    this.file,
    this.size = 0,
  });

  /// 视频消息且有封面（2026-09-17）：mimeType=video/* + thumbUrl
  bool get _isVideoWithCover {
    final mime = (file?['mimeType'] ?? '').toString().toLowerCase();
    final thumb = (file?['thumbUrl'] ?? '').toString();
    return mime.startsWith('video/') && thumb.isNotEmpty;
  }

  /// 视频消息但无封面：大视频 / 用「发送文件」入口发的视频常无 thumbUrl。
  /// 仍按视频渲染（深色占位 + 播放键），点击进预览页——服务端已按扩展名识别并
  /// 流式播放，与微信一致：任意视频都能点开播，不依赖封面（2026-09-24 大视频无法预览修复）。
  bool get _isVideoNoCover {
    final mime = (file?['mimeType'] ?? '').toString().toLowerCase();
    final name = (file?['name'] ?? '').toString().toLowerCase();
    final isVideo = mime.startsWith('video/') ||
        const ['.mp4', '.mov', '.avi', '.mkv', '.webm', '.flv', '.wmv', '.m4v', '.3gp', '.mpeg', '.mpg', '.ts']
            .any((e) => name.endsWith(e));
    return isVideo && (file?['thumbUrl'] ?? '').toString().isEmpty;
  }

  String get _thumbUrl => (file?['thumbUrl'] ?? '').toString();

  String get _fileId => (file?['fileId'] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final displayName = name.isEmpty
        ? AppLocalizations.of(context).t('chatFileFallback')
        : name;
    // 视频封面样式：封面图（圆角）+ 居中播放键 + 底部文件名/大小条
    if (_isVideoWithCover) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusBubble),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: context.cs.surface,
            borderRadius: BorderRadius.circular(AppTheme.radiusBubble),
          ),
          constraints: const BoxConstraints(maxWidth: 240),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  ClipRRect(
                    borderRadius:
                        BorderRadius.circular(AppTheme.radiusBubble - 6),
                    child: _VideoThumbImage(
                      fileId: _fileId,
                      localThumb: _thumbUrl,
                      width: 224,
                      height: 126,
                      fit: BoxFit.cover,
                      placeholder: AppNetImage(
                        url: _thumbUrl,
                        width: 224,
                        height: 126,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  // 半透明播放键
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.35),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.play_arrow,
                        size: 30, color: Colors.white),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 13, color: context.cs.onSurface),
                    ),
                    if (size > 0) ...[
                      const SizedBox(height: 2),
                      Text(
                        _formatBytes(size),
                        style: TextStyle(
                            fontSize: 11, color: context.cs.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    // 视频无封面：深色占位 + 播放键（微信式，不依赖 thumbUrl）。点开进预览页，
    // 服务端按扩展名识别为视频并流式播放（大视频亦可播）。
    if (_isVideoNoCover) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusBubble),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: context.cs.surface,
            borderRadius: BorderRadius.circular(AppTheme.radiusBubble),
          ),
          constraints: const BoxConstraints(maxWidth: 240),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  ClipRRect(
                    borderRadius:
                        BorderRadius.circular(AppTheme.radiusBubble - 6),
                    child: _VideoThumbImage(
                      fileId: _fileId,
                      width: 224,
                      height: 126,
                      fit: BoxFit.cover,
                      placeholder: Container(
                        width: 224,
                        height: 126,
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFF1B2733), Color(0xFF0E1621)],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.35),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.play_arrow,
                        size: 30, color: Colors.white),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 13, color: context.cs.onSurface),
                    ),
                    if (size > 0) ...[
                      const SizedBox(height: 2),
                      Text(
                        _formatBytes(size),
                        style: TextStyle(
                            fontSize: 11, color: context.cs.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusBubble),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: context.cs.surface,
          borderRadius: BorderRadius.circular(AppTheme.radiusBubble),
        ),
        constraints: const BoxConstraints(maxWidth: 240),
        child: Row(
          children: [
            const Icon(Icons.description, size: 28, color: AppTheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: context.cs.onSurface),
                  ),
                  if (size > 0) ...[
                    const SizedBox(height: 2),
                    Text(
                      _formatBytes(size),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: context.cs.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 字节数格式化（与群文件列表页 group_file_page._formatBytes 保持一致）。
  static String _formatBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }
}

// ========================== 浮动↓按钮 ==========================

class _JumpToBottomBtn extends StatelessWidget {
  final VoidCallback onTap;
  const _JumpToBottomBtn({required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: context.cs.surface,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(Icons.keyboard_arrow_down,
            size: 28, color: context.cs.onSurfaceVariant),
      ),
    );
  }
}

// =========================== 输入栏（语音 / + / 表情 / 输入） ===========================

class _InputBar extends StatefulWidget {
  final TextEditingController controller;
  final ChatMsg? quoteMsg;
  final VoidCallback onClearQuote;
  final VoidCallback onSend;
  // 「+」悬浮功能面板：开关状态由 ChatPage 持有（面板渲染在消息列表 Stack 里，
  // 面板项点击的分发逻辑也在 ChatPage —— 输入栏只负责 toggle）
  final bool plusOpen;
  final VoidCallback onTogglePlus;
  // 表情悬浮面板：同上，状态在 ChatPage（与「+」面板同款悬浮卡片、互斥）
  final bool emojiOpen;
  final VoidCallback onToggleEmoji;
  // 语音录制完成回调（type=4 语音消息，2026-09-17）
  final ValueChanged<VoiceRecorderResult> onVoiceSend;

  const _InputBar({
    required this.controller,
    required this.quoteMsg,
    required this.onClearQuote,
    required this.onSend,
    required this.plusOpen,
    required this.onTogglePlus,
    required this.emojiOpen,
    required this.onToggleEmoji,
    required this.onVoiceSend,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  bool _hasText = false;
  bool _voiceMode = false; // 语音模式：输入框变"按住说话"
  bool _recording = false; // 录音中（按钮按下态）
  bool _starting = false; // 正在异步启动录音（含等待授权），防止重复触发
  bool _pointerDown = false; // 手指是否仍按在"按住说话"上（授权弹窗期间可能被系统取消）
  double _recStartY = 0; // 按下时指针 Y，用于判定上滑取消
  final VoiceRecorderService _recSvc = VoiceRecorderService.instance;
  OverlayEntry? _overlay;

  /// 切换语音/键盘模式。进入语音模式时提前申请麦克风权限（首次为 denied 时），
  /// 让系统授权弹窗在"未按住"时出现，避免真正按住时被弹窗打断手势而卡死（见 _onRecordDown）。
  /// 已永久拒绝（isPermanentlyDenied）不在此重弹，交由按住时的 toast 提示。
  Future<void> _toggleVoiceMode() async {
    final next = !_voiceMode;
    if (next) {
      if (kIsWeb) {
        // H5：切语音模式时用 getUserMedia 先请求麦克风授权（与原生
        // 「未按住时弹窗」策略对齐），被拒不进入语音模式
        final ok = await CallPermissions.ensureForVoice();
        if (!ok || !mounted) return;
      } else {
        final st = await Permission.microphone.status;
        if (st.isDenied) {
          await Permission.microphone.request();
        }
      }
    }
    if (mounted) setState(() => _voiceMode = next);
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    _recSvc.elapsedMs.addListener(_onElapsed); // 60s 自动发送
  }

  @override
  void dispose() {
    _recSvc.elapsedMs.removeListener(_onElapsed);
    _removeOverlay();
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    final has = widget.controller.text.trim().isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);
  }

  // ===== 语音录制（type=4，2026-09-17）=====
  // 微信式交互：按住录制 → 上滑 >50px 取消 → 松开发送；<1s 太短丢弃；60s 自动发送。
  void _onElapsed() {
    if (_recSvc.isRecording && _recSvc.elapsedMs.value >= 60000) {
      _finishRecord(); // 到点自动结束并发送
    }
  }

  Future<void> _onRecordDown(PointerDownEvent e) async {
    if (_recSvc.isRecording || _starting) return;
    // 按下即标记"手指在按住"，并在异步等待授权期间跟踪是否被系统取消/抬起。
    _pointerDown = true;
    _starting = true;
    final ok = await _recSvc.start();
    _starting = false;
    if (!mounted) {
      // 组件已销毁：若已开录则回滚临时文件，避免残留。
      if (ok) await _recSvc.cancel();
      _pointerDown = false;
      return;
    }
    // 关键修复：首次授权弹窗会打断手势（系统派发 PointerCancel 或吃掉抬起事件），
    // 导致 _finishRecord 在 isRecording 仍为 false 时提前返回、事后 start 成功却无人停止而卡死。
    // 这里以 _pointerDown 是否仍为 true 判定：授权期间手指已离开/被取消 → 直接放弃本次录音。
    if (!_pointerDown) {
      if (ok) await _recSvc.cancel();
      _pointerDown = false;
      return;
    }
    if (!ok) {
      _pointerDown = false;
      AppDialogs.toast(
          context, AppLocalizations.of(context).t('chatVoicePermissionDenied'));
      return;
    }
    _recStartY = e.position.dy;
    _showOverlay();
    if (mounted) setState(() => _recording = true);
  }

  void _onRecordMove(PointerMoveEvent e) {
    if (!_recSvc.isRecording) return;
    final dy = e.position.dy - _recStartY;
    _recSvc.setCancelMode(dy < -50); // 上滑超过 50px 进入取消区
  }

  Future<void> _onRecordUp(PointerUpEvent e) async {
    _pointerDown = false;
    await _finishRecord();
  }

  Future<void> _onRecordCancel() async {
    _pointerDown = false;
    await _finishRecord();
  }

  Future<void> _finishRecord() async {
    if (!_recSvc.isRecording) return;
    _pointerDown = false;
    final cancel = _recSvc.cancelMode.value;
    _removeOverlay();
    if (mounted) setState(() => _recording = false);
    if (cancel) {
      await _recSvc.cancel();
      return;
    }
    final res = await _recSvc.stop();
    if (res == null) return;
    if (res.durationMs < 1000) {
      if (mounted) {
        AppDialogs.toast(
            context, AppLocalizations.of(context).t('chatVoiceTooShort'));
      }
      return;
    }
    widget.onVoiceSend(res);
  }

  void _showOverlay() {
    _removeOverlay();
    _overlay = OverlayEntry(builder: (c) => _recOverlay(c));
    Overlay.of(context).insert(_overlay!);
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  /// 录音浮层：半透明遮罩 + 居中卡片（计时 / 麦克风 / 取消提示）。
  Widget _recOverlay(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Positioned.fill(
      child: Material(
        color: Colors.black.withValues(alpha: 0.25),
        child: Center(
          child: ValueListenableBuilder<bool>(
            valueListenable: _recSvc.cancelMode,
            builder: (c, cancel, _) => Container(
              width: 160,
              height: 160,
              decoration: BoxDecoration(
                color: cancel
                    ? Colors.red.withValues(alpha: 0.85)
                    : Colors.black.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ValueListenableBuilder<int>(
                    valueListenable: _recSvc.elapsedMs,
                    builder: (c, ms, _) => Text(
                      _fmt(ms),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Icon(Icons.mic, color: Colors.white, size: 36),
                  const SizedBox(height: 10),
                  Text(
                    cancel
                        ? t('chatVoiceReleaseToCancel')
                        : t('chatVoiceSlideUpToCancel'),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _fmt(int ms) {
    final s = (ms / 1000).floor();
    final m = s ~/ 60;
    final ss = s % 60;
    return '$m:${ss.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Container(
      decoration: BoxDecoration(
        color: context.cs.surface,
        border: Border(
            top: BorderSide(color: context.cs.outlineVariant, width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 引用条
          if (widget.quoteMsg != null)
            Container(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: context.cs.surface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.format_quote,
                      size: 16, color: AppTheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      // 特殊消息（图片/红包/通话/名片等）显示 [图片] 等标签，
                      // 不透出 URL / JSON 原文（与消息气泡上的引用条同一套转换）
                      widget.quoteMsg!.replyPreview(t),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13, color: context.cs.onSurfaceVariant),
                    ),
                  ),
                  InkWell(
                    onTap: widget.onClearQuote,
                    child: Icon(Icons.close,
                        size: 16, color: context.cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Row(
              children: [
                // 语音模式切换：mic → 键盘（需求2：切换后按钮本身也要变）
                IconButton(
                  onPressed: _toggleVoiceMode,
                  icon: Icon(
                      _voiceMode ? Icons.keyboard_alt_outlined : Icons.mic_none,
                      size: 24,
                      color: _voiceMode
                          ? AppTheme.primary
                          : context.cs.onSurfaceVariant),
                ),
                // 语音模式：输入框变"按住说话"按钮（微信式：按住录制 / 上滑取消 / 60s 自动发送）
                if (_voiceMode)
                  Expanded(
                    child: Listener(
                      onPointerDown: (e) => _onRecordDown(e),
                      onPointerMove: (e) => _onRecordMove(e),
                      onPointerUp: (e) => _onRecordUp(e),
                      onPointerCancel: (_) => _onRecordCancel(),
                      child: Container(
                        height: 42,
                        decoration: BoxDecoration(
                          color: _recording
                              ? AppTheme.primary.withValues(alpha: 0.15)
                              : context.cs.surfaceContainer,
                          borderRadius: BorderRadius.circular(21),
                        ),
                        alignment: Alignment.center,
                        child: Text(t('chatHoldToTalk'),
                            style: TextStyle(
                                fontSize: 14,
                                color: _recording
                                    ? AppTheme.primary
                                    : context.cs.onSurfaceVariant)),
                      ),
                    ),
                  )
                else
                  Expanded(
                    // 输入框
                    child: Container(
                      decoration: BoxDecoration(
                        color: context.cs.surfaceContainer,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: TextField(
                        controller: widget.controller,
                        minLines: 1,
                        maxLines: 4,
                        decoration: InputDecoration(
                          hintText: t('chatMessageHint'),
                          hintStyle: TextStyle(
                              color: context.cs.onSurfaceVariant, fontSize: 14),
                          isDense: true,
                          border: InputBorder.none,
                          contentPadding:
                              EdgeInsets.symmetric(vertical: 10, horizontal: 0),
                        ),
                        onSubmitted: (_) => widget.onSend(),
                      ),
                    ),
                  ),
                // 需求2：有内容（文本）→ 右侧变发送按钮；无内容 → 表情 + +
                // （2026-09-16：多图选完直发，原「待发图片也显示发送钮」已删）
                if (!_voiceMode && _hasText)
                  IconButton(
                    onPressed: widget.onSend,
                    icon: const Icon(Icons.send_rounded,
                        size: 24, color: AppTheme.primary),
                  )
                else if (!_voiceMode) ...[
                  IconButton(
                    onPressed: widget.onToggleEmoji,
                    icon: Icon(
                        widget.emojiOpen
                            ? Icons.keyboard_alt_outlined
                            : Icons.emoji_emotions_outlined,
                        size: 24,
                        color: context.cs.onSurfaceVariant),
                  ),
                  IconButton(
                    onPressed: widget.onTogglePlus,
                    icon: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: context.cs.onSurfaceVariant
                                .withValues(alpha: 0.4),
                            width: 1.2),
                      ),
                      child: Icon(Icons.add,
                          size: 16, color: context.cs.onSurfaceVariant),
                    ),
                  ),
                ],
              ],
            ),
          ),
          // emoji 面板已改为悬浮卡片（与「+」功能面板同款），渲染在消息列表 Stack 中
        ],
      ),
    );
  }
}

/// 表情悬浮面板：与「+」功能卡片同款右下角小卡片（240 宽）
class _EmojiPane extends StatelessWidget {
  final TextEditingController controller;

  /// true=宽屏悬浮小卡片（240 宽、带阴影圆角）；false=窄屏输入栏上方全宽抽屉
  final bool wide;
  const _EmojiPane({required this.controller, this.wide = true});

  static const _emojis = [
    '😀',
    '😄',
    '😁',
    '😂',
    '😊',
    '😍',
    '🥰',
    '😘',
    '😎',
    '🤔',
    '😅',
    '😭',
    '😡',
    '👍',
    '👏',
    '🙏',
    '💪',
    '🎉',
    '❤️',
    '💙',
    '🔥',
    '✨',
    '✅',
    '👀',
    '🙌',
    '🤝',
    '🌹',
    '🎁',
    '🍵',
    '☕',
    '📌',
    '💡',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: wide ? 240 : double.infinity,
      decoration: BoxDecoration(
        color: context.cs.surface,
        borderRadius: wide
            ? BorderRadius.circular(16)
            : const BorderRadius.vertical(top: Radius.circular(12)),
        boxShadow: wide
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.14),
                  blurRadius: 18,
                  offset: const Offset(0, 4),
                ),
              ]
            : const [],
        border: wide
            ? null
            : Border(
                top: BorderSide(
                    color: context.cs.surfaceContainerHighest, width: 0.5),
              ),
      ),
      // 窄屏：顶部拖拽指示条 + 内容；宽屏直接内容
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!wide)
            Container(
              margin: const EdgeInsets.only(top: 6, bottom: 4),
              width: 32,
              height: 3,
              decoration: BoxDecoration(
                color: context.cs.onSurfaceVariant.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
          Padding(
            padding: EdgeInsets.all(wide ? 10 : 8),
            child: GridView.count(
              crossAxisCount: 8,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: wide ? 4 : 6,
              crossAxisSpacing: wide ? 4 : 6,
              childAspectRatio: wide ? 0.95 : 1.15,
              children: _emojis
                  .map((e) => InkWell(
                        onTap: () => controller.text += e,
                        borderRadius: BorderRadius.circular(6),
                        child: Center(
                            child: Text(e,
                                style: TextStyle(fontSize: wide ? 18 : 22))),
                      ))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlusDrawer extends StatelessWidget {
  final VoidCallback? onMention;
  final ValueChanged<String> onItem;
  final bool showMoney; // 功能开关：关闭零钱时隐藏红包/转账入口

  /// true=宽屏悬浮小卡片（240 宽、带阴影圆角）；false=窄屏输入栏上方全宽抽屉
  final bool wide;
  const _PlusDrawer(
      {this.onMention,
      required this.onItem,
      this.showMoney = true,
      this.wide = true});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    // label 存词典 key，显示时翻译；onItem 回传 key 供逻辑匹配
    var items = <_DrawerItem>[
      const _DrawerItem('chatDrawerAlbum', Icons.photo_outlined),
      const _DrawerItem('chatDrawerFile', Icons.folder_outlined),
      const _DrawerItem('chatDrawerRedPacket', Icons.card_giftcard),
      const _DrawerItem('chatDrawerTransfer', Icons.currency_yen),
      const _DrawerItem('chatDrawerVoiceCall', Icons.phone_outlined),
      const _DrawerItem('chatDrawerVideoCall', Icons.videocam_outlined),
      const _DrawerItem('chatDrawerCard', Icons.person_outline),
      const _DrawerItem('chatDrawerLocation', Icons.location_on_outlined),
    ];
    if (!showMoney) {
      items = items
          .where((it) =>
              it.key != 'chatDrawerRedPacket' && it.key != 'chatDrawerTransfer')
          .toList();
    }
    return Container(
      width: wide ? 240 : double.infinity, // 悬浮小卡片 / 全宽抽屉
      decoration: BoxDecoration(
        color: context.cs.surface,
        borderRadius: wide
            ? BorderRadius.circular(16)
            : const BorderRadius.vertical(top: Radius.circular(12)),
        boxShadow: wide
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.14),
                  blurRadius: 18,
                  offset: const Offset(0, 4),
                ),
              ]
            : const [],
        border: wide
            ? null
            : Border(
                top: BorderSide(
                    color: context.cs.surfaceContainerHighest, width: 0.5),
              ),
      ),
      // 窄屏：顶部加小拖拽指示条（微信式）；宽屏无
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!wide)
            Container(
              margin: const EdgeInsets.only(top: 6, bottom: 4),
              width: 32,
              height: 3,
              decoration: BoxDecoration(
                color: context.cs.onSurfaceVariant.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
          Padding(
            padding: EdgeInsets.symmetric(
                horizontal: wide ? 12 : 20, vertical: wide ? 14 : 8),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: wide ? 12 : 16,
                crossAxisSpacing: wide ? 8 : 16,
                // 窄屏用固定格高（mainAxisExtent），保证「52 图标 + 文字行」不被格子裁切；
                // 宽屏保持原 childAspectRatio 紧凑比例
                childAspectRatio: wide ? 0.86 : 1.0,
                mainAxisExtent: wide ? null : 86,
              ),
              itemCount: items.length,
              itemBuilder: (ctx, i) {
                final it = items[i];
                return InkWell(
                  onTap: () => onItem(it.key),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: wide ? 36 : 52,
                        height: wide ? 36 : 52,
                        decoration: BoxDecoration(
                          color: context.cs.surfaceContainerHighest
                              .withValues(alpha: wide ? 0.5 : 0.6),
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: Icon(it.icon,
                            size: wide ? 20 : 26,
                            color: it.key == 'chatDrawerRedPacket' ||
                                    it.key == 'chatDrawerTransfer'
                                ? AppTheme.primary
                                : context.cs.onSurfaceVariant),
                      ),
                      SizedBox(height: wide ? 5 : 6),
                      Text(t(it.key),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: wide ? 11 : 12,
                              color: context.cs.onSurfaceVariant)),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _DrawerItem {
  final String key; // 词典 key（显示时翻译，逻辑匹配用 key）
  final IconData icon;
  const _DrawerItem(this.key, this.icon);
}

// ===================== 名片气泡（type=10：头像 + 昵称 + "个人名片"角标） =====================

class _CardBubble extends StatelessWidget {
  final String content; // JSON {"userId","nickname","avatar"}
  final List<Color> colors; // 头像色板（与消息行一致）
  final VoidCallback onTap;

  const _CardBubble({
    required this.content,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    // 解析容错：坏 JSON 时展示降级内容，不崩溃
    Map<String, dynamic> d = {};
    try {
      final j = jsonDecode(content);
      if (j is Map) d = j.cast<String, dynamic>();
    } catch (_) {}
    final userId = (d['userId'] ?? '').toString();
    // 群/频道名片（be-channel 契约中）：名称字段可能是 name，兼容取之
    final nickname = (d['nickname'] ?? d['name'] ?? '').toString();
    final avatar = (d['avatar'] ?? '').toString();
    // 小字标签按名片类型：个人名片 / 群名片 / 频道名片（旧消息无 kind → 个人）
    final kind = _cardKindOf(d);
    final tagKey = kind == 'group'
        ? 'cardBubbleTagGroup'
        : kind == 'channel'
            ? 'cardBubbleTagChannel'
            : 'cardBubbleTag';
    final name = nickname.isNotEmpty
        ? nickname
        : (userId.isEmpty ? '?' : '...${userId.substring(userId.length - 4)}');
    final letter = name.characters.first;
    final colorIdx =
        (userId.isEmpty ? name : userId).hashCode.abs() % colors.length;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: context.cs.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusBubble),
      ),
      constraints: const BoxConstraints(maxWidth: 240),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 44px 圆角头像：加载中 / 失败 / 为空统一走 AppAvatar 占位（彩色底 + 首字）
                AppAvatar(
                  url: AppConfig.assetUrl(avatar),
                  name: letter,
                  size: 44,
                  radius: 10,
                  background: colors[colorIdx],
                ),
                const SizedBox(width: 10),
                // 昵称 + 「个人名片」小字上下排列（微信式，不再单起一行）
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: context.cs.onSurface)),
                      const SizedBox(height: 2),
                      Text(t(tagKey),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color: context.cs.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ===================== 长按消息全屏遮罩（图 7：模糊 + 高亮 + 回复输入） =====================

class _LongPressOverlay extends StatefulWidget {
  final ChatMsg msg;
  final String myId;
  final Rect? rowRect; // 消息行的屏幕矩形（RenderBox localToGlobal 取得）
  final List<Color> colors;
  final VoidCallback onClose;
  final VoidCallback onCopy;
  final VoidCallback onQuote;
  final VoidCallback onRecall;
  final VoidCallback onFavorite;
  final VoidCallback onForward;
  final VoidCallback onPin;
  final VoidCallback onMultiSelect; // 多选（进入多选模式）
  /// 群消息「已读详情」：仅群 + 自己发的 + 有服务端 ID 时传非 null；其余场景为 null（菜单不显示该项）
  final VoidCallback? onReadDetail;

  /// 消息行原位截图：非 null 时在遮罩上层清晰还原消息内容（微信式炸开），
  /// null（截图失败）时回落为半透明高亮框
  final ui.Image? snapshot;

  const _LongPressOverlay({
    required this.msg,
    required this.myId,
    required this.rowRect,
    required this.snapshot,
    required this.colors,
    required this.onClose,
    required this.onCopy,
    required this.onQuote,
    required this.onRecall,
    required this.onFavorite,
    required this.onForward,
    required this.onPin,
    required this.onMultiSelect,
    this.onReadDetail,
  });

  @override
  State<_LongPressOverlay> createState() => _LongPressOverlayState();
}

class _LongPressOverlayState extends State<_LongPressOverlay>
    with SingleTickerProviderStateMixin {
  // 出现动画：150ms scale+fade（origin 定在消息方向侧）
  late final AnimationController _anim = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 150));
  late final Animation<double> _curve =
      CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    _anim.forward();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  // 菜单几何：3 列 × N 行，横向 16px 边距、宽不超过屏宽-32
  static const double _menuGap = 10; // 菜单与消息行的间距
  static const double _tileH = 56; // 单个动作项高度
  static const double _menuVpad = 8;
  static const double _rowGap = 6;

  /// 菜单总高（按动作项数量动态算行数，每行 3 项）
  double _menuHeight(int itemCount) {
    final rows = (itemCount + 2) ~/ 3;
    return _menuVpad * 2 + _tileH * rows + _rowGap * (rows - 1);
  }

  @override
  Widget build(BuildContext context) {
    // sizeOf（aspect 订阅）：只依赖 size 字段，viewInsets（键盘）变化不触发
    // 本浮层逐帧重定位（第十四批问题 3，同底部区 paddingOf 的理由）
    final screen = MediaQuery.sizeOf(context);
    final rect = widget.rowRect;

    // 纵向自适应：默认放消息行下方；放不下 → 改到上方
    final menuHeight = _menuHeight(_buildActions().length); // 动作项数动态（群聊自己消息多一项「已读详情」）
    bool below;
    double menuTop;
    if (rect != null) {
      below = rect.bottom + _menuGap + menuHeight <= screen.height - 8;
      menuTop =
          below ? rect.bottom + _menuGap : rect.top - _menuGap - menuHeight;
    } else {
      below = true;
      menuTop = screen.height * 0.42;
    }
    if (menuTop < 8) menuTop = 8;

    // 水平：以消息行中心对齐，夹在屏内（16px 边距）
    final focusX = rect?.center.dx ?? screen.width / 2;
    final menuW = screen.width - 32 < 312 ? screen.width - 32 : 312.0;
    final maxLeft = max(16.0, screen.width - menuW - 16);
    final menuLeft = max(16.0, min(maxLeft, focusX - menuW / 2));
    // 三角箭头指向消息行中心（夹在菜单宽度内，不越界）
    const arrowW = 12.0;
    final arrowLeft =
        min(max(10.0, focusX - menuLeft - arrowW / 2), menuW - 10.0 - arrowW);

    return Stack(
      fit: StackFit.expand,
      children: [
        // 背景遮罩 + BackdropFilter 模糊（H5 支持 BackdropFilter）
        Positioned.fill(
          child: GestureDetector(
            onTap: widget.onClose,
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: Container(color: Colors.black.withValues(alpha: 0.45)),
            ),
          ),
        ),
        // 消息行原位还原：优先显示行截图（清晰的消息内容），外圈
        // primary 高亮边框 + 发光；截图失败回落白 8% 半透明填充框
        if (rect != null)
          Positioned(
            left: rect.left,
            top: rect.top,
            width: rect.width,
            height: rect.height,
            child: FadeTransition(
              opacity: _curve,
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: widget.snapshot != null
                      ? null
                      : Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: AppTheme.primary.withValues(alpha: 0.3),
                      width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.primary.withValues(alpha: 0.3),
                      blurRadius: 16,
                      offset: const Offset(0, 0),
                    ),
                  ],
                ),
                child: widget.snapshot != null
                    ? RawImage(
                        image: widget.snapshot,
                        fit: BoxFit.fill,
                        width: rect.width,
                        height: rect.height,
                      )
                    : null,
              ),
            ),
          ),
        // 菜单气泡：深色圆角 + 顶部小三角箭头指向消息；scale origin 在消息侧
        Positioned(
          left: menuLeft,
          top: menuTop,
          width: menuW,
          child: FadeTransition(
            opacity: _curve,
            child: ScaleTransition(
              scale: _curve,
              alignment: below ? Alignment.topCenter : Alignment.bottomCenter,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  _menuBody(),
                  Positioned(
                    left: arrowLeft,
                    top: below ? -5.0 : null,
                    bottom: below ? null : -5.0,
                    child: CustomPaint(
                      size: const Size(12, 5),
                      painter: _MenuArrowPainter(up: below),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 菜单动作项构建：固定 7 项 +（群聊自己的消息）追加「已读详情」第 8 项。
  List<_MenuAction> _buildActions() {
    final t = AppLocalizations.of(context).t;
    final items = <_MenuAction>[
      _MenuAction(Icons.copy, t('chatActionCopy'), widget.onCopy),
      _MenuAction(Icons.format_quote, t('chatActionQuote'), widget.onQuote),
      _MenuAction(
          Icons.star_outline, t('chatActionFavorite'), widget.onFavorite),
      _MenuAction(Icons.undo, t('chatActionRecall'), widget.onRecall),
      _MenuAction(Icons.forward, t('chatActionForward'), widget.onForward),
      _MenuAction(Icons.checklist, t('chatActionMerge'), widget.onMultiSelect),
      _MenuAction(Icons.push_pin_outlined, t('chatActionPin'), widget.onPin),
    ];
    if (widget.onReadDetail != null) {
      items.add(_MenuAction(
          Icons.visibility_outlined, t('chatActionReadDetail'), widget.onReadDetail!));
    }
    return items;
  }

  /// 菜单主体：#1C1C1E 圆角 14，3 列 × N 行（复制/引用/收藏/撤回/转发/多选/置顶）
  Widget _menuBody() {
    final items = _buildActions();
    // 每 3 项一行（末行不足 3 项也单独成行）
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += 3) {
      final chunk =
          items.sublist(i, i + 3 > items.length ? items.length : i + 3);
      rows.add(Row(
        children: [
          for (final it in chunk)
            Expanded(child: _menuItem(it.icon, it.label, it.onTap)),
        ],
      ));
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: _menuVpad),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: _rowGap),
            rows[i],
          ],
        ],
      ),
    );
  }

  Widget _menuItem(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        height: _tileH,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: Colors.white),
            const SizedBox(height: 4),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11, color: Colors.white.withValues(alpha: 0.7))),
          ],
        ),
      ),
    );
  }
}

/// 菜单气泡的小三角箭头（up=true 指向上方消息，false 指向下方消息）
class _MenuArrowPainter extends CustomPainter {
  final bool up;
  _MenuArrowPainter({required this.up});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFF1C1C1E);
    final path = Path();
    if (up) {
      path.moveTo(0, size.height);
      path.lineTo(size.width / 2, 0);
      path.lineTo(size.width, size.height);
    } else {
      path.moveTo(0, 0);
      path.lineTo(size.width / 2, size.height);
      path.lineTo(size.width, 0);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _MenuArrowPainter oldDelegate) =>
      oldDelegate.up != up;
}

/// 长按菜单动作项（动态行构建用）
class _MenuAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _MenuAction(this.icon, this.label, this.onTap);
}

/// 合并转发气泡（type=12）：
/// 卡片式引用样式 —— 标题（发送者汇总）+ 「共 N 条消息」+ 右上「聊天记录」角标，
/// 点击进 MergeForwardDetailPage 查看逐条内容。
class _MergeBubble extends StatelessWidget {
  final String content;
  final bool isMine;
  final VoidCallback onTap;

  const _MergeBubble({
    required this.content,
    required this.isMine,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final cs = context.cs;

    String users = '';
    int count = 0;
    final previews = <String>[];
    try {
      final data = jsonDecode(content);
      if (data is Map) {
        users = data['users']?.toString() ?? '';
        count = (data['count'] as num?)?.toInt() ?? 0;
        final items = data['items'];
        if (items is List) {
          for (final raw in items.take(2)) {
            if (raw is! Map) continue;
            final name = raw['senderName']?.toString() ?? '';
            final type = (raw['type'] as num?)?.toInt() ?? 1;
            final c = raw['content']?.toString() ?? '';
            final text = type == 1
                ? c.replaceAll('\n', ' ')
                : _mergeTypePlaceholder(type, t);
            previews.add(name.isNotEmpty ? '$name：$text' : text);
          }
        }
        if (count == 0 && items is List) count = items.length;
      }
    } catch (_) {
      previews.clear();
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 240),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.5), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题行：发送者汇总 + 「聊天记录」角标
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    users.isNotEmpty ? users : t('mergeRecordTag'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(t('mergeRecordTag'),
                      style:
                          TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(t('mergeCountMsg', {'n': '$count'}),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            // 摘要预览（前 2 条）：解析失败不显示
            if (previews.isNotEmpty) ...[
              const SizedBox(height: 4),
              for (final p in previews)
                Text(p,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.8))),
            ],
          ],
        ),
      ),
    );
  }
}

/// 合并摘要里非文本类型的占位文案
String _mergeTypePlaceholder(int type, String Function(String) t) {
  const map = {
    2: 'svcImage',
    3: 'svcFile',
    4: 'svcVoice',
    5: 'svcVideo',
    7: 'svcCall',
    8: 'svcRedPacket',
    9: 'svcTransfer',
    10: 'svcCard',
    11: 'svcLinkCard',
    12: 'mergeRecordTag',
    14: 'svcLocation',
  };
  final k = map[type];
  return k != null ? t(k) : '';
}

/// 行高测量（2026-09-20 防跳配套）：行布局完成后把尺寸回报给高度缓存。
/// RenderProxyBox 层直接比较，尺寸没变不触发回调；回调里只写内存 map 与
/// 异步写 Hive，不 setState（布局期间禁止）。
class _SizeReporter extends SingleChildRenderObjectWidget {
  final ValueChanged<Size> onSize;
  const _SizeReporter({required this.onSize, required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSizeReporter(onSize);
  @override
  void updateRenderObject(
      BuildContext context, covariant _RenderSizeReporter renderObject) {
    renderObject.onSize = onSize;
  }
}

class _RenderSizeReporter extends RenderProxyBox {
  _RenderSizeReporter(this.onSize);
  ValueChanged<Size> onSize;
  Size? _last;
  @override
  void performLayout() {
    super.performLayout();
    final child = this.child;
    if (child == null) return;
    final s = child.size;
    final last = _last;
    if (last == null ||
        (s.width - last.width).abs() > 0.5 ||
        (s.height - last.height).abs() > 0.5) {
      _last = s;
      onSize(s);
    }
  }
}
