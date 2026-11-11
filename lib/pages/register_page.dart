import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/e2ee_service.dart'; // E2EE 注册成功静默建钥（§36）
import '../services/settings_service.dart';
import '../theme/app_theme.dart';
import '../widgets/agreement_checkbox.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/v2_avatars.dart';
import '../widgets/v2_kit.dart';
import 'home_shell.dart';
import 'login_page.dart';
import 'policy_page.dart';

// 注册页（两步式，按参考 APK 截图复刻，规格见 `UI-ref/DESIGN.md` §3）
//
//   第 1 步「创建账号」：步骤指示器 + 头像预览 + 用户名 + 密码 + 确认密码 → 「下一步」
//   第 2 步「完善资料」：头像预览(相机徽标) + 选择一个头像(6 个预设) + 从相册选择
//                        + 昵称 + 邀请码 + 协议勾选 + 「完成注册」
//
// 关键设计决定（都有依据，改动前请先看 DESIGN.md）：
// 1. **两步不是两个接口**：两步收集完，最后一次性 POST /api/v1/auth/register。
//    服务端 RegisterReq 要什么就填什么，缺字段不影响（如昵称留空则由后端按账号生成）。
// 2. **注册接口没有 avatar 字段**，所以头像走「注册成功后补写」：
//    POST /api/v1/upload（字节直传，不落盘）→ PUT /api/v1/user/profile 写回 URL。
//    这样 user.avatar 里存的是普通 URL，im-pc / im-uniapp 不需要为「预设头像」做适配。
// 3. **校验提示一律走 Toast**：V2Field 是固定高 69 的框，塞 errorText 必 RenderFlex 溢出。
// 4. 尺寸全部按参考逻辑宽 420 推导，再乘 `v2Scale` —— 窄屏自动等比缩，宽屏限宽 420。

/// 第 1 步头像预览直径（实测 111.7）
const double _kAvatarStep1 = 112;

