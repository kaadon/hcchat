import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'app_navigator.dart';
import 'config/app_config.dart';
import 'l10n/app_locale.dart';
import 'pages/home_shell.dart';
import 'pages/incoming_call_page.dart';
import 'pages/login_page.dart';
import 'services/api_client.dart';
import 'services/auth_service.dart';
import 'services/conversation_service.dart';
import 'services/keep_alive_service.dart';
import 'services/local_notify_service.dart';
import 'services/local_store.dart';
import 'services/msg_height_cache.dart';
import 'services/settings_service.dart';
import 'services/update_service.dart';
import 'services/user_cache.dart';
import 'services/wallet_store.dart';
import 'theme/app_theme.dart';
import 'utils/web_connectivity_shim.dart';
import 'widgets/update_dialog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Web：connectivity_plus 6.x 的老式 web 注册在新 SDK 下被静默跳过
  // （Flutter 3.35+ 移除 Registrar 注册），livekit_client 断网检测一调就
  // MissingPluginException → H5 进不了 LiveKit 房间。runApp 前换上垫片。
  if (kIsWeb) WebConnectivityShim.register();
  // Android 保活：注册前台服务通信端口（必须 runApp 之前）
  KeepAliveService.instance.init();
  // 需求5：加载运行时接口配置（config/app_config.json），改 IP 不用重新编译
  await AppConfig.instance.loadRuntimeConfig();
  // 需求10：任意接口 401 且刷新失败 → 清登录态并跳转登录页
  //
  // 【修「被挤下线后登录页反复跳十几遍」（2026-09-19，iOS 实测）】
  // 被顶号后 rt 作废，首页并发的十几个请求同时 401 → 刷新全部 invalid →
  // 每个都各自走到这里反复 push 登录页。刷新已在 ApiClient 做单飞共享，
  // 这里再加 5 秒时间窗去重兜底：窗口内只跳一次（再触发也直接忽略）。
  // 5 秒远短于「重新登录成功」所需时间，不影响后续真正的再次被踢提醒。
  DateTime? _lastKickedNav;
  ApiClient.instance.onUnauthorized = () {
    final now = DateTime.now();
    final last = _lastKickedNav;
    if (last != null && now.difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _lastKickedNav = now;
    appNavigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  };
  // 需求7-8：加载本地设置（深色模式 / 通知开关）
  await AppSettings.instance.init();
  // 本地持久化缓存（Hive：会话列表 + 每会话最近消息）——冷启动首帧直出，
  // 失败不能阻塞启动（缓存只是加速器，数据仍可从服务端拉取）
  try {
    await LocalStore.init();
    // 缓存损坏时同步失效内存缓存 → 强制走网络重拉（防脏数据滞留内存）
    ConversationService.bindLocalStore();
    // 钱包余额快照：冷启动首屏直接显示上次余额，不再"先 ¥0 再跳变"
    // （仅展示用，任何金额操作前各页面都会先 refresh() 取服务端值）
    await WalletStore.instance.hydrate();
  } catch (_) {}
  // 实测高度内存层启动预热（fire-and-forget，几毫秒）：任何入口进聊天页的
  // 首帧 initialScrollOffset 都能用真实高度，避免估算低估导致首帧落点偏上
  unawaited(MsgHeightCache.ensureLoaded());
  // 需求3：App 后台时 WS 新消息 → 通知栏本地通知（极光只推离线用户）
  // 注意：init 只做插件初始化，不弹权限框；通知权限在登录后
  // （HomeShell.initState → requestPermission）统一申请
  unawaited(LocalNotifyService.instance.init());
  // 启动 logo 预解码（阻塞至解码完成，通常 10~40ms）：系统闪屏在 Flutter
  // 首帧那一刻被移除并播放退场淡出，若首帧 logo 还没解出来 → 淡出过程
  // 透出白底 2~4 帧（2026-09-20 video3 帧 89-95 实锤：淡出透白后 logo 才
  // 弹回）。方案 V2：直接解成 ui.Image + RawImage 绘制，不走 ImageCache
  // 异步链路——V1「预热 ImageCache」依赖缓存键 dpr 一致，真机未命中。
  await _prewarmSplashLogo();
  runApp(const ImApp());
}

/// 启动 logo 的已解码图像（runApp 前填充；null = 解码失败，走 Image.asset）
ui.Image? splashLogoImage;

/// 启动交接动画总开关（用户 2026-09-20 排障：怀疑动画引起闪烁，先关掉对照）。
/// false = 启动页→登录页直接切换，无上滑出场/上滑入场动画。确认后再改回 true。
const bool kSplashHandoffAnim = false;

