import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/call_service.dart';
import '../services/feature_flags.dart';
import '../services/friend_service.dart';
import '../services/local_store.dart';
import '../services/settings_service.dart';
import '../services/update_service.dart';
import '../services/user_cache.dart';
import '../services/wide_layout_store.dart';
import '../services/wallet_store.dart';
import '../services/ws_service.dart';
import '../widgets/lang_picker.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/v2_kit.dart';
import '../widgets/v2_seal_badge.dart';
import '../widgets/v2_tags.dart'; // CertBadge.isKefu（客服判定公共口径）
import 'about_page.dart';
import 'chat_settings_page.dart';
import 'data_storage_page.dart';
import 'device_page.dart';
import 'edit_profile_page.dart';
import 'favorites_page.dart';
import 'home_shell.dart';
import 'login_page.dart';
import 'my_qr_page.dart';
import 'notification_settings_page.dart';
import 'privacy_settings_page.dart';
import 'system_settings_page.dart';
import 'wallet_page.dart';

/// 我的（设计稿：顶部蓝色涂鸦插画 + 头像/昵称 + 白色圆角主体 + 分组设置卡片）
///
/// 布局基准与参考截图一致：本页**不放 AppBar、不用 SafeArea**（由 HomeShell 直接
/// 铺满全屏），蓝色插画因此能延伸到状态栏之下（沉浸式）；所有纵向基准以
/// **屏幕顶部为 0**。尺寸取自 UI-ref 的像素级实测（截图逻辑宽 420 / DPR 3），
/// 横向尺寸乘 [v2Scale] 等比缩放到当前屏宽，让窄屏上「元素与屏宽的比例」
/// 与截图一致。
class MePage extends StatefulWidget {
  const MePage({super.key});

  @override
  State<MePage> createState() => _MePageState();
}

/// 一行设置项：彩色图标块 + 标题（+ 可选副标题）+ 右侧箭头。
class _MeRowSpec {
  const _MeRowSpec({
    required this.fill,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.trailing,
  });

  final Color fill; // 图标块填充色（截图实测）
  final IconData icon; // 块内白色图形
  final String title;
  final String? subtitle;
  final Widget? trailing; // 行尾信息（余额 / 邀请码等）
  final VoidCallback onTap;
}

class _MePageState extends State<MePage> {
  // ===== 纵向基准（逻辑 px，屏幕顶部为 0，截图实测）=====
  static const double _blueH = 413.7; // 蓝底块高（含 sheet 圆角外的角缺口）
  static const double _sheetTop = 387.7; // 主体 sheet 顶边
  static const double _sheetRadius = 32.8; // sheet 顶角圆角
  static const double _sheetTopPad =
      32.0; // sheet 顶 → 第一张卡片（2026-09-15 紧凑：41→32）
  static const double _cardGap = 24.0; // 卡与卡之间（2026-09-15 紧凑：32→24）
  static const double _versionGap = 32.0; // 最后一张卡 → 版本号（46→32）
  static const double _bottomPad = 120.0; // 底部留白：让版本号能滚到浮动 Tab 胶囊上方

  // ===== 卡片 / 行（逻辑 px）=====
  static const double _cardGutter = 20.7; // 卡片左右外边距
  static const double _cardRadius = 23.0;
  static const double _rowVPad = 14.5; // 行上下内边距
  static const double _iconLeft = 17.7; // 图标块距卡片左缘
  static const double _iconBox = 44.0;
  static const double _iconRadius = 10.0;
  static const double _textLeft = 101.0; // 标题/副标题 ink 左缘
  static const double _chevronGutter = 20.0; // chevron 图标框右缘 → 卡片右缘
  static const double _sepIndent = 79.0; // 分隔线左内缩（距卡片左缘）

  // ===== 色值（截图实测）=====
  static const Color _blueTop = Color(0xFF75BEF5);
  static const Color _blueBottom = Color(0xFF4FA1E1);
  static const Color _pageBg = Color(0xFFF6F7F9);
  static const Color _cardBg = Color(0xFFFFFFFF);
  static const Color _titleInk = Color(0xFF141926);
  static const Color _subInk = Color(0xFFA0A4AD);
  static const Color _chevronInk = Color(0xFF9EA3AE);
  static const Color _separator = Color(0xFFE5E5E5);
  static const Color _versionInk = Color(0xFFA0A4AE);
  static const Color _btnFill = Color(0xFFF4F9FF); // 顶部两个按钮填充（非纯白）
  static const Color _btnInk = Color(0xFF213655);
  static const Color _danger = Color(0xFFFF3B2F);

  // 13 行入口的图标块填充色（iOS 系统色系，截图实测）
  static const Color _orange = Color(0xFFFF9501);
  static const Color _indigo = Color(0xFF5855D6);
  static const Color _gray = Color(0xFF8F8E93);
  static const Color _green = Color(0xFF34C85A);
  static const Color _nearBlack = Color(0xFF0C0D12);
  static const Color _purple = Color(0xFFAF52DE);
  static const Color _blue = Color(0xFF007AFF);

  final _svc = FriendService();
  final _api = ApiClient.instance;
  Map<String, dynamic>? _profile;
  String _inviteCode = ''; // 我的邀请码（用户中心展示 + 点击复制）
  String _brandName = ''; // 底部版本号里的品牌名（读后台 authConfig 本地缓存）

  @override
  void initState() {
    super.initState();
    // 立刻用全局身份缓存垫底：登录后消息列表/通讯录已拉过我的资料并写入 UserCache，
    // 这里直接显示，避免 profile 接口偶发抖动时"我的"页闪/卡在"未登录"。
    final ident = UserCache.myProfileData;
    if (ident != null) _profile = ident;
    _loadCachedProfile();
    _loadCachedBrand();
    _load();
    _refreshBalance();
    // 功能开关（零钱/邀请码）：后台可实时开关，进入本页刷新一次
    FeatureFlags.instance.load();
  }

  /// 先读本地缓存的资料，首帧直接渲染昵称/头像，
  /// 修复「快速切到'我的'先显示'未登录'/默认头像，接口回来才变」。
  /// 网络返回后再覆盖刷新（缓存只做展示兜底，不阻断更新）。
  Future<void> _loadCachedProfile() async {
    try {
      final raw = await _api.readPref('profile');
      if (raw == null || raw.isEmpty || !mounted) return;
      final cached = jsonDecode(raw);
      if (cached is Map<String, dynamic> &&
          _profile == null &&
          (cached['id']?.toString() ?? '').isNotEmpty) {
        setState(() => _profile = cached);
      }
    } catch (_) {}
  }

