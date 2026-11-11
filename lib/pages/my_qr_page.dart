import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/app_locale.dart';
import '../services/friend_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/v2_kit.dart';

typedef _Tr = String Function(String key, [Map<String, String>? params]);

// ============================================================================
// 我的二维码页（像素级复刻参考 APK 截图）
//
// 测量基准：**以 1260×4055 / DPR 3 的 1260 图为唯一几何基准**（⇒ 逻辑 420.0 × 1351.7）。
// 下面全部常量都是该图的逻辑 px 实测值。完整测量见 `UI-ref/measure/audit_myqr.md`，
// 口径变更与逐项对照见该文件 **§12 第七批回退：以 1260 图为唯一基准**。
//
// ⚠️ 另一张 556×988 的 `clipboard-2026-09-14T16-21-12-985Z-...png` **是 App 现状截图**，
//   自带两处调试痕迹：右上角红色 DEBUG 缎带、卡底黄黑斜条纹 + `BOTTOM OVERFLOWED BY 27 PIXELS`；
//   **它不是设计稿，不得作为几何基准**（第六批曾误按它落地一批取值，已在第七批回退）。
//
// 版面结构（1260 图实测）：
//   浅黄绿→绿 竖向渐变底 + 深绿涂鸦（整页）
//   ├ 顶部：居中「我的二维码」+ 右侧白色圆形 ×（∅45.3，中心与标题同线）
//   ├ 白色大圆角卡 x22.4 w374.0 h604.8 r32（头像骑在卡上边缘，中心距卡顶 16.5）
//   ├ 全宽白色圆角面板 y778.0..1010.5 r30：「二维码」标题 + 蓝色圆钮 + 3 个样式缩略图
//   ├ 近黑胶囊按钮「保存二维码」x28.0 y1024.0 w363.6 h74.3 r37.15
//   └ 绿色小字「扫描二维码」+ 图标
//
// 卡内竖向节奏（1260 图实测，卡内相对 y）：
//   头像下缘 58.85 → 19.75 → 签名 20.5 → 19.7 → 昵称 26.0 → 7.55
//   → 小胶囊 128.3×36.3（水平居中）→ 11.28 → 二维码白框 297.7×297.7 r26（本体 260.0）
//   → 18.34 → @账号 29.0 → 14.66 → 「扫描二维码添加我为好友」17.5 →（卡底余白 27.7）
//   内容自然高 577.1 ≤ 卡高 604.8 ⇒ **不溢出**（见 §12.5 的自洽校验）。
//
// 二维码渲染：复用项目已有依赖 `qr_flutter`（pubspec 里已有，未新增依赖）。
// 实测配色：定位图案 #69B35A、数据模块 #2C9779，两者分开上色（QrEyeStyle / QrDataModuleStyle）。
// 三套样式（含主图）共用 `_thumbs` 这一份定义（单一数据源，见 _ThumbStyle 注释）。
// ============================================================================

// ---------- 配色（截图实测） ----------
const Color _kGradTop = Color(0xFFE9F5B7); // 渐变顶端（y=0 外推）
const Color _kGradBottom = Color(0xFF95D3A7); // 渐变底端（y=1352 外推）
const Color _kGradTopDark = Color(0xFF25301F);
const Color _kGradBottomDark = Color(0xFF0D1810);

const Color _kEyeGreen = Color(0xFF69B35A); // 头像描边绿环（二维码配色已并入 _thumbs）
const Color _kHandleGreen = Color(0xFF2A9476); // @UYD6GZYC
const Color _kBottomGreen = Color(0xFF68B356); // 底部「扫描二维码」
const Color _kPillFill = Color(0xFFECECEC); // 用户名胶囊
const Color _kSubGrey = Color(0xFF4A4A4A); // 客服名 / 胶囊文字
const Color _kScanGrey = Color(0xFF9C9C9C); // 「扫描二维码添加我为好友」
const Color _kQrBoxBorder = Color(0xFFF0F2EE); // 二维码白框描边
const Color _kSelRing = Color(0xFF50A4E2); // 缩略图选中蓝环
const Color _kIconBtnBg = Color(0xFFF3F7FA); // 右侧小圆钮底
const Color _kIconBtnFg = Color(0xFF4AA4E8); // 右侧小圆钮图标（月亮 + 圆点）
// 右上关闭钮的 × 与标题同色（**近黑**）：556 参考图上 × 被 EBUG 缎带覆盖、不可测，
// 但同图标题实测 #0C0D12、首轮 1260 图直接测得 × 亦为 #0C0D12。上一版 #5E6982 系细描边混色伪影。
const Color _kCloseFg = Color(0xFF0C0D12);
const Color _kTitleInk = Color(0xFF0C0D12); // 「我的二维码」标题（556 图最暗 3% 中位实测）

