import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// 功能开关（后台「系统配置 → 功能开关」配置，经 /auth/config 下发）。
/// 默认全开：后台未配置时不应影响现有功能。
class FeatureFlags {
  FeatureFlags._();
  static final FeatureFlags instance = FeatureFlags._();

  /// 是否开启零钱（关闭 → 聊天窗口不显示红包/转账入口、用户中心不显示我的钱包）
  final ValueNotifier<bool> walletOn = ValueNotifier<bool>(true);

  /// 是否开启邀请码（2026-09-22 需求3 合并：改读「邀请码注册」inviteCodeOn，
  /// 后台原 invite_feature_enabled 开关废弃）。
  /// 关闭 → 注册页无邀请码输入框、游客直接进入、用户中心不显示我的邀请码
  final ValueNotifier<bool> inviteOn = ValueNotifier<bool>(true);

  /// 是否开启小助手（2026-09-22 需求2，sys_config assistant_enabled 默认 true）
  /// 关闭 → 通讯录不显示小助手入口（注册不自动添加由服务端短路）
  final ValueNotifier<bool> assistantOn = ValueNotifier<bool>(true);

  /// 是否开启频道（2026-09-22 需求2，sys_config channel_enabled 默认 true）
  /// 关闭 → 消息页「+」面板隐藏「新建频道」入口（注册自动关注由服务端短路）
  final ValueNotifier<bool> channelOn = ValueNotifier<bool>(true);

  bool _loaded = false;

  /// 拉取一次配置（缓存生效；force=true 强制刷新）。
  /// 失败静默：保持上次/默认值，不打扰用户。
  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    try {
      final r = await ApiClient.instance.get('/api/v1/auth/config');
      final j = r.data['data'];
      if (j is Map) {
        walletOn.value = j['walletOn'] != false && j['walletOn'] != 'false';
        // 需求3 合并 + 三态（2026-11-04）：邀请码展示开关 = inviteCodeMode != 'off'
        // （优先读三态 inviteCodeMode，未配置回退旧键 inviteCodeOn）
        final mode = (j['inviteCodeMode'] ?? '').toString();
        inviteOn.value = mode == 'off'
            ? false
            : (mode == 'optional' || mode == 'required'
                ? true
                : (j['inviteCodeOn'] != false && j['inviteCodeOn'] != 'false'));
        assistantOn.value =
            j['assistantOn'] != false && j['assistantOn'] != 'false';
        channelOn.value =
            j['channelOn'] != false && j['channelOn'] != 'false';
        _loaded = true;
      }
    } catch (_) {
      // 网络异常时保持默认值
    }
  }
}
