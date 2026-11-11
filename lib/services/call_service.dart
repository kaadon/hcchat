import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'user_cache.dart';
import 'ws_service.dart';

/// 通话阶段
enum CallPhase { idle, outgoing, incoming, connected }

/// 通话信令动作（承载在 type=7 消息的 content JSON 里）
class CallAction {
  static const invite = 'invite';
  static const accept = 'accept';
  static const reject = 'reject';
  static const hangup = 'hangup';
  static const cancel = 'cancel'; // 主叫在对方接听前挂断
  // ---- 群通话 / WebRTC 扩展（服务端纯透传）----
  static const join = 'join'; // 接听方媒体就绪，广播入房（WebRTC 触发 offer）
  static const leave = 'leave'; // 群通话中某人退出（通话对其他人继续）
  static const sdp = 'sdp'; // WebRTC offer/answer（{to, kind, sdp}）
  static const ice = 'ice'; // WebRTC ICE 候选（{to, candidate}）
}

/// 群通话成员（宫格 UI 展示）
class CallParticipant {
  final String id;
  final String name;
  final String avatar;
  const CallParticipant({required this.id, this.name = '', this.avatar = ''});

  @override
  bool operator ==(Object other) => other is CallParticipant && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

/// 通话引擎配置（/api/v1/trtc/config 归一化结果）
class CallConfig {
  final String engine; // trtc | webrtc | livekit
  final bool trtcEnabled; // engine=trtc 时是否已配置 appId
  final Map<String, dynamic> trtcSig; // /trtc/usersig 响应（appId/userId/userSig）
  final List<Map<String, dynamic>> iceServers; // WebRTC STUN/TURN
  final String livekitUrl; // LiveKit SFU 房间地址（engine=livekit 时有效）
  const CallConfig({
    required this.engine,
    required this.trtcEnabled,
    this.trtcSig = const {},
    this.iceServers = const [],
    this.livekitUrl = '',
  });

  bool get trtcUsable => engine == 'trtc' && trtcEnabled;
  bool get webrtcUsable => engine == 'webrtc' && iceServers.isNotEmpty;
  // LiveKit 走 SFU：无需 ICE 配置，有 url 即可用（token 由 /livekit/token 按通话签发）
  bool get livekitUsable => engine == 'livekit' && livekitUrl.isNotEmpty;
}

/// 全局通话状态（UI 通过 ValueNotifier 监听）
class CallState {
  final String convId;
  final String callType; // voice / video
  final String peerName;
  final String peerAvatar;
  final CallPhase phase;
  final bool isCaller;
  final bool isGroup; // 群组通话
  final String engine; // trtc | webrtc（invite 协商结果）
  final String callerName; // 群通话：发起人昵称（来电页副标题）

  const CallState({
    required this.convId,
    required this.callType,
    required this.peerName,
    required this.peerAvatar,
    required this.phase,
    required this.isCaller,
    this.isGroup = false,
    this.engine = 'trtc',
    this.callerName = '',
  });

  CallState copyWith({CallPhase? phase}) => CallState(
        convId: convId,
        callType: callType,
        peerName: peerName,
        peerAvatar: peerAvatar,
        phase: phase ?? this.phase,
        isCaller: isCaller,
        isGroup: isGroup,
        engine: engine,
        callerName: callerName,
      );
}

/// 一次性通话事件（供通话页弹提示 / 关闭页面）
class CallEvent {
  final String action; // accept / reject / hangup / cancel / timeout
  final String convId;
  final int duration;
  const CallEvent(this.action, this.convId, {this.duration = 0});
}

/// 通话信令服务（全局单例）
///
/// 职责：
/// 1. 主叫：发 invite → 等 accept（超时 45s 自动 cancel）
/// 2. 被叫：收 invite → 置 incoming（UI 弹来电页）→ accept/reject
/// 3. 任一方挂断：发 hangup（带时长），对端收到后关闭
/// 4. 群组通话：accept 后媒体就绪广播 join；退出发 leave（别人不挂）；参与人列表实时更新
/// 5. WebRTC 媒体信令（sdp/ice）：页面挂 [mediaSignalHandler] 后逐条转发
///
/// 信令全部走 type=7 消息，content 为 JSON：{action, callType, roomId, ...}
class CallService {
  CallService._();
  static final CallService instance = CallService._();

