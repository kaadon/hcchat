import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;

import '../l10n/app_locale.dart';
import '../services/user_cache.dart';
import '../services/wallet_store.dart';
import '../services/wide_layout_store.dart';
import '../theme/app_theme.dart';
import '../widgets/v2_kit.dart';
import '../widgets/v2_settings.dart';
import 'about_page.dart';
import 'bill_page.dart';
import 'pay_pwd_setup_page.dart';
import 'recharge_page.dart';
import 'withdraw_page.dart';

/// 零钱 / 我的钱包（余额 + 充值 / 提现 / 账单入口）。
///
/// 交易记录**不在本页**：用户要求（第六批第 5 项）「钱包不要交易记录，交易记录在钱包
/// 右上角账单进入查看」——流水本体在 `bill_page.dart`（分页 + 日期筛选）。
///
/// 数据源统一走 WalletStore（后端 user.balance），与"我的"页共享同一份缓存，
/// 避免出现两个页面余额不一致（B-20）。
///
/// 视觉：2026-09-14 按参考 APK 截图像素级复刻，逐元素实测见
/// `UI-ref/measure/measure_wallet.md`；2026-09-14 二轮逐元素重核见
/// `UI-ref/measure/audit_wallet.md`。结构自上而下：
/// 近黑深色头部（底角 40.8 大圆角，压在 #F6F7F9 浅灰底上，自身铺到屏幕顶端；
/// 参考机总高 443.7 = 状态栏 59.35 + 固定段 384.35，本页固定段与之一致）
///   ├ 返回「＜」+ 居中标题「钱包」（56 内容区，与 V2SetHeader 同）+ 1 物理 px 细线
///   ├ 「账户余额」+ 眼睛（余额显示/隐藏）
///   ├ ¥ 0.00（¥ 32 / 数字 54 粗体）
///   └ 充值 / 提现 / 账单 三个 109.3×90 深灰方块按钮
/// 头部下方 25.6 处是白卡（「支付密码」「关于钱包」两行，行高 83，圆角 21.2）。
class WalletPage extends StatefulWidget {
  const WalletPage({super.key});

  @override
  State<WalletPage> createState() => _WalletPageState();
}

class _WalletPageState extends State<WalletPage> {
  // 原 `_loading` 字段从未被读取（analyze: unused_field），首次加载态不参与渲染，
  // 与截图一致（进页面即显示 ¥0.00，无骨架/转圈），故删除该死字段。
  double _balance = 0;
  double _frozen = 0;

  /// 余额是否打码（截图「账户余额」右侧的眼睛）。
  bool _hideAmount = false;

  VoidCallback? _onStoreChanged;

  // ==========================================================================
  // 实测规格（逻辑 px；参考机 1260 物理 / DPR 3 ⇒ 逻辑宽 420，与 v2Scale 基准一致）
  // 落地统一 `* v2Scale(context)`。
  // ==========================================================================

  /// 深色头部：**只圆底角** r=40.8（最小二乘 RMSE 0.24 / n=90），上两角直角
  /// （物理前 4 行与底色的最大差值全 0）。参考机总高 443.7 = 状态栏 59.35
  /// + 固定段 384.35（63.65+44.4+23.3+33.3+54+40.3+90+35.4）。
  static const double _kHeaderRadius = 40.8;

  /// 状态栏以下到 1 物理 px 细线：56 内容区（与 V2SetHeader 同）+ 7.65。
  ///
  /// 细线实测在 ly=**123.00**（x=6 列色变 14→108→14，唯一一行）。推导不用「中文
  /// ink 中心偏移 δ」——那个 δ 无独立验证；改用 B 型页（设备/通知/数据）的独立约束：
  /// 它们的顶部条带同样在 123.00 结束，且 123.0 = 状态栏 **59.35** + 56 + **7.65**
  /// （59.35 见 DESIGN §12.2，参考机是灵动岛机型）。同一台机两族页共用一条 123.0
  /// 边界 ⇒ 状态栏只有一个值 ⇒ 块高 = 123.00 − 59.35 = **63.65**。
  /// （上一版 62.0 是把 δ 当成 1.8 得出来的，在参考机上细线会落在 121.35，**偏高 1.65**。）
  static const double _kNavBlockH = 63.65;
  static const double _kNavInnerH = 56.0;

