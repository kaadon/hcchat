import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/app_config.dart';
import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/e2ee_service.dart'; // E2EE 登录后静默建钥/解锁（§36）
import '../services/feature_flags.dart'; // 小助手开关（决定是否显示「改用验证码」）
import '../services/settings_service.dart';
import '../theme/app_theme.dart';
import '../widgets/agreement_checkbox.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/lang_picker.dart';
import '../widgets/v2_avatars.dart';
import '../widgets/v2_kit.dart';
import 'home_shell.dart';
import 'policy_page.dart';
import 'register_page.dart';

/// 等待其他设备批准的呼吸动效：外圈光环 + 设备图标做缩放/透明度呼吸。
/// 比裸 CircularProgressIndicator 更有「正在等待对方设备」的语义。
class _ApprovePulse extends StatefulWidget {
  final Color color;
  const _ApprovePulse({required this.color});

  @override
  State<_ApprovePulse> createState() => _ApprovePulseState();
}

class _ApprovePulseState extends State<_ApprovePulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);
  late final Animation<double> _scale = Tween(begin: 0.82, end: 1.12).animate(
    CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
  );
  late final Animation<double> _glow = Tween(begin: 0.2, end: 0.55).animate(
    CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 96,
      height: 96,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 外圈呼吸光环（描边，非填充，避免盖成实心圆盘）
          AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) => Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border:
                    Border.all(color: widget.color.withOpacity(_glow.value), width: 2.5),
              ),
            ),
          ),
          // 内圈设备图标：随呼吸缩放
          AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) => Transform.scale(
              scale: _scale.value,
              child: Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withOpacity(0.18),
                ),
                child: Icon(Icons.devices_other_rounded,
                    size: 30, color: widget.color),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 登录页（V2 复刻版：纯白底 + 近黑主按钮 + 灰色填充输入框）