  final ValueNotifier<CallState?> state = ValueNotifier(null);

  /// 群通话参与人（含自己；UI 宫格监听）
  final ValueNotifier<List<CallParticipant>> participants =
      ValueNotifier(const []);

  /// 当前引擎配置（发起/接听时 ensureConfig 填充；通话页据此创建 CallMedia）
  CallConfig? config;

  /// 通话页挂载的媒体信令处理器（sdp/ice/join/leave 转发进媒体引擎）。
  ///
  /// handler 尚未挂载时到达的信令先入 _pendingMediaSigs 队列，挂载后重放。
  /// 2026-09-17 视频通话「只看到自己画面」根因：被叫 accept 后立即广播 join，
  /// 而主叫还在拉配置/getUserMedia（视频初始化比语音慢数秒），join 早到被
  /// 静默丢弃 → 主叫永远不发 offer → 双方都收不到对方媒体。
  void Function(Map<String, dynamic> sig)? _mediaSignalHandler;

  /// handler 未就绪期间缓存的媒体信令（join/sdp/ice/leave）
  final List<Map<String, dynamic>> _pendingMediaSigs = [];

  void Function(Map<String, dynamic> sig)? get mediaSignalHandler =>
      _mediaSignalHandler;

  set mediaSignalHandler(void Function(Map<String, dynamic> sig)? fn) {
    _mediaSignalHandler = fn;
    if (fn == null) {
      // 通话结束/通话页销毁：清空缓存，防止跨通话重放旧信令
      _pendingMediaSigs.clear();
      return;
    }
    if (_pendingMediaSigs.isEmpty) return;
    final pending = List<Map<String, dynamic>>.of(_pendingMediaSigs);
    _pendingMediaSigs.clear();
    for (final sig in pending) {
      fn(sig);
    }
  }

  /// 媒体信令统一出口：handler 未就绪先缓存（上限 80 条，防异常堆积）
  void _dispatchMediaSignal(Map<String, dynamic> sig) {
    final h = _mediaSignalHandler;
    if (h != null) {
      h(sig);
      return;
    }
    final from = sig['from']?.toString() ??
        sig['userId']?.toString() ??
        sig['to']?.toString() ??
        '';
    if (from.isEmpty) return;
    if (_pendingMediaSigs.length < 80) _pendingMediaSigs.add(sig);
  }

  final _events = StreamController<CallEvent>.broadcast();
  Stream<CallEvent> get events => _events.stream;

  VoidCallback? _wsCancel;
  String _myId = '';
  Timer? _ringTimer;
  DateTime? _connectedAt;
  int _joinTs = 0; // 自己的 join 时间戳（glare 仲裁参考）
  /// 当前通话对应的 invite 记录 msgId（一通电话一条记录模型）：
  /// 主叫取自 invite 发送响应；被叫取自收到的 invite 消息帧。
  /// 结束信令（hangup/cancel/reject）携带它，服务端据此把 invite 记录
  /// 原地改写为最终状态（done/rejected/missed），而不是新增第二条记录。
  String _inviteMsgId = '';

  static const int _ringTimeoutSec = 45;

  /// 群通话 Mesh 人数上限（WebRTC 每对成员一条直连，人数多上行扛不住）
  static const int groupMaxMembers = 4;

  /// 通话累计秒数（通话页每秒回写，挂断时用于上报通话时长）
  int _callSeconds = 0;

  int get callSeconds => _callSeconds;

  /// 通话页每秒回写一次自己的计时
  void syncCallSeconds(int s) {
    _callSeconds = s;
  }

  String get myId => _myId;

  /// 登录后调用：登记自己的 ID + 挂上全局 WS 监听
  Future<void> attach() async {
    await _ensureMyId();
    _wsCancel ??= GlobalWs.instance.onMessage(_onWsMessage);
    GlobalWs.instance.ensureConnected();
  }