  /// 底部版本号里的品牌名：与「关于」页同源（后台 authConfig）。
  /// 先读本地缓存垫底；**缓存没有（用户没进过关于页）时直连 /auth/config 拉一次
  /// 并落盘**——以前只读缓存，没进过「关于」页就一直回落 ChatPulse（二十七批需求5）。
  Future<void> _loadCachedBrand() async {
    try {
      final raw = await _api.readPref('authConfig');
      if (raw != null && raw.isNotEmpty && mounted) {
        final d = jsonDecode(raw);
        if (d is Map) {
          final b = (d['brandName'] ?? d['appName'] ?? '').toString();
          if (b.isNotEmpty) setState(() => _brandName = b);
        }
      }
    } catch (_) {}
    if (!mounted || _brandName.isNotEmpty) return; // 缓存已命中就不打接口
    try {
      final r = await _api.get('/api/v1/auth/config');
      final d =
          (r.data as Map<String, dynamic>)['data'] as Map<String, dynamic>? ??
              {};
      final b = (d['brandName'] ?? d['appName'] ?? '').toString();
      if (!mounted) return;
      if (b.isNotEmpty) setState(() => _brandName = b);
      if (d.isNotEmpty) {
        unawaited(_api.writePref('authConfig', jsonEncode(d))); // 与「关于」页同源落盘
      }
    } catch (_) {}
  }

  /// 钱包余额走后端（"我的钱包"行 trailing 展示）。
  /// B-20：以前只在 initState 拉一次，而本页常驻在 HomeShell 的 _pages 里不销毁，
  /// 后台给用户加了余额后 App 里永远是旧值。改为可重复调用（切回"我的" tab 时会触发）。
  Future<void> _refreshBalance() async {
    await WalletStore.instance.refresh();
    if (mounted) setState(() {});
  }

  /// 下拉刷新：重新拉资料 + 余额。
  /// 主链路是服务端 WS 主动推送（B-24），这里只是给用户一个"手动刷新"的入口，
  /// 同时也兜住 WS 断开 / 推送丢失的情况。
  Future<void> _onPullRefresh() async {
    await Future.wait([_load(), _refreshBalance()]);
  }

  Future<void> _load({int retry = 0}) async {
    try {
      final p = await _svc.profile();
      if (mounted) {
        setState(() {
          _profile = p;
          _inviteCode = p['myInviteCode']?.toString() ?? '';
        });
        // 同步全局身份缓存：供失败兜底，也避免其他页面再拉一遍
        UserCache.setMyProfile(p);
        // 资料写入本地缓存，下次进 App / 切 tab 首帧即有昵称头像
        unawaited(_api.writePref('profile', jsonEncode(p)));
      }
    } catch (e) {
      // 首次请求偶发超时（服务端瞬时慢，与登录/进群超时同款）→ 自动重试，
      // 否则"我的"页会一直显示"未登录"，直到手动下拉刷新
      if (retry < 2 && mounted) {
        await Future.delayed(Duration(milliseconds: 600 * (retry + 1)));
        if (!mounted) return;
        return _load(retry: retry + 1);
      }
      // 重试耗尽也不应卡在"未登录"：用全局身份缓存（消息列表/通讯录已拉过）兜底
      if (mounted) {
        final fallback = UserCache.myProfileData;
        if (fallback != null) setState(() => _profile = fallback);
      }
    }
  }

  Future<void> _logout() async {
    final t = AppLocalizations.of(context).t;
    final confirm = await AppDialogs.confirm(
      context,
      title: t('meLogoutTitle'),
      message: t('meLogoutMsg'),
      confirmText: t('meLogoutConfirm'),
      danger: true,
    );
    if (confirm != true) return;
    // 关键：退出登录必须清干净全局态，否则再登录会白屏 / 复用上一个账号的连接。
    // 1) CallService：清通话态 + 关悬浮小窗 + 释放 TRTC 引擎 + 清空 _myId
    // 2) GlobalWs：断开 WS 并清空监听列表（原连接带的是旧 token）
    // 两步都套 3s 超时兜底（B-18）：局部清理失败/卡住也必须把用户送到登录页，
    // 不能出现"点了退出登录没反应"。
    await CallService.instance
        .resetSession()
        .timeout(const Duration(seconds: 3), onTimeout: () {});
    GlobalWs.instance.close();
    // 这里不要再单独 close 一次浮窗：resetSession 已经在关了，
    // 重复调用反而会撞上"插件不回 result → await 永久挂起"的坑（B-18）。
    // ApiClient.logout 内部已改成"先清本地 token，再通知服务端"，
    // 所以这里压到 2s 也只是放弃服务端通知，不影响本地已登出。
    await _api.logout().timeout(const Duration(seconds: 2), onTimeout: () {});
    UserCache.clear(); // 清用户信息缓存：换账号登录不能复用上一个会话的数据
    // 钱包：清内存余额（磁盘快照已由 logout→LocalStore.clearUserData 清）。
    // 不清的话换账号登录后、refresh() 返回前会短暂显示上一个人的余额。
    WalletStore.instance.reset();
    if (!mounted) return;
    // 用 pushAndRemoveUntil 清栈，避免回退键还能回到已登出的首页
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  // ===== 多账号切换（Telegram 式）=====

  /// 弹出账号切换面板：列出本机记住的账号，点一下切换，可移除单个账号，可添加账号。
  Future<void> _openAccountSwitcher() async {
    final accounts = await _api.readAccounts();
    final currentId = (_profile?['id'] ?? UserCache.myProfileData?['id'])
        ?.toString() ??
        '';
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AccountSwitcherSheet(
        accounts: accounts,
        currentId: currentId,
        onSwitch: (id) async {
          await _doSwitchAccount(id);
        },
        onRemove: (id) async {
          await _api.removeAccount(id);
        },
        onAdd: () async {
          // 添加账号 = 回登录页（保留账号列表），登录新账号后自动入列
          await _doLogoutToLogin();
        },
      ),
    );
  }