// ---------- 尺寸（截图逻辑 px 实测） ----------
const double _kHeaderH = 56.0; // 顶部标题条内容区高（与 v2_settings 一致）
const double _kHeaderGap = 39.6; // 标题条底 → 大卡顶（556 图实测「钮心 → 卡顶」= 67.61 ⇒ 67.61 − 28）
const double _kCardX = 22.4; // 大卡左缘
const double _kCardW = 374.0; // 大卡宽
// 大卡高 = 604.8（1260 图实测卡顶 156.7 / 卡底 761.5）。
// 高度用 **minHeight 约束 + 内容自适应**：按 1260 口径算出的内容自然高是 577.1
//（见 §12.5），604.8 作下限 ⇒ 卡片既不会比参考矮，也不会因字体度量出入而裁切/溢出。
// ⚠️ 第六批曾把这里写成 648.0 —— 那是为了兜住「556 图口径下内容 632 > 卡 605」的溢出，
//    口径回退后 648.0 会让卡片比参考高 43 px，已回退。
const double _kCardH = 604.8;
const double _kCardR = 32.0; // 大卡圆角（1260 图拟合 r=32.0，RMSE 0.12）
const double _kAvatarD = 84.7; // 头像外圈直径（含绿环）
const double _kAvatarRing = 5.3; // 绿环厚
const double _kAvatarGap = 3.5; // 绿环与照片之间的白圈厚
const double _kAvatarCY = 16.5; // 头像中心距卡顶（骑跨在卡上缘）
const double _kTitleSize = 22.0; // 标题字号（1260 图 22.0）
// 二维码白框：1260 图逐行/逐列扫「近中性浅灰描边」（raw 上 1069..1073 / 下 1957..1962 /
// 左 183..187 / 右 1072..1077）⇒ 外缘 183..1078 × 1069..1963 ⇒ **297.7 × 297.7 正方形**。
// 框内二维码本体绿掩码 bbox 260.67 × 260.67，四边内距均匀 ≈18.5（含描边）—— 互证为正方形。
// ⚠️ 第二轮审计曾把「白框高」测成 266.3：那其实是**二维码本体 + JPEG 光晕**的 bbox
//    （y 373.3..639.7 ≈ 本体 375.0..635.7 外扩），不是框；由此派生的 266.4 已废除。
const double _kQrBoxW = 297.7; // 二维码白框宽（1260 图 297.7）
const double _kQrBoxH = 297.7; // 二维码白框高（1260 图 297.7，与宽相等 ⇒ 正方形）
const double _kQrBoxR = 26.0; // 白框圆角（由「描边跨度随下潜深度」反解 r≈26.0，与首轮一致）
const double _kQrInner = 260.0; // 二维码本体边长（1260 图绿掩码 260.67）

// 卡内竖向节奏（全部按「白卡顶 = 0」的卡内相对 y 实测值反推，见 audit_myqr.md §12.2）
const double _kCardPadTop = _kAvatarCY + _kAvatarD / 2; // 58.85 头像下缘 + 0
const double _kGapSub = 19.75; // 头像下缘 58.85 → 客服名 ink 顶 78.60（1260 图）
const double _kGapName = 19.7; // 客服名盒底 99.10 → 昵称 ink 顶 118.80
const double _kGapPill = 7.55; // 昵称盒底 144.80 → 胶囊顶 152.35
const double _kGapQr = 11.28; // 胶囊底 188.65 → 白框顶 199.93
//   （实测相邻差 12.66；此处置 11.28 = 12.66 − 1.38，把上面 `_kGapPill` 按清单取 7.55
//    所多出的 1.38 px 扣掉，使**白框的绝对位置**仍等于实测 199.63 —— 见 §12.4）
// 账号胶囊：1260 图 `#ECECEC` 掩码实测**小胶囊** w 128.0 × h 36.0、水平居中（中心 x 209.83）。
// ⚠️ 第六批曾按 556 图把它做成**整卡宽**，形态错，本轮回退为小胶囊。
// 第十二批起高/圆角不再用常量（上下 padding 6.5、全胶囊 r=999）；
// 第十八批起**宽度也不再保底**：旧 `minWidth _kPillW 128.3` 会在账号文字短于
// 128.3 − 32（padding）时让灰底右侧拖出一截空白——即横向版「背景灰色太长」。
// 现灰底宽 = 文字 intrinsic 宽 + 左右 padding 16×2，严格贴合内容、不裁字
//（历史值 `_kPillW 128.3` / `_kPillH 36.3` 备查）。
const double _kGapHandle = 18.34; // 白框底 497.63 → @UYD6GZYC ink 顶 515.97
const double _kGapAddMe = 14.66; // @UYD6GZYC 盒底 544.97 → 「扫描…」盒顶 559.63
const double _kPanelTop = 778.0; // 白色面板顶（页面绝对 y）
const double _kPanelBottom = 1010.5;
const double _kPanelR = 30.0;
const double _kThumbW = 98.0; // 样式缩略图宽
const double _kThumbH = 111.0; // 样式缩略图高
const double _kThumbGap = 25.5; // 缩略图间距
const double _kThumbStart = 29.0; // 首个缩略图左缘
const double _kThumbR = 16.0;
const double _kInnerSq = 53.0; // 缩略图内部白色圆角方块（实测 53.0）
const double _kSaveX = 28.0;
const double _kSaveW = 363.6;
const double _kSaveH = 74.3;