  /// 返回「＜」实测 ink **12.33×21.00**、ink 左缘 **23.00**、ink 中心 ly **87.00**
  /// （= 标题 ink 中心，Δ0.17 ⇒ 参考里两者 ink 中心对齐）。
  ///
  /// 选型按 **path 数据**算，不靠目视：`arrow_back_ios_new`（`M17.77 3.77…`）ink =
  /// 11.77/24 × 20/24 = **0.4904×0.8333 em**（宽高比 0.588）、笔画垂直厚 2.5/24 =
  /// 0.104 em、ink 左偏 6/24 = 0.25 em、ink 垂直中心 = 盒中心（y 2..22 对称）；
  /// `chevron_left` 是 0.3088×0.5 em（比例 0.618）、笔画 0.0833 em（= ink 高的 0.167）。
  /// 参考 ink 宽/高 = 12.33/21.00 = **0.587**、笔画/ink 高 = 2.83/21.0 = **0.135**
  /// ⇒ 只有 `arrow_back_ios_new`（0.588 / 0.125）对得上，**不自绘**。
  /// size = 21.00 ÷ 0.8333 = **25.2**（ink 宽 12.36，误差 0.03）；box 左 = 23.00 − 0.25×25.2 = **16.7**。
  static const double _kBackSize = 25.2;
  static const double _kBackLeft = 16.7;
  /// ink 中心对齐：参考图标 ink 中心 87.00、标题 ink 中心 87.167 ⇒ 图标再上移 0.35。
  static const double _kBackDy = -0.35;
  /// 命中盒：ink 只有 21 高，拿 25.2 当 SizedBox 会让点击区过小，故用 44 的盒并把图标居中。
  static const double _kBackHit = 44.0;

  /// 右上角「账单」入口字号。参考图该区域**无任何 ink**（阈值低到 20 仍 n=0；AppBar 带
  /// 只有返回 23.00–35.67 与标题 189.00–230.67）⇒ 本项是**参考图之外的新增入口**，
  /// 位置/字号均为推导：右缘距屏右 = [_kPadX]（与左侧内容边距对称）、垂直与返回图标
  /// ink 中心同高（同居中于 56 内容区）、字号取本页已实测的 16.3（三个方块按钮文字）。
  static const double _kBillActionSize = 16.3;
  static const double _kBillActionW = 56.0; // 命中盒宽（高借用 _kBackHit）

  static const double _kPadX = 30.7; // 头部内容左右边距（= 按钮左缘）
  /// 细线 → 「账户余额」/眼睛 行顶。该行高 = max(label 17.8, eye 23.3) = 23.3，
  /// 参考 label 行框顶 = 169.87（由 ink 169.33..185.33 反推基线 184.0）
  /// ⇒ 行顶 = 169.87 − (23.3−17.8)/2 = 167.12；减去细线 123.0 ⇒ 44.4（原 43.1）。
  static const double _kHeadPadTop = 44.4;
  static const double _kHeadPadBottom = 35.4; // 按钮底 → 头部底缘（443.7−408.3）

  static const double _kLabelSize = 17.8; // 「账户余额」ink 69.33 = 3.88em ⇒ 17.87
  /// 眼睛：ink 21.33×14.67。`visibility_outlined` glyph 占视框 22/24 × 16/24
  /// ⇒ size = 21.33/(22/24) ≈ 23.3（原 22.5）。逐物理行游程证实是「描边眼睛
  /// + 空心瞳孔环」（中心行 4 段游程），即 outlined 而非实心，故图标不换。
  static const double _kEyeSize = 23.3;
  static const double _kLabelEyeGap = 10.45;
  /// 行底 → 金额行顶。金额框顶 = 参考 223.95 − (行顶 167.4 + 行高 23.3) ≈ 33.3（原 35.4）。
  static const double _kLabelToAmount = 33.3;

  /// ¥ 0.00：数字 ink 高 39.67 × (k=0.7227) ⇒ 54；¥ ink 高 23.33 ÷ 0.711 ⇒ 32
  static const double _kAmountSize = 54.0;
  static const double _kYenSize = 32.0;

