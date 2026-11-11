import 'package:flutter/material.dart';

import '../app_navigator.dart';
import '../l10n/app_locale.dart';
import '../services/call_service.dart';
import '../services/sound_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import 'group_call_page.dart';
import 'video_call_page.dart';
import 'voice_call_page.dart';

/// 全局来电覆盖层：挂在 MaterialApp.builder 上，
/// 收到 invite 信令时在任意页面之上弹出全屏来电界面。
///
/// 通话最小化后**不再**显示应用内浮条：系统级悬浮小窗已经在屏幕上，
/// 再叠一个应用内浮条只会重复（B-14）。小窗的计时与时长推送已下沉到
/// CallService，移除这里不影响小窗跑秒。
class CallOverlay extends StatelessWidget {
  final Widget? child;
  const CallOverlay({super.key, this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CallState?>(
      valueListenable: CallService.instance.state,
      builder: (context, s, _) {
        final showIncoming = s != null && s.phase == CallPhase.incoming;
        return Stack(
          children: [
            if (child != null) child!,
            if (showIncoming)
              IncomingCallPage(
                key: ValueKey('incoming-${s.convId}'),
                state: s,
              ),
          ],
        );
      },
    );
  }
}

/// 来电界面：大头像 + 对方昵称 + 通话类型 + 拒绝/接听
class IncomingCallPage extends StatefulWidget {
  final CallState state;
  const IncomingCallPage({super.key, required this.state});

  @override
  State<IncomingCallPage> createState() => _IncomingCallPageState();
}

class _IncomingCallPageState extends State<IncomingCallPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  bool _handling = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    // 需求：来电播放铃声（循环，直到接听/拒绝）
    SoundService.instance.startRing(video: widget.state.callType == 'video');
  }

  @override
  void dispose() {
    _pulse.dispose();
    SoundService.instance.stopRing();
    super.dispose();
  }

  /// 接听：发 accept 信令 → 打开通话页（此时已进入 connected，页面会直接进房）
  /// 群通话 → GroupCallPage；单聊 → Video/VoiceCallPage
  Future<void> _accept() async {
    if (_handling) return;
    setState(() => _handling = true);
    await SoundService.instance.stopRing();
    final callType = widget.state.callType;
    final isGroup = widget.state.isGroup;
    await CallService.instance.accept();
    if (isGroup) {
      appNavigatorKey.currentState?.push(MaterialPageRoute(
        builder: (_) => const GroupCallPage(),
      ));
      return;
    }
    final convId = widget.state.convId;
    final peerName = widget.state.peerName;
    appNavigatorKey.currentState?.push(MaterialPageRoute(
      builder: (_) => callType == 'video'
          ? VideoCallPage(
              peerName: peerName,
              peerAvatar: widget.state.peerAvatar,
              convId: convId)
          : VoiceCallPage(
              peerName: peerName,
              peerAvatar: widget.state.peerAvatar,
              convId: convId),
    ));
  }

  Future<void> _reject() async {
    if (_handling) return;
    setState(() => _handling = true);
    await SoundService.instance.stopRing();
    await CallService.instance.reject();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final s = widget.state;
    final isVideo = s.callType == 'video';
    final name = s.peerName.isEmpty ? t('incomingCallUnknown') : s.peerName;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        color: Colors.black,
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 72),
              Text(isVideo ? t('incomingCallVideo') : t('incomingCallVoice'),
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 15)),
              const SizedBox(height: 40),
              ScaleTransition(
                scale: Tween<double>(begin: 1.0, end: 1.06).animate(
                  CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
                ),
                child: _avatar(name, s.peerAvatar),
              ),
              const SizedBox(height: 28),
              Text(name,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                  s.isGroup
                      ? t('incomingCallGroupInvite', {
                          'name': s.callerName.isEmpty
                              ? t('incomingCallUnknown')
                              : s.callerName
                        })
                      : (isVideo
                          ? t('incomingCallInviteVideo')
                          : t('incomingCallInviteVoice')),
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.65),
                      fontSize: 14)),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.fromLTRB(40, 0, 40, 56),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _actionBtn(
                      icon: Icons.call_end,
                      label: t('incomingCallReject'),
                      color: AppTheme.danger,
                      onTap: _reject,
                    ),
                    _actionBtn(
                      icon: isVideo ? Icons.videocam : Icons.call,
                      label: t('incomingCallAccept'),
                      color: AppTheme.success,
                      onTap: _accept,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _avatar(String name, String url) {
    return Container(
      width: 128,
      height: 128,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppTheme.primary,
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withValues(alpha: 0.45),
            blurRadius: 32,
            spreadRadius: 6,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: AppAvatar(
        url: url,
        name: name,
        size: 128,
        background: AppTheme.primary,
      ),
    );
  }

  Widget _actionBtn({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkResponse(
          onTap: onTap,
          radius: 44,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
        ),
        const SizedBox(height: 10),
        Text(label,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85), fontSize: 13)),
      ],
    );
  }
}