class MyQrPage extends StatefulWidget {
  const MyQrPage({super.key});

  @override
  State<MyQrPage> createState() => _MyQrPageState();
}

class _MyQrPageState extends State<MyQrPage> {
  final _svc = FriendService();
  final _cardKey = GlobalKey();
  Map<String, dynamic>? _profile;
  bool _loading = true;
  bool _failed = false;
  bool _saving = false;

  /// 选中的样式缩略图下标（本地状态，无后端字段）
  int _style = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final p = await _svc.profile();
      if (mounted) {
        setState(() {
          _profile = p;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    final dark = context.v2IsDark;

    return Scaffold(
      backgroundColor: dark ? _kGradBottomDark : _kGradBottom,
      body: LayoutBuilder(
        builder: (ctx, cons) {
          final top = MediaQuery.paddingOf(ctx).top;
          final bottomSafe = MediaQuery.paddingOf(ctx).bottom;
          return SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: dark
                      ? const [_kGradTopDark, _kGradBottomDark]
                      : const [_kGradTop, _kGradBottom],
                ),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                    minHeight: math.max(0, cons.maxHeight - top - bottomSafe)),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                          painter: _DoodlePainter(
                              dark ? Colors.white24 : Colors.white,
                              dark ? Colors.black26 : const Color(0xFF8FBF7F))),
                    ),
                    Padding(
                      padding: EdgeInsets.only(
                          top: top, bottom: 24 * s + bottomSafe),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _header(context, t, s),
                          SizedBox(height: _kHeaderGap * s),
                          _body(context, t, s),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // --------------------------------------------------------------------------
  // 顶部：标题 + 圆形关闭按钮（∅45.3，右缘距屏右 21.0；× 与标题同色 #0C0D12）
  // --------------------------------------------------------------------------
  Widget _header(BuildContext context, _Tr t, double s) {
    final dark = context.v2IsDark;
    final ink = dark ? Colors.white : _kTitleInk;
    return SizedBox(
      height: _kHeaderH * s,
      child: Stack(
        children: [
          Center(
            child: Text(
              t('myQrTitle'),
              maxLines: 1,
              style: TextStyle(
                fontSize: _kTitleSize * s,
                fontWeight: FontWeight.w600,
                height: 1.0,
                color: ink,
              ),
            ),
          ),
          Positioned(
            right: 21.0 * s,
            top: 0,
            bottom: 0,
            child: Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).maybePop(),
                child: Container(
                  width: 45.3 * s,
                  height: 45.3 * s,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: dark ? const Color(0xFF2C2C2E) : Colors.white,
                  ),
                  child: Icon(Icons.close_rounded,
                      size: 24 * s,
                      color: dark ? Colors.white : _kCloseFg),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, _Tr t, double s) {
    if (_loading && _profile == null) {
      return Padding(
        padding: EdgeInsets.only(top: 120 * s),
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_failed && _profile == null) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: 30 * s, vertical: 60 * s),
        child: Column(
          children: [
            Text(t('mqLoadFailed'),
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 17 * s,
                    color: context.v2IsDark
                        ? Colors.white70
                        : const Color(0xFF444444))),
            SizedBox(height: 16 * s),
            GestureDetector(
              onTap: _load,
              child: Container(
                padding: EdgeInsets.symmetric(
                    horizontal: 26 * s, vertical: 12 * s),
                decoration: BoxDecoration(
                  color: context.v2ActionBg,
                  borderRadius: BorderRadius.circular(22 * s),
                ),
                child: Text(t('mqRetry'),
                    style: TextStyle(
                        fontSize: 17 * s,
                        fontWeight: FontWeight.w600,
                        color: context.v2ActionFg)),
              ),
            ),
          ],
        ),
      );
    }

    final p = _profile ?? const {};
    final name = (p['nickname']?.toString().trim().isNotEmpty ?? false)
        ? p['nickname'].toString().trim()
        : t('myQrDefaultName');
    final account = p['account']?.toString() ?? '';
    final avatar = p['avatar']?.toString() ?? '';
    final signature = p['signature']?.toString().trim() ?? '';
    final id = p['id']?.toString() ?? '';
    final qrData = 'chatpulse://user?uid=$id&name=${Uri.encodeComponent(name)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _bigCard(context, t, s,
            name: name,
            account: account,
            avatar: avatar,
            // 卡内灰字 = 用户真实签名；没写签名时给中性占位（不伪造数据）
            subtitle: signature.isEmpty ? t('mqNoSignature') : signature,
            qrData: qrData),
        SizedBox(height: 16.5 * s),
        _stylePanel(context, t, s, qrData),
        SizedBox(height: 13.5 * s),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: _kSaveX * s),
          child: SizedBox(
            width: _kSaveW * s,
            height: _kSaveH * s,
            child: ElevatedButton(
              onPressed: _saving ? null : _saveQr,
              style: ElevatedButton.styleFrom(
                backgroundColor: context.v2ActionBg,
                foregroundColor: context.v2ActionFg,
                disabledBackgroundColor:
                    context.v2ActionBg.withValues(alpha: 0.6),
                disabledForegroundColor: context.v2ActionFg,
                elevation: 0,
                shadowColor: Colors.transparent,
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(_kSaveH / 2 * s)),
              ),
              child: _saving
                  ? SizedBox(
                      width: 22 * s,
                      height: 22 * s,
                      child: CircularProgressIndicator(
                          strokeWidth: 2 * s, color: context.v2ActionFg),
                    )
                  : Text(t('mqSaveQr'),
                      style: TextStyle(
                          fontSize: 20 * s,
                          fontWeight: FontWeight.w600,
                          height: 1.0,
                          letterSpacing: 0.2)),
            ),
          ),
        ),
        SizedBox(height: 31.3 * s),
        _bottomScanLabel(context, t, s),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // 白色大卡
  // --------------------------------------------------------------------------
  Widget _bigCard(
    BuildContext context,
    _Tr t,
    double s, {
    required String name,
    required String account,
    required String avatar,
    required String subtitle,
    required String qrData,
  }) {
    final dark = context.v2IsDark;
    final cardBg = dark ? const Color(0xFF1C1C1E) : Colors.white;
    final nameColor = dark ? const Color(0xFFF2F2F7) : const Color(0xFF0C0D12);
    final subColor = dark ? const Color(0xFF98989F) : _kSubGrey;
    final pillBg = dark ? const Color(0xFF2C2C2E) : _kPillFill;
    final boxBorder = dark ? const Color(0xFF3A3A3C) : _kQrBoxBorder;
    // 当前选中的二维码样式（主图与缩略图共用 _thumbs 这一份定义）
    final st = _thumbs[_style];

    const photoD = _kAvatarD - 2 * (_kAvatarRing + _kAvatarGap); // 67.1

    Widget inner = RepaintBoundary(
      key: _cardKey,
      child: Container(
        width: _kCardW * s,
        // ⚠️ 高度用 **minHeight 约束 + 内容自适应**，不写死 height。
        // 1260 口径下卡内内容自然高 577.1（§12.5），卡高实测 604.8 ⇒ minHeight 取 604.8：
        // 内容与约束一致，即使字体度量略有出入也只会让卡片多长几个 px，不会裁切、不会溢出。
        // 同理**不可能**出现 556 参考图那种「BOTTOM OVERFLOWED BY 27 PIXELS」。
        constraints: BoxConstraints(minHeight: _kCardH * s),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(_kCardR * s),
        ),
        // 头像骑在卡顶：中心距卡顶 16.5 ⇒ 内容从头像下缘开始
        padding: EdgeInsets.only(top: _kCardPadTop * s),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: _kGapSub * s),
            Text(subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 20.5 * s,
                    fontWeight: FontWeight.w400,
                    height: 1.0,
                    color: subColor)),
            SizedBox(height: _kGapName * s),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 12 * s),
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 26 * s,
                      fontWeight: FontWeight.w600,
                      height: 1.0,
                      color: nameColor)),
            ),
            SizedBox(height: _kGapPill * s),
            // 账号胶囊（灰底）：**横竖两个方向都紧贴内容**，不再用固定高/最小宽。
            // 第十二批用户反馈「账号的背景灰色太长了」：上一版 `height: _kPillH(36.3)`
            // 把灰底上下各撑出 ≈9.15 空白（文字行盒只有 18.0）——撑高的是**这层固定高**。
            // 改为上下 padding 6.5 ⇒ 灰底高 = 18.0 + 13 = 31.0（缩短 5.3、不裁字，
            // Text 无 clipBehavior 不会裁 ink），圆头用 999 全胶囊，高度随内容自适应。
            // 第十八批再修横向版同款问题：去掉 `minWidth _kPillW 128.3` 与
            // `alignment: Alignment.center`（后者在有界约束下会把 Container 撑到卡宽），
            // 灰底宽 = 文字 intrinsic 宽 + 16×2，由 Column 交叉轴居中定位。
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: 16 * s, vertical: 6.5 * s),
              decoration: BoxDecoration(
                color: pillBg,
                borderRadius: BorderRadius.circular(999 * s),
              ),
              child: Text(account.isEmpty ? '-' : '@$account',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      // 字号 18.0：1260 图胶囊内 `@uyd6gzyc` ink 高 18.00（含 'd' 升部与
                      // 'g'/'y' 降部 ≈ 1.0 em）⇒ F ≈ 18.0。第六批的 20.5 是错抄。
                      fontSize: 18.0 * s,
                      fontWeight: FontWeight.w400,
                      height: 1.0,
                      color: subColor)),
            ),
            SizedBox(height: _kGapQr * s),
            // 二维码白框：297.7×297.7（**正方形**）r26 细描边，内部二维码 260.0
            Container(
              width: _kQrBoxW * s,
              height: _kQrBoxH * s,
              decoration: BoxDecoration(
                color: dark ? const Color(0xFF1C1C1E) : Colors.white,
                borderRadius: BorderRadius.circular(_kQrBoxR * s),
                border: Border.all(color: boxBorder, width: 1 * s),
              ),
              alignment: Alignment.center,
              child: QrImageView(
                data: qrData.isEmpty ? 'chatpulse://user' : qrData,
                version: QrVersions.auto,
                size: _kQrInner * s,
                backgroundColor: Colors.transparent,
                padding: EdgeInsets.zero,
                eyeStyle: QrEyeStyle(
                    eyeShape: st.eyeShape,
                    color: dark ? st.eyeDark : st.eye),
                dataModuleStyle: QrDataModuleStyle(
                    dataModuleShape: st.moduleShape,
                    color: dark ? st.moduleDark : st.module),
              ),
            ),
            SizedBox(height: _kGapHandle * s),
            Text('@${account.toUpperCase()}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 29 * s,
                    fontWeight: FontWeight.w600,
                    height: 1.0,
                    color: _kHandleGreen)),
            SizedBox(height: _kGapAddMe * s),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.qr_code_2,
                    size: 17 * s, color: dark ? _kScanGrey : _kScanGrey),
                SizedBox(width: 6 * s),
                Text(t('mqAddMeByQr'),
                    style: TextStyle(
                        fontSize: 17.5 * s,
                        fontWeight: FontWeight.w400,
                        height: 1.0,
                        color: _kScanGrey)),
              ],
            ),
          ],
        ),
      ),
    );

    // 头像：绿环 + 白圈 + 照片（中心距卡顶 16.5）
    inner = Stack(
      clipBehavior: Clip.none,
      children: [
        inner,
        Positioned(
          top: (_kAvatarCY - _kAvatarD / 2) * s,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              width: _kAvatarD * s,
              height: _kAvatarD * s,
              decoration: const BoxDecoration(
                  shape: BoxShape.circle, color: _kEyeGreen),
              alignment: Alignment.center,
              child: Container(
                width: (_kAvatarD - 2 * _kAvatarRing) * s,
                height: (_kAvatarD - 2 * _kAvatarRing) * s,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dark ? const Color(0xFF1C1C1E) : Colors.white,
                ),
                alignment: Alignment.center,
                child: ClipOval(
                  child: AppAvatar(
                    url: avatar,
                    name: name,
                    size: photoD * s,
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: _loading
              ? Padding(
                  padding: EdgeInsets.all(10 * s),
                  child: SizedBox(
                      width: 16 * s,
                      height: 16 * s,
                      child: const CircularProgressIndicator(strokeWidth: 2)),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );

    // 不再套 SizedBox(height: _kCardH)：卡片高度由自身 minHeight 约束 + 内容决定，
    // 避免「固定高 < 内容高」导致的 RenderFlex overflow（556 参考图里溢出 27 px）。
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: _kCardX * s),
      child: inner,
    );
  }

  // --------------------------------------------------------------------------
  // 全宽白色面板：标题 + 蓝色圆钮 + 样式缩略图
  // --------------------------------------------------------------------------
  Widget _stylePanel(
      BuildContext context, _Tr t, double s, String qrData) {
    final dark = context.v2IsDark;
    final panelBg = dark ? const Color(0xFF1C1C1E) : Colors.white;
    final ink = dark ? const Color(0xFFF2F2F7) : const Color(0xFF0C0D12);

    return Container(
      // 内容自适应：minHeight 而非固定高 —— 缩略图行若有增长，面板跟着长，
      // 不再出现固定高 < 内容高的 RenderFlex overflow（参考 232.5 为 1260 基准值）。
      constraints: BoxConstraints(minHeight: (_kPanelBottom - _kPanelTop) * s),
      decoration: BoxDecoration(
        color: panelBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(_kPanelR * s)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: 22.7 * s),
          Padding(
            padding: EdgeInsets.only(left: 24.7 * s, right: 23.5 * s),
            child: Row(
              children: [
                Expanded(
                  child: Text(t('epQrCode'),
                      style: TextStyle(
                          fontSize: 23 * s,
                          fontWeight: FontWeight.w600,
                          height: 1.0,
                          color: ink)),
                ),
                // 右侧小圆钮 ∅47.7（图标为**月亮 + 左下圆点**的描边图形，
                // 裁图 `_z_blue.png` + ASCII 逐像素确认；旧版画的音符是错的）
                Semantics(
                  label: t('mqStylePicker'),
                  button: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(
                        () => _style = (_style + 1) % _thumbs.length),
                    child: Container(
                      width: 47.7 * s,
                      height: 47.7 * s,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: dark ? const Color(0xFF2C2C2E) : _kIconBtnBg,
                      ),
                      child: Center(
                        child: SizedBox(
                          width: 22 * s,
                          height: 23.3 * s,
                          child: CustomPaint(
                              painter: _MoonDotPainter(_kIconBtnFg)),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 24.3 * s),
          SizedBox(
            height: _kThumbH * s,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              padding: EdgeInsets.only(
                  left: _kThumbStart * s, right: 20 * s),
              itemCount: _thumbs.length,
              separatorBuilder: (_, __) => SizedBox(width: _kThumbGap * s),
              itemBuilder: (ctx, i) => _thumb(context, s, i, qrData),
            ),
          ),
        ],
      ),
    );
  }

  Widget _thumb(BuildContext context, double s, int i, String qrData) {
    final item = _thumbs[i];
    final selected = _style == i;
    // 选中态：3.4 粗蓝环，环与缩略图之间留 6.4 间隙（实测外径 111）
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _style = i),
      child: Container(
        width: _kThumbW * s,
        height: _kThumbH * s,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular((_kThumbR + 6.4) * s),
          border: selected
              ? Border.all(color: _kSelRing, width: 3.4 * s)
              : Border.all(color: Colors.transparent, width: 3.4 * s),
        ),
        padding: EdgeInsets.all(6.4 * s),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_kThumbR * s),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: item.gradient,
            ),
          ),
          child: Column(
            children: [
              SizedBox(height: 6 * s),
              Container(
                width: _kInnerSq * s,
                height: _kInnerSq * s,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14 * s),
                ),
                alignment: Alignment.center,
                child: QrImageView(
                  data: qrData.isEmpty
                      ? 'chatpulse://user?style=$i'
                      : '$qrData&style=$i',
                  version: QrVersions.auto,
                  size: 38 * s,
                  backgroundColor: Colors.transparent,
                  padding: EdgeInsets.zero,
                  eyeStyle: QrEyeStyle(
                      eyeShape: item.eyeShape, color: item.eye),
                  dataModuleStyle: QrDataModuleStyle(
                      dataModuleShape: item.moduleShape, color: item.module),
                ),
              ),
              const Spacer(),
              // 余下空间全部给 emoji：Expanded + FittedBox(scaleDown) 双保险。
              // 成因（用户真机 556×988 截图实测）：部分机型 emoji 回退字体行盒
              // ≈1.21em（30×1.21=36.3），而 6+53+8 之后只剩 31.2 ⇒ 恰好溢出 5.1；
              // Expanded 使 Column 结构上不可能 overflow，FittedBox 兜底等比缩小。
              Expanded(
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(item.emoji,
                        maxLines: 1,
                        style: TextStyle(fontSize: 30 * s, height: 1.0)),
                  ),
                ),
              ),
              SizedBox(height: 8 * s),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomScanLabel(
      BuildContext context, _Tr t, double s) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.qr_code_scanner_rounded,
            size: 20.4 * s, color: _kBottomGreen),
        SizedBox(width: 13.4 * s),
        Text(t('mqScanQr'),
            style: TextStyle(
                fontSize: 20.4 * s,
                fontWeight: FontWeight.w600,
                height: 1.0,
                color: _kBottomGreen)),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // 保存二维码 → 相册（RepaintBoundary 截图 → PNG → ImageGallerySaverPlus）
  // --------------------------------------------------------------------------
  Future<void> _saveQr() async {
    final t = AppLocalizations.of(context).t;
    if (kIsWeb) {
      AppDialogs.toast(context, t('mqSaveFailed'));
      return;
    }
    setState(() => _saving = true);
    try {
      final boundary =
          _cardKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) {
        AppDialogs.toast(context, t('mqSaveFailed'));
        return;
      }
      final ui.Image img = await boundary.toImage(pixelRatio: 3);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        if (mounted) AppDialogs.toast(context, t('mqSaveFailed'));
        return;
      }
      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          await Permission.storage.request();
        } catch (_) {
          // Android 13+ 无需存储权限即可写 MediaStore，权限异常不阻断
        }
      }
      await ImageGallerySaverPlus.saveImage(
          Uint8List.fromList(data.buffer.asUint8List()),
          quality: 100,
          name: 'chatpulse_qr_${DateTime.now().millisecondsSinceEpoch}');
      if (mounted) AppDialogs.toast(context, t('mqSaved'));
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('mqSaveFailed'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// 面板右侧圆钮里的图形：**月牙（凹面朝左下）+ 左下圆点**。
///
/// 参考图裁切 `_z_blue.png` 与 ASCII 逐像素确认：整体 ink 22.0×23.3，
/// 主体是「大圆 − 偏左下圆」得到的月牙，左下另有一个圆点被月牙的凹口包住。
/// Material 里没有完全对应的图标（`music_note_rounded` 是完全错的），故本地绘制。
class _MoonDotPainter extends CustomPainter {
  _MoonDotPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final p = Paint()
      ..color = color
      ..isAntiAlias = true;
    final body = Path()
      ..addOval(Rect.fromCircle(
          center: Offset(w * 0.60, size.height * 0.42), radius: w * 0.40));
    final bite = Path()
      ..addOval(Rect.fromCircle(
          center: Offset(w * 0.34, size.height * 0.70), radius: w * 0.35));
    canvas.drawPath(
        Path.combine(ui.PathOperation.difference, body, bite), p);
    canvas.drawCircle(Offset(w * 0.22, size.height * 0.78), w * 0.20, p);
  }

  @override
  bool shouldRepaint(covariant _MoonDotPainter old) => old.color != color;
}