  /// 自己的 ID（用于过滤自己信令的回显，避免把自己发的 invite 当成来电）
  Future<void> _ensureMyId() async {
    if (_myId.isNotEmpty) return;
    // 进程内缓存命中直接用（一次登录会话只拉一次 /user/profile）
    final cached = UserCache.myId;
    if (cached != null && cached.isNotEmpty) {
      _myId = cached;
      return;
    }
    try {
      final r = await ApiClient.instance.get('/api/v1/user/profile');
      final d = (r.data['data'] as Map<String, dynamic>?);
      UserCache.setMyProfile(d ?? {});
      _myId = d?['id']?.toString() ?? '';
    } catch (_) {}
  }

  void detach() {
    _wsCancel?.call();
    _wsCancel = null;
    _ringTimer?.cancel();
    _ringTimer = null;
    state.value = null;
  }

  /// 退出登录 / 切换账号：把通话相关的全局态彻底清干净。
  /// 不清的话 `_myId` 仍是上一个账号，接听来电时会把自己的信令回显误判成对方来电。
  Future<void> resetSession() async {
    _ringTimer?.cancel();
    _ringTimer = null;
    _connectedAt = null;
    _callSeconds = 0;
    _joinTs = 0;
    state.value = null;
    participants.value = const [];
    mediaSignalHandler = null;
    detach();
    _myId = ''; // 换号登录必须清空，否则 attach 时会复用旧 ID
  }

  // ============================ 引擎配置 ============================

