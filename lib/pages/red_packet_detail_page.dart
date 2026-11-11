import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_locale.dart';
import '../services/moment_service.dart';
import '../services/user_cache.dart';
import '../widgets/app_avatar.dart';
import 'wallet_page.dart';

/// 红包领取详情页（ckao envelope_receive 同款视觉）：
/// 顶部红色圆弧 #F25745 + 金边 #F8CA75（大圆溢出顶部，弧内含发送者+祝福语）→
/// 金色大金额 #C2A26F +「已存入账户」入口 → 领取列表（手气最佳皇冠）。
class RedPacketDetailPage extends StatefulWidget {
  final String msgId;

  /// 领取/详情接口已拉到的数据直接透传 → 页面秒开，不再转圈二次请求；
  /// 为空（如深链直达）时才自己请求
  final Map<String, dynamic>? initialDetail;
  const RedPacketDetailPage(
      {super.key, required this.msgId, this.initialDetail});

  @override
  State<RedPacketDetailPage> createState() => _RedPacketDetailPageState();
}

class _RedPacketDetailPageState extends State<RedPacketDetailPage> {
  final _svc = MomentService.instance;
  bool _loading = true;
  Map<String, dynamic> _detail = {};

  @override
  void initState() {
    super.initState();
    final pre = widget.initialDetail;
    if (pre != null && pre.isNotEmpty) {
      _detail = Map<String, dynamic>.from(pre);
      _loading = false;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final d = await _svc.redPacketDetail(widget.msgId);
      if (mounted) {
        setState(() {
          _detail = d;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _fmt(num? v) {
    final d = (v ?? 0).toDouble();
    final s = d.toStringAsFixed(2);
    return s.endsWith('.00') ? d.toStringAsFixed(0) : s;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final note =
        (_detail['note'] ?? t('redPacketDetailDefaultNote')).toString();
    final senderName =
        (_detail['senderName'] ?? t('redPacketDetailDefaultSender')).toString();
    final senderAvatar = (_detail['senderAvatar'] ?? '').toString();
    final claimedCnt = (_detail['claimedCnt'] as num?)?.toInt() ?? 0;
    final count = (_detail['count'] as num?)?.toInt() ?? 1;
    // 后端字段是 totalAmount（wallet.go:605），不是 amount
    final totalAmount = (_detail['totalAmount'] as num?)?.toDouble() ?? 0;
    final list = ((_detail['list'] as List<dynamic>?) ?? [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    // 我是否领取过 / 领取金额（uniapp myAmount 同款逻辑）
    Map<String, dynamic>? mine;
    for (final c in list) {
      if (c['userId']?.toString() == (UserCache.myId ?? '')) {
        mine = c;
        break;
      }
    }
    final myAmount =
        mine == null ? null : ((mine['amount'] as num?)?.toDouble() ?? 0);
    // 大金额：领过 = 我领的；没领过 = 红包总额
    final bigAmount = myAmount ?? totalAmount;
    // 手气最佳：金额最高的一条
    var bestIndex = -1;
    var maxAmount = -1.0;
    for (var i = 0; i < list.length; i++) {
      final v = ((list[i]['amount'] as num?)?.toDouble() ?? 0);
      if (v > maxAmount) {
        maxAmount = v;
        bestIndex = i;
      }
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        body: _loading
            ? const Center(
                child: CircularProgressIndicator(color: Color(0xFFF25745)))
            : SafeArea(
                bottom: false,
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    _buildTopArc(context, senderName, senderAvatar, note),
                    // ===== 金额：金色大字 #C2A26F（96rpx≈48px），紧跟弧底 =====
                    Container(
                      margin: const EdgeInsets.only(top: 16),
                      height: 55,
                      alignment: Alignment.bottomCenter,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(_fmt(bigAmount),
                              style: const TextStyle(
                                  fontSize: 48,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFFC2A26F),
                                  height: 1)),
                          const SizedBox(width: 5),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text('￥',
                                style: const TextStyle(
                                    fontSize: 15, color: Color(0xFFC2A26F))),
                          ),
                        ],
                      ),
                    ),
                    // 已存入账户入口（领取过才显示，点击跳钱包页）
                    if (myAmount != null)
                      InkWell(
                        onTap: () {
                          Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => const WalletPage()));
                        },
                        child: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(t('rpDetailDeposited'),
                                  style: const TextStyle(
                                      fontSize: 13, color: Color(0xFFC2A26F))),
                              const SizedBox(width: 3),
                              const Text('›',
                                  style: TextStyle(
                                      fontSize: 15,
                                      height: 1,
                                      color: Color(0xFFC2A26F))),
                            ],
                          ),
                        ),
                      ),
                    _buildClaimList(
                        context, list, claimedCnt, count, bestIndex),
                  ],
                ),
              ),
      ),
    );
  }

  /// 顶部红色圆弧：560rpx(280) 高区域内，600×450 大圆溢出顶部，
  /// 弧内偏下：发送者头像 + 「XX 发出的红包」白字 + 祝福语白 85%
  Widget _buildTopArc(BuildContext context, String senderName,
      String senderAvatar, String note) {
    final t = AppLocalizations.of(context).t;
    return SizedBox(
      // 弧底在 235，盒高压到 240（原 280 多出 45px 白空隙，把金额往下顶）
      height: 240,
      width: double.infinity,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          // 大圆封底：#F25745 + 金边 #F8CA75（top -215 → 弧底在 235）
          Positioned(
            left: -155,
            right: -155,
            top: -215,
            child: Container(
              width: 600,
              height: 450,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFF25745),
                border: Border.all(color: const Color(0xFFF8CA75), width: 3),
              ),
            ),
          ),
          // 关闭 ×（白字，状态栏下）
          Positioned(
            top: 4,
            left: 8,
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                child: const Text('×',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        height: 1,
                        fontWeight: FontWeight.w300)),
              ),
            ),
          ),
          // 弧内偏下（bottom 30）：头像 + 发送者 + 祝福语
          Positioned(
            left: 0,
            right: 0,
            bottom: 30,
            child: Column(
              children: [
                AppAvatar(
                    url: senderAvatar, name: senderName, size: 32, radius: 5),
                const SizedBox(height: 7),
                Text(t('rpOverlayFrom', {'name': senderName}),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 5),
                Text(note,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 领取列表：「领取N/M个」灰字 + 发丝线 + 列表（头像/昵称/时间/金额/手气最佳）
  Widget _buildClaimList(BuildContext context, List<Map<String, dynamic>> list,
      int claimedCnt, int count, int bestIndex) {
    final t = AppLocalizations.of(context).t;
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 16, 15, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t('rpDetailClaimProgress', {'n': '$claimedCnt', 'm': '$count'}),
              style: const TextStyle(fontSize: 15, color: Color(0xFFB2B2B2))),
          Container(
            margin: const EdgeInsets.only(bottom: 15),
            height: 0.5,
            color: const Color(0xFFE5E5E5),
          ),
          if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(t('redPacketDetailNobodyClaimed'),
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFFB2B2B2))),
              ),
            )
          else
            for (var i = 0; i < list.length; i++)
              _claimRow(list[i], i == bestIndex),
        ],
      ),
    );
  }

  Widget _claimRow(Map<String, dynamic> r, bool best) {
    final t = AppLocalizations.of(context).t;
    final name = (r['userName'] ?? t('redPacketDetailDefaultUser')).toString();
    final avatar = (r['avatar'] ?? '').toString();
    final amount = (r['amount'] as num?)?.toDouble() ?? 0;
    // 后端 createdAt 已格式化为 "2006-01-02 15:04"，直接展示
    final time = (r['createdAt'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppAvatar(
                  url: avatar,
                  name: name,
                  size: 40,
                  background: const Color(0xFFF25745)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 昵称 + 右侧金额
                    Row(
                      children: [
                        Expanded(
                          child: Text(name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 15, color: Color(0xFF191919))),
                        ),
                        Text('¥${_fmt(amount)}',
                            style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF191919))),
                      ],
                    ),
                    // 时间 + 手气最佳（皇冠 + 金字）
                    SizedBox(
                      height: 17,
                      child: Row(
                        children: [
                          Text(time,
                              style: const TextStyle(
                                  fontSize: 11, color: Color(0xFFB2B2B2))),
                          const Spacer(),
                          if (best) ...[
                            const Icon(Icons.workspace_premium,
                                size: 17, color: Color(0xFFEDB746)),
                            const SizedBox(width: 5),
                            Text(t('redPacketDetailBestLuck'),
                                style: const TextStyle(
                                    fontSize: 11, color: Color(0xFFEDB746))),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // 发丝线
          Container(
            margin: const EdgeInsets.only(top: 10),
            height: 0.5,
            color: const Color(0xFFE5E5E5),
          ),
        ],
      ),
    );
  }

  String _myUid() {
    // 与 chat_page 同源：登录态用户 id（UserCache 权威缓存）
    final cached = UserCache.myId;
    return (cached != null && cached.isNotEmpty) ? cached : '';
  }
}
