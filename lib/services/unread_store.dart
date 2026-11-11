import 'package:flutter/foundation.dart';

import 'app_badge.dart';

/// 全局未读消息数（底部"消息"tab 红点数据源）。
/// ChatListPage 每次拉会话列表后把 ConvItem.unread 求和写入，
/// HomeShell 监听显示红点。单例 ValueNotifier，改动即通知。
class UnreadStore {
  UnreadStore._();
  static final UnreadStore instance = UnreadStore._();

  final ValueNotifier<int> total = ValueNotifier<int>(0);

  /// 会话列表刷新后调用：传入各会话未读数之和。
  /// 顺带把未读数同步到桌面图标角标（各厂商静默失败，见 AppBadge）。
  void update(int sum) {
    if (total.value != sum) {
      total.value = sum;
      AppBadge.sync(sum);
    }
  }
}