/// 样式缩略图配色（截图：前两个绿色系、第三个蓝紫系；装饰图案分别为房子 / 小鸡 / 雪人）
///
/// **单一数据源**：缩略图与主二维码共用同一份定义 —— 眼形状 / 模块形状 /
/// 眼色 / 模块色 / 深浅两套值全部只在这里写一遍。旧版缩略图一套色、
/// 主图写死 `_kEyeGreen/_kModuleGreen`，导致用户在「样式」里点了另外两套
/// 主图却不变（假交互），本轮接通。
///
/// 三套的取值依据：
///  * style 0 = 1260 参考图实测（眼 `#69B35A` / 模块 `#2C9779`，全方形）——主图默认态；
///  * style 1 / 2 的主图形态参考图未展示，模块色按缩略图实测（`#3EA34D` / `#4A90D9`），
///    形状用 qr_flutter 4.1 里仅有的 square / circle 两档做区分；
///  * 深色模式在深卡（`#1C1C1E`）上用同色相提亮一档的值，保证对比度。
class _ThumbStyle {
  final List<Color> gradient;
  final String emoji;
  final QrEyeShape eyeShape;
  final QrDataModuleShape moduleShape;
  final Color eye; // 浅色模式：定位图案
  final Color module; // 浅色模式：数据模块
  final Color eyeDark; // 深色模式：定位图案
  final Color moduleDark; // 深色模式：数据模块
  const _ThumbStyle(this.gradient, this.emoji,
      {required this.eyeShape,
      required this.moduleShape,
      required this.eye,
      required this.module,
      required this.eyeDark,
      required this.moduleDark});
}

