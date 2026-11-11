import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

import 'settings_service.dart';

/// 铃声 / 提示音服务（音频在 assets/sounds/，pubspec 已声明该目录）
/// 映射：
/// - msg_in.mp3   = 来新信息·默认（收到新消息 / 被添加好友）
/// - msn.mp3      = 来新信息·MSN信息（用户可选音效，2026-09-15）
/// - dingding.mp3 = 来新信息·叮叮
/// - dong.mp3     = 来新信息·咚
/// - bibi.mp3     = 来新信息·哔哔
/// - shuipao.mp3  = 来新信息·水泡
/// - msg_out.mp3  = 发送消息（消息发送成功）
/// - ring.mp3     = 语音通话铃声（来电循环，语音/视频共用）
/// - ringback.mp3 = 主叫回铃音（拨出后等待对方接听，嘟嘟声循环）
/// - hangup.mp3   = 通话挂断
/// - scan.mp3     = 扫码成功
class SoundService {
  SoundService._();
  static final SoundService instance = SoundService._();

  /// 来消息可选音效目录（key = AppSettings.notifyTone 存储值；
  /// nameKey 是展示名 l10n 词条）。默认永远排第一。
  static const List<({String key, String asset, String nameKey})> notifyTones =
      [
    (key: 'msg_in', asset: 'sounds/msg_in.mp3', nameKey: 'nsetToneDefault'),
    (key: 'msn', asset: 'sounds/msn.mp3', nameKey: 'nsetToneMsn'),
    (key: 'dingding', asset: 'sounds/dingding.mp3', nameKey: 'nsetToneDing'),
    (key: 'dong', asset: 'sounds/dong.mp3', nameKey: 'nsetToneDong'),
    (key: 'bibi', asset: 'sounds/bibi.mp3', nameKey: 'nsetToneBibi'),
    (key: 'shuipao', asset: 'sounds/shuipao.mp3', nameKey: 'nsetToneShuipao'),
  ];

  /// key → 资产路径（未知 key / 脏数据回退默认铃声）
  static String toneAsset(String key) {
    for (final t in notifyTones) {
      if (t.key == key) return t.asset;
    }
    return 'sounds/msg_in.mp3';
  }

  final AudioPlayer _msg = AudioPlayer();
  final AudioPlayer _out = AudioPlayer();
  final AudioPlayer _friend = AudioPlayer();
  final AudioPlayer _scan = AudioPlayer();
  final AudioPlayer _preview = AudioPlayer(); // 设置页试听（独立，不影响正式播放）
  AudioPlayer? _hangup; // 挂断音（一次性，播完即弃）
  AudioPlayer? _connected; // 接通音（一次性）
  AudioPlayer? _ring; // 来电铃声（循环）
  AudioPlayer? _ringback; // 主叫回铃音（循环）
  Timer? _ringVibrateTimer; // 来电循环震动（配合铃声；stopRing 时取消）

  /// 新消息提示音（App 前台 · 应用内提示 = 「应用内声音」开关的消费点）：
  /// ① 系统通知总开关关闭 → 静默；② 「应用内声音」关闭 → 不播音；
  /// ③ 按用户选择的音效播放；④ 「振动」开启时同步震一下。
  Future<void> playNewMessage() async {
    final s = AppSettings.instance;
    if (!s.notifications) return;
    if (!s.notifyPref('inAppSound', true)) return;
    if (s.notifyPref('vibrate', true)) {
      try {
        HapticFeedback.mediumImpact();
      } catch (_) {}
    }
    try {
      await _msg.stop();
      await _msg.play(AssetSource(toneAsset(s.notifyTone)));
    } catch (_) {}
  }

  /// 消息发送成功提示音
  Future<void> playMessageSent() async {
    try {
      await _out.stop();
      await _out.play(AssetSource('sounds/msg_out.mp3'));
    } catch (_) {}
  }

  /// 被添加好友提示音（沿用用户选中的来消息音效，受「应用内声音」开关）
  Future<void> playFriendAdded() async {
    final s = AppSettings.instance;
    if (!s.notifications) return;
    if (!s.notifyPref('inAppSound', true)) return;
    try {
      await _friend.stop();
      await _friend.play(AssetSource(toneAsset(s.notifyTone)));
    } catch (_) {}
  }

  /// 设置页试听（播指定 key 的音效，正式提示音通道不受影响）
  Future<void> previewTone(String key) async {
    try {
      await _preview.stop();
      await _preview.play(AssetSource(toneAsset(key)));
    } catch (_) {}
  }

  /// 扫码成功提示音
  Future<void> playScan() async {
    try {
      await _scan.stop();
      await _scan.play(AssetSource('sounds/scan.mp3'));
    } catch (_) {}
  }

  /// 通话接通提示音（进房成功时播一次）
  Future<void> playCallConnected() async {
    try {
      _connected?.dispose();
    } catch (_) {}
    _connected = AudioPlayer();
    try {
      await _connected!.play(AssetSource('sounds/call_connected.mp3'));
    } catch (_) {}
  }

  /// 通话挂断音（一次性；与来电铃声分player，stopRing 不会误伤）
  Future<void> playHangup() async {
    try {
      _hangup?.dispose();
    } catch (_) {}
    _hangup = AudioPlayer();
    try {
      await _hangup!.play(AssetSource('sounds/hangup.mp3'));
    } catch (_) {}
  }

  /// 来电铃声（循环；语音/视频共用 ring.mp3，video 参数保留兼容旧调用）。
  /// 「振动」开关开启时随铃声循环震动（700ms 一轮，来电页在前台所以
  /// HapticFeedback 有效；接听/拒绝/挂断走 stopRing 一并取消）。
  Future<void> startRing({required bool video}) async {
    try {
      await stopRing();
      _ring = AudioPlayer()..setReleaseMode(ReleaseMode.loop);
      await _ring!.play(AssetSource('sounds/ring.mp3'));
    } catch (_) {}
    if (AppSettings.instance.notifyPref('vibrate', true)) {
      try {
        HapticFeedback.heavyImpact(); // 立刻震一下，不等第一轮定时
      } catch (_) {}
      _ringVibrateTimer = Timer.periodic(const Duration(milliseconds: 700),
          (_) {
        try {
          HapticFeedback.heavyImpact();
        } catch (_) {}
      });
    }
  }

  /// 停止来电铃声（接听 / 拒绝 / 挂断时调用；同时取消来电震动循环）
  Future<void> stopRing() async {
    _ringVibrateTimer?.cancel();
    _ringVibrateTimer = null;
    try {
      await _ring?.stop();
      await _ring?.dispose();
      _ring = null;
    } catch (_) {
      _ring = null;
    }
  }

  /// 主叫回铃音（拨出后等待对方接听，嘟嘟声循环；独立 player 与来电铃声互不影响）
  Future<void> startRingback() async {
    try {
      await stopRingback();
      _ringback = AudioPlayer()..setReleaseMode(ReleaseMode.loop);
      await _ringback!.play(AssetSource('sounds/ringback.mp3'));
    } catch (_) {}
  }

  /// 停止主叫回铃音（接通 / 结束 / 挂断 / 离开通话页时调用）
  Future<void> stopRingback() async {
    try {
      await _ringback?.stop();
      await _ringback?.dispose();
      _ringback = null;
    } catch (_) {
      _ringback = null;
    }
  }
}