///
/// 一屏改版（原独立游客引导页 GuestPage 已合并进本页）：
/// - 未登录启动直达本页；「一键注册登录」按钮仅在后端 guestOn 开启时显示
/// - 「找回账号密码」提示行与链接行已删除
/// - 顶部留白与表单间距整体压缩，保证一屏内显示完
///
/// 版式与尺寸全部来自 `UI-ref/DESIGN.md` —— 对目标 APK 真机截图做程序化取色与元素
/// bbox 测量得出（DPR=3，逻辑尺寸 420×1153），不是肉眼估的：
///
/// | 元素 | 尺寸（逻辑px） |
/// |---|---|
/// | 页面左右留白 | 51 |
/// | 输入框 | 高 69 / 圆角 16 / 填充 `#F1F2F4` |
/// | 主按钮（登录） | 高 65 / 填充 `#0C0D12` |
/// | 描边按钮（一键注册登录） | 高 64 |
/// | Logo | 118 圆角方形 |
/// | 应用名 | fontSize 32 / w800 |
///
/// 与旧版差异：去掉白色大卡片与品牌圆环加载动画（截图里没有），接口状态指示退居为
/// 左上角一个 6px 小点 + 10px 灰字（保留可观测性但不抢视觉），语言胶囊保留。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _accountCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _pwdFocus = FocusNode();
  final _codeCtrl = TextEditingController(); // 二次验证（验证码输入）
  bool _pwdVisible = false;
  bool _loading = false; // 密码登录中
  bool _quickLoading = false; // 一键注册登录中

  // ===== 账户安全验证（二次验证）=====
  // 非空即进入验证流程，包含 ticket / method('code'|'approve') / expiresIn
  Map<String, dynamic>? _verify;
  bool _verifyBusy = false; // 验证码提交中
  String? _verifyError; // 验证错误提示
  Timer? _pollTimer; // 审批方式下的轮询定时器
  bool _switchBusy = false; // 切换验证方式中
  bool _resendBusy = false; // 重新发送验证码中

  // ===== 后台下发品牌信息 =====
  AuthConfig? _cfg; // 完整配置（邀请码开关 inviteCodeOn 用）
  String _logoUrl = ''; // appLogo / brandLogo
  String _appName = ''; // appName / brandName（截图中 Logo 下方那行大字）
  bool _guestOn = false; // 一键注册登录开关（后端 /auth/config 的 guestOn）

  // ===== 协议勾选（App Store 审核合规）=====
  // 默认不勾（iOS 要求用户主动同意）；本地已同意过则默认勾上，免重复勾选。
  bool _agreeChecked = false;
  bool _agreeWarn = false; // 未勾选拦截提示态（淡红底 + 抖动）

  // ===== 接口状态指示（左上角：点 + 毫秒）=====
  // 0=检测中(灰) 1=正常(绿) 2=慢(黄) 3=不通(红)
  static const int _apiChecking = 0;
  static const int _apiOk = 1;
  static const int _apiSlow = 2;
  static const int _apiDown = 3;
  int _apiState = _apiChecking;
  int? _apiMs;
  Timer? _apiTimer;
  Dio? _apiProbe;

  final _svc = AuthService();

  @override
  void initState() {
    super.initState();
    // 拉取功能开关（含小助手 assistantOn）：幂等缓存，失败静默保持默认开启
    unawaited(FeatureFlags.instance.load());
    // 恢复本地「已同意协议」状态（勾选一次后不再要求重复勾）
    _agreeChecked = AppSettings.instance.policyAgreed;
    _loadBrand();
    _probeApi();
  }

  @override
  void dispose() {
    _apiTimer?.cancel();
    _apiProbe?.close();
    _pollTimer?.cancel();
    _accountCtrl.dispose();
    _pwdCtrl.dispose();
    _pwdFocus.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  // ============================================================
  // 品牌信息
  // ============================================================
  Future<void> _loadBrand() async {
    // 首帧即用启动页预加载好的缓存（同步上屏），网络刷新回来再覆盖：
    // 消「进登录页 logo/名字先显示占位、接口回来才变一下」。
    final pre = AuthService.cachedConfig;
    if (pre != null) _applyCfg(pre);
    try {
      final cfg = await _svc.preloadConfig();
      if (!mounted || cfg == null) return;
      _applyCfg(cfg);
    } catch (_) {
      // 接口失败静默回退默认品牌占位，不影响登录
    }
  }

  void _applyCfg(AuthConfig cfg) {
    setState(() {
      _cfg = cfg;
      _logoUrl = cfg.appLogo.isNotEmpty ? cfg.appLogo : cfg.brandLogo;
      _appName = cfg.appName.isNotEmpty ? cfg.appName : cfg.brandName;
      _guestOn = cfg.guestOn;
    });
  }

  /// 显示用应用名。接口未返回时回落后端同款默认值（AuthConfig 里也是 ChatPulse）。
  String get _displayAppName => _appName.isNotEmpty ? _appName : 'ChatPulse';

  // ============================================================
  // 接口延迟探测
  // ============================================================
  /// GET /api/v1/health，独立轻量 Dio（3s 超时，不走鉴权拦截器）。
  /// 服务器有任何响应（含 4xx/5xx）都算"通"，只有连接失败/超时才算不通。
  ///
  /// 自适应复测间隔（2026-09-19）：接口不通时 3 秒快探——iOS 首次安装的
  /// 「无线数据」授权弹窗期间探测全失败，用户同意后要快速自愈（改品牌/
  /// 状态点），固定 20 秒要等太久；通了再回到 20 秒慢探。
  Future<void> _probeApi() async {
    final sw = Stopwatch()..start();
    try {
      _apiProbe ??= Dio(BaseOptions(
        baseUrl: AppConfig.instance.apiBase,
        connectTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
        // 服务器返回任何状态码都算连通（health 正常是 200，这里宽容处理）
        validateStatus: (_) => true,
      ));
      // 8 秒硬性兜底超时（2026-09-20）：部分机型/网络下 Dio 的 connectTimeout
      // 偶发不生效（连接阶段挂死），探测 await 永不返回 → 状态点永远停在
      // 「检测中」。这层 Future.timeout 不依赖 Dio 内部实现，到点必抛，
      // 保证状态点最迟 8 秒出结果、复测定时器必然重排。
      await _apiProbe!
          .get('/api/v1/health')
          .timeout(const Duration(seconds: 8));
      sw.stop();
      if (!mounted) return;
      final ms = sw.elapsedMilliseconds;
      // 探测从"不通"恢复"通"，且品牌配置还没拿到（首次安装授权窗口里
      // preloadConfig 全失败过）→ 自动补拉一次，logo/名字/游客开关自愈
      if (_apiState == _apiDown && _cfg == null) {
        unawaited(_loadBrand());
      }
      setState(() {
        _apiMs = ms;
        _apiState = ms > 1000 ? _apiSlow : _apiOk;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _apiState = _apiDown;
        _apiMs = null;
      });
    } finally {
      _scheduleProbe();
    }
  }

  /// 按当前状态安排下一次探测：不通 3 秒快探（等授权/等网络自愈），通则 20 秒慢探。
  void _scheduleProbe() {
    if (!mounted) return;
    _apiTimer?.cancel();
    _apiTimer = Timer(
      _apiState == _apiDown
          ? const Duration(seconds: 3)
          : const Duration(seconds: 20),
      _probeApi,
    );
  }

  // ============================================================
  // 协议
  // ============================================================
  /// 勾选/取消协议（同步写本地持久化）
  Future<void> _toggleAgree(bool v) async {
    setState(() {
      _agreeChecked = v;
      _agreeWarn = false; // 勾选后立即解除红色提示态
    });
    await AppSettings.instance.setPolicyAgreed(v);
  }

  /// 未勾选拦截：Toast + 协议行淡红高亮 + 抖动（重复点击重复抖）
  void _flagAgreeWarn() {
    final t = AppLocalizations.of(context).t;
    AppDialogs.toast(context, t('termsAgreeRequired'));
    if (_agreeWarn) {
      // 已经处于提示态：先复位再下一帧重新触发，让抖动重放
      setState(() => _agreeWarn = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _agreeWarn = true);
      });
    } else {
      setState(() => _agreeWarn = true);
    }
  }

  /// 打开协议详情页（isPrivacy=false → 用户服务协议；true → 隐私政策）
  void _openPolicy({required bool isPrivacy}) {
    final t = AppLocalizations.of(context).t;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PolicyPage(
        title: t(isPrivacy ? 'mePrivacyPolicy' : 'meTermsOfService'),
        content: isPrivacy ? kPrivacyPolicy : kTermsOfService,
        appName: _appName,
      ),
    ));
  }

  // ============================================================
  // 登录
  // ============================================================
  Future<void> _doLogin() async {
    final t = AppLocalizations.of(context).t;
    // App Store 合规：未同意协议不得登录（淡红高亮 + 抖动 + Toast）
    if (!_agreeChecked) {
      _flagAgreeWarn();
      return;
    }
    final account = _accountCtrl.text.trim();
    if (account.isEmpty) {
      AppDialogs.toast(context, t('loginAccountRequired'));
      return;
    }
    if (account.length < 3) {
      AppDialogs.toast(context, t('loginAccountTooShort'));
      return;
    }
    // 登录侧只校验「非空」：密码强度规则归注册/改密管，这里再卡长度只会
    // 拦住历史短密码账号登录，属于纯误伤（后端仍会正常校验）。
    final password = _pwdCtrl.text.trim();
    if (password.isEmpty) {
      AppDialogs.toast(context, t('loginPwdRequired'));
      return;
    }

    setState(() => _loading = true);
    try {
      // 带上设备号 + 设备类型：服务端据此登记 device 表行，
      // 设备页「当前设备」/活跃会话才能看到本机（H5 类型是 3 Web）
      final deviceId = await ApiClient.instance.getDeviceId();
      final r = await _svc.login(account, password,
          deviceId: deviceId, deviceType: AuthService.detectDeviceType());
      if (!mounted) return;
      // 账户安全验证（二次验证）：密码已校验通过，服务端要求额外验证。
      // 移动端只会收到 method='approve'（等待其它可信设备批准）；此处仍保留
      // code 分支做兜底——若服务端未来对移动端下发验证码也能正确处理。
      if (r.verifyRequired) {
        _enterVerify(r);
        return;
      }
      await _completeLogin(r);
    } catch (e) {
      if (!mounted) return;
      // 网络超时/连接失败不再 dump 原始 DioException，给可读提示
      AppDialogs.toast(context, _friendlyError(e, t));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 密码校验通过、拿到登录结果后的统一收尾：存 token + 静默建 E2EE 密钥 + 跳主页。
  /// 正常登录与二次验证（输码/审批通过）共用，避免成功路径重复。
  Future<void> _completeLogin(AuthResult r) async {
    final t = AppLocalizations.of(context).t;
    final password = _pwdCtrl.text.trim();
    await ApiClient.instance.saveToken(r.accessToken);
    await ApiClient.instance.saveRefresh(r.refreshToken);
    // 多账号切换：记住本账号（Telegram 式），供后续一键切换
    unawaited(_rememberAccount(r));
    // E2EE（§36）：手里还有明文密码 → 静默建钥/解锁备份（首次登录自动开）。
    // 后台模式非 e2ee / 网络失败均静默跳过，不阻断登录。
    unawaited(E2eeService.instance.setupAfterLogin(password));
    if (!mounted) return;
    AppDialogs.toast(context, t('loginSuccess'));
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeShell()),
      (route) => false,
    );
  }

  // ===== 账户安全验证（二次验证）=====

  /// 登录成功后把账号记入「多账号切换」列表（Telegram 式，上限 10）。
  Future<void> _rememberAccount(AuthResult r) async {
    try {
      final u = r.user;
      final id = u['id']?.toString() ?? '';
      final account = (u['account'] ?? u['username'] ?? '').toString();
      await ApiClient.instance.rememberAccount(
        id: id,
        account: account,
        nickname: (u['nickname'] ?? '').toString(),
        avatar: (u['avatar'] ?? '').toString(),
        accessToken: r.accessToken,
        refreshToken: r.refreshToken,
      );
    } catch (_) {}
  }

  /// 进入二次验证界面：记录会话信息，按 method 分支进入输码 / 等待批准。
  void _enterVerify(AuthResult r) {
    setState(() {
      _loading = false;
      _verify = {
        'ticket': r.verifyTicket,
        'method': r.verifyMethod,
        'expiresIn': r.verifyExpiresIn,
      };
      _verifyError = null;
      _codeCtrl.clear();
    });
    // 审批方式：后台已向可信设备推送登录请求，本机轮询结果。
    if (r.verifyMethod == 'approve') {
      _pollOnce();
    }
  }

  /// 取消二次验证，回到普通登录表单。
  void _cancelVerify() {
    _pollTimer?.cancel();
    _pollTimer = null;
    setState(() {
      _verify = null;
      _verifyError = null;
      _codeCtrl.clear();
    });
  }

  /// 验证码方式提交：调 /auth/verify/code 换取 token，成功即登录。
  Future<void> _submitCode() async {
    if (_verifyBusy) return;
    final t = AppLocalizations.of(context).t;
    final ticket = _verify?['ticket'] as String? ?? '';
    final code = _codeCtrl.text.trim();
    if (code.isEmpty) {
      setState(() => _verifyError = t('verifyCodeEmpty'));
      return;
    }
    setState(() {
      _verifyBusy = true;
      _verifyError = null;
    });
    try {
      final res = await _svc.verifyByCode(ticket, code);
      if (!mounted) return;
      _pollTimer?.cancel();
      await _completeLogin(res);
    } catch (e) {
      if (!mounted) return;
      setState(() => _verifyError = _friendlyError(e, t));
    } finally {
      if (mounted) setState(() => _verifyBusy = false);
    }
  }

  /// 审批方式轮询：每 2s 查一次 /auth/verify/poll。
  /// 已批准 → 登录；终态（拒绝/过期）→ 提示并停止；网络抖动 → 静默继续。
  Future<void> _pollOnce() async {
    if (_verify == null) return;
    final ticket = _verify!['ticket'] as String;
    var reschedule = true;
    try {
      final res = await _svc.verifyPoll(ticket);
      if (!mounted) return;
      if (res != null) {
        _pollTimer?.cancel();
        reschedule = false;
        await _completeLogin(res);
        return;
      }
    } on VerifyTerminalException catch (e) {
      _pollTimer?.cancel();
      reschedule = false;
      if (!mounted) return;
      setState(() => _verifyError = e.toString());
    } catch (_) {
      // 网络抖动：保持轮询，不提示
    }
    if (reschedule && mounted && _verify != null) {
      _pollTimer = Timer(const Duration(seconds: 2), _pollOnce);
    }
  }

  /// 重新发送验证码：复用「切到 code」逻辑（服务端经小助手发新码 + 刷新时效），
  /// 单设备一天最多重发 5 次（服务端 4109 拦截，超限给可读提示）。
  Future<void> _resendCode() async {
    if (_resendBusy || _verify == null) return;
    final t = AppLocalizations.of(context).t;
    final ticket = _verify!['ticket'] as String? ?? '';
    setState(() => _resendBusy = true);
    try {
      await _svc.verifySwitch(ticket, 'code');
      if (!mounted) return;
      setState(() {
        _verifyError = null;
        _codeCtrl.clear();
      });
      AppDialogs.toast(context, t('verifyResendOk'));
    } catch (e) {
      if (!mounted) return;
      AppDialogs.toast(context, _friendlyError(e, t));
    } finally {
      if (mounted) setState(() => _resendBusy = false);
    }
  }

  /// 切换验证方式（同一 verify 会话内 code/approve 互切）。
  /// 切到 code：停掉审批轮询，等待用户在小助手会话里拿到验证码后输入；
  /// 切到 approve：重新发起轮询等待对方设备批准。
  Future<void> _switchMethod(String method) async {
    if (_switchBusy || _verify == null) return;
    final t = AppLocalizations.of(context).t;
    final ticket = _verify!['ticket'] as String? ?? '';
    setState(() => _switchBusy = true);
    try {
      await _svc.verifySwitch(ticket, method);
      if (!mounted) return;
      if (method == 'code') {
        _pollTimer?.cancel();
        _pollTimer = null; // 已改走验证码，不再轮询审批
      } else {
        _pollOnce(); // 切回设备批准：重新开始轮询
      }
      setState(() {
        _verify = {..._verify!, 'method': method};
        _verifyError = null;
      });
    } catch (e) {
      if (!mounted) return;
      // 服务端返回可读错误（如小助手未开启/无审批设备），直接提示
      AppDialogs.toast(context, _friendlyError(e, t));
    } finally {
      if (mounted) setState(() => _switchBusy = false);
    }
  }

  /// 一键注册登录：按设备号幂等建号并直接进入（复用后端 `/auth/guest`）。
  /// 由原独立游客引导页 GuestPage 合并而来：后台开启游客登录（guestOn）时
  /// 才显示该按钮，对应文案「无需填写资料，直接创建正式账号」。
  Future<void> _doQuickRegister() async {
    final t = AppLocalizations.of(context).t;
    if (!_agreeChecked) {
      _flagAgreeWarn();
      return;
    }
    if (_quickLoading) return;
    if (!_guestOn) {
      AppDialogs.toast(context, t('loginQuickDisabled'));
      return;
    }
    setState(() => _quickLoading = true);
    try {
      final deviceId = await ApiClient.instance.getDeviceId();
      AuthResult r;
      try {
        // 先静默登录（2026-09-17 二次需求）：老游客同设备复用时服务端
        // 不校验邀请码 → 直接进，不再弹码；只有【新游客 + 后台开启
        // 邀请码强制】才报 2003，此时才弹必填弹窗。
        r = await _svc.guestRegister(
          deviceId: deviceId,
          deviceType: _deviceType,
        );
      } on InviteRequiredException {
        // 新设备首次创建游客：邀请码**必填**弹窗——服务端强制校验、
        // 不允许跳过（无效码 2003 弹窗内报错不关闭）。
        final got = await _showRequiredInviteDialog(deviceId);
        if (!mounted) return;
        if (got == null) return; // 弹窗不可关闭，仅页面销毁时为 null
        r = got;
      }
      await ApiClient.instance.saveToken(r.accessToken);
      await ApiClient.instance.saveRefresh(r.refreshToken);
      // 多账号切换：记住本账号（游客也入列，同设备可切回）
      unawaited(_rememberAccount(r));
      // E2EE（2026-09-18）：游客也建钥（§36 默认开启）。游客无登录密码，
      // setupForGuest 内部用一次性随机口令包裹备份 —— 同设备复用走本机私钥。
      unawaited(E2eeService.instance.setupForGuest());
      if (!mounted) return;
      // 新游客随机分配一张内置预设头像（二十批需求）。仅 isNewGuest 时执行：
      // 同设备复用老账号时不覆盖用户已选头像。做法与注册页一致（v2_avatars.dart
      // 顶部注释）：预设头像必须真上传成 URL —— 多端都按 URL 渲染头像，存本地
      // 路径会破图。失败静默降级，不阻断登录（可后续在个人资料里换）。
      if (r.isNewGuest) {
        // 头像上传改后台执行（三次紧凑同批）：两次 HTTP 不再阻塞进主页，
        // AppAvatar 无 URL 时有内置默认头像回落，中途不会破图。
        unawaited(_applyRandomAvatar());
      }
      AppDialogs.toast(context, t('loginQuickDone'));
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeShell()),
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      AppDialogs.toast(context, _friendlyError(e, t));
    } finally {
      if (mounted) setState(() => _quickLoading = false);
    }
  }

  /// 新游客随机头像（二十批 #2）：从 6 张内置预设里随机选一张，读字节直传
  /// `/upload` 成 URL 后 `PUT /user/profile` 写回（与注册页 `_applyAvatar`
  /// 同款链路）。任何失败都静默 —— 头像不是登录的必要条件。
  Future<void> _applyRandomAvatar() async {
    try {
      final i = Random().nextInt(kV2AvatarAssets.length);
      final data = await rootBundle.load(kV2AvatarAssets[i]);
      final bytes = data.buffer.asUint8List();
      final up = await ApiClient.instance
          .uploadBytes(bytes, 'avatar_${i + 1}.png', dir: 'avatar/');
      final url = (up['url'] ?? '').toString();
      if (url.isEmpty) return;
      final r = await ApiClient.instance
          .put('/api/v1/user/profile', data: {'avatar': url});
      final code = (r.data is Map ? r.data['code'] : null);
      if (code is num && code.toInt() != 0) return;
    } catch (_) {
      // 静默降级
    }
  }

  /// 游客登录**必填**邀请码弹窗（2026-09-17 需求）：后台开启 inviteCodeOn 时，
  /// 填码 → 直接调 `/auth/guest`（服务端强制校验，无效码 2003 弹窗内报错、
  /// 不关闭）。无「跳过」按钮、不可点外部关闭；右上角关闭按钮与系统返回键可
  /// 放弃注册。成功 pop 返回登录结果，关闭时 pop null（调用方据此中止并复位）。
  Future<AuthResult?> _showRequiredInviteDialog(String deviceId) async {
    final codeCtrl = TextEditingController();
    var loading = false;
    var err = '';
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    const primary = AppTheme.primary;
    return showDialog<AuthResult>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: true, // 2026-11-01：允许系统返回键关闭（与右上角关闭按钮同义）
        child: StatefulBuilder(
          builder: (ctx, setSt) => AlertDialog(
            // 2026-11-01 需求：弹窗原先没有任何关闭入口（外部点击 + 返回键都被
            // 屏蔽），新游客必须填码才能出去。补右上角关闭按钮 → pop(null)，
            // 调用方 _doQuickRegister 视为放弃本次一键注册，回到登录页。
            title: Row(
              children: [
                Expanded(child: Text(t('guestInviteTitle'))),
                IconButton(
                  onPressed:
                      loading ? null : () => Navigator.of(ctx).pop(null),
                  icon: const Icon(Icons.close_rounded),
                  iconSize: 20,
                  color: scheme.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  tooltip: t('cancel'),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 2026-11-01 按需求移除「填写邀请码自动添加好友」提示小字
                TextField(
                  controller: codeCtrl,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 1.5,
                      color: scheme.onSurface),
                  decoration: InputDecoration(
                    hintText: t('guestInviteInputHint'),
                    hintStyle: TextStyle(
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
                    prefixIcon: const Padding(
                      padding: EdgeInsets.only(left: 12, right: 8),
                      child: Icon(Icons.confirmation_number_outlined,
                          color: primary, size: 20),
                    ),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 0, minHeight: 0),
                    filled: true,
                    fillColor: scheme.surfaceContainerHighest,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 16),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                          color: scheme.outlineVariant.withValues(alpha: 0.5)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: primary, width: 1.6),
                    ),
                  ),
                ),
                if (err.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(err,
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.danger)),
                ],
              ],
            ),
            actions: [
              ElevatedButton(
                onPressed: loading
                    ? null
                    : () async {
                        final code = codeCtrl.text.trim();
                        if (code.isEmpty) {
                          setSt(() => err = t('guestInviteInvalid'));
                          return;
                        }
                        setSt(() {
                          loading = true;
                          err = '';
                        });
                        try {
                          final r = await _svc.guestRegister(
                            deviceId: deviceId,
                            deviceType: _deviceType,
                            inviteCode: code,
                          );
                          if (!ctx.mounted) return;
                          Navigator.of(ctx).pop(r);
                        } catch (e) {
                          setSt(() {
                            loading = false;
                            err = e.toString().replaceFirst('Exception: ', '');
                          });
                        }
                      },
                child: Text(t('guestInviteConfirm')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  int get _deviceType {
    // 设备类型与 im-server GuestRegister 对齐：1=Android 2=iOS 3=Web 4=Windows 5=macOS
    // 用 defaultTargetPlatform 替代 dart:io Platform（Web 上 dart:io Platform 抛
    // Unsupported operation: Platform._operatingSystem 直接崩页）。
    if (kIsWeb) return 3;
    if (defaultTargetPlatform == TargetPlatform.iOS) return 2;
    return 1; // Android 等默认
  }

  String _friendlyError(
      Object e, String Function(String, [Map<String, String>]) t) {
    final msg = e is DioException && ApiClient.isTransient(e)
        ? t('bootLoadFailed')
        : e.toString().replaceFirst('Exception: ', '');
    return msg.isEmpty ? t('unknownError') : msg;
  }

  void _goRegister() {
    // 用 push 而非 pushReplacement：截图里目标页顶部有返回箭头，允许退回登录页
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const RegisterPage()),
    );
  }

  // ===== 二次验证界面（替换登录表单）=====
  /// 根据验证方式渲染对应界面：code=输码；approve=等待设备批准。
  List<Widget> _verifyChildren(
      String Function(String, [Map<String, String>]) t) {
    final method = _verify!['method'] as String? ?? '';
    final scheme = Theme.of(context).colorScheme;
    final err = _verifyError;
    if (method == 'code') {
      return [
        Text(t('verifyTitle'),
            style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: scheme.onSurface)),
        const SizedBox(height: 8),
        Text(t('verifyCodeHint'),
            style: TextStyle(fontSize: 14, color: context.v2MutedColor)),
        const SizedBox(height: 20),
        TextField(
          controller: _codeCtrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submitCode(),
          style: const TextStyle(
              fontSize: 22, letterSpacing: 6, fontWeight: FontWeight.w600),
          decoration: InputDecoration(
            hintText: t('verifyCodePh'),
            filled: true,
            fillColor: scheme.surfaceContainerHighest,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          ),
        ),
        if (err != null) ...[
          const SizedBox(height: 10),
          Text(err,
              style: const TextStyle(fontSize: 13, color: AppTheme.danger)),
        ],
        const SizedBox(height: 18),
        V2PrimaryButton(
          label: t('verifySubmit'),
          loading: _verifyBusy,
          onPressed: _submitCode,
        ),
        const SizedBox(height: 12),
        // 已输码界面也可切回「设备批准」（需存在可信设备，否则服务端提示）
        TextButton(
          onPressed: () => _switchMethod('approve'),
          child: Text(t('verifySwitchToApprove')),
        ),
        const SizedBox(height: 12),
        // 验证码 5 分钟时效：过期/未收到可重新发送（服务端按设备限一天 5 次）
        TextButton(
          onPressed: _resendBusy ? null : _resendCode,
          child: _resendBusy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(t('verifyResend')),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: _cancelVerify,
          child: Text(t('cancel')),
        ),
      ];
    }
    // approve：等待其它可信设备批准
    final assistantOn = FeatureFlags.instance.assistantOn.value;
    return [
      Text(t('verifyTitle'),
          style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: scheme.onSurface)),
      const SizedBox(height: 8),
      Text(t('verifyApproveHint'),
          style: TextStyle(fontSize: 14, color: context.v2MutedColor)),
      const SizedBox(height: 30),
      // 呼吸动效（替代裸 spinner）：外圈光环 + 设备图标缩放/透明度呼吸，
      // 直观传达「正在等待对方设备批准」的等待语义。
      if (err == null) _ApprovePulse(color: context.v2ActionBg),
      if (err != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(err,
              style: const TextStyle(fontSize: 13, color: AppTheme.danger)),
        ),
      const SizedBox(height: 10),
      Text(
        err != null ? '' : t('verifyApproveWaiting'),
        style: TextStyle(fontSize: 14, color: context.v2MutedColor),
      ),
      const SizedBox(height: 22),
      // 小助手开启时提供「改用验证码」入口（服务端经小助手发码）
      if (assistantOn && err == null)
        V2PrimaryButton(
          label: t('verifySwitchToCode'),
          loading: _switchBusy,
          onPressed: () => _switchMethod('code'),
        ),
      const SizedBox(height: 12),
      TextButton(
        onPressed: _cancelVerify,
        child: Text(t('cancel')),
      ),
    ];
  }

  // ============================================================
  // 构建
  // ============================================================
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final isDark = context.v2IsDark;
    final screenW = MediaQuery.sizeOf(context).width;
    // 左右留白按截图 51；窄屏（<420 逻辑宽）按 12.2% 等比缩，否则 360 宽机型
    // 两侧各吃掉 51 会明显比设计稿瘦。
    final gutter = screenW <= 420
        ? (screenW * 0.122).clamp(18.0, AppTheme.v2Gutter)
        : AppTheme.v2Gutter;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        // 截图是纯白底（深色模式纯黑），不是旧的浅灰
        backgroundColor: context.v2Bg,
        resizeToAvoidBottomInset: true,
        // 2026-09-20 加固：去掉此前包裹整个页面的 Opacity（入场淡入）——
        // 它把所有输入/按钮都罩在一个逐帧 saveLayer 里，真机上还观察
        // 到疑似卡死。现在页面主体永远全透明度、完全可交互；入场动画
        // 只隐藏 logo 槽位（见下方 KeyedSubtree），覆盖层飞到位后补上。
        body: SafeArea(
          child: LayoutBuilder(
            builder: (ctx, c) {
              // 纵向自适应（见 v2_kit.v2VScale）：设计稿是按逻辑高 1153 的机型出的，
              // 那些绝对值直接搬到 800 高的屏上，「留白+Logo+应用名」会吃掉近一半屏。
              // 系数：屏高 ≥1150 → 1.0（与设计稿一致）；800 → 约 0.65；≤700 → 0.55。
              // 顶部留白上限整体压低（一屏改版：尽量不滚动即可见全表单）。
              // 2026-09-15 三次紧凑：Logo→名/名→表单上限减半（用户反馈名字上下留白太高）。
              final v = v2VScale(context);
              final topGap = (96 * v).clamp(10.0, 36.0); // SafeArea→Logo 留白
              final logoSize = (118 * v).clamp(72.0, 118.0); // Logo 边长
              final gapLogoName = (57 * v).clamp(5.0, 14.0); // Logo→应用名
              final gapNameForm = (70 * v).clamp(6.0, 16.0); // 应用名→表单
              final nameFontSize = (32 * v).clamp(26.0, 32.0); // 应用名字号
              return SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    // ── 顶栏：接口指示（退居）+ 语言切换（保留）──
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                      child: Row(
                        children: [
                          _buildApiStatusChip(t),
                          const Spacer(),
                          _buildLangChip(),
                        ],
                      ),
                    ),
                    SizedBox(height: topGap),
                    // Logo：截图是 118 圆角方形（旧版是圆 + 蓝色光晕，已去掉）
                    _brandLogo(size: logoSize),
                    SizedBox(height: gapLogoName),
                    // 应用名（后台配置名，接口未返回回落 ChatPulse）
                    Text(
                      _displayAppName,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: nameFontSize,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.2,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    SizedBox(height: gapNameForm),
                    // ── 表单区（无卡片，直接落在白底上）──
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: gutter),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: _verify != null
                            ? _verifyChildren(t)
                            : _formChildren(t),
                      ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  List<Widget> _formChildren(String Function(String, [Map<String, String>]) t) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final muted = context.v2MutedColor;
    return [
      // ① 账号
      V2Field(
        controller: _accountCtrl,
        hint: t('loginAccountHint'),
        icon: Icons.person_outline_rounded,
        textInputAction: TextInputAction.next,
        autofillHints: const [AutofillHints.username],
        onSubmitted: (_) => _pwdFocus.requestFocus(),
      ),
      const SizedBox(height: 12),
      // ② 密码（右侧睁眼/闭眼）
      V2Field(
        controller: _pwdCtrl,
        hint: t('loginPwdHint'),
        icon: Icons.lock_outline_rounded,
        focusNode: _pwdFocus,
        obscureText: !_pwdVisible,
        textInputAction: TextInputAction.done,
        autofillHints: const [AutofillHints.password],
        onSubmitted: (_) => _doLogin(),
        suffix: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _pwdVisible = !_pwdVisible),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(
              _pwdVisible
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 20,
              color: context.v2HintColor,
            ),
          ),
        ),
      ),
      const SizedBox(height: 18),
      // ③ 协议勾选行（plain：截图里是白底裸文字，没有灰底圆角块）
      AgreementCheckbox(
        checked: _agreeChecked,
        warn: _agreeWarn,
        onToggle: _toggleAgree,
        onOpenTerms: () => _openPolicy(isPrivacy: false),
        onOpenPrivacy: () => _openPolicy(isPrivacy: true),
        plain: true,
        checkColor: context.v2ActionBg,
      ),
      const SizedBox(height: 18),
      // ④ 主按钮（近黑填充）
      V2PrimaryButton(
        label: t('loginSubmit'),
        loading: _loading,
        onPressed: _doLogin,
      ),
      // ⑤ 一键注册登录区：后台开启游客登录（/auth/config 的 guestOn）才显示；
      //    未开启时整块（分隔线+按钮+说明）不渲染，登录页更紧凑。
      if (_guestOn) ...[
        const SizedBox(height: 14),
        V2OrDivider(label: t('loginOr')),
        const SizedBox(height: 14),
        V2OutlineButton(
          label: t('loginQuickRegister'),
          loading: _quickLoading,
          onPressed: _doQuickRegister,
        ),
        const SizedBox(height: 8),
        Text(
          t('loginQuickRegisterDesc'),
          textAlign: TextAlign.center,
          // 实测 15 字占 227.3 逻辑px → 15.2 ≈ 15
          style: TextStyle(fontSize: 15, color: muted),
        ),
      ],
      const SizedBox(height: 20),
      // ⑥ 底部：还没有账号？立即注册
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            t('loginNoAccount'),
            // 实测 9 字（含间隔）占 181.7 逻辑px → 单字步进 17.3 ≈ 17
            style: TextStyle(fontSize: 17, color: muted),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _goRegister,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                t('registerNow'),
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: onSurface,
                ),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
    ];
  }

  // ========= 品牌 Logo（118 圆角方形；接口图片优先，失败回退占位） =========
  Widget _brandLogo({double size = 118}) {
    if (_logoUrl.isEmpty) return AppTheme.brandAvatar(size: size);
    final radius = BorderRadius.circular(size / 4);
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: radius,
        // 加载中 / 加载失败都露出底层品牌占位，避免白块
        child: Stack(
          fit: StackFit.expand,
          children: [
            AppTheme.brandAvatar(size: size),
            Image.network(
              _logoUrl,
              fit: BoxFit.cover,
              frameBuilder: (ctx, child, frame, wasSync) =>
                  (wasSync || frame != null) ? child : const SizedBox.shrink(),
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  // ========= 左上角接口状态指示（退居版：无胶囊底、无阴影，6px 点 + 10px 灰字） =========
  Widget _buildApiStatusChip(
    String Function(String, [Map<String, String>]) t,
  ) {
    late final Color dot;
    late final String label;
    switch (_apiState) {
      case _apiOk:
        dot = const Color(0xFF34C759); // 绿：正常
        label = '${_apiMs ?? 0}ms';
        break;
      case _apiSlow:
        dot = const Color(0xFFFFB020); // 黄：慢（>1000ms）
        label = '${_apiMs ?? 0}ms';
        break;
      case _apiDown:
        dot = const Color(0xFFE5484D); // 红：不通
        label = t('apiDown');
        break;
      default:
        dot = const Color(0xFF9E9E9E); // 灰：检测中
        label = t('apiChecking');
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: context.v2MutedColor,
            fontWeight: FontWeight.w500,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  // ========= 右上角语言入口（点击弹语言菜单，见 widgets/lang_picker.dart） =========
  Widget _buildLangChip() {
    // 显示当前语言；点开弹窗可四语切换或恢复跟随系统
    final cur = AppLocalizations.of(context).locale;
    final curLabel = AppLocalizations.langNativeName(cur);
    return Material(
      color: context.v2Fill,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => showLangPicker(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.language, size: 15, color: context.v2MutedColor),
              const SizedBox(width: 5),
              Text(
                curLabel,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