  /// 执行切换：清全局态 → 写目标 token → 重进主界面（HomeShell 重新 init）。
  Future<void> _doSwitchAccount(String id) async {
    if (!mounted) return;
    // 1) 清干净当前账号的全局态（复用登出清理，避免串号）
    await CallService.instance
        .resetSession()
        .timeout(const Duration(seconds: 3), onTimeout: () {});
    GlobalWs.instance.close();
    UserCache.clear();
    WalletStore.instance.reset();
    unawaited(LocalStore.clearUserData());
    // 2) 写目标账号 token（内部先静默续期）
    final target = await _api.switchToAccount(id);
    if (!mounted) return;
    if (target == null) return;
    // 3) 重进主界面（HomeShell.initState 会重连 WS、重拉数据、重绑推送）
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeShell()),
      (route) => false,
    );
  }

  /// 添加账号：登出到登录页（保留账号列表，登录新账号后自动入列）。
  Future<void> _doLogoutToLogin() async {
    await _logout();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // 已登录时绝不应显示"未登录"：优先用本页 profile，再退回全局身份缓存
    // （profile 接口偶发抖动时，消息列表/通讯录早已写入 UserCache，可兜底显示真实昵称）。
    final p = _profile ?? UserCache.myProfileData;
    final name = (p?['nickname']?.toString() ?? '').isNotEmpty
        ? p!['nickname'].toString()
        : t('meNotLoggedIn');
    final account = p?['account']?.toString() ?? '';
    final shortId = p?['shortId']?.toString() ?? '';
    // 靓号标识：short_id 来自后台靓号池（已分配）
    final isVipShort = p?['vipShortId'] == true && shortId.isNotEmpty;
    final pageBg = dark ? Theme.of(context).scaffoldBackgroundColor : _pageBg;

    // 头部高度（2026-09-17 用户指定）：改为「去掉底部导航后剩余高度的一半」。
    // 底部导航 = HomeShell 的浮动 Tab 胶囊（bar 高 83.7*s + 下边距 30*s ≈ 113.7*s）。
    // hv 从目标高度反推（headerH = _blueH * s * hv），内部全部纵向坐标/内容尺寸
    // 继续随 sv = s * hv 等比缩放：任意屏高下蓝底正好占可用区一半，
    // 头像/二维码/编辑按钮/字号随之铺开不重叠（0.40~1.40 防极端屏形挤压/拉伸）。
    final screenH = MediaQuery.sizeOf(context).height;
    final navH = (83.7 + 30) * s;
    final headerH = (screenH - navH) / 2;
    final hv = (headerH / (_blueH * s)).clamp(0.40, 1.40);

    return Scaffold(
      backgroundColor: pageBg,
      // 本页无 AppBar / SafeArea：蓝色插画从 y=0 起铺满（沉浸到状态栏之下），
      // 底部浮动 Tab 胶囊由 HomeShell 用 Stack 盖在上面，所以这里只留出滚动内边距。
      body: RefreshIndicator(
        onRefresh: _onPullRefresh,
        color: scheme.primary,
        backgroundColor: pageBg,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          children: [
            _headerBoard(s, hv, t, name, p, account, shortId, isVipShort),
            // 主体 sheet：与页面同色的圆角容器盖在蓝底上（顶角 R=32.8，露出蓝色角缺口），
            // 上移 (_blueH - _sheetTop) * hv 让 sheet 顶边正好落在 387.7 * hv。
            Transform.translate(
              offset: Offset(0, -(_blueH - _sheetTop) * s * hv),
              child: Container(
                decoration: BoxDecoration(
                  color: pageBg,
                  borderRadius: BorderRadius.vertical(
                      top: Radius.circular(_sheetRadius * s)),
                ),
                child: Column(
                  children: [
                    SizedBox(height: _sheetTopPad * s),
                    // 卡片 A：账号 / 钱包 / 会员 / 通知 / 隐私 / 存储 / 邀请码
                    // 功能开关实时驱动：后台关闭「零钱/邀请码」后立即隐藏对应入口
                    AnimatedBuilder(
                      animation: Listenable.merge([
                        FeatureFlags.instance.walletOn,
                        FeatureFlags.instance.inviteOn,
                      ]),
                      builder: (_, __) => _card(s, dark, [
                        // 完善登录账号（绑手机）：已绑定手机的用户不显示（二十七批需求2）
                        if (!(p?['phone']?.toString() ?? '').trim().isNotEmpty)
                          _MeRowSpec(
                            fill: _danger,
                            icon: Icons.error_outline,
                            title: t('meRowCompleteAccount'),
                            subtitle: t('meSubCompleteAccount'),
                            // 2026-09-14 需求2：由「进账号安全页」改为**直接弹绑定手机号码面板**。
                            // 账号安全页（改登录密码 / 注销账户）入口没丢：仍在「编辑资料」页里。
                            onTap: _showBindPhoneSheet,
                          ),
                        if (FeatureFlags.instance.walletOn.value)
                          _MeRowSpec(
                            fill: _orange,
                            icon: Icons.account_balance_wallet_outlined,
                            title: t('meRowWallet'),
                            // 余额用监听而不是快照：后台改了余额 / 领了红包后不用手动 setState（B-20）
                            trailing: ValueListenableBuilder<double>(
                              valueListenable:
                                  WalletStore.instance.balanceNotifier,
                              builder: (_, v, __) => Text(
                                  '¥ ${WalletStore.instance.fmt(v)}',
                                  style: TextStyle(
                                      fontSize: 16.2 * s,
                                      color: dark
                                          ? scheme.onSurfaceVariant
                                          : _subInk)),
                            ),
                            onTap: _openWallet,
                          ),
                        // VIP 会员入口隐藏（二十七批需求3）：购买页面后期再上，
                        // 恢复时把这块 _MeRowSpec 加回即可。
                        // _MeRowSpec(
                        //   fill: _indigo,
                        //   icon: Icons.workspace_premium_outlined,
                        //   title: t('meRowVip'),
                        //   subtitle: isVipShort
                        //       ? t('vipIdBadge', {'id': shortId})
                        //       : t('meSubVipInactive'),
                        //   onTap: () => _comingSoon(t('meRowVip')),
                        // ),
                        _MeRowSpec(
                          fill: _danger,
                          icon: Icons.notifications_none,
                          title: t('meRowNotify'),
                          // 2026-09-14：原先指向 SystemSettingsPage，现按参考截图
                          // 改为独立的「通知和声音」页（V2 复刻）。
                          onTap: () => _openNotifySettings(),
                        ),
                        _MeRowSpec(
                          fill: _gray,
                          icon: Icons.lock_outline,
                          title: t('meRowPrivacy'),
                          // 2026-09-14 需求6：由「隐私政策全文（PolicyPage）」改为
                          // **V2 复刻的隐私设置页**；政策全文仍可从「关于」页进入。
                          onTap: _openPrivacySettings,
                        ),
                        _MeRowSpec(
                          fill: _green,
                          icon: Icons.cloud_outlined,
                          title: t('meRowStorage'),
                          // 2026-09-14：数据和存储页建出来后接线（原先只弹「敬请期待」）
                          onTap: _openDataStorage,
                        ),
                        if (FeatureFlags.instance.inviteOn.value)
                          _MeRowSpec(
                            fill: AppTheme.green,
                            icon: Icons.share_outlined,
                            title: t('meInviteCode'),
                            // 后台关联的邀请码：直接展示 + 整行可点复制
                            subtitle:
                                _inviteCode.isNotEmpty ? _inviteCode : null,
                            onTap: _copyInviteCode,
                          ),
                      ]),
                    ),
                    SizedBox(height: _cardGap * s),
                    // 卡片 B：聊天设置 / 设备（消息保活设置行已按 2026-09-15 用户要求删除）
                    _card(s, dark, [
                      _MeRowSpec(
                        fill: _nearBlack,
                        icon: Icons.chat_bubble,
                        title: t('meRowChatSettings'),
                        onTap: _openChatSettings,
                      ),
                      _MeRowSpec(
                        fill: _orange,
                        icon: Icons.devices,
                        title: t('meRowDevice'),
                        // 固定文案，无数据源（参考截图即如此）
                        subtitle: t('meSubDeviceCount'),
                        onTap: _openDevice,
                      ),
                    ]),
                    SizedBox(height: _cardGap * s),
                    // 卡片 C：语言 / 外观
                    _card(s, dark, [
                      _MeRowSpec(
                        fill: _purple,
                        icon: Icons.language,
                        title: t('meSwitchLanguage'),
                        // 右侧显示当前语言（语言入口是弹窗菜单）
                        subtitle: _otherLangLabel(context),
                        onTap: () => _showLangPicker(context),
                      ),
                      _MeRowSpec(
                        fill: _blue,
                        icon: Icons.wb_sunny_outlined,
                        title: t('meRowAppearance'),
                        // 2026-09-14 需求8：改为底部弹「深色模式 / 浅色模式」选择面板。
                        // 数据源仍是 AppSettings.dark；全局主题由 main.dart 的
                        // `ctx.watch<AppSettings>()` 驱动，本行副标题靠 setState 跟着刷新。
                        subtitle: AppSettings.instance.dark
                            ? t('settingsDarkMode')
                            : t('settingsLightMode'),
                        onTap: _showAppearanceSheet,
                      ),
                    ]),
                    SizedBox(height: _cardGap * s),
                    // 卡片 D：我的收藏 / 系统设置 / 关于（贴纸和表情、常见问题两行已按
                    // 2026-09-15 用户要求删除；两行原本只弹「敬请期待」，无页面文件）
                    // 2026-09-17 需求：我的收藏下方新增「系统设置」，
                    // 修改密码（账号安全）/ AI 翻译等功能收口进系统设置页。
                    _card(s, dark, [
                      _MeRowSpec(
                        fill: AppTheme.pink,
                        icon: Icons.favorite_border_rounded,
                        title: t('meFavorites'),
                        onTap: _openFavorites,
                      ),
                      _MeRowSpec(
                        fill: _indigo,
                        icon: Icons.settings_outlined,
                        title: t('settingsTitle'),
                        onTap: _openSystemSettings,
                      ),
                      _MeRowSpec(
                        fill: _gray,
                        icon: Icons.info_outline,
                        title: t('meRowAbout'),
                        onTap: _openAbout,
                      ),
                    ]),
                    SizedBox(height: _cardGap * s),
                    // 切换账号（Telegram 式：本机记住多个账号，点一下切换）
                    _card(s, dark, [
                      _MeRowSpec(
                        fill: _blue,
                        icon: Icons.swap_horiz,
                        title: t('meRowSwitchAccount'),
                        subtitle: t('meSubSwitchAccount'),
                        onTap: _openAccountSwitcher,
                      ),
                    ]),
                    SizedBox(height: _cardGap * s),
                    // 退出登录（截图无此行，属保留现有入口）
                    _cardShell(
                      s,
                      dark,
                      InkWell(
                        onTap: _logout,
                        borderRadius: BorderRadius.circular(_cardRadius * s),
                        child: SizedBox(
                          height: 73.0 * s,
                          child: Center(
                            child: Text(t('meLogoutTitle'),
                                style: TextStyle(
                                    fontSize: 19.4 * s,
                                    fontWeight: FontWeight.w500,
                                    height: 1.0,
                                    color: _danger)),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: _versionGap * s),
                    // 底部版本号（品牌名 + 版本）
                    Center(
                      child: Text(
                          '${_brandName.isEmpty ? 'ChatPulse' : _brandName} v${UpdateService.currentVersion}',
                          style: TextStyle(
                              fontSize: 16.1 * s,
                              fontWeight: FontWeight.w400,
                              height: 1.0,
                              color: dark
                                  ? scheme.onSurfaceVariant
                                  : _versionInk)),
                    ),
                    // 底部留白：让版本号能滚到浮动 Tab 胶囊（高 83.7 + 底距 30）上方
                    SizedBox(
                        height: _bottomPad * s +
                            MediaQuery.paddingOf(context).bottom),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // =============== 顶部蓝色插画区 ===============

  /// 顶部插画区（参考高 413.7，按 [hv] 纵向自适应压缩）：蓝色渐变 + **参考图涂鸦
  /// 背景图**（`assets/me_header_doodle.png`，亮度→alpha 提取的白色线稿透明 PNG）+
  /// 二维码/编辑按钮 + 头像/昵称/副标题。
  ///
  /// 纵向坐标与内容尺寸（头像/字号/徽标）× `s * hv`；按钮尺寸保持 × s（触控目标不缩）。
  Widget _headerBoard(
      double s,
      double hv,
      dynamic Function(String, [Map<String, String>?]) t,
      String name,
      Map<String, dynamic>? p,
      String account,
      String shortId,
      bool isVipShort) {
    final avatarUrl = p?['avatar']?.toString() ?? '';
    final bound = (p?['phone']?.toString() ?? '').trim().isNotEmpty;
    // 副标题里的 @handle 用**账号**（= 用户名），不是一信号（shortId）。
    // 说明这里给的是用户名（account），不是可搜索的短 ID。shortId 仅在 account 为空时兜底。
    // 2026-09-15 需求：@账号 后面跟上短ID；2026-09-25 需求：前缀改大写「ID: 」。
    // 2026-09-25 需求2：删掉「已/未绑定手机」文案，改用图标标识——
    // 已绑定 = 绿色对勾盾（verified），未绑定 = 灰色禁用电话（phone_disabled）。
    final idText = account.isNotEmpty ? account : shortId;
    // 二十六批二轮：普通用户副标题拼短ID；靓号用户把「ID: 短ID」原位换成
    // 靓号本身（金色 kV2VipGold），不再另放金色徽标（用户反馈：相当于改个颜色）。
    final showPlainId = shortId.isNotEmpty && shortId != idText && !isVipShort;
    // 纵向综合系数：位置/头像/字号全部随压缩比例缩放（保证任意 hv 下不重叠）。
    final sv = s * hv;

    return SizedBox(
      height: _blueH * sv,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 蓝底：垂直线性渐变 #75BEF5 → #4FA1E1，全宽满铺（含状态栏区域），
          // 上面叠参考图涂鸦线稿（纯白透明 PNG，2026-09-15 需求：背景 = 颜色 + 背景图）。
          Positioned.fill(
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [_blueTop, _blueBottom],
                ),
              ),
              child: Image.asset(
                'assets/me_header_doodle.png',
                fit: BoxFit.cover,
                // 资产加载失败退化为纯渐变，不挡登录
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          ),
          // 二维码按钮：正圆 ∅55.7，x 28.7 / y 67.0（y 随 hv 压缩）
          Positioned(
            left: 28.7 * s,
            top: 67.0 * sv,
            child: _circleButton(s, Icons.qr_code_2, 55.7, 20.3, () {
              WideLayoutStore.instance.openDetail(context, const MyQrPage(),
                  paneKey: 'myqr', fadeScale: true);
            }),
          ),
          // 「编辑」胶囊：83.7×50.0，右外边距 29.0 / y 69.3（y 随 hv 压缩）
          Positioned(
            right: 29.0 * s,
            top: 69.3 * sv,
            child: _pillButton(s, t('chatListEdit'), _openProfile),
          ),
          // 头像：中心 (屏宽/2, 195.0)，外径 ∅142.8（白环 4.3 + 内圆 ∅134.2）+ 向下投影
          Positioned(
            top: (195.0 - 142.8 / 2) * sv,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: _openProfile,
                child: Container(
                  width: 142.8 * sv,
                  height: 142.8 * sv,
                  padding: EdgeInsets.all(4.3 * sv),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF08212F).withValues(alpha: 0.18),
                        blurRadius: 20 * sv,
                        offset: Offset(0, 6 * sv),
                      ),
                    ],
                  ),
                  child: AppAvatar(
                    url: avatarUrl,
                    name: name,
                    size: 134.2 * sv,
                    radius: 134.2 / 2 * sv,
                    background: AppTheme.primary,
                  ),
                ),
              ),
            ),
          ),
          // 昵称 32.9 / w700 / 白，居中（2026-09-15 需求：删掉昵称右侧的表情徽标）
          Positioned(
            top: (305.0 - 35.0 / 2) * sv,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: _openProfile,
                child: SizedBox(
                  height: 35.0 * sv,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 32.9 * sv,
                                fontWeight: FontWeight.w700,
                                height: 1.0,
                                color: Colors.white)),
                      ),
                      // 客服标识：V2SealBadge 与好友资料页统一（二十六批需求）
                      // 仅自己的 role=3（客服账号）时显示，判定复用 CertBadge.isKefu
                      if (CertBadge.isKefu(p?['role'])) ...[
                        SizedBox(width: 8 * s),
                        const V2SealBadge(size: 23, color: Color(0xFF4FA4EE)),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          // 副标题：「[绑定图标] @账号 ID: 短ID」20.1 / w400 / 白 85%，整行居中
          // （2026-09-25 需求2：手机绑定态不再用文案，用图标——已绑定绿色对勾盾，
          // 未绑定灰色禁用电话；点一下复制 ID —— 保留原资料卡片上的复制入口）
          Positioned(
            top: (348.0 - 18.7 / 2) * sv,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: () => _copyId(shortId, account),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24 * s),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        bound ? Icons.verified : Icons.phone_disabled,
                        size: 20.1 * sv,
                        color: bound
                            ? const Color(0xFF8FF0A4) // 蓝底上的浅绿：一眼「已绑定」
                            : Colors.white.withValues(alpha: 0.45),
                      ),
                      SizedBox(width: 5 * sv),
                      Flexible(
                        child: Text('@$idText',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 20.1 * sv,
                                fontWeight: FontWeight.w400,
                                height: 1.0,
                                color:
                                    Colors.white.withValues(alpha: 0.85))),
                      ),
                      // 普通 ID：白色；靓号：原位金色高亮（用户要求带 ID: 前缀）
                      if (shortId.isNotEmpty && shortId != idText)
                        Text(
                          '  ID: $shortId',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 20.1 * sv,
                              fontWeight: isVipShort
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              height: 1.0,
                              color: isVipShort
                                  ? kV2VipGold
                                  : Colors.white.withValues(alpha: 0.85)),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // 靓号金色徽标已移除（二十六批二轮）：靓号原位显示在副标题 id 位置
          // （金色高亮），不再重复放一枚徽标。
        ],
      ),
    );
  }

  /// 圆形按钮（二维码入口）：填充 #F4F9FF，图标 #213655
  Widget _circleButton(
      double s, IconData icon, double d, double iconSize, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: d * s,
        height: d * s,
        alignment: Alignment.center,
        decoration:
            const BoxDecoration(shape: BoxShape.circle, color: _btnFill),
        child: Icon(icon, size: iconSize * s, color: _btnInk),
      ),
    );
  }

  /// 胶囊按钮（编辑入口）：83.7×50.0，文字 19.5 / w500 / #203555
  Widget _pillButton(double s, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 83.7 * s,
        height: 50.0 * s,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _btnFill,
          borderRadius: BorderRadius.circular(25.0 * s),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 19.5 * s,
                fontWeight: FontWeight.w500,
                height: 1.0,
                color: _btnInk)),
      ),
    );
  }

  // =============== 设置卡片 / 行 ===============

  /// 卡片外壳：白底 + R23 + 极浅阴影（深色下用卡片底色、不投阴影）
  Widget _cardShell(double s, bool dark, Widget child) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: EdgeInsets.symmetric(horizontal: _cardGutter * s),
      decoration: BoxDecoration(
        color: dark ? scheme.surface : _cardBg,
        borderRadius: BorderRadius.circular(_cardRadius * s),
        boxShadow: dark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 14 * s,
                  offset: Offset(0, 4 * s),
                ),
              ],
      ),
      child: child,
    );
  }

  /// 分组卡片：若干行 + 行间分隔线（左内缩 79、右通到卡片边）
  Widget _card(double s, bool dark, List<_MeRowSpec> rows) {
    final separators =
        dark ? Theme.of(context).colorScheme.outlineVariant : _separator;
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      children.add(_row(s, dark, rows[i]));
      if (i != rows.length - 1) {
        children.add(Divider(
          height: 1,
          thickness: 1 * s,
          indent: _sepIndent * s,
          endIndent: 0.7 * s,
          color: separators,
        ));
      }
    }
    return _cardShell(s, dark, Column(children: children));
  }

  /// 单行：44×44 彩色图标块（R10）+ 标题/副标题 + 行尾信息 + chevron
  Widget _row(double s, bool dark, _MeRowSpec r) {
    final scheme = Theme.of(context).colorScheme;
    final titleInk = dark ? scheme.onSurface : _titleInk;
    final subInk = dark ? scheme.onSurfaceVariant : _subInk;
    return InkWell(
      onTap: r.onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: _rowVPad * s),
        child: Row(
          children: [
            SizedBox(width: _iconLeft * s),
            Container(
              width: _iconBox * s,
              height: _iconBox * s,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: r.fill,
                borderRadius: BorderRadius.circular(_iconRadius * s),
              ),
              child: Icon(r.icon, size: 23.0 * s, color: Colors.white),
            ),
            SizedBox(width: (_textLeft - _iconLeft - _iconBox) * s),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 19.4 * s,
                          fontWeight: FontWeight.w600,
                          height: 1.0,
                          color: titleInk)),
                  if (r.subtitle != null) ...[
                    SizedBox(height: 8.6 * s),
                    Text(r.subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 16.2 * s,
                            fontWeight: FontWeight.w400,
                            height: 1.28,
                            color: subInk)),
                  ],
                ],
              ),
            ),
            if (r.trailing != null)
              Padding(
                  padding: EdgeInsets.only(left: 8 * s), child: r.trailing!),
            SizedBox(width: 12.3 * s),
            Icon(Icons.chevron_right,
                size: 24 * s,
                color: dark ? scheme.onSurfaceVariant : _chevronInk),
            SizedBox(width: _chevronGutter * s),
          ],
        ),
      ),
    );
  }

  // =============== 入口跳转 / 交互 ===============

  /// 编辑资料（顶部「编辑」胶囊、头像、昵称共用）
  ///
  /// 2026-09-14 需求9：由「用户资料展示页 `ProfilePage`」改为**直接进编辑资料页
  /// `EditProfilePage`**。`ProfilePage` 在本仓已无任何引用（它页内的「编辑」也是转跳
  /// `EditProfilePage`），按约定**保留文件不删**，只是本页不再引用。
  Future<void> _openProfile() async {
    // 编辑资料返回后刷新（IndexedStack 常驻后 initState 不再重跑，必须手动刷）
    // 宽屏：右栏打开，await 立即完成（右栏无"关闭"概念）
    await WideLayoutStore.instance
        .openDetail(context, const EditProfilePage(), paneKey: 'profileEdit');
    if (mounted) _load();
  }

  /// 钱包：宽屏右栏 / 窄屏 push；返回后强刷余额（页内可能刚发生收支）
  Future<void> _openWallet() async {
    await WideLayoutStore.instance
        .openDetail(context, const WalletPage(), paneKey: 'wallet');
    if (mounted) _refreshBalance();
  }

  void _openFavorites() {
    WideLayoutStore.instance
        .openDetail(context, const FavoritesPage(), paneKey: 'favorites');
  }

  void _openAbout() {
    WideLayoutStore.instance
        .openDetail(context, const AboutPage(), paneKey: 'about');
  }

  /// 「系统设置」（2026-09-17 需求：我的收藏下方新增入口）。
  /// 页内收口：账号安全（修改登录密码/支付密码/绑定手机/注销）、AI 翻译、
  /// 群发助手、通知开关、深色模式。该页此前无任何入口（孤儿页），此为唯一入口。
  void _openSystemSettings() {
    WideLayoutStore.instance.openDetail(context, const SystemSettingsPage(),
        paneKey: 'systemSettings');
  }

  /// 「聊天设置」（V2 复刻页，2026-09-14 接线；原先只弹「敬请期待」）
  void _openChatSettings() {
    WideLayoutStore.instance
        .openDetail(context, const ChatSettingsPage(), paneKey: 'chatSettings');
  }

  /// 「设备」（V2 复刻页，2026-09-14 接线；原先只弹「敬请期待」）
  void _openDevice() {
    WideLayoutStore.instance
        .openDetail(context, const DevicePage(), paneKey: 'device');
  }

  /// 「通知和声音」（V2 复刻页，2026-09-14 接线；原先是打开 SystemSettingsPage）
  void _openNotifySettings() {
    WideLayoutStore.instance.openDetail(
        context, const NotificationSettingsPage(),
        paneKey: 'notifySettings');
  }

  /// 「数据和存储」（V2 复刻页，2026-09-14 接线；原先只弹「敬请期待」）
  void _openDataStorage() {
    WideLayoutStore.instance
        .openDetail(context, const DataStoragePage(), paneKey: 'dataStorage');
  }

  /// 「隐私」（2026-09-14 需求6）：打开 V2 复刻的**隐私设置页**。
  ///
  /// 原先这里打开的是隐私政策全文（`PolicyPage`）；政策全文仍可从「关于」页
  /// / 登录页 / 注册页三处进入，入口没丢，故本页删掉那条重复引用。
  void _openPrivacySettings() {
    WideLayoutStore.instance
        .openDetail(context, const PrivacySettingsPage(), paneKey: 'privacy');
  }

  /// 「外观」（2026-09-14 需求8）：底部弹出「深色模式 / 浅色模式」选择面板。
  ///
  /// - 当前生效项右侧打勾（`Icons.check` —— 界面统一不用 emoji）；
  /// - 选中即切换主题：数据源是 `AppSettings.dark`，调用 `setDark` 后
  ///   `notifyListeners` 会让 main.dart 的 `ctx.watch<AppSettings>()` 重建整个
  ///   `MaterialApp.theme`；本页再 `setState` 一次，刷新「外观」行右侧的状态文字。
  /// - 面板是新增交互（参考包没有这一屏），尺寸沿用本 App 既有的 `showModalBottomSheet`
  ///   风格（圆角 16、行高 56），不自造设计语言。
  Future<void> _showAppearanceSheet() async {
    final t = AppLocalizations.of(context).t;
    final dark = AppSettings.instance.dark;
    final picked = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 勾选单一数据源：第 4 参是「该选项当前是否被选中」，须按各自
            // 选项判断（深色=dark、浅色=!dark）。之前两行都直接传 dark，
            // 导致深色开启时两行同时打勾、浅色时两行都不勾（用户反馈 bug）。
            _appearanceOption(ctx, t('settingsDarkMode'), true, dark),
            _appearanceOption(ctx, t('settingsLightMode'), false, !dark),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await AppSettings.instance.setDark(picked);
    if (mounted) setState(() {});
  }

  /// 外观面板的单行：标题 + 当前生效项右侧打勾。点一下即回传选中值并关面板。
  Widget _appearanceOption(
      BuildContext ctx, String label, bool value, bool current) {
    final scheme = Theme.of(ctx).colorScheme;
    return InkWell(
      onTap: () => Navigator.pop(ctx, value),
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            const SizedBox(width: 20),
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 16, color: scheme.onSurface)),
            ),
            if (current)
              Padding(
                padding: const EdgeInsets.only(right: 20),
                child: Icon(Icons.check, size: 22, color: scheme.primary),
              ),
          ],
        ),
      ),
    );
  }

  /// 「完善登录账号」（2026-09-14 需求2）：底部弹出**绑定手机号码**面板。
  ///
  /// 复用现成能力：验证码与绑定走 `AuthService`（`getCaptcha` /
  /// `sendBindPhoneCode` / `bindPhone`）—— 与「账号安全 → 绑定手机号」用的
  /// 完全同一套接口。那一处是 `account_security_page.dart` 里的**私有**组件
  /// `_BindPhoneSheet`，跨文件取不到，故这里用同一套 API 复刻同款面板。
  ///
  /// ⚠️ 客户端**只做采集与展示**：手机号是否可用、短信验证码是否正确，全部由服务端
  /// 判定（本地不落库、不自行判断验证码）—— 账号安全类交互的红线。
  Future<void> _showBindPhoneSheet() async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => _BindPhoneSheet(
          currentPhone: (_profile?['phone']?.toString() ?? '').trim()),
    );
    // 绑定成功后刷新本页（副标题里的「已绑定手机」文案跟着变）
    if (ok == true && mounted) await _load();
  }

  /// 邀请码整行可点：有码则复制，无码提示联系管理员（行为与原实现一致）
  void _copyInviteCode() {
    final t = AppLocalizations.of(context).t;
    if (_inviteCode.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: _inviteCode));
      AppDialogs.toast(context, t('meCopied'));
    } else {
      AppDialogs.toast(context, t('meInviteCodeToast'));
    }
  }

  /// 复制 ID（原资料卡片上的复制按钮改挂在副标题行上）
  void _copyId(String shortId, String account) {
    final t = AppLocalizations.of(context).t;
    final v = shortId.isNotEmpty ? shortId : account;
    if (v.isEmpty) return;
    Clipboard.setData(ClipboardData(text: v));
    AppDialogs.toast(context, t('meCopied'));
  }

  /// 本 App 暂未实现的入口：给明确反馈，不做「点了没反应」的死行
  void _comingSoon(String label) {
    AppDialogs.toast(context,
        AppLocalizations.of(context).t('meComingSoonSuffix', {'name': label}));
  }

  /// 右侧显示当前语言（语言入口已改为弹窗菜单选择）
  String _otherLangLabel(BuildContext context) {
    final loc = AppLocalizations.of(context).locale;
    return AppLocalizations.langNativeName(loc);
  }

  /// 语言选择弹窗（跟随系统 + 四语），实现见 widgets/lang_picker.dart（登录/注册/扫码页共用）
  void _showLangPicker(BuildContext context) => showLangPicker(context);
}