  /// 拉取通话引擎配置并归一化（一次通话只拉一次；TRTC 模式顺带签 usersig）
  Future<CallConfig> ensureConfig() async {
    final cached = config;
    if (cached != null) return cached;
    var engine = 'trtc';
    var trtcEnabled = false;
    var iceServers = const <Map<String, dynamic>>[];
    var trtcSig = const <String, dynamic>{};
    var livekitUrl = '';
    try {
      final r = await ApiClient.instance.get('/api/v1/trtc/config');
      final c = (r.data['data'] as Map<String, dynamic>?) ?? {};
      final rawEngine = (c['engine']?.toString() ?? 'trtc');
      engine = ['webrtc', 'livekit'].contains(rawEngine) ? rawEngine : 'trtc';
      if (engine == 'trtc') {
        trtcEnabled = c['enabled'] == true;
        if (trtcEnabled) {
          try {
            final sig = await ApiClient.instance
                .get('/api/v1/trtc/usersig', query: {'room': ''});
            final d = (sig.data['data'] as Map<String, dynamic>?) ?? {};
            if (d['userSig'] != null) trtcSig = d;
          } catch (_) {}
          if (trtcSig.isEmpty) trtcEnabled = false;
        }
      } else if (engine == 'webrtc') {
        final w = c['webrtc'] as Map<String, dynamic>?;
        final raw = (w?['iceServers'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
            .toList();
        iceServers = raw;
      } else if (engine == 'livekit') {
        final lk = c['livekit'] as Map<String, dynamic>?;
        livekitUrl = lk?['url']?.toString() ?? '';
      }
    } catch (_) {}
    config = CallConfig(
      engine: engine,
      trtcEnabled: trtcEnabled,
      trtcSig: trtcSig,
      iceServers: iceServers,
      livekitUrl: livekitUrl,
    );
    return config!;
  }

  // ============================ 主叫 ============================

  /// 发起单聊通话：发 invite 信令，进入 outgoing（等待对方接听）
  Future<void> startCall({
    required String convId,
    required String callType,
    required String peerName,
    String peerAvatar = '',
  }) async {
    config = await ensureConfig();
    // invite 信令必须带【主叫自己】的昵称/头像：
    // 2026-09-17 用户实测：旧实现把 peerName（= 会话对方 = 被叫的名字）当成
    // callerName 塞进信令，被叫 A 的来电页/接听页显示的是 A 自己。
    // 正确语义见 startGroupCall：从 UserCache 取主叫本人信息；
    // peerName/peerAvatar 参数只用于主叫自己的等待页展示。
    final me = UserCache.myProfileData;
    final myName = me?['nickname']?.toString() ?? '';
    final myAvatar = me?['avatar']?.toString() ?? '';
    final mid = await _sendSignal(
      convId: convId,
      action: CallAction.invite,
      callType: callType,
      callerName: myName,
      callerAvatar: myAvatar,
    );
    if (mid != null && mid.isNotEmpty) _inviteMsgId = mid;
    state.value = CallState(
      convId: convId,
      callType: callType,
      peerName: peerName,
      peerAvatar: peerAvatar,
      phase: CallPhase.outgoing,
      isCaller: true,
      engine: config?.engine ?? 'trtc',
    );
    _startRingTimeout(convId);
  }

  /// 发起群组通话：邀请全群成员（room 即会话），信令带 group:true
  Future<void> startGroupCall({
    required String convId,
    required String callType,
    required String groupName,
    String groupAvatar = '',
  }) async {
    config = await ensureConfig();
    final me = UserCache.myProfileData;
    final myName = me?['nickname']?.toString() ?? '';
    final myAvatar = me?['avatar']?.toString() ?? '';
    final gMid = await _sendSignal(
      convId: convId,
      action: CallAction.invite,
      callType: callType,
      callerName: myName,
      callerAvatar: myAvatar,
      extras: {
        'group': true,
        'groupName': groupName,
        'groupAvatar': groupAvatar,
      },
    );
    if (gMid != null && gMid.isNotEmpty) _inviteMsgId = gMid;
    state.value = CallState(
      convId: convId,
      callType: callType,
      peerName: groupName,
      peerAvatar: groupAvatar,
      phase: CallPhase.outgoing,
      isCaller: true,
      isGroup: true,
      engine: config?.engine ?? 'trtc',
      callerName: myName,
    );
    _setParticipants(
        [CallParticipant(id: _myId, name: myName, avatar: myAvatar)]);
    _startRingTimeout(convId);
  }

  void _startRingTimeout(String convId) {
    _ringTimer?.cancel();
    _ringTimer = Timer(const Duration(seconds: _ringTimeoutSec), () {
      final s = state.value;
      if (s != null && s.convId == convId && s.phase == CallPhase.outgoing) {
        _sendSignal(
            convId: convId,
            action: CallAction.cancel,
            callType: s.callType,
            extras: s.isGroup ? {'group': true} : null,
            // 单聊振铃超时 → cancel 需要服务端把 invite 记录改写为「通话未接通」；
            // 群通话 cancel 仍是纯信令。
            silent: s.isGroup);
        _reset();
        _emit(CallEvent(CallAction.cancel, convId));
      }
    });
  }

  // ============================ 被叫 ============================

  /// 接听：发 accept，进入 connected
  Future<void> accept() async {
    final s = state.value;
    if (s == null) return;
    _ringTimer?.cancel();
    await _sendSignal(
      convId: s.convId,
      action: CallAction.accept,
      callType: s.callType,
      silent: true, // 纯信令：实时通知主叫即可，不落库成通话记录
    );
    _connectedAt = DateTime.now();
    _callSeconds = 0;
    state.value = s.copyWith(phase: CallPhase.connected);
    if (s.isGroup) {
      _addParticipant(CallParticipant(
        id: _myId,
        name: UserCache.myProfileData?['nickname']?.toString() ?? '',
        avatar: UserCache.myProfileData?['avatar']?.toString() ?? '',
      ));
    }
    _emit(CallEvent(CallAction.accept, s.convId));
  }

  /// 拒接：发 reject，回到 idle。
  /// 单聊 reject 非 silent：服务端把 invite 记录改写为「对方拒绝接听」。
  Future<void> reject() async {
    final s = state.value;
    if (s == null) return;
    _ringTimer?.cancel();
    await _sendSignal(
      convId: s.convId,
      action: CallAction.reject,
      callType: s.callType,
      silent: s.isGroup,
    );
    _reset();
  }

  // ============================ 通用 ============================

  /// 挂断：发 hangup（带通话时长），回到 idle
  /// 群通话：发 leave（带时长，可留通话记录），通话对其他成员继续
  Future<void> hangup() async {
    final s = state.value;
    if (s == null) return;
    _ringTimer?.cancel();
    // 先取时长再清 _connectedAt：_elapsedSec() 依赖它，先置 null 会恒得 00:00
    final dur = _elapsedSec();
    _connectedAt = null;
    final action = s.isGroup
        ? CallAction.leave
        : (s.phase == CallPhase.connected
            ? CallAction.hangup
            : CallAction.cancel);
    // 单聊 hangup/cancel **不 silent**：服务端把 invite 记录原地改写为最终态
    // （接通挂断 = 带时长的「语音通话 00:05」；未接取消 = 「通话未接通」），
    // 不再新增第二条通话记录。群 leave 是纯信令，只转发不落库。
    await _sendSignal(
      convId: s.convId,
      action: action,
      callType: s.callType,
      duration: dur,
      extras: s.isGroup ? {'group': true, 'userId': _myId} : null,
      silent: s.isGroup,
    );
    _reset();
  }

  int _elapsedSec() {
    final t = _connectedAt;
    if (t == null) return 0;
    return DateTime.now().difference(t).inSeconds;
  }

  void _reset() {
    _ringTimer?.cancel();
    _ringTimer = null;
    _connectedAt = null;
    state.value = null;
    participants.value = const [];
    mediaSignalHandler = null;
    _joinTs = 0;
    _callSeconds = 0;
    _inviteMsgId = '';
  }

  void _emit(CallEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  // ============================ 媒体就绪 ============================

  /// 通话页媒体引擎 join 成功后调用：
  /// - 被叫/群成员广播 join（房间内已有成员向其发 WebRTC offer；TRTC 用于成员列表）
  /// - 单聊主叫不需要广播（主叫收到被叫 join 后主动 offer）
  Future<void> notifyMediaJoined() async {
    final s = state.value;
    if (s == null) return;
    _joinTs = DateTime.now().millisecondsSinceEpoch;
    if (s.isCaller && !s.isGroup) return;
    final me = UserCache.myProfileData;
    await _sendSignal(
      convId: s.convId,
      action: CallAction.join,
      callType: s.callType,
      silent: true,
      extras: {
        'group': true,
        'userId': _myId,
        'name': me?['nickname']?.toString() ?? '',
        'avatar': me?['avatar']?.toString() ?? '',
        'ts': _joinTs,
      },
    );
  }

  /// 转发 WebRTC 媒体信令（sdp/ice）到对端（type=7 透传，服务端零逻辑）
  Future<void> sendMediaSignal(Map<String, dynamic> sig) async {
    final s = state.value;
    if (s == null) return;
    await _sendSignal(
      convId: s.convId,
      action: sig['action']?.toString() ?? '',
      callType: s.callType,
      silent: true,
      extras: {...sig, 'group': true},
    );
  }

  // ============================ 参与人 ============================

  void _setParticipants(List<CallParticipant> list) {
    participants.value = List.unmodifiable(list);
  }

  void _addParticipant(CallParticipant p) {
    final list = [...participants.value];
    if (list.any((e) => e.id == p.id)) return;
    list.add(p);
    _setParticipants(list);
  }

  void _removeParticipant(String id) {
    _setParticipants(participants.value.where((e) => e.id != id).toList());
  }

  // ============================ 收信令 ============================

  Future<void> _onWsMessage(Map<String, dynamic> m) async {
    // 只处理通话信令 type=7
    final type = (m['type'] as num?)?.toInt();
    if (type != 7) return;

    // 自己 ID 未知时补拉一次，否则会把自己的信令回显当成对方来电
    await _ensureMyId();
    final senderId = m['senderId']?.toString() ?? '';
    // 自己的回显忽略
    if (senderId.isNotEmpty && senderId == _myId) return;

    final convId = m['conversationId']?.toString() ?? '';
    if (convId.isEmpty) return;

    Map<String, dynamic> sig = {};
    try {
      final raw = m['content'];
      sig = raw is String
          ? (jsonDecode(raw) as Map<String, dynamic>)
          : (raw as Map<String, dynamic>);
    } catch (_) {
      return;
    }
    sig['from'] = senderId; // 媒体信令需要知道来源成员
    final action = sig['action']?.toString() ?? CallAction.invite;
    final callType = sig['action'] == CallAction.invite
        ? (sig['callType']?.toString() ?? 'voice')
        : (state.value?.callType ?? sig['callType']?.toString() ?? 'voice');
    final isGroupSig = sig['group'] == true;

    switch (action) {
      case CallAction.invite:
        // 自己 invite 的 WS 回显/重复帧：msgId 与自己刚发出的 invite 相同。
        // 绝不能当成新来电走占线拒接（会把这通电话改写成「对方拒绝接听」，
        // 实测「一拨就提示被拒绝、对方还在响铃」就是它）。
        final mid = m['msgId']?.toString() ?? '';
        if (mid.isNotEmpty && mid == _inviteMsgId) return;
        if (mid.isNotEmpty) _inviteMsgId = mid;
        _onInvite(convId, sig, callType, isGroupSig);
        break;

      case CallAction.accept:
        final s = state.value;
        if (s == null || s.convId != convId) return;
        if (s.isGroup) {
          // 群通话：成员接听只停主叫的等待态，不互相影响
          if (s.isCaller && s.phase != CallPhase.connected) {
            _ringTimer?.cancel();
            _connectedAt = DateTime.now();
            state.value = s.copyWith(phase: CallPhase.connected);
            _emit(CallEvent(CallAction.accept, convId));
          }
          return;
        }
        _ringTimer?.cancel();
        _connectedAt = DateTime.now();
        _callSeconds = 0;
        state.value = s.copyWith(phase: CallPhase.connected);
        _emit(CallEvent(CallAction.accept, convId));
        break;

      case CallAction.reject:
        final s = state.value;
        if (s == null || s.convId != convId) return;
        if (s.isGroup) return; // 群通话：有人拒绝不影响其他人
        _reset();
        _emit(CallEvent(action, convId));
        break;

      case CallAction.hangup:
      case CallAction.cancel:
        final s = state.value;
        if (s == null || s.convId != convId) return;
        _reset();
        _emit(CallEvent(action, convId,
            duration: (sig['duration'] as num?)?.toInt() ?? 0));
        break;

      case CallAction.leave:
      // 群通话成员退出（单聊不会出现）
      case 'join':
        _onMemberSignal(convId, sig, action);
        break;

      case 'sdp':
      case 'ice':
        final s = state.value;
        if (s == null || s.convId != convId) return;
        // 群通话：先于我们入房的成员不会广播 join 给我们，只会直接发来 offer ——
        // 收到陌生来源的 sdp/ice 时补一个占位成员，宫格才能显示其画面
        if (s.isGroup) {
          final from = sig['from']?.toString() ?? '';
          if (from.isNotEmpty &&
              from != _myId &&
              !participants.value.any((e) => e.id == from)) {
            _addParticipant(CallParticipant(id: from));
          }
        }
        _dispatchMediaSignal(sig);
        break;
    }
  }

  void _onInvite(String convId, Map<String, dynamic> sig, String callType,
      bool isGroupSig) {
    // 已在通话中 → 直接回 busy（用 reject 语义）。
    // 非 silent：让服务端把这条新 invite 记录改写为「对方拒绝接听」。
    if (state.value != null) {
      final cur = state.value!;
      // 同一会话且我是主叫 → 这是自己 invite 的回显/重放（HTTP 响应未返回时
      // 回显先到，mid 比对兜不住），直接忽略，不发占线拒接。
      if (cur.isCaller && cur.convId == convId) return;
      _sendSignal(
          convId: convId,
          action: CallAction.reject,
          callType: callType,
          silent: false);
      return;
    }
    state.value = CallState(
      convId: convId,
      callType: callType,
      peerName: isGroupSig
          ? (sig['groupName']?.toString() ??
              sig['callerName']?.toString() ??
              '')
          : (sig['callerName']?.toString() ?? ''),
      peerAvatar: isGroupSig
          ? (sig['groupAvatar']?.toString() ?? '')
          : (sig['callerAvatar']?.toString() ?? ''),
      phase: CallPhase.incoming,
      isCaller: false,
      isGroup: isGroupSig,
      engine: sig['engine']?.toString() ?? 'trtc',
      callerName: sig['callerName']?.toString() ?? '',
    );
    if (isGroupSig) {
      _setParticipants([
        CallParticipant(
          id: sig['from']?.toString() ?? '',
          name: sig['callerName']?.toString() ?? '',
          avatar: sig['callerAvatar']?.toString() ?? '',
        )
      ]);
    }
  }

  /// 群通话的 join / leave：更新参与人 + 转发媒体引擎（WebRTC mesh 建连/拆除）
  /// 单聊也转发 join：主叫收到被叫 join 后才向其发 offer（TRTC 收到无影响）
  void _onMemberSignal(String convId, Map<String, dynamic> sig, String action) {
    final s = state.value;
    if (s == null || s.convId != convId) return;
    if (action == 'join') {
      final uid = sig['userId']?.toString() ?? sig['from']?.toString() ?? '';
      if (uid.isEmpty || uid == _myId) return;
      if (s.isGroup) {
        _addParticipant(CallParticipant(
          id: uid,
          name: sig['name']?.toString() ?? '',
          avatar: sig['avatar']?.toString() ?? '',
        ));
      }
      _dispatchMediaSignal(sig);
    } else {
      if (!s.isGroup) return; // leave 只在群通话出现
      final uid = sig['userId']?.toString() ?? sig['from']?.toString() ?? '';
      if (uid.isEmpty) return;
      _removeParticipant(uid);
      _dispatchMediaSignal({'action': 'leave', 'userId': uid, 'from': uid});
      // 只剩自己（或没人）→ 通话结束
      final others = participants.value.where((e) => e.id != _myId).length;
      if (others == 0) {
        _reset();
        _emit(CallEvent(CallAction.hangup, convId));
      }
    }
  }

  // ============================ 发送信令 ============================

  /// 发送信令。返回服务端落库消息的 msgId（invite 落库时非空；纯信令为空），
  /// 主叫用它记住 invite 记录 ID，供结束信令回指。
  Future<String?> _sendSignal({
    required String convId,
    required String action,
    required String callType,
    int duration = 0,
    bool silent = false,
    String? callerName, // invite 信令主叫昵称覆盖（startCall 时 state 还没值）
    String? callerAvatar, // invite 信令主叫头像覆盖
    Map<String, dynamic>? extras, // 群通话/WebRTC 扩展字段
  }) async {
    try {
      final token = await ApiClient.instance.readToken();
      final r = await ApiClient.instance.dio.post(
        '/api/v1/message/send',
        data: {
          'conversationId': convId,
          'type': 7,
          'content': jsonEncode({
            'action': action,
            'callType': callType,
            'roomId': convId,
            'duration': duration,
            'callerName': callerName ?? state.value?.peerName ?? '',
            'callerAvatar': callerAvatar ?? state.value?.peerAvatar ?? '',
            'ts': DateTime.now().millisecondsSinceEpoch,
            // 结束信令回指 invite 记录（服务端据此原地改写，不新增第二条记录）
            if (_inviteMsgId.isNotEmpty) 'inviteMsgId': _inviteMsgId,
            if (extras != null) ...extras,
          }),
          // silent=true 的纯信令（accept/join/sdp/ice/群信令）：
          // 服务端只实时转发，不落库不写未读 —— 否则一次通话会把每条信令
          // 都存成「通话记录」气泡（线上实测：接通一次出现 5 条记录）。
          'silent': silent,
          'clientMsgId':
              'call-$action-${DateTime.now().millisecondsSinceEpoch}',
        },
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final d = r.data;
      if (d is Map) {
        final data = d['data'];
        if (data is Map) {
          final mid = data['msgId']?.toString() ?? '';
          return mid.isEmpty ? null : mid;
        }
      }
    } catch (_) {
      // 信令发送失败不阻断 UI
    }
    return null;
  }
}