/// 启动 logo 预解码：PNG 字节 → ui.Image，_SplashHold/_SplashSlideOut 用
/// RawImage 直接绘制，首帧必有图、无任何异步空窗。
Future<void> _prewarmSplashLogo() async {
  try {
    final data = await rootBundle.load('assets/icon/splash_logo.png');
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    splashLogoImage = frame.image;
  } catch (_) {
    // 解码失败回退 Image.asset（最坏回到「首帧后 logo 才出现」的现状）
  }
}

class ImApp extends StatelessWidget {
  const ImApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppSettings>.value(
      value: AppSettings.instance,
      child: LocaleProvider(
        child: Builder(builder: (ctx) {
          // 主题实时切换：跟随 AppSettings 的深色模式开关
          final settings = ctx.watch<AppSettings>();
          // 语言实时切换：MaterialApp.locale 跟随 LocaleProvider 当前语言
          final loc = AppLocalizations.of(ctx).locale;
          return MaterialApp(
            title: 'ChatPulse',
            theme: settings.dark ? AppTheme.dark() : AppTheme.light(),
            locale: loc,
            supportedLocales: const [
              Locale('zh'), // 简体（zh_CN）
              Locale('zh', 'TW'), // 繁體中文
              Locale('en'),
              Locale('ja'),
            ],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            navigatorKey: appNavigatorKey,
            home: const AuthGate(),
            builder: (context, child) {
              // 设置 → 聊天设置 → 字体大小（档位 0..6）全局生效：
              // 档 2（默认）= 1.0 零跳变，每档 ±5% → 0.90..1.20。
              // 旧实现只有聊天文本气泡读档位（且手动改 fontSize），其余界面完全不吃。
              final level = settings.chatFontLevel.clamp(0, 6);
              final scale = 1.0 + (level - 2) * 0.05;
              return CallOverlay(
                child: MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child ?? const SizedBox.shrink(),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}

/// 启动登录态判断（需求：杀进程后不用每次重新登录）
/// token 已持久化在 FlutterSecureStorage，401 拦截器会自动 refresh+重试。
/// 这里只判断"有没有 refresh token"：有 → 静默续期后进主界面，
/// 没有 → 登录页。
///
/// 关键纪律：**网络故障绝不清登录态**。杀进程重开 App 时安卓网络常常
/// 还没就绪，以前一次刷新失败就 clearAuth() 把 token 全删了 → 用户被
/// 强制重新登录。现在区分三态：续期成功 → 主界面；服务端明确拒绝
/// （rt 真作废）→ 清凭据回登录页；网络不通 → 保留凭据显示失败态，
/// 点"重新加载"原地重试。
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  // 启动等待态（2026-09-20）：不再显示彗星环转圈——那一下转圈把
  // 「原生启动图 → 登录页」的视觉连续性打断了。改为与原生启动图完全
  // 一致的居中 logo（轻呼吸），登录决策完成后登录页入场动画从同一
  // 屏幕位置接管，全程无断点。
  Widget _body = const _SplashHold();
  // 方案 C（用户 2026-09-20 选定）：启动 logo 上滑出场覆盖层。
  // 交接期间 Stack 叠在登录页上方，动画结束后移除（登录页变为可交互）。
  Widget? _splashOverlay;
  Timer? _splashOverlayTimer;
  // 启动网络失败态的自动重试：3 秒倒计时自动再试，不用手动点
  Timer? _autoRetryTimer;
  int _retryCountdown = 0;

  @override
  void initState() {
    super.initState();
    _decide();
  }

  // 第十二批问题 1：聊天背景涂鸦 asset 全局预热。此前首次进入聊天窗口时
  // Image.asset 异步解码，涂鸦层晚 1~N 帧浮现 = 「闪一下才显示背景」；
  // 这里登录判断期间（异步网络等待 1s+）就把 1136×692 小图解码进常驻
  // ImageCache，之后任何入口（会话列表/通讯录/推送等 12 处）push ChatPage
  // 首帧即有完整背景。重复调用幂等（ImageCache 命中直接返回）。
  bool _bgPrecached = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bgPrecached) return;
    _bgPrecached = true;
    precacheImage(const AssetImage('assets/chat_bg_doodle.png'), context);
  }

  @override
  void dispose() {
    _autoRetryTimer?.cancel();
    _splashOverlayTimer?.cancel();
    super.dispose();
  }

  /// 启动页 → 登录页交接动画（方案 C，用户 2026-09-20 选定）：
  /// 启动 logo 上滑滑出屏幕，登录页同时从下方 26px 处轻微上滑 + 淡入。
  /// 系统「减弱动态效果」开启时直接切换不做动画。
  /// 仅登录页走交接；进主界面（HomeShell）直接切换——主界面有自己的
  /// 首帧直出节奏，叠动画反而拖慢可用时间。
  ///
  /// [kSplashHandoffAnim]=false：交接动画整体关闭（用户 2026-09-20 排障
  /// 要求，怀疑动画本身引起闪烁）——登录判定完成后直接切登录页，
  /// 无滑出/滑入。排障结束确认根因后再决定是否恢复。
  void _gotoWithSplashHandoff(Widget target) {
    _splashOverlayTimer?.cancel();
    // 滑出动画仅登录页播；主界面（HomeShell）恒遮罩直切——主界面要的是
    // 首帧直出节奏，不叠上滑动画，遮罩静止盖住其首帧构建期即可。
    final playSlideAnim = kSplashHandoffAnim &&
        target is LoginPage &&
        !MediaQuery.of(context).disableAnimations;
    if (!playSlideAnim) {
      setState(() {
        _body = target;
        _splashOverlay = const _SplashHold(breathe: false);
      });
      // 撤遮罩时机 = 400ms 定时。依据（2026-09-20 19:00 release 录屏逐帧）：
      // 登录页从切换到完整呈现约 600ms（19 帧），其中白屏段在前 ~200ms；
      // 14:39 版的双层 postFrame 只等 2 帧就撤 → 白屏全露（用户复测仍闪）。
      // 400ms 盖住白屏段且不过分拖延；中间态本身白底+同款 108dp 居中
      // logo，遮罩撤除时与其视觉连续，表单略晚出现无闪烁感。
      _splashOverlayTimer = Timer(const Duration(milliseconds: 400), () {
        if (mounted) setState(() => _splashOverlay = null);
      });
      return;
    }
    setState(() {
      _body = _SplashPageSlideIn(child: target);
      _splashOverlay = const _SplashSlideOut();
    });
    _splashOverlayTimer = Timer(const Duration(milliseconds: 340), () {
      if (!mounted) return;
      setState(() => _splashOverlay = null);
    });
  }

  /// 进入失败态后启动自动重试倒计时（每次失败重新计时）
  void _startAutoRetry() {
    _autoRetryTimer?.cancel();
    _retryCountdown = 3;
    _autoRetryTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      _retryCountdown--;
      if (_retryCountdown <= 0) {
        timer.cancel();
        // 自动重试：回到启动等待态（居中 logo 轻呼吸），走完整 _decide 流程
        setState(() => _body = const _SplashHold());
        _decide();
      } else {
        // 刷新倒计时文案（重建失败态 widget 以更新秒数）
        setState(() => _body = _buildNetFailed());
      }
    });
  }

  Future<void> _decide() async {
    if (_deciding) return; // 防重入：自动重试定时器触发时上一次可能还没走完
    _deciding = true;
    try {
      await _decideInner();
    } finally {
      _deciding = false;
    }
  }

  Future<void> _decideInner() async {
    final api = ApiClient.instance;
    // 品牌预加载（2026-09-17）：启动页转圈期间就把 /auth/config 的 logo/名字
    // 拉好并落磁盘缓存 —— 登录页首帧直接用缓存渲染，不再「进登录页 logo
    // 先闪一下占位才变成真实品牌」。失败静默（登录页有自己的网络兜底）。
    // （cachedConfig/_preloading 是 static，任意实例共享在途请求）
    unawaited(AuthService().preloadConfig());
    // 读 refresh token：secure storage 偶发读取失败/挂起，重试 2 次（每次 5s 封顶）。
    // 都读不到再进登录页（登录页本身不需要旧凭据，误进一次可重新登录，代价可控；
    // 但绝不能在读失败时主动清凭据）。
    String? rt;
    for (var i = 0; i < 2; i++) {
      try {
        rt = await api.readRefresh().timeout(const Duration(seconds: 5));
        if (rt != null && rt.isNotEmpty) break;
      } catch (_) {}
      if (i < 1) await Future.delayed(const Duration(milliseconds: 400));
    }
    Widget target;
    if (rt != null && rt.isNotEmpty) {
      // 有 refresh token：静默续期。网络错误自动重试（含 refreshSession 内部重试），
      // 仍失败保持失败态；只有服务端明确拒绝才清登录态。
      // 每次尝试整体 15s 封顶（dio 最坏 5s 连接 + 10s 响应）——
      // 之前 3 次不设整体上限，服务端慢时纯转圈最长 60~90s，看起来像卡死
      var result = AuthRefreshResult.network;
      for (var i = 0; i < 2; i++) {
        try {
          result =
              await api.refreshSession().timeout(const Duration(seconds: 15));
        } catch (_) {
          result = AuthRefreshResult.network;
        }
        if (result != AuthRefreshResult.network) break;
        if (i < 1) await Future.delayed(const Duration(milliseconds: 600));
      }
      if (result == AuthRefreshResult.ok) {
        target = const HomeShell();
      } else if (result == AuthRefreshResult.invalid) {
        // 服务端明确拒绝：rt 已被作废（多端登录挤掉白名单 / Redis 重启 / rt 过期），
        // 留着只会让下次启动再空跑一次 → 清凭据去登录页
        await api.clearAuth();
        UserCache.clear(); // 换账号不能复用上一个登录会话的用户缓存
        WalletStore.instance.reset(); // 同上：别让上一个人的余额串到新账号
        // 本地消息/会话缓存一并清（换账号不能看到上一个人的聊天记录）
        unawaited(LocalStore.clearUserData());
        target = const LoginPage();
      } else {
        // 网络不通：保留登录态，显示失败态，3 秒后自动重试（也可手动立即重试）
        if (!mounted) return;
        setState(() => _body = _buildNetFailed());
        _startAutoRetry();
        return;
      }
    } else {
      // 未登录一律直接进登录页（独立游客引导页已移除）。
      // 后台开启游客登录时，登录页会按 /auth/config 的 guestOn
      // 自己显示「一键注册登录」按钮（见 login_page.dart 的 _guestOn）。
      target = const LoginPage();
    }
    if (!mounted) return;
    // 登录页与主界面统一走遮罩交接。release 实测（2026-09-20 19:00 模拟器
    // 录屏帧 59-63）：主界面 HomeShell 直切时首帧 build/光栅化约 5 帧白屏
    // ——主界面比登录页更重，之前的「直切」分支就是用户看到的最后一闪。
    // 函数内部按 target 类型决定是否播滑出动画（主界面不播，遮罩直切）。
    _gotoWithSplashHandoff(target);
    // 已登录进入主界面：延迟几秒自动检查一次版本更新（本次启动只查一次）
    if (target is HomeShell && !_updateChecked) {
      _updateChecked = true;
      _autoCheckUpdate();
    }
  }

  bool _updateChecked = false;
  bool _deciding = false; // _decide 防重入标记

  /// 启动自动检查更新：进主界面 2 秒后静默拉后台版本配置，
  /// 有新版本且配置了下载地址 → 弹更新弹窗；失败/无新版本完全不打扰。
  /// H5（Flutter Web）不检测更新——网页刷新即最新，无需版本提示。
  Future<void> _autoCheckUpdate() async {
    if (kIsWeb) return;
    await Future.delayed(const Duration(seconds: 2));
    final info = await UpdateService.fetch();
    if (info == null || !info.hasNew || !info.hasUrl) return;
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    await UpdateDialog.showIfAvailable(ctx, info);
  }

  /// 启动时网络不通的失败态（不清登录态，重试后凭据还在，能直接进主界面）
  Widget _buildNetFailed() {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(t('bootLoadFailed'),
                style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 14),
            // 倒计时自动重试提示
            Text(t('bootAutoRetryIn', {'s': '$_retryCountdown'}),
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                // 手动立即重试：停掉倒计时
                _autoRetryTimer?.cancel();
                setState(() => _body = const _SplashHold());
                _decide();
              },
              child: Text(t('contactsRetry'),
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primary)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final overlay = _splashOverlay;
    if (overlay == null) return _body;
    return Stack(children: [_body, overlay]);
  }
}

/// 启动等待态（2026-09-20）：与原生启动图视觉完全一致的居中 logo。
///
/// - 背景 #ffffff 与 flutter_native_splash 的 color 配置一致，启动图消失
///   → 本页接管，肉眼无跳变；
/// - logo 固定 108dp：与 Android 系统闪屏（288dp 框 × inset 31.25%）和
///   iOS 启动屏（110pt）对齐，三方尺寸恒定，闪屏切换无大小跳变；
/// - 轻呼吸（1.0↔1.04，1.1s 往复）表示「在加载」而非卡死；系统开启
///   「减弱动画」时静止。不再使用旋转圆环——转圈会把启动图到登录页
///   入场动画的连续性打断（用户 2026-09-20 反馈移除）。
class _SplashHold extends StatefulWidget {
  const _SplashHold({this.breathe = true});

  /// false = 完全静止（交接遮罩用）：遮罩必须与上一帧逐像素一致，
  /// 若重新开始呼吸动画，scale 会从 1.0 起跳（前一帧可能是 1.03），
  /// logo 有一次轻微跳动。
  final bool breathe;

  @override
  State<_SplashHold> createState() => _SplashHoldState();
}

class _SplashHoldState extends State<_SplashHold>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
      value: 0,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 系统「减弱动态效果」开启或静止模式（交接遮罩）→ 不启动呼吸
    if (widget.breathe == false || MediaQuery.of(context).disableAnimations) {
      _ctl.stop();
    } else if (!_ctl.isAnimating) {
      _ctl.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 固定 108dp：与 Android 系统闪屏图标（288dp 框 × inset 31.25% = 108dp）
    // 和 iOS 启动屏（108pt）逐像素对齐。此前用 shortestSide×0.30 会随设备
    // 变化，与固定尺寸的系统闪屏之间出现可见的 logo 大小跳变（用户看到的
    // 「两个启动图」）。
    const side = 108.0;
    // 首帧必有图：main() 已同步解码成 ui.Image，RawImage 不走异步解码链路
    // （Image.asset 首次解码要几帧，会造成系统闪屏移除后 logo 缺位的白闪）
    final logo = splashLogoImage != null
        ? RawImage(
            image: splashLogoImage,
            width: side,
            height: side,
            fit: BoxFit.contain)
        : Image.asset(
            'assets/icon/splash_logo.png',
            width: side,
            height: side,
            fit: BoxFit.contain,
          );
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: AnimatedBuilder(
          animation: _ctl,
          builder: (_, __) => Transform.scale(
            scale: 1.0 + 0.04 * Curves.easeInOut.transform(_ctl.value),
            child: logo,
          ),
        ),
      ),
    );
  }
}