/// 第 2 步头像预览直径（实测 128.7）
const double _kAvatarStep2 = 129;

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  /// 1 = 创建账号；2 = 完善资料
  int _step = 1;

  // 第 1 步
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirmPwd = TextEditingController();

  // 第 2 步
  final _nickname = TextEditingController();
  final _inviteCode = TextEditingController();

  // 认证模式开启时才用到的字段（默认配置下不渲染，截图里的第 1 步没有它们）
  final _captchaCode = TextEditingController();
  final _smsCode = TextEditingController();

  final _svc = AuthService();
  final _api = ApiClient.instance;

  AuthConfig? _config;
  bool _loading = false;
  bool _pwdVisible = false;
  bool _confirmPwdVisible = false;

  /// 选中的预设头像下标（第 1 步先随机给一个，第 2 步可换）
  int _avatarIndex = 0;

  /// 从相册选的图（只存在内存里，注册成功后再上传）
  Uint8List? _galleryBytes;
  String _galleryName = 'avatar.jpg';

  /// 用户名校验状态：'' | 'checking' | 'ok' | 'taken'
  String _unameState = '';

  // ===== 协议勾选（App Store 审核合规）=====
  bool _agreeChecked = false;
  bool _agreeWarn = false;

  // 图形验证码 + 短信验证码
  Captcha? _captcha;
  Uint8List? _captchaBytes;
  int _smsLeft = 0;
  Timer? _smsTimer;

  @override
  void initState() {
    super.initState();
    // 第 1 步就露出的头像预览：先随机挑一张预设，两侧保持同一个选择
    _avatarIndex = DateTime.now().microsecondsSinceEpoch % kV2AvatarAssets.length;
    _load();
  }

  /// 注册方式（2026-09-22 需求6）：account（账号密码，历史行为）/ phone / email。
  /// 新服务端直接下发 registerType；老服务端缺字段时按 authMode 推导兜底
  /// （sms→phone、email→email、none→account），存量部署行为不变
  String get _regType {
    final rt = _config?.registerType ?? '';
    if (rt == 'account' || rt == 'phone' || rt == 'email') return rt;
    switch (_config?.authMode) {
      case 'sms':
        return 'phone';
      case 'email':
        return 'email';
      default:
        return 'account';
    }
  }

  /// 是否需要短信/邮箱验证码（2026-09-22 需求6）：
  /// 仅注册方式为手机/邮箱且后台「开启注册认证」时需要；
  /// **账号密码注册方式即使开启认证也不需要**（需求原文口径）。
  /// registerVerifyOn 为 null（老服务端未下发）→ 沿用旧语义 authMode != none
  bool get _needAuth {
    final cfg = _config;
    if (cfg == null) return false;
    if (cfg.registerVerifyOn == null) {
      final m = cfg.authMode;
      return m == 'sms' || m == 'email';
    }
    return cfg.registerVerifyOn! && _regType != 'account';
  }

  /// 是否需要图形验证码：仅在「开启手机/邮箱认证」且后台打开了图形验证码时。
  /// 图文码是发手机/邮箱验证码的前置门槛；认证模式为 none 时根本不发码，自然不要。
  bool get _needCaptcha => _needAuth && (_config?.captchaOn ?? false);

  Future<void> _load() async {
    _agreeChecked = AppSettings.instance.policyAgreed;
    final cfg = await _svc.getConfig();
    if (!mounted) return;
    setState(() => _config = cfg);
    if (_needCaptcha) await _loadCaptcha();
  }

  /// 勾选/取消协议（同步写本地持久化）
  Future<void> _toggleAgree(bool v) async {
    setState(() {
      _agreeChecked = v;
      _agreeWarn = false;
    });
    await AppSettings.instance.setPolicyAgreed(v);
  }

  /// 未勾选拦截：Toast + 协议行淡红高亮 + 抖动（重复点击重复抖）
  void _flagAgreeWarn() {
    AppDialogs.toast(context, t('termsAgreeRequired'));
    if (_agreeWarn) {
      setState(() => _agreeWarn = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _agreeWarn = true);
      });
    } else {
      setState(() => _agreeWarn = true);
    }
  }

  String Function(String, [Map<String, String>]) get t =>
      AppLocalizations.of(context).t;

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    AppDialogs.toast(context, msg);
  }

  /// 打开协议详情页（isPrivacy=false → 用户服务协议；true → 隐私政策）
  void _openPolicy({required bool isPrivacy}) {
    final cfg = _config;
    final appName =
        (cfg?.appName.isNotEmpty ?? false) ? cfg!.appName : (cfg?.brandName ?? '');
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PolicyPage(
        title: t(isPrivacy ? 'mePrivacyPolicy' : 'meTermsOfService'),
        content: isPrivacy ? kPrivacyPolicy : kTermsOfService,
        appName: appName,
      ),
    ));
  }

  // ================= 第 1 步 =================

  /// 用户名规则：6-20 位，仅限英文、数字、下划线（2026-09-28 需求1：下限 3→6）。
  /// 注意只收紧注册入口：后端 isUsername 仍为 3-20 且登录也在用，
  /// 若改后端会把老的 3-5 位账号锁在登录门外，故仅 App 注册侧限制。
  static final RegExp _unameRe = RegExp(r'^[A-Za-z0-9_]{6,20}$');

  /// 「下一步」：校验第 1 步 → 查账号可用性 → 进第 2 步
  Future<void> _next() async {
    final u = _username.text.trim();
    if (u.isEmpty) {
      _toast(t('regUsernameRequired'));
      return;
    }
    // 注册方式账号格式（2026-09-22 需求6）：phone=5-20 位纯数字（对齐服务端
    // isPhone）、email=含 @ 和 .（对齐服务端 isEmail）、account=用户名规则（历史）
    switch (_regType) {
      case 'phone':
        if (!RegExp(r'^\d{5,20}$').hasMatch(u)) {
          _toast(t('regPhoneInvalid'));
          return;
        }
      case 'email':
        if (!(u.contains('@') && u.contains('.'))) {
          _toast(t('regEmailInvalid'));
          return;
        }
      default:
        // 2026-09-28 需求1：账号下限 3→6 位（密码 6-20 本来就有校验）
        if (!_unameRe.hasMatch(u)) {
          _toast(t('regUsernameRule'));
          return;
        }
    }
    final pwdLen = _password.text.runes.length; // 按字符数计，与后端一致
    if (pwdLen < 6 || pwdLen > 20) {
      _toast(t('regPwdRule'));
      return;
    }
    if (_password.text != _confirmPwd.text) {
      _toast(t('pwdMismatch'));
      return;
    }
    // 后台开启认证模式时的前置校验（默认配置下不会走到）
    if (_needCaptcha) {
      if (_captcha == null) {
        _toast(t('captchaLoading'));
        return;
      }
      if (_captchaCode.text.trim().isEmpty) {
        _toast(t('captchaRequired'));
        return;
      }
    }
    if (_needAuth && _smsCode.text.trim().isEmpty) {
      _toast(t('smsCodeRequired'));
      return;
    }
    late final AuthConfig cfg;
    try {
      cfg = await _svc.getConfig();
    } catch (_) {
      _toast(t('inviteCodeRequired'));
      return;
    }
    if (!mounted) return;
    setState(() => _config = cfg);
    if (cfg.inviteCodeRequired && _inviteCode.text.trim().isEmpty) {
      _toast(t('inviteCodeRequired'));
      return;
    }

    setState(() => _unameState = 'checking');
    var ok = true;
    try {
      ok = await _svc.checkAccount(u);
    } catch (_) {
      // 网络失败不拦路：交给注册接口兜底报错，避免网络抖动时卡在第 1 步
      ok = true;
    }
    if (!mounted) return;
    if (!ok) {
      setState(() => _unameState = 'taken');
      _toast(t('regUsernameTaken'));
      return;
    }
    setState(() {
      _unameState = 'ok';
      // 昵称预填用户名：用户不动就能直接完成，避免第 2 步出现空昵称
      if (_nickname.text.trim().isEmpty) _nickname.text = u;
      _step = 2;
    });
  }

  // ================= 提交 =================

  Future<void> _submit() async {
    if (!_agreeChecked) {
      _flagAgreeWarn();
      return;
    }
    // 2026-11-04 三态：required 时前端也做必填拦截（off 不显示输入框，optional 选填）。
    // 服务端仍会兜底校验（Register 里 invite_code_mode=required 空码报 2003），双保险。
    late final AuthConfig cfg2;
    try {
      cfg2 = await _svc.getConfig();
    } catch (_) {
      _toast(t('inviteCodeRequired'));
      return;
    }
    if (!mounted) return;
    setState(() => _config = cfg2);
    if (cfg2.inviteCodeRequired && _inviteCode.text.trim().isEmpty) {
      _toast(t('inviteCodeRequired'));
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _loading = true);
    try {
      final channel = _needAuth ? (_regType == 'email' ? 'email' : 'sms') : null;
      // 设备号 + 类型（同登录）：注册即建 device 表行，设备页可见本机
      final deviceId = await _api.getDeviceId();
      final r = await _svc.register(
        account: _username.text.trim(),
        password: _password.text,
        nickname: _nickname.text.trim(),
        inviteCode: _inviteCode.text.trim().isEmpty ? null : _inviteCode.text.trim(),
        code: _needAuth ? _smsCode.text.trim() : null,
        captchaId: _needCaptcha && _captcha != null ? _captcha!.captchaId : null,
        captchaCode: _needCaptcha ? _captchaCode.text.trim() : null,
        // channel 必须跟认证模式走：authMode=none 时传非空 channel 会让后端
        // 拿空 code 去比对 → 误报 2002「验证码错误或过期」。
        channel: channel,
        deviceId: deviceId,
        deviceType: AuthService.detectDeviceType(),
      );
      await _api.saveToken(r.accessToken);
      await _api.saveRefresh(r.refreshToken);
      // 多账号切换：记住本账号
      unawaited(_api.rememberAccount(
        id: r.user['id']?.toString() ?? '',
        account: (r.user['account'] ?? r.user['username'] ?? _username.text.trim())
            .toString(),
        nickname: (r.user['nickname'] ?? _nickname.text.trim()).toString(),
        avatar: (r.user['avatar'] ?? '').toString(),
        accessToken: r.accessToken,
        refreshToken: r.refreshToken,
      ));
      // E2EE（§36）：密码注册成功手里还有明文密码 → 静默建钥上云（失败不阻断）。
      unawaited(E2eeService.instance
          .setupAfterLogin(_password.text));
      // 头像上传改后台执行：两次 HTTP 不再阻塞进主页（静默失败不影响注册流程）。
      unawaited(_applyAvatar());
      if (!mounted) return;
      Navigator.of(context)
          .pushReplacement(MaterialPageRoute(builder: (_) => const HomeShell()));
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 头像落地：`/auth/register` 没有 avatar 字段，注册成功（已拿到 token）后补写。
  /// 失败**不阻断注册** —— 用户可以在「设置 > 个人资料」里再换。
  Future<void> _applyAvatar() async {
    try {
      Uint8List bytes;
      String name;
      final gallery = _galleryBytes;
      if (gallery != null) {
        bytes = gallery;
        name = _galleryName;
      } else {
        // 预设头像是 App 内置资源：读字节直传，不落临时文件
        final data = await rootBundle.load(kV2AvatarAssets[_avatarIndex]);
        bytes = data.buffer.asUint8List();
        name = 'avatar_${_avatarIndex + 1}.png';
      }
      final up = await _api.uploadBytes(bytes, name, dir: 'avatar/');
      final url = (up['url'] ?? '').toString();
      if (url.isEmpty) return;
      final r = await _api.put('/api/v1/user/profile', data: {'avatar': url});
      final code = (r.data is Map ? r.data['code'] : null);
      if (code is num && code.toInt() != 0) return;
    } catch (_) {
      // 静默降级：头像不是注册的必要条件
    }
  }

  // ================= 相册 / 图形验证码 =================

  Future<void> _pickFromGallery() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1080,
        imageQuality: 88,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      setState(() {
        _galleryBytes = bytes;
        _galleryName = picked.name.isEmpty ? 'avatar.jpg' : picked.name;
      });
    } catch (_) {
      // 用户取消 / 无权限：静默
    }
  }

  Future<void> _loadCaptcha() async {
    try {
      final c = await _svc.getCaptcha();
      if (!mounted) return;
      Uint8List bytes;
      try {
        bytes = base64Decode(c.imageBase64);
      } catch (_) {
        bytes = Uint8List(0);
      }
      // 只在拿到新验证码时解码一次，避免倒计时每秒重建导致图片闪烁
      setState(() {
        _captcha = c;
        _captchaBytes = bytes;
      });
    } catch (_) {
      // 静默失败：用户可点图片重试
    }
  }

  void _startSmsCountdown() {
    _smsTimer?.cancel();
    _smsTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_smsLeft <= 1) {
        timer.cancel();
        setState(() => _smsLeft = 0);
      } else {
        setState(() => _smsLeft--);
      }
    });
  }

  Future<void> _sendCode() async {
    if (!_needAuth) return;
    final acc = _username.text.trim();
    if (acc.isEmpty) {
      _toast(t('regUsernameRequired'));
      return;
    }
    if (_needCaptcha) {
      if (_captcha == null) {
        _toast(t('captchaLoading'));
        return;
      }
      if (_captchaCode.text.trim().isEmpty) {
        _toast(t('captchaRequired'));
        return;
      }
    }
    // 发码/注册渠道按注册方式决定（2026-09-22 需求6）：phone→sms、email→email；
    // account 模式不会进这里（_needAuth=false）
    final channel = _regType == 'email' ? 'email' : 'sms';
    setState(() => _loading = true);
    try {
      await _svc.sendCode(
        acc,
        _captcha?.captchaId ?? '',
        _captchaCode.text.trim(),
        channel: channel,
      );
      if (!mounted) return;
      setState(() => _smsLeft = 60);
      _startSmsCountdown();
      // 统一用 codeSent（四语已有）；不按渠道分两句可以少维护 2 个词条
      _toast(t('codeSent'));
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _confirmPwd.dispose();
    _nickname.dispose();
    _inviteCode.dispose();
    _captchaCode.dispose();
    _smsCode.dispose();
    _smsTimer?.cancel();
    super.dispose();
  }

  // ================= 构建 =================

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final isDark = context.v2IsDark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
          .copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        // V2 版式是纯白底（深色模式纯黑），不是旧的浅灰 #F5F6F8
        backgroundColor: context.v2Bg,
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                children: [
                  _topBar(s),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.symmetric(horizontal: AppTheme.v2Gutter * s),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: _step == 1 ? _step1(s) : _step2(s),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 顶栏：左侧返回箭头（实测 x 43.3），标题在**整屏居中**（实测 203.8 ≈ 420/2）
  Widget _topBar(double s) {
    final icon = Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      height: 44 * s,
      child: Stack(
        children: [
          Positioned(
            left: 43.3 * s,
            top: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (_step == 2) {
                  setState(() => _step = 1);
                } else if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                } else {
                  Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const LoginPage()));
                }
              },
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 4 * s),
                child: Icon(Icons.arrow_back_ios_new,
                    size: 20 * s, color: icon),
              ),
            ),
          ),
          Center(
            child: Text(
              t('regNavTitle'),
              style: TextStyle(
                fontSize: 18 * s,
                fontWeight: FontWeight.w600,
                height: 1.0,
                color: icon,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 第 1 步 ----------

  List<Widget> _step1(double s) {
    final title = TextStyle(
      fontSize: 28 * s,
      fontWeight: FontWeight.w800,
      height: 1.0,
      color: context.v2ActionBg,
    );
    // 顶部区块的纵向尺寸额外乘 v（屏高自适应）：设计稿是逻辑高 1153 的机型，
    // 45 / 59.7 / 112 / 39.6 这些绝对值搬到 800 高的屏上会吃掉近一半屏高。
    // 见 v2_kit.v2VScale（屏高 ≥1150 → 1.0；800 → 约 0.65）。表单区的小间距不缩。
    // 2026-09-15 排版紧凑：顶部区块的 v 系数保留，绝对值整体压小一档
    //（45/59.7/39.6/44.8 → 28/36/26/28），表单间距 21→16、按钮区 31/52.9/40 → 22/28/24，
    // 保证小屏（约 640dp）一屏内放完。
    final v = v2VScale(context);
    final avatarSize = (_kAvatarStep1 * s * v).clamp(76.0, _kAvatarStep1);
    return [
      SizedBox(height: 28 * s * v),
      const V2StepIndicator(current: 1),
      SizedBox(height: 36 * s * v),
      Center(child: V2AvatarCircle(index: _avatarIndex, size: avatarSize)),
      SizedBox(height: 26 * s * v),
      Center(child: Text(t('createAccount'), style: title)),
      SizedBox(height: 20.7 * s),
      Center(
        child: Text(
          t('regStep1Subtitle'),
          style: TextStyle(
            fontSize: 17.5 * s,
            height: 1.0,
            color: context.v2MutedColor,
          ),
        ),
      ),
      SizedBox(height: 28 * s * v),
      // 注册方式账号输入框（2026-09-22 需求6）：account=用户名 / phone=手机号 / email=邮箱
      _accountField(s),
      SizedBox(height: 16 * s),
      V2Field(
        controller: _password,
        hint: t('regPwdHint'),
        icon: Icons.lock_outline_rounded,
        obscureText: !_pwdVisible,
        textInputAction: TextInputAction.next,
        inputFormatters: [LengthLimitingTextInputFormatter(20)],
        suffix: _eye(_pwdVisible, () => setState(() => _pwdVisible = !_pwdVisible), s),
      ),
      SizedBox(height: 16 * s),
      V2Field(
        controller: _confirmPwd,
        hint: t('confirmPassword'),
        icon: Icons.lock_outline_rounded,
        obscureText: !_confirmPwdVisible,
        textInputAction: TextInputAction.done,
        inputFormatters: [LengthLimitingTextInputFormatter(20)],
        suffix: _eye(_confirmPwdVisible,
            () => setState(() => _confirmPwdVisible = !_confirmPwdVisible), s),
      ),
      SizedBox(height: 16 * s),
      // 邀请码（2026-11-04 三态）：invite_code_mode = off 不显示 / optional 选填 / required 必填。
      // 提示文案统一为「邀请码」（regInviteHintOptional/Required 已同文案，去掉代理码/选填后缀）。
      if (_config != null && _config!.inviteCodeVisible) ...[
        V2Field(
          controller: _inviteCode,
          hint: _config?.inviteCodeRequired == true
              ? t('regInviteHintRequired')
              : t('regInviteHintOptional'),
          icon: Icons.card_giftcard_rounded,
          textInputAction: TextInputAction.next,
          inputFormatters: [LengthLimitingTextInputFormatter(32)],
        ),
      ],
      if (_needCaptcha) ...[
        SizedBox(height: 16 * s),
        _captchaRow(s),
      ],
      if (_needAuth) ...[
        SizedBox(height: 16 * s),
        _smsRow(s),
      ],
      SizedBox(height: 22 * s),
      V2PrimaryButton(
        label: t('regNext'),
        onPressed: _loading || _unameState == 'checking' ? null : _next,
      ),
      SizedBox(height: 28 * s),
      _bottomRow(s),
      SizedBox(height: 24 * s),
    ];
  }

  /// 注册方式账号输入框（2026-09-22 需求6）：
  ///   - account（默认）：用户名，3-20 位英文/数字/下划线（历史行为）；
  ///   - phone：手机号，hint 带 +86 默认区号（服务端 CountryCode 缺省即 +86），
  ///     数字键盘、5-20 位纯数字（对齐服务端 isPhone，兼容国际号码）；
  ///   - email：邮箱，email 键盘。
  Widget _accountField(double s) {
    switch (_regType) {
      case 'phone':
        return V2Field(
          controller: _username,
          hint: t('regPhoneHint'),
          icon: Icons.phone_iphone_rounded,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.next,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
            LengthLimitingTextInputFormatter(20),
          ],
          onChanged: (_) {
            if (_unameState != '') setState(() => _unameState = '');
          },
          suffix: _unameSuffix(s),
        );
      case 'email':
        return V2Field(
          controller: _username,
          hint: t('regEmailHint'),
          icon: Icons.alternate_email_rounded,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          inputFormatters: [LengthLimitingTextInputFormatter(64)],
          onChanged: (_) {
            if (_unameState != '') setState(() => _unameState = '');
          },
          suffix: _unameSuffix(s),
        );
      default:
        return V2Field(
          controller: _username,
          hint: t('regUsernameHint'),
          icon: Icons.alternate_email_rounded,
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.next,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9_]')),
            LengthLimitingTextInputFormatter(20),
          ],
          onChanged: (_) {
            if (_unameState != '') setState(() => _unameState = '');
          },
          suffix: _unameSuffix(s),
        );
    }
  }

  /// 用户名输入框右侧的状态位（checking / ok / taken）—— 不占额外高度，不会破坏版式
  Widget? _unameSuffix(double s) {
    switch (_unameState) {
      case 'checking':
        return SizedBox(
          width: 18 * s,
          height: 18 * s,
          child: CircularProgressIndicator(
              strokeWidth: 2 * s, color: context.v2HintColor),
        );
      case 'ok':
        return Icon(Icons.check_circle_rounded,
            size: 20 * s, color: context.v2MutedColor);
      case 'taken':
        return Icon(Icons.cancel_rounded, size: 20 * s, color: AppTheme.danger);
      default:
        return null;
    }
  }

  Widget _eye(bool visible, VoidCallback onTap, double s) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.all(6 * s),
        child: Icon(
          visible ? Icons.visibility_outlined : Icons.visibility_off_outlined,
          size: 22 * s,
          color: context.v2MutedColor,
        ),
      ),
    );
  }

  /// 第 1 步的图形验证码（仅后台开启「认证模式 + 图形验证码」时出现）
  Widget _captchaRow(double s) {
    return Row(
      children: [
        Expanded(
          child: V2Field(
            controller: _captchaCode,
            hint: t('graphicCaptcha'),
            icon: Icons.verified_user_outlined,
          ),
        ),
        SizedBox(width: 10 * s),
        GestureDetector(
          onTap: _loadCaptcha,
          child: Container(
            width: 112 * s,
            height: AppTheme.v2FieldHeight * s,
            decoration: BoxDecoration(
              color: context.v2Fill,
              borderRadius: BorderRadius.circular(AppTheme.v2Radius * s),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppTheme.v2Radius * s),
              child: _captchaBytes == null
                  ? Center(
                      child: SizedBox(
                        width: 18 * s,
                        height: 18 * s,
                        child: const CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : Image.memory(_captchaBytes!, fit: BoxFit.fill,
                      errorBuilder: (_, __, ___) => const Icon(Icons.refresh)),
            ),
          ),
        ),
      ],
    );
  }

  /// 第 1 步的短信/邮箱验证码（仅后台开启认证模式时出现）
  Widget _smsRow(double s) {
    return Row(
      children: [
        Expanded(
          child: V2Field(
            controller: _smsCode,
            hint: t('smsCode'),
            icon: Icons.sms_outlined,
            keyboardType: TextInputType.number,
          ),
        ),
        SizedBox(width: 10 * s),
        SizedBox(
          height: AppTheme.v2FieldHeight * s,
          child: ElevatedButton(
            onPressed: (_smsLeft > 0 || _loading) ? null : _sendCode,
            style: ElevatedButton.styleFrom(
              backgroundColor: context.v2ActionBg,
              foregroundColor: context.v2ActionFg,
              disabledForegroundColor: context.v2HintColor,
              disabledBackgroundColor: context.v2Fill,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.v2Radius * s)),
              padding: EdgeInsets.symmetric(horizontal: 16 * s),
            ),
            child: Text(
              _smsLeft > 0 ? '$_smsLeft s' : t('sendCode'),
              style: TextStyle(fontSize: 15 * s, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }

  // ---------- 第 2 步 ----------

  List<Widget> _step2(double s) {
    final title = TextStyle(
      fontSize: 28 * s,
      fontWeight: FontWeight.w800,
      height: 1.0,
      color: context.v2ActionBg,
    );
    // 2026-09-15 排版紧凑：同第 1 步，绝对值整体压小一档。
    final v = v2VScale(context);
    final avatarSize = (_kAvatarStep2 * s * v).clamp(88.0, _kAvatarStep2);
    return [
      SizedBox(height: 26 * s * v),
      Center(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _pickFromGallery,
          child: _galleryBytes == null
              ? V2AvatarCircle(
                  index: _avatarIndex,
                  size: avatarSize,
                  badge: const V2CameraBadge(size: 34),
                )
              : Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ClipOval(
                      child: Image.memory(
                        _galleryBytes!,
                        width: avatarSize,
                        height: avatarSize,
                        fit: BoxFit.cover,
                      ),
                    ),
                    Positioned(
                      right: -2 * s,
                      bottom: -2 * s,
                      child: const V2CameraBadge(size: 34),
                    ),
                  ],
                ),
        ),
      ),
      SizedBox(height: 24 * s * v),
      Center(child: Text(t('regStep2Title'), style: title)),
      SizedBox(height: 20 * s),
      Center(
        child: Text(
          t('regStep2Subtitle'),
          style: TextStyle(
              fontSize: 17.5 * s, height: 1.0, color: context.v2MutedColor),
        ),
      ),
      SizedBox(height: 24 * s),
      Text(
        t('regPickAvatar'),
        style: TextStyle(
          fontSize: 17.5 * s,
          fontWeight: FontWeight.w600,
          height: 1.0,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
      SizedBox(height: 19.5 * s),
      // 候选两行：第一行 4 个，第二行 2 个整行居中（实测：直径 67、间距 10）
      _avatarRow(List.generate(4, (i) => i), s),
      SizedBox(height: 11 * s),
      _avatarRow(List.generate(2, (i) => i + 4), s),
      SizedBox(height: 20 * s),
      Center(child: _galleryEntry(s)),
      SizedBox(height: 32 * s),
      V2Field(
        controller: _nickname,
        hint: t('regNicknameHint'),
        icon: Icons.person_outline_rounded,
        textInputAction: TextInputAction.next,
        inputFormatters: [LengthLimitingTextInputFormatter(20)],
      ),
      SizedBox(height: 20 * s),
      AgreementCheckbox(
        checked: _agreeChecked,
        warn: _agreeWarn,
        plain: true,
        checkColor: context.v2ActionBg,
        onToggle: _toggleAgree,
        onOpenTerms: () => _openPolicy(isPrivacy: false),
        onOpenPrivacy: () => _openPolicy(isPrivacy: true),
      ),
      SizedBox(height: 20 * s),
      V2PrimaryButton(
        label: _loading ? t('registering') : t('regFinish'),
        loading: _loading,
        onPressed: _submit,
      ),
      SizedBox(height: 28 * s),
      _bottomRow(s),
      SizedBox(height: 24 * s),
    ];
  }

  Widget _avatarRow(List<int> indexes, double s) {
    final cells = <Widget>[];
    for (var i = 0; i < indexes.length; i++) {
      if (i > 0) cells.add(SizedBox(width: 10 * s));
      final idx = indexes[i];
      cells.add(V2AvatarOption(
        index: idx,
        selected: _galleryBytes == null && _avatarIndex == idx,
        onTap: () => setState(() {
          _galleryBytes = null;
          _avatarIndex = idx;
        }),
      ));
    }
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: cells);
  }

  Widget _galleryEntry(double s) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _pickFromGallery,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.photo_library_outlined,
              size: 20 * s, color: Theme.of(context).colorScheme.onSurface),
          SizedBox(width: 8 * s),
          Text(
            t('regFromGallery'),
            style: TextStyle(
              fontSize: 18 * s,
              fontWeight: FontWeight.w600,
              height: 1.0,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  /// 底部「已有账号？ 立即登录」行（两步都有，实测宽度 178、圆角与按钮同宽）
  Widget _bottomRow(double s) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          t('haveAccount'),
          style: TextStyle(
              fontSize: 17.5 * s, height: 1.0, color: context.v2MutedColor),
        ),
        SizedBox(width: 30 * s),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            } else {
              Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => const LoginPage()));
            }
          },
          child: Text(
            t('regLoginNow'),
            style: TextStyle(
              fontSize: 17.5 * s,
              fontWeight: FontWeight.w600,
              height: 1.0,
              color: context.v2ActionBg,
            ),
          ),
        ),
      ],
    );
  }
}