  /// 跟踪字距：参考字体数字比 Roboto Bold 宽（ink/advance = 0.792 vs 0.904），
  /// 无法同时对上「逐字步进 35.33」与「ink 总宽 113.67」，取折中 4.3
  /// （步进 34.6 / 总宽 115.5，两误差 0.7 / 1.8 反号）。
  static const double _kAmountTracking = 4.3;
  static const double _kAmountToBtn = 40.3;

  /// 三个按钮：w=(420-2×30.7-2×15.3)/3=109.3、h=90、圆角 15.5、底色 #3C3D41
  static const double _kBtnH = 90.0;
  static const double _kBtnGap = 15.3;
  static const double _kBtnRadius = 15.5;
  static const double _kBtnIconSize = 28.0;
  static const double _kBtnIconTop = 15.6;
  static const double _kBtnIconGap = 11.75;
  static const double _kBtnTextSize = 16.3;

  /// 头部底 → 白卡顶 25.6
  static const double _kHeaderToCard = 25.6;

  /// 白卡：左 20.7 / 宽 378.7、行高 83.0；**圆角 21.2**——左右上两角最小二乘
  /// 同为 r=21.2 / RMSE 0.251 / n=62，与 `kSetCardR`(=16) 不同（本页量到的卡更圆），
  /// 故用页内常量而不复用共享常量。
  static const double _kCardRadius = 21.2;
  static const double _kRowH = 83.0;
  static const double _kRowPadL = 20.3; // 卡内左内边距（= 图标块左缘 41.0）
  static const double _kIconBlockSize = 46.3;
  static const double _kIconBlockRadius = 12.0;
  static const double _kIconBlockGap = 15.3;
  static const double _kIconSize = 23.0;
  static const double _kRowTitleSize = 19.0; // 「支付密码」逐字步进 19.0/19.3/19.0
  static const double _kRowTailSize = 16.6; // 「未设置」步进 16.4/16.6
  static const double _kChevronSize = 27.5; // ink 8.7×14.7
  static const double _kTailChevronGap = 2.4;
  static const double _kChevronRight = 15.2; // chevron box 右缘 → 卡右缘

  /// 卡内分隔线：左端距卡左 71.6（= 图标块右缘 87.3 − 15.7），右端距卡右 20.4，
  /// 与 V2SetCard 的「左 20.3 / 右通到卡缘」**不一致**，故本页自绘卡片。
  /// 厚度：物理行 1656/1657/1658 的 255−v = 4/26/20（能量 50）⇒ 覆盖 2.1 物理 px
  /// = **0.7 逻辑 px**（= kSetHairThickness）。
  static const double _kHairLeft = 71.6;
  static const double _kHairRight = 20.4;
  static const double _kHairH = kSetHairThickness;

  /// 分隔线色。能量守恒：E = Σ(255−v) = 4+26+20 = **50**，线宽 0.7 逻辑 px
  /// = 2.1 物理 px ⇒ 255−C = 50/2.1 = 23.8 ⇒ **#E7E7E7**。
  /// 共享 token `setHair`(#F3F3F3) 同宽下 E 只有 12×2.1 = 25.2，**正好一半**，肉眼可辨。
  /// 另两种可能已排除：① 1 物理 px 单像素线 ⇒ 剖面该是单个 50，而非 4/26/20；
  /// ② #F3F3F3 ⇒ 需加宽到 1.4 逻辑 px 才凑够 50，那会跨 ~4.2 物理 px，与「只有 3 行非零」矛盾。
  static const Color _kHairColor = Color(0xFFE7E7E7);

  /// 深色推导值（参考包无深色截图）：深卡 #1C1C1E 上用同量级可见度，非实测。
  static const Color _kHairColorDark = Color(0xFF2C2D31);

  // ---------- 色板（实测） ----------
  static const Color _kHeaderBg = Color(0xFF0C0D12);
  static const Color _kHeaderBgDark = Color(0xFF1C1C1E);
  static const Color _kHeaderHair = Color(0xFF6A6B6F); // 1 物理 px，实测 (106,107,111)
  static const Color _kHeaderHairDark = Color(0xFF3A3B40);
  static const Color _kBtnBg = Color(0xFF3C3D41);
  static const Color _kBtnBgDark = Color(0xFF3C3D41);
  static const Color _kDimFg = Color(0xCCFFFFFF); // 「账户余额」/ 眼睛 ≈ 白 80%
  static const Color _kIconBlockBg = Color(0xFFECECEC);
  static const Color _kIconBlockBgDark = Color(0xFF2C2C2E);
  static const Color _kGlyph = Color(0xFF0C0D12);
  static const Color _kGlyphDark = Color(0xFFF2F2F7);
  static const Color _kTailOrange = Color(0xFFFF9500); // 「未设置」
  static const Color _kChevron = Color(0xFF9CA2AE);
  static const Color _kChevronDark = Color(0xFF8E8E93);