/// 绑定手机号码底部面板：手机号 → 图形验证码 → 短信验证码（60s 倒计时）→ 确定。
///
/// 需求2（2026-09-14）：「完善登录账号」行改为直接弹这个面板。
///
/// 与 `account_security_page.dart` 的 `_BindPhoneSheet` **同源同接口**
/// （`AuthService.getCaptcha` / `sendBindPhoneCode` / `bindPhone`）——
/// 那个类是私有的、跨文件取不到，故在本文件复刻一份；接口与文案 key 都复用，
/// 不新增任何客户端侧的判定逻辑。
class _BindPhoneSheet extends StatefulWidget {
  const _BindPhoneSheet({this.currentPhone = ''});

  final String currentPhone;

  @override
  State<_BindPhoneSheet> createState() => _BindPhoneSheetState();
}

class _BindPhoneSheetState extends State<_BindPhoneSheet> {
  final _svc = AuthService();
  final _phone = TextEditingController();
  final _captchaCode = TextEditingController();
  final _smsCode = TextEditingController();
  Captcha? _captcha;
  Uint8List? _captchaBytes; // 图形验证码解码一次，避免每秒重建闪烁
  int _left = 0;
  Timer? _timer;
  bool _loading = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _loadCaptcha();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _phone.dispose();
    _captchaCode.dispose();
    _smsCode.dispose();
    super.dispose();
  }

  Future<void> _loadCaptcha() async {
    try {
      final c = await _svc.getCaptcha();
      if (!mounted) return;
      final bytes = base64Decode(c.imageBase64);
      setState(() {
        _captcha = c;
        _captchaBytes = bytes;
      });
    } catch (_) {}
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_left <= 1) {
        t.cancel();
        setState(() => _left = 0);
      } else {
        setState(() => _left--);
      }
    });
  }

  Future<void> _send() async {
    final t = AppLocalizations.of(context).t;
    final phone = _phone.text.trim();
    if (phone.isEmpty) {
      setState(() => _error = t('acctSecPhoneHint'));
      return;
    }
    if (_captcha == null) {
      setState(() => _error = t('graphicCaptcha'));
      return;
    }
    if (_captchaCode.text.trim().isEmpty) {
      setState(() => _error = t('graphicCaptcha'));
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      await _svc.sendBindPhoneCode(
          phone, '+86', _captcha!.captchaId, _captchaCode.text.trim());
      if (!mounted) return;
      setState(() => _left = 60);
      _start();
      AppDialogs.toast(context, t('codeSent'));
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    final t = AppLocalizations.of(context).t;
    final phone = _phone.text.trim();
    if (_smsCode.text.trim().isEmpty) {
      setState(() => _error = t('smsCode'));
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      await _svc.bindPhone(phone, '+86', _smsCode.text.trim());
      if (!mounted) return;
      AppDialogs.toast(context, t('acctSecBindSuccess'));
      Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _field(TextEditingController c, String hint, {TextInputType? kt}) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return TextField(
      controller: c,
      keyboardType: kt,
      style: TextStyle(fontSize: 15, color: scheme.onSurface),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
            fontSize: 15,
            color: isDark ? scheme.outlineVariant : const Color(0xFFAAAAAA)),
        filled: true,
        fillColor:
            isDark ? scheme.surfaceContainerHighest : const Color(0xFFF7F8FA),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const primary = AppTheme.primary;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t('meBindPhoneTitle'),
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface)),
          const SizedBox(height: 12),
          if (widget.currentPhone.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark
                    ? scheme.surfaceContainerHighest
                    : const Color(0xFFF7F8FA),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('${t('acctSecCurrentPhone')}：${widget.currentPhone}',
                  style:
                      TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            ),
            const SizedBox(height: 12),
          ],
          _field(_phone, t('acctSecPhoneHint'), kt: TextInputType.phone),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _field(_captchaCode, t('graphicCaptcha'))),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: _loadCaptcha,
                child: Container(
                  width: 112,
                  height: 44,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: isDark
                            ? scheme.outlineVariant
                            : const Color(0xFFE2E5EA)),
                    color: isDark
                        ? scheme.surfaceContainerHighest
                        : const Color(0xFFF7F8FA),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: _captchaBytes == null
                        ? const Center(
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : Image.memory(
                            _captchaBytes!,
                            fit: BoxFit.fill,
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.refresh),
                          ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _field(_smsCode, t('smsCode'), kt: TextInputType.number),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 44,
                child: ElevatedButton(
                  onPressed: (_left > 0 || _loading) ? null : _send,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primary,
                    foregroundColor: Colors.white,
                    disabledForegroundColor: scheme.onSurfaceVariant,
                    disabledBackgroundColor: isDark
                        ? scheme.surfaceContainerHighest
                        : const Color(0xFFEDEFF2),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  child: Text(
                    _left > 0 ? '$_left s' : t('sendCode'),
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.error_outline_rounded,
                    size: 18, color: AppTheme.danger),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_error,
                      style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.danger,
                          fontWeight: FontWeight.w500)),
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: FilledButton(
              onPressed: _loading ? null : _submit,
              style: FilledButton.styleFrom(backgroundColor: primary),
              child: Text(t('acctSecBindConfirm')),
            ),
          ),
        ],
      ),
    );
  }
}

