import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/moment_service.dart';
import '../services/wallet_store.dart';
import '../theme/app_theme.dart';
import '../widgets/v2_kit.dart';
import '../widgets/v2_settings.dart';
import 'pay_ui.dart';

/// 我的账单 / 交易记录。
///
/// 2026-09-14 第六批第 5 项：用户要求「钱包 不要交易记录，交易记录在钱包右上角
/// 账单进入查看」——钱包页不再内嵌流水卡片，流水统一由本页承载（钱包右上角「账单」
/// 与三个方块按钮里的「账单」都进这里）。
///
/// 数据源：`MomentService.records()` → `GET /api/v1/wallet/records`，与钱包页余额
/// （`/api/v1/wallet/me`）同属钱包模块的同一份流水；本页是它的完整版（日期筛选 +
/// 分页），**没有新造接口**。
///
/// 外观：v2 **A 型**（自绘 AppBar + `V2SetBackSpec.full` 完整 `←`；底 #F6F7F9、
/// 内容白卡），深浅色一律走 `context.setPageBg / setCard / setTitle / setSub`。
/// 流水行样式由钱包页原来的 `_recordRow` 整体搬来（不留在钱包页当死代码），
/// 并按 v2 尺度 `* v2Scale(context)` 归一。
///
/// 为什么用 [V2SetHeader] 而不是 [V2SetScaffold]：本页要自己持有 [ScrollController]
/// 做「触底加载下一页」，而 `V2SetScaffold` 内部的 ListView 不对外暴露滚动控制。
/// 头部与底色和 A 型完全一致——`V2SetHeader` 就是 `V2SetScaffold` 内部用的那个，
/// 官方注释也写明「供需要自定义 body 的页面直接用」。
class BillPage extends StatefulWidget {
  const BillPage({super.key, this.onBack});

  /// 宽屏右栏用；不传则返回键走 `Navigator.maybePop`（见 [V2SetHeader]）。
  final VoidCallback? onBack;

  @override
  State<BillPage> createState() => _BillPageState();
}

class _BillPageState extends State<BillPage> {
  final _svc = MomentService.instance;
  final _scroll = ScrollController();

  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  int _total = 0;
  List<Map<String, dynamic>> _records = [];

  DateTime? _start;
  DateTime? _end;

