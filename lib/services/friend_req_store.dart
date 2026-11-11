import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// 全局好友申请数（底部"通讯录"tab 红点数据源）。
///
/// 与 UnreadStore 同款单例 ValueNotifier：通讯录/新朋友页处理完申请后、
/// WS 收到 friend 事件、或 App 切回前台时调用 [refresh] 重新拉取待处理数，
/// HomeShell 监听并刷新红点。
///
/// 关键修复：审批申请的是"被申请人"自己，后端只给申请人推 friend.accepted 事件，
/// 被申请人设备收不到 WS 事件，因此必须在本端点完申请的动作里主动 [refresh]，
/// 否则红点要等杀进程重进才消失。
class FriendReqStore {
  FriendReqStore._();
  static final FriendReqStore instance = FriendReqStore._();

  final ValueNotifier<int> count = ValueNotifier<int>(0);

  /// 重新拉取待处理申请数（status==0 视为未处理）。失败静默保留旧值。
  Future<void> refresh() async {
    try {
      final api = ApiClient.instance;
      final r = await api.get('/api/v1/friend/request/incoming');
      final list = (r.data['data'] as List<dynamic>? ?? [])
          .where((e) => (e as Map<String, dynamic>)['status'] == 0)
          .length;
      if (count.value != list) count.value = list;
    } catch (_) {}
  }
}