/// 账号切换面板（Telegram 式）：底部弹层，列出本机记住的账号。
class _AccountSwitcherSheet extends StatefulWidget {
  final List<Map<String, dynamic>> accounts;
  final String currentId;
  final Future<void> Function(String id) onSwitch;
  final Future<void> Function(String id) onRemove;
  final Future<void> Function() onAdd;

  const _AccountSwitcherSheet({
    required this.accounts,
    required this.currentId,
    required this.onSwitch,
    required this.onRemove,
    required this.onAdd,
  });

  @override
  State<_AccountSwitcherSheet> createState() => _AccountSwitcherSheetState();
}

class _AccountSwitcherSheetState extends State<_AccountSwitcherSheet> {
  late List<Map<String, dynamic>> _accounts;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _accounts = List.of(widget.accounts);
  }

  Future<void> _switch(Map<String, dynamic> acc) async {
    if (_busy) return;
    final id = acc['id']?.toString() ?? '';
    if (id == widget.currentId) {
      // 点当前账号：直接关面板
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.onSwitch(id);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(Map<String, dynamic> acc) async {
    final id = acc['id']?.toString() ?? '';
    final name = (acc['nickname'] ?? '').toString();
    final display = name.isNotEmpty ? name : (acc['account'] ?? '').toString();
    final ok = await AppDialogs.confirm(
      context,
      title: AppLocalizations.of(context)
          .t('acctRemoveConfirm', {'name': display}),
      danger: true,
    );
    if (ok != true) return;
    setState(() => _accounts.removeWhere((a) => a['id'] == id));
    await widget.onRemove(id);
  }

  Future<void> _add() async {
    if (_busy) return;
    if (mounted) Navigator.of(context).pop();
    await widget.onAdd();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: dark ? scheme.surface : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 12,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 标题 + 关闭
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    t('acctSwitchTitle'),
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          // 账号列表
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: _accounts.length,
              separatorBuilder: (_, __) =>
                  Divider(height: 1, indent: 72, color: scheme.outlineVariant),
              itemBuilder: (_, i) {
                final acc = _accounts[i];
                final id = acc['id']?.toString() ?? '';
                final nickname = (acc['nickname'] ?? '').toString();
                final account = (acc['account'] ?? '').toString();
                final avatar = (acc['avatar'] ?? '').toString();
                final isCurrent = id == widget.currentId;
                final name = nickname.isNotEmpty ? nickname : account;
                return InkWell(
                  onTap: () => _switch(acc),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 10),
                    child: Row(
                      children: [
                        AppAvatar(url: avatar, name: name, size: 48),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: scheme.onSurface),
                              ),
                              if (account.isNotEmpty)
                                Text(
                                  account,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: scheme.onSurfaceVariant),
                                ),
                            ],
                          ),
                        ),
                        if (isCurrent)
                          Icon(Icons.check_circle,
                              color: Theme.of(context).colorScheme.primary,
                              size: 22)
                        else
                          IconButton(
                            onPressed: () => _remove(acc),
                            icon: Icon(Icons.delete_outline,
                                color: scheme.onSurfaceVariant, size: 22),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          // 添加账号
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: FilledButton.icon(
              onPressed: _busy ? null : _add,
              icon: const Icon(Icons.add),
              label: Text(t('acctAddAccount')),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