const List<_ThumbStyle> _thumbs = [
  // 实测渐变 #DDF1B6→#BDE3AF / #DBF2C6→#C4E7BE / #DDEEFF→#D1E4FF
  _ThumbStyle([Color(0xFFDDF1B6), Color(0xFFBDE3AF)], '🏠',
      eyeShape: QrEyeShape.square,
      moduleShape: QrDataModuleShape.square,
      eye: Color(0xFF69B35A),
      module: Color(0xFF2C9779),
      eyeDark: Color(0xFF8BD07E),
      moduleDark: Color(0xFF57C4A0)),
  _ThumbStyle([Color(0xFFDBF2C6), Color(0xFFC4E7BE)], '🐤',
      eyeShape: QrEyeShape.circle,
      moduleShape: QrDataModuleShape.circle,
      eye: Color(0xFF3EA34D),
      module: Color(0xFF3EA34D),
      eyeDark: Color(0xFF74C57F),
      moduleDark: Color(0xFF74C57F)),
  _ThumbStyle([Color(0xFFDDEEFF), Color(0xFFD1E4FF)], '⛄',
      eyeShape: QrEyeShape.square,
      moduleShape: QrDataModuleShape.circle,
      eye: Color(0xFF4A90D9),
      module: Color(0xFF4A90D9),
      eyeDark: Color(0xFF84B8EC),
      moduleDark: Color(0xFF84B8EC)),
];

