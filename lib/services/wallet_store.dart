import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'local_store.dart';
import '../l10n/app_locale.dart';

/// 零钱 / 钱包（以后端 `user.balance` 为唯一数据源）
///
/// 职责边界（B-19 后重新划分）：
/// - **发红包 / 转账的扣款由后端在发消息时原子完成**（service.SendMoneyCharge），
///   前端**不再**调用 `debit()` 记账，否则会扣两次。
/// - 领取入账同样在后端完成（红包走 /wallet/redpacket/:id/claim；转账走 record tr_in）。
/// - 本类只负责：拉取余额 / 账单缓存，并把余额变化广播出去。
class WalletStore {
  WalletStore._();
  static final WalletStore instance = WalletStore._();

  final _api = ApiClient.instance;

  double _balance = 0;
  double _frozen = 0;
  List<Map<String, dynamic>> _records = [];
  bool _loadedOnce = false;

  /// 余额变化通知。页面用 ValueListenableBuilder 监听它，
  /// 这样后台改了余额、切回页面时不用手动 setState 也能更新（B-20）。
  final ValueNotifier<double> balanceNotifier = ValueNotifier(0);

  /// 冻结金额（发出的红包 / 转账还没被领走的部分，24h 未领会自动退回）
  final ValueNotifier<double> frozenNotifier = ValueNotifier(0);

  /// 上一次资金操作失败的**后端原因**（成功时清空），用于给用户看真实提示
  String _lastError = '';
  String get lastError => _lastError;

  double get balance => _balance;
  double get frozen => _frozen;
  List<Map<String, dynamic>> get records => List.unmodifiable(_records);
  bool get loaded => _loadedOnce;

  /// 拉取最新余额与流水（进钱包页 / 切到"我的" / 记账后调用）
  Future<void> refresh() async {
    try {
      final r = await _api.get('/api/v1/wallet/me');
      final data = ((r.data['data'] as Map<String, dynamic>?) ?? {});
      _setBalance((data['balance'] as num?)?.toDouble() ?? 0);
      final f = (data['frozen'] as num?)?.toDouble() ?? 0;
      if (frozenNotifier.value != f) frozenNotifier.value = f;
      _frozen = f;
      _records = ((data['records'] as List<dynamic>?) ?? [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
      _loadedOnce = true;
      // 落盘：下次冷启动首屏直出，不再"先 ¥0 再跳成真实值"。
      // 只用于展示，见 LocalStore.loadWallet 的安全说明。
      unawaited(LocalStore.saveWallet(balance: _balance, frozen: _frozen));
    } catch (_) {}
  }

  /// 冷启动：用本地快照先撑住首屏，随后 refresh() 会用服务端真实值覆盖。
  ///
  /// **只影响展示**。任何涉及金额的计算/校验都必须先 refresh() 拿服务端值——
  /// 这份快照可能过期（用户可能在 PC 端改过余额、或离线很久）。
  /// 提现 / 转账 / 红包页在打开时都会先 refresh()，见各自 _load()。
  Future<void> hydrate() async {
    try {
      final snap = await LocalStore.loadWallet();
      if (snap == null) return;
      _setBalance((snap['balance'] as num?)?.toDouble() ?? 0);
      _frozen = (snap['frozen'] as num?)?.toDouble() ?? 0;
      if (frozenNotifier.value != _frozen) frozenNotifier.value = _frozen;
    } catch (_) {}
  }

  void _setBalance(double v) {
    _balance = v;
    if (balanceNotifier.value != v) balanceNotifier.value = v;
  }

  /// 退出登录 / 被踢下线：清空内存里的余额与流水。
  ///
  /// 磁盘快照由 `LocalStore.clearUserData()` 清，这里清内存——
  /// 否则换账号登录后、refresh() 返回之前，会短暂显示上一个人的余额（金额类绝不能串号）。
  void reset() {
    _balance = 0;
    _frozen = 0;
    _records = [];
    _loadedOnce = false;
    _lastError = '';
    if (balanceNotifier.value != 0) balanceNotifier.value = 0;
    if (frozenNotifier.value != 0) frozenNotifier.value = 0;
  }

  /// 转账收款（B-21）。
  ///
  /// **只传消息 ID，不传金额**：金额由服务端从转账消息内容里读，
  /// 服务端同时校验「消息是转账 / 领取人是会话成员 / 不是发送者本人 / 未被领取过」。
  /// 这样客户端改金额、清本地缓存重复领取都无效。
  ///
  /// 成功返回 `{'amount': x, 'balance': y, 'already': bool}`，失败返回 null（原因见 [lastError]）。
  Future<Map<String, dynamic>?> acceptTransfer(String msgId) async {
    if (msgId.isEmpty) {
      _lastError = AppLocalizations.instance.t('svcBadParams');
      return null;
    }
    try {
      final r = await _api.post('/api/v1/wallet/transfer/$msgId/accept');
      final body = r.data as Map<String, dynamic>? ?? {};
      final code = (body['code'] as num?)?.toInt() ?? -1;
      if (code != 0) {
        _lastError =
            (body['message'] ?? AppLocalizations.instance.t('svcAcceptFailed'))
                .toString();
        return null;
      }
      final data = (body['data'] as Map<String, dynamic>?) ?? {};
      final b = (data['balance'] as num?)?.toDouble();
      if (b != null) _setBalance(b);
      _loadedOnce = true;
      _lastError = '';
      unawaited(refresh());
      return data;
    } catch (_) {
      _lastError = AppLocalizations.instance.t('svcNetRetry');
      return null;
    }
  }

  String fmt(double v) {
    final s = v.toStringAsFixed(2);
    return s.endsWith('.00') ? v.toStringAsFixed(0) : s;
  }
}