  @override
  void initState() {
    super.initState();
    _load();
    // B-24：余额变动现在是服务端 WS 主动推的，本页不能只认进页面时的那次快照，
    // 否则后台加了钱、红包被人领走时页面还停在旧值。跟着 WalletStore 走即可。
    _onStoreChanged = () {
      if (!mounted) return;
      setState(() {
        _balance = WalletStore.instance.balance;
        _frozen = WalletStore.instance.frozen;
      });
    };
    WalletStore.instance.balanceNotifier.addListener(_onStoreChanged!);
    WalletStore.instance.frozenNotifier.addListener(_onStoreChanged!);
  }

  @override
  void dispose() {
    final cb = _onStoreChanged;
    if (cb != null) {
      WalletStore.instance.balanceNotifier.removeListener(cb);
      WalletStore.instance.frozenNotifier.removeListener(cb);
    }
    super.dispose();
  }

  /// 每次进页面都强刷一次（不等缓存），保证后台调整过的余额能立刻看到（B-20）
  Future<void> _load() async {
    await WalletStore.instance.refresh();
    if (!mounted) return;
    setState(() {
      _balance = WalletStore.instance.balance;
      _frozen = WalletStore.instance.frozen;
    });
  }

  /// 冻结额仍用共享格式化器（去掉无意义的 ".00"）；
  /// 头部余额按截图固定两位小数（截图即「¥ 0.00」）。
  String _fmt(double v) => WalletStore.instance.fmt(v);