  @override
  void initState() {
    super.initState();
    _load();
    _scroll.addListener(() {
      if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 200 &&
          !_loadingMore &&
          _hasMore) {
        _loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await _svc.records(
          start: _start != null ? _fmtDate(_start!) : null,
          end: _end != null ? _fmtDate(_end!) : null);
      if (mounted) {
        setState(() {
          _total = (data['total'] as num?)?.toInt() ?? 0;
          _records = ((data['list'] as List<dynamic>?) ?? [])
              .map((e) => (e as Map).cast<String, dynamic>())
              .toList();
          _page = 1;
          _hasMore = _records.length < _total;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    try {
      final data = await _svc.records(
          start: _start != null ? _fmtDate(_start!) : null,
          end: _end != null ? _fmtDate(_end!) : null,
          page: _page + 1);
      if (mounted) {
        final more = ((data['list'] as List<dynamic>?) ?? [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        setState(() {
          _records.addAll(more);
          _page++;
          _hasMore = _records.length < _total;
          _loadingMore = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _pickRange() async {
    final t = AppLocalizations.of(context).t;
    final now = DateTime.now();
    final initial = _start ?? now.subtract(const Duration(days: 30));
    final s = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2024),
      lastDate: now,
      helpText: t('billSelectStartDate'),
    );
    if (s == null || !mounted) return;
    final e = await showDatePicker(
      context: context,
      initialDate: _end ?? now,
      firstDate: s,
      lastDate: now,
      helpText: t('billSelectEndDate'),
    );
    if (!mounted) return;
    setState(() {
      _start = s;
      _end = e; // 可只选开始日期
    });
    _load();
  }

  void _clearRange() {
    setState(() {
      _start = null;
      _end = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    return Scaffold(
      backgroundColor: context.setPageBg,
      body: Column(
        children: [
          V2SetHeader(
            title: t('walletTransactions'),
            onBack: widget.onBack,
            backSpec: V2SetBackSpec.full,
          ),
          _filterBar(context, s),
          Expanded(child: _list(context, t, s)),
        ],
      ),
    );
  }

  /// 日期筛选条（沿用原页面的「选区间 / 清除 / 总数」，只是换成 v2 白卡语言）。
  Widget _filterBar(BuildContext context, double s) {
    final t = AppLocalizations.of(context).t;
    final range = _start == null
        ? t('billAllTime')
        : '${_fmtDate(_start!)}${_end != null ? ' ~ ${_fmtDate(_end!)}' : ' ${t('billToNow')}'}';
    return Padding(
      padding: EdgeInsets.fromLTRB(
          kSetCardX * s, 4 * s, kSetCardX * s, 12 * s),
      child: Row(
        children: [
          Material(
            color: context.setCard,
            borderRadius: BorderRadius.circular(10 * s),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _pickRange,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 8 * s),
                child: Row(
                  children: [
                    Icon(Icons.filter_alt_outlined,
                        size: 15 * s, color: context.setSub),
                    SizedBox(width: 6 * s),
                    Text(range,
                        style: TextStyle(
                            fontSize: 14 * s, color: context.setTitle)),
                    if (_start != null) ...[
                      SizedBox(width: 6 * s),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _clearRange,
                        child: Icon(Icons.close,
                            size: 15 * s, color: context.setSub),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const Spacer(),
          Text(t('billTotalCount', {'count': '$_total'}),
              style: TextStyle(fontSize: 13 * s, color: context.setSub)),
        ],
      ),
    );
  }

  Widget _list(BuildContext context, String Function(String) t, double s) {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: AppTheme.primary));
    }
    if (_records.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_long_outlined,
                size: 48 * s,
                color: context.setSub.withValues(alpha: 0.5)),
            SizedBox(height: 10 * s),
            Text(t('billEmpty'),
                style: TextStyle(fontSize: 13 * s, color: context.setSub)),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: EdgeInsets.zero,
      itemCount: _records.length + (_hasMore ? 1 : 0),
      itemBuilder: (ctx, i) {
        if (i >= _records.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
                child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppTheme.primary))),
          );
        }
        return _cardedRow(context, i, s);
      },
    );
  }

  /// 让列表**看着像一张 v2 白卡**（首行圆上角、末行圆下角，行间分隔线左起
  /// [kSetHairInset]），但仍是 `ListView.builder` 惰性构建（分页可能上百行）。
  Widget _cardedRow(BuildContext context, int i, double s) {
    final first = i == 0;
    final last = i == _records.length - 1;
    final r = kSetCardR * s;
    return Container(
      margin: EdgeInsets.symmetric(horizontal: kSetCardX * s),
      decoration: BoxDecoration(
        color: context.setCard,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(first ? r : 0),
          bottom: Radius.circular(last ? r : 0),
        ),
      ),
      child: Column(
        children: [
          if (!first)
            Padding(
              padding: EdgeInsets.only(left: kSetHairInset * s),
              child: Container(
                  height: kSetHairThickness * s, color: context.setHair),
            ),
          _recordRow(_records[i], s),
        ],
      ),
    );
  }

  /// 流水行（原 `wallet_page.dart` 的 `_recordRow` 整体搬来，尺度改为 `* s`）。
  /// 后端流水：amount 正 = 入账 / 负 = 支出；title / typeName / createdAt 已格式化。
  /// 金额只读服务端值，格式化走共享的 [WalletStore.fmt]（去掉无意义的 ".00"）。
  Widget _recordRow(Map<String, dynamic> r, double s) {
    final amount = (r['amount'] as num?)?.toDouble() ?? 0;
    final income = amount >= 0;
    final title = (r['title'] ?? r['typeName'] ?? '').toString();
    final createdAt = (r['createdAt'] ?? '').toString();
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16 * s, vertical: 13 * s),
      child: Row(
        children: [
          Container(
            width: 36 * s,
            height: 36 * s,
            decoration: BoxDecoration(
              color: (income ? const Color(0xFFE9564E) : PayUI.primary)
                  .withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              income ? Icons.south_west : Icons.north_east,
              size: 18 * s,
              color: income ? const Color(0xFFE9564E) : PayUI.primary,
            ),
          ),
          SizedBox(width: 12 * s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15 * s, color: context.setTitle)),
                Text(createdAt,
                    style: TextStyle(fontSize: 12 * s, color: context.setSub)),
              ],
            ),
          ),
          Text(
            '${income ? '+' : '-'}¥${WalletStore.instance.fmt(amount.abs())}',
            style: TextStyle(
              fontSize: 15 * s,
              fontWeight: FontWeight.w600,
              color: income ? const Color(0xFF34A853) : context.setTitle,
            ),
          ),
        ],
      ),
    );
  }
}
