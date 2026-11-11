import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../theme/app_theme.dart';

/// 充值/提现记录独立页（从充值页、提现页底部迁移而来，AppBar 右上角「记录」进入）。
/// 接口：GET /api/v1/wallet/recharge/orders | GET /api/v1/wallet/withdraw/orders
/// 分页加载（page/size=20），下拉刷新 + 滚动到底自动翻页。

/// 充值记录
class RechargeRecordsPage extends StatelessWidget {
  const RechargeRecordsPage({super.key});

  @override
  Widget build(BuildContext context) => _RecordsScaffold(
        title: AppLocalizations.of(context).t('rcOrders'),
        ordersUrl: '/api/v1/wallet/recharge/orders',
        rowBuilder: (o) => _RechargeOrderRow(o: o),
      );
}

/// 提现记录
class WithdrawRecordsPage extends StatelessWidget {
  const WithdrawRecordsPage({super.key});

  @override
  Widget build(BuildContext context) => _RecordsScaffold(
        title: AppLocalizations.of(context).t('wdOrders'),
        ordersUrl: '/api/v1/wallet/withdraw/orders',
        rowBuilder: (o) => _WithdrawOrderRow(o: o),
      );
}

class _RecordsScaffold extends StatefulWidget {
  const _RecordsScaffold({
    required this.title,
    required this.ordersUrl,
    required this.rowBuilder,
  });

  final String title;
  final String ordersUrl;
  final Widget Function(Map<String, dynamic> o) rowBuilder;

  @override
  State<_RecordsScaffold> createState() => _RecordsScaffoldState();
}

class _RecordsScaffoldState extends State<_RecordsScaffold> {
  final _api = ApiClient.instance;
  final _scroll = ScrollController();

  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  List<Map<String, dynamic>> _orders = [];

  @override
  void initState() {
    super.initState();
    _load();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await _fetch(1);
    if (!mounted) return;
    setState(() {
      _orders = list;
      _page = 1;
      _hasMore = list.length >= 20;
      _loading = false;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    setState(() => _loadingMore = true);
    final list = await _fetch(_page + 1);
    if (!mounted) return;
    setState(() {
      _orders.addAll(list);
      _page += 1;
      _hasMore = list.length >= 20;
      _loadingMore = false;
    });
  }

  Future<List<Map<String, dynamic>>> _fetch(int page) async {
    try {
      final r = await _api.get(widget.ordersUrl, query: {
        'page': page,
        'size': 20,
      });
      if ((r.data['code'] as num?)?.toInt() == 0) {
        final d = r.data['data'] as Map<String, dynamic>? ?? {};
        return (d['list'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .toList();
      }
    } catch (_) {}
    return [];
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    return Scaffold(
      // 深色模式回退主题纯黑背景，浅色保持微信灰
      backgroundColor: isDark ? null : const Color(0xFFEDEDED),
      appBar: AppBar(
          title: Text(widget.title,
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _orders.isEmpty
                  ? ListView(
                      children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height * 0.6,
                          child: Center(
                            child: Text(
                                widget.ordersUrl.contains('recharge')
                                    ? t('rcNoOrders')
                                    : t('wdNoOrders'),
                                style: TextStyle(
                                    fontSize: 13,
                                    color: scheme.onSurfaceVariant)),
                          ),
                        ),
                      ],
                    )
                  : ListView.separated(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                      itemCount: _orders.length + (_hasMore ? 1 : 0),
                      separatorBuilder: (_, __) => Divider(
                          height: 1, indent: 12, color: scheme.outlineVariant),
                      itemBuilder: (ctx, i) {
                        if (i >= _orders.length) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 16),
                            child: Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          );
                        }
                        return Container(
                          color: scheme.surface,
                          child: widget.rowBuilder(_orders[i]),
                        );
                      },
                    ),
            ),
    );
  }
}

// ============ 充值单行 ============

class _RechargeOrderRow extends StatelessWidget {
  const _RechargeOrderRow({required this.o});

  final Map<String, dynamic> o;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    final amount = (o['amount'] as num?)?.toDouble() ?? 0;
    final status = (o['status'] as num?)?.toInt() ?? 1;
    final method = (o['payMethod'] as num?)?.toInt() ?? 1;
    final methodTxt = [
      t('rcPayMethodWechat'),
      t('rcPayMethodAlipay'),
      t('rcPayMethodBank')
    ][method - 1];
    final (statusTxt, statusColor) = switch (status) {
      2 => (t('rcStatusApproved'), AppTheme.green),
      3 => (t('rcStatusRejected'), AppTheme.danger),
      _ => (t('rcStatusPending'), const Color(0xFFF5A623)),
    };
    final reject = (o['rejectReason'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('¥${amount.toStringAsFixed(2)}  ·  $methodTxt',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface)),
                const SizedBox(height: 3),
                Text((o['createdAt'] ?? '').toString(),
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
                if (status == 3 && reject.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(t('rcRejectReason', {'reason': reject}),
                      style: TextStyle(fontSize: 12, color: AppTheme.danger)),
                ],
              ],
            ),
          ),
          _statusChip(statusTxt, statusColor),
        ],
      ),
    );
  }
}

// ============ 提现单行 ============

class _WithdrawOrderRow extends StatelessWidget {
  const _WithdrawOrderRow({required this.o});

  final Map<String, dynamic> o;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    final amount = (o['amount'] as num?)?.toDouble() ?? 0;
    final actual = (o['actualAmount'] as num?)?.toDouble() ?? 0;
    final status = (o['status'] as num?)?.toInt() ?? 1;
    final type = (o['withdrawType'] as num?)?.toInt() ?? 1;
    final typeTxt =
        [t('wdMethodWechat'), t('wdMethodAlipay'), t('wdMethodBank')][type - 1];
    final (statusTxt, statusColor) = switch (status) {
      2 => (t('wdStatusApproved'), AppTheme.green),
      3 => (t('wdStatusRejected'), AppTheme.danger),
      _ => (t('wdStatusPending'), const Color(0xFFF5A623)),
    };
    final reject = (o['rejectReason'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('¥${amount.toStringAsFixed(2)}  ·  $typeTxt',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface)),
                const SizedBox(height: 3),
                Text(
                    '${t('wdActual')} ¥${actual.toStringAsFixed(2)}  ·  '
                    '${(o['createdAt'] ?? '').toString()}',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
                if (status == 3 && reject.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(t('wdRejectReason', {'reason': reject}),
                      style: TextStyle(fontSize: 12, color: AppTheme.danger)),
                ],
              ],
            ),
          ),
          _statusChip(statusTxt, statusColor),
        ],
      ),
    );
  }
}

// ============ 共用状态角标 ============

class _statusChip extends StatelessWidget {
  const _statusChip(this.txt, this.color);

  final String txt;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(txt, style: TextStyle(fontSize: 12, color: color)),
    );
  }
}