  void _push(Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    // 头部整片铺到屏幕顶端，状态栏压在深色上 ⇒ 状态栏图标必须常亮（与红包详情页同款）。
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: context.setPageBg,
        body: ListView(
          padding: EdgeInsets.zero,
          children: [
            _header(context, t, s),
            SizedBox(height: _kHeaderToCard * s),
            _menuCard(context, t, s),
            // 第六批第 5 项：**交易记录不再内嵌在本页**（用户原话「钱包 不要交易记录，
            // 交易记录在钱包右上角 账单进入查看」）。入口见 _header 右上角「账单」，
            // 流水本体在 `bill_page.dart`（分页 + 日期筛选，数据源同为
            // `GET /api/v1/wallet/records`）。原来这份内嵌卡片的行样式已整体搬到账单页。
            SizedBox(height: 40 * s + MediaQuery.paddingOf(context).bottom),
          ],
        ),
      ),
    );
  }

  // ==========================================================================
  // 深色头部
  // ==========================================================================

  Widget _header(BuildContext context, String Function(String) t, double s) {
    final dark = context.v2IsDark;
    final topPad = MediaQuery.paddingOf(context).top;
    final hairPx = 1 / MediaQuery.devicePixelRatioOf(context);
    return Container(
      decoration: BoxDecoration(
        color: dark ? _kHeaderBgDark : _kHeaderBg,
        borderRadius:
            BorderRadius.vertical(bottom: Radius.circular(_kHeaderRadius * s)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: topPad),
          SizedBox(
            height: _kNavBlockH * s,
            child: Stack(
              children: [
                // 标题：「钱包」居中，垂直中心在 56 内容区
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: _kNavInnerH * s,
                  child: Center(
                    child: Text(
                      t('meRowWallet'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: kSetHeaderTitleSize * s,
                        fontWeight: FontWeight.w600,
                        height: 1.0,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                // 返回：截图是细「＜」（iOS 风格），不是 V2SetHeader 的实心箭头。
                // 盒按 _kBackHit 放大以保点击区，图标在盒内居中（故盒中心即 ink 中心）。
                Positioned(
                  left: (_kBackLeft - (_kBackHit - _kBackSize) / 2) * s,
                  top: ((_kNavInnerH - _kBackHit) / 2 + _kBackDy) * s,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).maybePop(),
                    child: SizedBox(
                      width: _kBackHit * s,
                      height: _kBackHit * s,
                      child: Center(
                        child: Icon(Icons.arrow_back_ios_new,
                            size: _kBackSize * s, color: Colors.white),
                      ),
                    ),
                  ),
                ),
                // AppBar 下边框：1 物理 px
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    height: hairPx,
                    color: dark ? _kHeaderHairDark : _kHeaderHair,
                  ),
                ),
                // 右上角「账单」入口（第六批第 5 项，参考图无此项，位置为对称推导，
                // 见 _kBillActionSize 注释）。与页内其他入口一致走 openDetail。
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: _kNavInnerH * s,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: EdgeInsets.only(right: _kPadX * s),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => WideLayoutStore.instance
                            .openDetail(context, const BillPage(),
                                paneKey: 'bill'),
                        child: SizedBox(
                          width: _kBillActionW * s,
                          height: _kBackHit * s,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              t('walletBill'),
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: _kBillActionSize * s,
                                fontWeight: FontWeight.w400,
                                height: 1.0,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.only(
              left: _kPadX * s,
              right: _kPadX * s,
              top: _kHeadPadTop * s,
              bottom: _kHeadPadBottom * s,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      t('walletAccountBalance'),
                      style: TextStyle(
                        fontSize: _kLabelSize * s,
                        fontWeight: FontWeight.w400,
                        height: 1.0,
                        color: _kDimFg,
                      ),
                    ),
                    SizedBox(width: _kLabelEyeGap * s),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _hideAmount = !_hideAmount),
                      child: Icon(
                        _hideAmount
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: _kEyeSize * s,
                        color: _kDimFg,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: _kLabelToAmount * s),
                _amount(s),
                // 冻结金额（B-22）：发出的红包/转账还没被领走的部分，24h 未领自动退回。
                // 截图为 0，为 0 时不占位（保证与截图逐像素一致）。
                if (_frozen > 0) ...[
                  SizedBox(height: 12 * s),
                  _frozenChip(t, s),
                  SizedBox(height: 6 * s),
                  Text(
                    t('walletRecordHint'),
                    style: TextStyle(fontSize: 12 * s, color: _kDimFg),
                  ),
                ],
                SizedBox(height: _kAmountToBtn * s),
                _actions(context, t, s),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 超大金额。「¥」比数字小一号，同一段落共基线自动对齐。
  Widget _amount(double s) {
    // 一律两位小数（截图即「¥ 0.00」）；余额只读服务端值，前端不做任何计算。
    final digits = _hideAmount ? '****' : _balance.toStringAsFixed(2);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '¥ ',
            style: TextStyle(
              fontSize: _kYenSize * s,
              fontWeight: FontWeight.w700,
              height: 1.0,
              color: Colors.white,
            ),
          ),
          TextSpan(
            text: digits,
            style: TextStyle(
              fontSize: _kAmountSize * s,
              fontWeight: FontWeight.w700,
              height: 1.0,
              letterSpacing: _kAmountTracking * s,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _frozenChip(String Function(String) t, double s) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: 10 * s, vertical: 8 * s),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8 * s),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_clock, size: 14 * s, color: _kDimFg),
          SizedBox(width: 6 * s),
          Text(t('walletFrozen'),
              style: TextStyle(fontSize: 12 * s, color: _kDimFg)),
          Text('¥ ${_fmt(_frozen)}',
              style: TextStyle(
                  fontSize: 13 * s,
                  fontWeight: FontWeight.w600,
                  color: Colors.white)),
          const Spacer(),
          Text(t('walletAutoRefund'),
              style: TextStyle(fontSize: 11 * s, color: _kDimFg)),
        ],
      ),
    );
  }

  /// 充值 / 提现 / 账单 三个并排方块按钮（图标在上、文字在下）。
  Widget _actions(BuildContext context, String Function(String) t, double s) {
    final dark = context.v2IsDark;
    final specs = <(IconData, String, VoidCallback)>[
      (Icons.add, t('walletRecharge'), () => _push(const RechargePage())),
      (
        Icons.arrow_upward,
        t('walletWithdraw'),
        () => _push(const WithdrawPage())
      ),
      // 「账单」与右上角入口同一目标，故同样走 openDetail：宽屏时两者都应开右栏，
      // 只用 Navigator.push 会出现「按钮开整屏路由、右上角开右栏」的不一致。
      (
        Icons.receipt_long,
        t('walletBill'),
        () => WideLayoutStore.instance
            .openDetail(context, const BillPage(), paneKey: 'bill')
      ),
    ];
    return Row(
      children: [
        for (var i = 0; i < specs.length; i++) ...[
          if (i > 0) SizedBox(width: _kBtnGap * s),
          Expanded(child: _actionButton(s, specs[i], dark)),
        ],
      ],
    );
  }

  Widget _actionButton(
      double s, (IconData, String, VoidCallback) spec, bool dark) {
    final (icon, label, onTap) = spec;
    return SizedBox(
      height: _kBtnH * s,
      child: Material(
        color: dark ? _kBtnBgDark : _kBtnBg,
        borderRadius: BorderRadius.circular(_kBtnRadius * s),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.only(top: _kBtnIconTop * s),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: _kBtnIconSize * s, color: Colors.white),
                SizedBox(height: _kBtnIconGap * s),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: _kBtnTextSize * s,
                    fontWeight: FontWeight.w400,
                    height: 1.0,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ==========================================================================
  // 头部下方的白卡（支付密码 / 关于钱包）
  // ==========================================================================

  Widget _menuCard(BuildContext context, String Function(String) t, double s) {
    final dark = context.v2IsDark;
    final pwdSet = UserCache.myProfileData?['payPwdSet'] == true;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: kSetCardX * s),
      child: Container(
        width: kSetCardW * s,
        decoration: BoxDecoration(
          color: context.setCard,
          borderRadius: BorderRadius.circular(_kCardRadius * s),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _cardRow(
              context: context,
              s: s,
              dark: dark,
              icon: Icons.lock_outline,
              title: t('walletPayPassword'),
              tail: pwdSet ? t('payPwdSetDone') : t('convSetNotSet'),
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const PayPwdSetupPage()));
                if (mounted) setState(() {}); // 返回后刷新「已设置 / 未设置」
              },
            ),
            Padding(
              padding: EdgeInsets.only(
                  left: _kHairLeft * s, right: _kHairRight * s),
              child: Container(
                  height: _kHairH * s,
                  color: dark ? _kHairColorDark : _kHairColor),
            ),
            // 「关于钱包」跳「关于」页。2026-09-14：AboutPage 原在 me_page.dart，
            // 而钱包页已被 me_page 单向引用，引回来会成环；现已抽到独立文件
            // `about_page.dart`，两边都单向依赖它。
            _cardRow(
              context: context,
              s: s,
              dark: dark,
              icon: Icons.info_outline,
              title: t('walletAbout'),
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AboutPage())),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cardRow({
    required BuildContext context,
    required double s,
    required bool dark,
    required IconData icon,
    required String title,
    String? tail,
    required VoidCallback? onTap,
  }) {
    final body = Padding(
      padding: EdgeInsets.only(left: _kRowPadL * s),
      child: SizedBox(
        height: _kRowH * s,
        child: Row(
          children: [
            Container(
              width: _kIconBlockSize * s,
              height: _kIconBlockSize * s,
              decoration: BoxDecoration(
                color: dark ? _kIconBlockBgDark : _kIconBlockBg,
                borderRadius: BorderRadius.circular(_kIconBlockRadius * s),
              ),
              child: Icon(icon,
                  size: _kIconSize * s,
                  color: dark ? _kGlyphDark : _kGlyph),
            ),
            SizedBox(width: _kIconBlockGap * s),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: _kRowTitleSize * s,
                  fontWeight: FontWeight.w400,
                  height: 1.0,
                  color: context.setTitle,
                ),
              ),
            ),
            if (tail != null) ...[
              Text(
                tail,
                style: TextStyle(
                  fontSize: _kRowTailSize * s,
                  fontWeight: FontWeight.w400,
                  height: 1.0,
                  color: _kTailOrange,
                ),
              ),
              SizedBox(width: _kTailChevronGap * s),
            ],
            V2SetChevron(
                size: _kChevronSize, color: dark ? _kChevronDark : _kChevron),
            SizedBox(width: _kChevronRight * s),
          ],
        ),
      ),
    );
    if (onTap == null) return body;
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, child: body),
    );
  }
}