/// 方案 C 之「logo 出场」（用户 2026-09-20 选定）：
/// 启动 logo 从原位向上滑出屏幕（320ms easeIn 加速，末 35% 轻淡出）。
/// 覆盖层只含 logo 本体（不带白底 Scaffold）——白底若一起滑走会变成
/// 「整页白幕上掀」而不是「logo 上滑」。translate 取 屏高一半+logo 边长，
/// 任何机型都保证完全滑出屏幕顶端。
class _SplashSlideOut extends StatelessWidget {
  const _SplashSlideOut();

  @override
  Widget build(BuildContext context) {
    // 与 _SplashHold / 系统闪屏同一固定尺寸（108dp），出场起点逐像素对齐
    const side = 108.0;
    final logo = splashLogoImage != null
        ? RawImage(
            image: splashLogoImage,
            width: side,
            height: side,
            fit: BoxFit.contain)
        : Image.asset(
            'assets/icon/splash_logo.png',
            width: side,
            height: side,
            fit: BoxFit.contain,
          );
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeIn,
      builder: (context, t, child) {
        final h = MediaQuery.of(context).size.height;
        final fade = t < 0.65 ? 1.0 : (1 - (t - 0.65) / 0.35).clamp(0.0, 1.0);
        return Opacity(
          opacity: fade,
          child: Transform.translate(
            offset: Offset(0, -t * (h / 2 + side)),
            child: child,
          ),
        );
      },
      child: Center(child: logo),
    );
  }
}

/// 方案 C 之「登录页入场」：从下方 26px 处轻微上滑 + 淡入
/// （300ms easeOutCubic）。与 logo 上滑出场同时进行，方向感呼应
/// 「往上进登录页」；26px 位移很小，登录页内容几乎原位浮现。
class _SplashPageSlideIn extends StatelessWidget {
  const _SplashPageSlideIn({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      // 白色垫底层（2026-09-20 修交接黑闪）：登录页淡入前半段整页半透明，
      // 透出的是窗口背景——深色模式下 NormalTheme 的 colorBackground 是
      // 黑色（录屏帧 130-135 黑底 166ms 实锤）。垫白后淡入期间背景恒为
      // 白，与启动屏无缝衔接。
      builder: (context, t, child) => Stack(
        children: [
          const Positioned.fill(child: ColoredBox(color: Colors.white)),
          Opacity(
            opacity: t.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, (1 - t) * 26),
              child: child,
            ),
          ),
        ],
      ),
      child: child,
    );
  }
}
