import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_locale.dart';
import '../services/call_service.dart';
import '../services/keep_alive_service.dart';
import '../services/local_notify_service.dart';
import '../services/push_service.dart';
import '../services/sound_service.dart';
import '../services/unread_store.dart';
import '../services/wide_layout_store.dart';
import '../services/friend_req_store.dart';
import '../services/wallet_store.dart';
import '../services/ws_service.dart';
import '../theme/app_theme.dart';
import '../utils/breakpoints.dart';
import '../widgets/v2_kit.dart';
import '../widgets/wide_chat_pane.dart';
import 'chat_list_page.dart';
import 'contacts_page.dart';
import 'create_channel_sheet.dart';
import 'discover_page.dart';
import 'me_page.dart';

/// 底部 4 Tab（消息 / 通讯录 / 发现 / 我的）—— V2 像素级复刻 2026-09-14
///
/// 旧版是「通栏白底 + 顶部细线 + 蓝色选中」，现改为参考截图的**浮动白色胶囊**：
/// x28.3 / w363.0 / h83.7 / 圆角 41.8，无顶部分隔线；2026-09-15 起底色改
/// 纯白（深色 #1C1C1E）+ 阴影（见 `_bottomBar` 注释）；
/// 选中态是浅灰胶囊（82.7×66.0 / 圆角 33）+ 近黑图文，未选中是灰图文。
/// 因为它是浮动的（不占位），不能用 `bottomNavigationBar`，见 `build` 里的 Stack。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;

  late final List<Widget> _pages;
  VoidCallback? _offFriend;

  /// 会话列表页的 GlobalKey：回前台时需要转调它的补拉入口（修 R-20）。
  /// ChatListPage 被 IndexedStack 常驻持有，用 key 取 state 比重建实例安全。
  final GlobalKey<ChatListPageState> _chatListKey =
      GlobalKey<ChatListPageState>();

  @override
  void initState() {
    super.initState();
    // B-24：监听前后台切换——WS 断了、或推送没收到时，切回前台兜底拉一次余额
    WidgetsBinding.instance.addObserver(this);
    _pages = <Widget>[
      ChatListPage(key: _chatListKey),
      const ContactsPage(),
      const DiscoverPage(),
      const MePage(),
    ];
    FriendReqStore.instance.refresh();
    _offFriend = GlobalWs.instance.onFriend((_) {
      FriendReqStore.instance.refresh();
      // 需求：被添加好友提示音
      SoundService.instance.playFriendAdded();
    });
    GlobalWs.instance.ensureConnected();
    // 通话信令：登录后挂上全局监听（来电可在任意页面弹出）
    CallService.instance.attach();
    // 通知权限：登录后才申请（2026-09-06 需求：不在打开 App 时弹框）。
    // 【必须串行】等权限弹框答复完成后再启动保活前台服务——
    // 若并发启动，服务带着"通知权限未授予"状态运行，Android 13+ 会
    // 隐藏其常驻通知 → 通知栏看不到保活提示（2026-09-06 踩坑）。
    unawaited(LocalNotifyService.instance
        .requestPermission()
        .whenComplete(() => KeepAliveService.instance.start()));
    // 极光推送：绑定 alias = 用户 ID（覆盖启动自动登录/登录/注册/扫码四条入口）
    unawaited(PushService.instance.start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _offFriend?.call();
    super.dispose();
  }

  /// App 切回前台：补拉余额与好友申请数。
  /// 主链路是服务端 WS 推送（B-24），这里只是兜底——
  /// 覆盖「WS 断开」「推送丢失」「用户在 PC 后台改完再拿起手机」几种情况。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // 回到前台：先确保 WS 长连接健康（切后台期间可能被系统回收 / 网络断开），
    // 死连接会在 _scheduleReconnect 里被重建；再兜底刷新余额与好友申请数。
    GlobalWs.instance.reconnectIfNeeded();
    unawaited(WalletStore.instance.refresh());
    FriendReqStore.instance.refresh();
    // 【修 R-20】切后台期间 WS 可能已死、事件通道可能丢事件：
    // 回前台时给**所有会话**补一次缺口（旧逻辑只刷钱包和好友申请，
    // 消息全靠用户点进会话时拉 80 条历史 → 缺口 >80 条就永久漏了）。
    _chatListKey.currentState?.onAppResumed();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 状态栏颜色 = 页面背景灰（4 个 tab 页 Scaffold 都是 scaffoldBackgroundColor）。
    // 不设的话状态栏保持系统默认白色，只有进过带 AppBar 的二级页（如新朋友）
    // 返回后才被它的 AnnotatedRegion 顺手染成灰色 —— 现在主界面自己声明，保证始终一致。
    // PopScope 的 canPop 需随右栏选中状态变化 → ListenableBuilder 监听分发层。
    return ListenableBuilder(
      listenable: WideLayoutStore.instance,
      builder: (context, _) {
        final wide = Breakpoints.isWide(context);
        // 宽屏返回键两段式：右栏有内容 → 先清右栏（拦截）；已空 → 正常退出
        final paneOpen = wide && WideLayoutStore.instance.currentKey != null;
        return PopScope(
          canPop: !paneOpen,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) WideLayoutStore.instance.closePane();
          },
          // 「新建频道」sheet 开关（第八批）：chat_list_page 的 + 宫格第四项触发；
          // sheet 画在 tab 页之上、底部导航胶囊之下（参考图：遮罩压暗页面但
          // 白胶囊不被压暗 ⇒ 导航必须在 sheet 层之上，measure_channel.md §0/§11.3-2）。
          child: ValueListenableBuilder<bool>(
            valueListenable: CreateChannelSheetController.open,
            builder: (context, showChannel, _) =>
                AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemUiOverlayStyle(
                // 状态栏底色**跟随当前 Tab 页的顶部颜色**（2026-09-14 V2 复刻）：
                // 4 个 tab 页各自的 Scaffold 底色不同（消息=纯白、通讯录=#F5F5F5、
                // 我的=蓝色插画渐变），继续沿用全局 scaffoldBackgroundColor
                // 会在页面顶部留一条明显色带。
                statusBarColor: _statusBarColor(context, isDark),
                // 「我的」页顶部是浅蓝插画 → 深色图标；其余页按深浅色模式常规反相
                statusBarIconBrightness: _index == 3
                    ? Brightness.dark
                    : (isDark ? Brightness.light : Brightness.dark),
              ),
              child: wide
                  ? Scaffold(
                      body: Stack(
                        // expand 保持 _wideBody 原有满幅约束（包 Stack 后不改变布局）
                        fit: StackFit.expand,
                        children: [
                          _wideBody(context),
                          ..._createChannelLayers(context, showChannel),
                        ],
                      ),
                    )
                  : Scaffold(
                      // IndexedStack 保活 4 个 tab：切换时不销毁/重建页面，
                      // 修复「快速点'我的'先闪'未登录'再加载头像昵称」「发现页每次切 tab 都重新加载」。
                      // 代价是 4 页 initState 在进入首页时并发执行一次（各自拉一次接口），可接受。
                      //
                      // Tab 栏是**浮动白色胶囊**（截图实测 x28.3 / w363 / h83.7 / r41.8），
                      // 所以不能用 bottomNavigationBar（它会占位、把内容顶上去），改用 Stack 叠在
                      // 内容之上：列表可以延伸到胶囊后面 —— 与参考截图一致
                      // （聊天列表页同为白底看不出边界，通讯录页灰底上胶囊边界清晰）。
                      body: Stack(
                        children: [
                          IndexedStack(index: _index, children: _pages),
                          ..._createChannelLayers(context, showChannel),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: _bottomBar(context, t),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }

  /// 「新建频道」sheet 的图层（scrim + 面板）：插在 tab 页之上、底部导航胶囊之前，
  /// 所以胶囊绘制在最上层 —— 这是「sheet 铺到屏底但导航不被压暗」的关键
  /// （不能走 showModalBottomSheet：它的 barrier 会连导航一起盖住）。
  /// 遮罩用 Flutter 默认 modal barrier 同款 black54（实测命中参考图）。
  /// 隐藏时层仍挂载但 IgnorePointer + 透明/滑出，展开收起均 250ms easeOut。
  static const Duration _createChannelAnim = Duration(milliseconds: 250);

  List<Widget> _createChannelLayers(BuildContext context, bool show) {
    return [
      // 遮罩层：点按空白处关闭
      Positioned.fill(
        child: IgnorePointer(
          ignoring: !show,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: CreateChannelSheetController.hide,
            child: AnimatedOpacity(
              opacity: show ? 1 : 0,
              duration: _createChannelAnim,
              curve: Curves.easeOut,
              child: const ColoredBox(color: Colors.black54),
            ),
          ),
        ),
      ),
      // 面板层：目标屏高 85%（实测 779.11/916.7 = 0.8500），自底部滑入。
      // 高度钳制在 Stack 可视区内：键盘弹出时 Scaffold body 缩小，
      // 85% 全屏高会超出可视区把头栏/私密行顶出屏（第十批问题 7），取两者较小值。
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: LayoutBuilder(
          builder: (context, c) {
            final h = math.min(
              MediaQuery.sizeOf(context).height * 0.85,
              c.maxHeight,
            );
            return IgnorePointer(
              ignoring: !show,
              child: AnimatedSlide(
                offset: show ? Offset.zero : const Offset(0, 1),
                duration: _createChannelAnim,
                curve: Curves.easeOut,
                child: AnimatedOpacity(
                  opacity: show ? 1 : 0,
                  duration: _createChannelAnim,
                  curve: Curves.easeOut,
                  child: SizedBox(
                    width: double.infinity,
                    height: h,
                    child: const CreateChannelSheet(),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ];
  }

  /// 宽屏三段布局：[导航 rail] [列表列 IndexedStack] [聊天右栏]
  /// 铰链间距并入分栏缝；超宽时整体居中限宽（Breakpoints.maxContentWidth）。
  Widget _wideBody(BuildContext context) {
    final gap = Breakpoints.paneGap(context);
    final content = Row(
      children: [
        _navRail(context),
        SizedBox(width: gap > 0 ? gap : 0.5), // 分栏缝（有铰链时让出折痕宽度）
        SizedBox(
          width: Breakpoints.listPaneWidth,
          child: IndexedStack(index: _index, children: _pages),
        ),
        // 右栏：列表列与右栏之间细分隔线（与 rail 右缘同款），分栏更清晰
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.08),
                    width: 0.5),
              ),
            ),
            child: const WideChatPane(),
          ),
        ),
      ],
    );
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      if (w <= Breakpoints.maxContentWidth) return content;
      // 超宽（大显示器/平板横屏）：整体居中限宽，两侧留白
      return Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        alignment: Alignment.center,
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: Breakpoints.maxContentWidth),
          child: content,
        ),
      );
    });
  }

  /// 宽屏左侧导航 rail：4 Tab 竖排（图标 + 未读角标，无文字）
  Widget _navRail(BuildContext context) {
    return Container(
      width: Breakpoints.navRailWidth,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
            right: BorderSide(
                color: context.cs.onSurface.withValues(alpha: 0.08),
                width: 0.5)),
      ),
      child: SafeArea(
        top: true,
        bottom: false,
        child: Column(
          children: [
            const SizedBox(height: 8),
            _railItem(context, 0, Icons.chat_bubble_outline,
                Icons.chat_bubble_rounded),
            _railItem(
                context, 1, Icons.contacts_outlined, Icons.contacts_rounded),
            _railItem(
                context, 2, Icons.explore_outlined, Icons.explore_rounded),
            _railItem(context, 3, Icons.person_outline, Icons.person_rounded),
          ],
        ),
      ),
    );
  }

  /// rail 单个图标项（复用 _tab 的角标逻辑，竖排紧凑版）
  Widget _railItem(
      BuildContext context, int i, IconData iconOff, IconData iconOn) {
    final active = i == _index;
    final icon = Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(active ? iconOn : iconOff,
            size: 26,
            color: active ? AppTheme.primary : context.cs.onSurfaceVariant),
        if (i == 0)
          ValueListenableBuilder<int>(
            valueListenable: UnreadStore.instance.total,
            builder: (_, unread, __) {
              if (unread <= 0) return const SizedBox.shrink();
              return Positioned(right: -7, top: -7, child: _badge(unread));
            },
          ),
        if (i == 1)
          ValueListenableBuilder<int>(
            valueListenable: FriendReqStore.instance.count,
            builder: (_, c, __) => c > 0
                ? Positioned(right: -7, top: -7, child: _badge(c))
                : const SizedBox.shrink(),
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: () => _onTabTap(i),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 52,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: active
                ? AppTheme.primary.withValues(alpha: 0.10)
                : Colors.transparent,
          ),
          child: icon,
        ),
      ),
    );
  }

  /// 状态栏底色：跟随当前 Tab 页的**顶部颜色**（2026-09-14 V2 复刻新增）。
  ///
  /// - 0 消息：页面纯白（截图实测 #FFFFFF）
  /// - 1 通讯录：#F5F5F5
  /// - 2 发现：保持全局页面底色（该页未做 V2 复刻）
  /// - 3 我的：**transparent** —— 蓝色插画要一直铺到状态栏之下，
  ///   给它一个不透明色会把插画顶部盖掉
  Color _statusBarColor(BuildContext context, bool isDark) {
    switch (_index) {
      case 0:
        return isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
      case 1:
        return isDark ? const Color(0xFF000000) : const Color(0xFFF5F5F5);
      case 3:
        return Colors.transparent;
      default:
        return Theme.of(context).scaffoldBackgroundColor;
    }
  }

  /// 窄屏底部导航：**浮动白底胶囊 + 阴影**（2026-09-15 需求）。
  ///
  /// 尺寸全部来自参考截图实测（逻辑 px，基准宽 420）：
  /// 胶囊 x28.3 / w363.0 / h83.7、圆角 = 半高 41.8；四个槽位等距 82.3
  /// （槽中心 86.5 / 168.8 / 251.1 / 333.4）；胶囊距屏幕底约 30。
  /// 选中态是**浅灰胶囊**（82.7×66.0，圆角 33），不是旧版的蓝色文字。
  /// 图标用参考包直拷的 PNG（`assets/icons/tab_*.png`：未选中灰、选中近黑），
  /// 所以不需要再 tint —— 参考图里选中/未选中的差异就来自这套图本身。
  ///
  /// **底色与阴影**（2026-09-15 用户原话「别透明了做复杂效果了，直接白色+阴影」）：
  /// - 此前是毛玻璃（BackdropFilter + 半透明底色），第十六批已去掉模糊，
  ///   本轮再把半透明底色改**纯白 / 深色纯暗 #1C1C1E**（opacity 1.0）。
  /// - 阴影：y 3 / blur 10 / 黑 alpha 0.10（指定范围 0.08~0.12 取中值）；
  ///   深色模式阴影不明显，改用**上缘细边框线**（白 alpha 0.08）替代，
  ///   与项目里分栏缝 0.5px 边框的用法一致。
  /// - 形状不变：仍是浮动胶囊（x28.3 / h83.7 / r41.8），不占位。
  Widget _bottomBar(
      BuildContext context, String Function(String, [Map<String, String>?]) t) {
    final s = v2Scale(context);
    final dark = context.v2IsDark;
    return Padding(
      padding: EdgeInsets.only(left: 28.3 * s, right: 28.3 * s, bottom: 30 * s),
      child: Container(
        height: 83.7 * s,
        decoration: BoxDecoration(
          // 纯白（深色纯暗），不再半透明
          color: dark ? const Color(0xFF1C1C1E) : Colors.white,
          borderRadius: BorderRadius.circular(41.8 * s),
          boxShadow: dark
              ? null
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.10),
                    offset: Offset(0, 3 * s),
                    blurRadius: 10 * s,
                  ),
                ],
          border: dark
              ? Border.all(
                  color: Colors.white.withValues(alpha: 0.08), width: 0.5)
              : null,
        ),
        child: Row(
          children: [
            _tab(0, 'tab_chat', t('home')),
            _tab(1, 'tab_contacts', t('contacts')),
            _tab(2, 'tab_moments', t('discover')),
            _tab(3, 'tab_settings', t('me')),
          ],
        ),
      ),
    );
  }

  /// 切 Tab。切到"我的"（index 3）时顺手拉一次余额 ——
  /// 后台给用户加了余额，用户不用杀 App 重进就能看到（B-20）。
  void _onTabTap(int i) {
    setState(() => _index = i);
    if (i == 3) WalletStore.instance.refresh();
  }

  /// 单个 Tab。[iconBase] = `assets/icons` 下的文件名前缀（如 tab_chat），
  /// 选中态自动换成 `<iconBase>_active.png`。
  Widget _tab(int i, String iconBase, String label) {
    final s = v2Scale(context);
    final active = i == _index;
    final dark = context.v2IsDark;

    // 图标：参考包 PNG 本身就是「未选中灰 / 选中近黑」，直接切图即可。
    // 深色模式下反相（黑→白），否则近黑图标贴在深色胶囊上看不见。
    Widget iconWidget = Image.asset(
      'assets/icons/$iconBase${active ? '_active' : ''}.png',
      width: 24 * s,
      height: 24 * s,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );
    if (dark) {
      iconWidget = ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          -1, 0, 0, 0, 255, //
          0, -1, 0, 0, 255, //
          0, 0, -1, 0, 255, //
          0, 0, 0, 1, 0, //
        ]),
        child: iconWidget,
      );
    }

    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _onTabTap(i),
        child: Center(
          child: Container(
            width: 82.7 * s,
            height: 66 * s,
            decoration: BoxDecoration(
              // 选中：浅灰胶囊（截图实测 #EAEAEA；复用 v2 填充 token 以兼容深色）
              color: active ? context.v2Fill : Colors.transparent,
              borderRadius: BorderRadius.circular(33 * s),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    iconWidget,
                    // 需求1："消息" tab 未读红点（ChatListPage 拉会话列表后上报总数）
                    if (i == 0)
                      ValueListenableBuilder<int>(
                        valueListenable: UnreadStore.instance.total,
                        builder: (_, unread, __) => unread > 0
                            ? Positioned(
                                right: -10 * s,
                                top: -7 * s,
                                child: _badge(unread),
                              )
                            : const SizedBox.shrink(),
                      ),
                    // 「联系人」tab 的好友申请红点（FriendReqStore）
                    if (i == 1)
                      ValueListenableBuilder<int>(
                        valueListenable: FriendReqStore.instance.count,
                        builder: (_, c, __) => c > 0
                            ? Positioned(
                                right: -10 * s,
                                top: -7 * s,
                                child: _badge(c),
                              )
                            : const SizedBox.shrink(),
                      ),
                  ],
                ),
                SizedBox(height: 7 * s),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14.3 * s,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                    height: 1.0,
                    // 截图实测：选中 #08080D、未选中 #1F2229（两者都近黑，不是灰）
                    color: active
                        ? (dark ? Colors.white : const Color(0xFF08080D))
                        : (dark
                            ? const Color(0xFFB0B3B8)
                            : const Color(0xFF1F2229)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 未读/申请角标：截图实测红底 #FF453A、直径 ≈19、白字 13、**外圈有一圈白描边**。
  Widget _badge(int count) {
    final s = v2Scale(context);
    return Container(
      constraints: BoxConstraints(minWidth: 19 * s, minHeight: 19 * s),
      padding: EdgeInsets.symmetric(horizontal: 5.5 * s),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFFF453A),
        borderRadius: BorderRadius.circular(10 * s),
        border: Border.all(color: Colors.white, width: 1.6 * s),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: TextStyle(
          fontSize: 13 * s,
          fontWeight: FontWeight.w600,
          height: 1.0,
          color: Colors.white,
        ),
      ),
    );
  }
}