/// 背景涂鸦：白色描边气泡/圆圈 + 少量深绿描边，位置按屏宽/高取比例，随尺寸缩放。
class _DoodlePainter extends CustomPainter {
  _DoodlePainter(this.light, this.accent);

  /// 白色描边（截图里最显眼的一层）
  final Color light;

  /// 深绿描边（更淡的一层）
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, w * 0.004)
      ..strokeCap = StrokeCap.round;

    void bubble(double fx, double fy, double fw, double fh, double alpha,
        {bool tail = true}) {
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(fx * w, fy * h, fw * w, fh * w),
        Radius.circular(fh * w * 0.45),
      );
      canvas.drawRRect(r, p..color = light.withValues(alpha: alpha));
      if (tail) {
        final path = Path()
          ..moveTo(fx * w + fw * w * 0.22, fy * h + fh * w)
          ..lineTo(fx * w + fw * w * 0.16, fy * h + fh * w + fh * w * 0.5)
          ..lineTo(fx * w + fw * w * 0.48, fy * h + fh * w);
        canvas.drawPath(path, p);
      }
    }

    void circle(double fx, double fy, double fr, double alpha) {
      canvas.drawCircle(Offset(fx * w, fy * h), fr * w,
          p..color = light.withValues(alpha: alpha));
    }

    // ---- 白色层（按截图分布密度铺，位置为视觉近似） ----
    circle(0.47, 0.055, 0.065, 0.55);
    circle(0.155, 0.125, 0.05, 0.30);
    bubble(0.06, 0.105, 0.10, 0.062, 0.42);
    bubble(0.78, 0.108, 0.11, 0.066, 0.45);
    circle(0.93, 0.20, 0.055, 0.30);
    bubble(0.02, 0.245, 0.085, 0.055, 0.35);
    bubble(0.86, 0.255, 0.095, 0.058, 0.32);
    circle(0.30, 0.315, 0.045, 0.25);
    bubble(0.09, 0.40, 0.09, 0.055, 0.30);
    bubble(0.88, 0.44, 0.10, 0.06, 0.35);
    circle(0.06, 0.545, 0.05, 0.28);
    bubble(0.83, 0.56, 0.11, 0.065, 0.32);
    circle(0.50, 0.665, 0.06, 0.30);
    bubble(0.04, 0.70, 0.095, 0.058, 0.30);
    bubble(0.87, 0.735, 0.10, 0.06, 0.32);
    circle(0.20, 0.80, 0.045, 0.22);
    bubble(0.10, 0.845, 0.10, 0.06, 0.35);
    bubble(0.80, 0.90, 0.11, 0.066, 0.35);
    circle(0.62, 0.945, 0.05, 0.25);
    bubble(0.02, 0.965, 0.09, 0.055, 0.30);

    // ---- 深绿层（截图里很淡的一层，压在白线之间） ----
    p.color = accent.withValues(alpha: 0.28);
    canvas.drawArc(
        Rect.fromLTWH(-0.10 * w, 0.03 * h, 0.55 * w, 0.10 * h),
        3.4,
        1.4,
        false,
        p);
    canvas.drawArc(
        Rect.fromLTWH(0.62 * w, 0.055 * h, 0.50 * w, 0.09 * h), 4.6, 1.2, false, p);
    canvas.drawArc(
        Rect.fromLTWH(-0.14 * w, 0.55 * h, 0.42 * w, 0.08 * h), 5.0, 1.1, false, p);
    canvas.drawArc(
        Rect.fromLTWH(0.78 * w, 0.62 * h, 0.36 * w, 0.07 * h), 3.2, 1.3, false, p);
    canvas.drawArc(
        Rect.fromLTWH(-0.06 * w, 0.90 * h, 0.34 * w, 0.07 * h), 3.6, 1.2, false, p);
  }

  @override
  bool shouldRepaint(covariant _DoodlePainter old) =>
      old.light != light || old.accent != accent;
}
