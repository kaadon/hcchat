import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/friend_service.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/v2_kit.dart';
import '../widgets/v2_settings.dart';
import 'account_security_page.dart';
import 'my_qr_page.dart';
import '../widgets/transitions.dart';

// ============================================================================
// 编辑资料页（像素级复刻参考 APK 截图 Screenshot_2026_0914_204045.jpg）
//
// 测量基准：截图物理宽 1260 / DPR 3 ⇒ **逻辑宽 420**，与 v2Scale 基准一致。
// 下面所有常量都是截图的逻辑 px 实测值，落地时统一 `* v2Scale(context)`。
// 完整逐元素测量见 `UI-ref/measure/measure_editprofile_myqr.md`。
//
// 与设置类页面（v2_settings）的关键差异：
//   1) **页面底色是纯白 #FFFFFF**（不是设置页的 #F6F7F9）；
//   2) 卡片不是白卡，而是**浅灰填充卡 #F1F2F4**（= v2Fill），圆角 13.5（不是 16）；
//   3) 输入行高 67（V2Field 是 69）、圆角 13.5（V2Field 是 16）、
//      正文 21.5（V2Field 是 18）—— 所以本页不复用 V2Field，另建本地 field。
//
// 真实能力保留：昵称 / 签名 / 头像走 `FriendService.profile()` +
// `updateProfile()`（PUT /api/v1/user/profile），头像上传走 ApiClient.uploadFile。
// ============================================================================

// ---------- 尺寸（截图逻辑 px 实测） ----------
const double _kGutter = 20.7; // 页面左右留白（内容区 20.7 → 399.7）
const double _kFieldH = 67.0; // 输入行高（实测 66.7~67.0）
const double _kFieldR = 13.5; // 输入行 / 灰卡圆角（左上+右上 14 角一致拟合 r=13.5，RMSE 0.32）
const double _kFieldTextX = 26.5; // 可编辑输入框内文字左内边距（ink 47.0~48.0）
const double _kRowLabelX = 22.3; // 行样式内容左内边距（ink 43.0）
const double _kTailX = 22.0; // 尾部元素（绑定文字 / chevron / 一信号复制钮）右内边距
const double _kTailXUsername = 17.0; // 用户名行复制钮右内边距（比同页其它尾部元素靠右 5.0）
const double _kBodySize = 21.5; // 输入框正文 / 行标题 / 性别 / 一信号
const double _kNameSize = 23.0; // 头像下方昵称（逐字步进 22.85）
const double _kPhotoHintSize = 20.6; // 「设置新照片」逐字步进 20.6
const double _kHintSize = 16.5; // 说明文字（逐字步进 16.4~16.8）
const double _kHintLH = 1.38; // 说明文字行距（两行 baseline 间距 22.7/16.5）
const double _kHintX = 26.5; // 说明文字左缘（ink 27.3）
const double _kTitleSize = 21.0; // AppBar 标题（逐字步进 21.0）
const double _kDoneSize = 20.0; // 右上「完成」（逐字步进 20.0）
const double _kDoneRight = 21.5; // 「完成」右缘内边距（ink 右 398.0）
const double _kBackIconX =
    20.0; // 返回图标 icon box 左缘（ink 左 30.7 = 20.0 + 0.333×30）
const double _kBackIconSize = 30.0; // 返回图标边长（细雪佛龙 arrow_back_ios_new）
const double _kHeaderH = 56.0; // AppBar 内容区高（与 v2_settings 一致；标题中心 = 状态栏 + 28）
const double _kHeaderGap = 35.0; // 头栏底 → 头像顶（实测「标题中心 → 头像顶」= 62.95）

/// 卡片内分隔线（实测 y1421 行中位 #E2E1E6，厚约 1.0）
const Color _kRowHair = Color(0xFFE3E3E8);
const Color _kRowHairDark = Color(0xFF3A3A3C);

/// 图标块底色（实测：二维码 #0C0D12 / 邀请朋友 #34C85A）——
/// 「您的颜色」行（粉 #FF2D55）已按需求整体删除，`_kIconPink` 一并移除
const Color _kIconDark = Color(0xFF0C0D12);
const Color _kIconDarkLightMode = Color(0xFF3A3A3C);
const Color _kIconGreen = Color(0xFF34C759);

/// 取词函数类型（`AppLocalizations.of(context).t` 的 tear-off 签名）。
typedef _Tr = String Function(String key, [Map<String, String>? params]);

/// 取异常的**后端原始提示**（去掉 Dart 的 "Exception: " 前缀），失败时回退 fallback。
String _errMsg(Object e, String fallback) {
  var s = e.toString().trim();
  if (s.startsWith('Exception:')) s = s.substring('Exception:'.length).trim();
  if (s.startsWith('DioException')) s = fallback;
  return s.isEmpty ? fallback : s;
}

/// 个人资料编辑（需求9）：昵称 / 头像 / 签名（后端 PUT /user/profile）
class EditProfilePage extends StatefulWidget {
  const EditProfilePage({super.key});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  final _svc = FriendService();
  final _nickname = TextEditingController();
  final _bio = TextEditingController();
  String _avatar = '';
  String _account = ''; // 用户名（后端 User.account）
  String _shortId = ''; // 一信号（后端 User.shortId）
  String _phone = '';
  bool _loading = true;
  bool _saving = false;
  bool _uploadingAvatar = false; // 头像上传中：禁用点击 + 显示菊花

  /// 性别三态：'' = 未知 / 'male' = 男生 / 'female' = 女生，**默认未知**。
  /// 后端走 `PUT /user/privacy` 的 `gender` 字段（枚举 male/female/secret，
  /// 无空串 ⇒ 未知=secret，见 _save）。本机 `AppSettings.profileGender`
  /// 仅作隐私接口拉取失败时的回显兜底。
  String _gender = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nickname.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final p = await _svc.profile();
      if (mounted) {
        setState(() {
          _nickname.text = p['nickname']?.toString() ?? '';
          _avatar = p['avatar']?.toString() ?? '';
          _bio.text = p['signature']?.toString() ?? '';
          _account = p['account']?.toString() ?? '';
          // ID 字段 JSON tag 是 `,string`，统一按字符串取，别按 number 解析
          _shortId = p['shortId']?.toString() ?? '';
          _phone = p['phone']?.toString() ?? '';
          // 性别：先落本机缓存兜底，下方隐私接口成功后覆盖
          _gender = AppSettings.instance.profileGender;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
    // 性别回显：GET /user/privacy 的 gender（'secret' → '' 未知）；
    // 拉取失败保持上面的本机缓存值，不打断页面。
    try {
      final m = await ApiClient.instance.fetchPrivacy();
      final g = (m['gender'] as String?) ?? '';
      if (mounted) setState(() => _gender = g == 'secret' ? '' : g);
    } catch (_) {}
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    // 本机缓存照旧落一份：隐私接口不可用时（旧服务端/离线）下次回显仍有值
    AppSettings.instance.setProfileGender(_gender);
    try {
      final r = await _svc.updateProfile(
        nickname: _nickname.text.trim(),
        signature: _bio.text.trim(),
        avatar: _avatar,
      );
      // 性别走 /user/privacy（后端枚举 male/female/secret，无空串 ⇒ 未知=secret）。
      // 失败**不阻断**昵称等其它字段的保存结果，单独 toast 服务端 message。
      String? genderErr;
      try {
        await ApiClient.instance
            .updatePrivacy({'gender': _gender.isEmpty ? 'secret' : _gender});
      } catch (e) {
        if (mounted) {
          final t = AppLocalizations.of(context).t;
          genderErr = _genderErrText(e, t);
        }
      }
      if (mounted) {
        final t = AppLocalizations.of(context).t;
        if (r) {
          // 资料保存成功但性别失败 → 用性别错误提示顶掉「已保存」，如实反馈
          AppDialogs.toast(context, genderErr ?? t('editProfileSaved'));
          Navigator.of(context).pop(true);
        } else {
          AppDialogs.toast(context, genderErr ?? t('editProfileSaveFailed'));
        }
      }
    } catch (e) {
      if (mounted) {
        final t = AppLocalizations.of(context).t;
        AppDialogs.toast(context, _errMsg(e, t('editProfileSaveFailed')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 性别保存的 toast 文案：网络层错误（PrivacyNetException）取 l10n 友好文案
  /// （404=服务端过旧 / 其余=网络错误），其余显示服务端 message。
  String _genderErrText(Object e, _Tr t) {
    if (e is PrivacyNetException) {
      return t(e.type == PrivacyNetErrorType.unsupported
          ? 'netErrUnsupported'
          : 'netErrRetry');
    }
    return _errMsg(e, t('netErrRetry'));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    return Scaffold(
      backgroundColor: context.v2Bg,
      body: Column(
        children: [
          _header(context, t('editProfileTitle'), s),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: EdgeInsets.only(
                        bottom: 40 * s + MediaQuery.paddingOf(context).bottom),
                    children: _content(context, s, t),
                  ),
          ),
        ],
      ),
    );
  }

  /// 自绘 AppBar：标题居中（21 / w600），右上「完成」（20 / w600，近黑）。
  ///
  /// 不用 Material AppBar：截图里返回箭头是**细雪佛龙 `<`**（ink 10.3×19.0，ink 左缘 30.7
  /// ⇒ `Icons.arrow_back_ios_new` @30，icon box 左缘 20.0）。标题 ink 中心与「完成」同线，
  /// 且「标题中心 → 头像顶」实测 62.95 ⇒ 内容区高沿用 56（与 v2_settings 一致）+ 间隔 35.0。
  Widget _header(BuildContext context, String title, double s) {
    final t = AppLocalizations.of(context).t;
    final top = MediaQuery.paddingOf(context).top;
    return Container(
      color: context.v2Bg,
      height: top + _kHeaderH * s,
      padding: EdgeInsets.only(top: top),
      child: Stack(
        children: [
          // 返回箭头：细雪佛龙 `Icons.arrow_back_ios_new` @30，icon box 左缘 20.0
          Positioned(
            left: _kBackIconX * s,
            top: (_kHeaderH - _kBackIconSize) / 2 * s,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).maybePop(),
              child: SizedBox(
                width: _kBackIconSize * s,
                height: _kBackIconSize * s,
                child: Icon(Icons.arrow_back_ios_new,
                    size: _kBackIconSize * s, color: context.setTitle),
              ),
            ),
          ),
          Center(
            child: Text(
              title,
              maxLines: 1,
              style: TextStyle(
                fontSize: _kTitleSize * s,
                fontWeight: FontWeight.w600,
                height: 1.0,
                color: context.setTitle,
              ),
            ),
          ),
          Positioned(
            right: _kDoneRight * s,
            top: 0,
            bottom: 0,
            child: Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _saving ? null : _save,
                child: Text(
                  t('epDone'),
                  style: TextStyle(
                    fontSize: _kDoneSize * s,
                    fontWeight: FontWeight.w600,
                    height: 1.0,
                    color: _saving ? context.v2HintColor : context.setTitle,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _content(BuildContext context, double s, _Tr t) {
    return [
      SizedBox(height: _kHeaderGap * s), // 头栏底 → 头像顶
      // ---------- 头像 + 昵称 + 设置新照片 ----------
      Center(
        child: GestureDetector(
          onTap: _uploadingAvatar ? null : _pickAvatar,
          child: Stack(
            children: [
              Container(
                width: 115 * s,
                height: 115 * s,
                decoration: const BoxDecoration(shape: BoxShape.circle),
                clipBehavior: Clip.antiAlias,
                alignment: Alignment.center,
                child: AppAvatar(
                  url: _avatar,
                  name: _nickname.text,
                  size: 115 * s,
                ),
              ),
              if (_uploadingAvatar)
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                        color: Colors.black54, shape: BoxShape.circle),
                    child: Center(
                      child: SizedBox(
                        width: 24 * s,
                        height: 24 * s,
                        child: const CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      SizedBox(height: 20.2 * s),
      Center(
        child: Text(
          _nickname.text.isEmpty ? ' ' : _nickname.text,
          style: TextStyle(
            fontSize: _kNameSize * s,
            fontWeight: FontWeight.w600,
            height: 1.0,
            color: context.setTitle,
          ),
        ),
      ),
      SizedBox(height: 18.9 * s),
      Center(
        child: Text(
          t('epSetNewPhoto'),
          style: TextStyle(
            fontSize: _kPhotoHintSize * s,
            fontWeight: FontWeight.w400,
            height: 1.0,
            color: context.setTitle,
          ),
        ),
      ),
      SizedBox(height: 42.2 * s), // 设置新照片 → 昵称卡顶（实测卡顶 391.33 反推）

      // ---------- 昵称（真实可编辑） ----------
      _editField(context, s, controller: _nickname, maxLength: 20),
      SizedBox(height: 9.3 * s),
      _hint(context, s, t('epNameHint')),
      SizedBox(height: 31.9 * s),

      // ---------- 用户名（= 后端 account，只读 + 复制） ----------
      _valueField(
        context,
        s,
        value: _account.isEmpty ? '-' : '@$_account',
        copyLabel: t('epCopyUsername'),
        copyText: _account,
        tailInset: _kTailXUsername,
        onTapField: () => AppDialogs.toast(context, t('epUsernameReadonly')),
      ),
      SizedBox(height: 10.0 * s),
      _hint(context, s, t('epUsernameHint'), rightPad: 8.0),
      SizedBox(height: 23.5 * s),
      _hint(context, s, t('epUsernameRule')),
      SizedBox(height: 31.4 * s),

      // ---------- 一信号（= 后端 shortId，只读 + 复制） ----------
      _valueField(
        context,
        s,
        label: t('epSignal'),
        labelGap: 28.5,
        value: _shortId.isEmpty ? '-' : _shortId,
        copyLabel: t('epCopySignal'),
        copyText: _shortId,
      ),
      SizedBox(height: 10.0 * s),
      _hint(context, s, t('epSignalHint')),
      SizedBox(height: 31.3 * s),

      // ---------- 性别（保存走 PUT /user/privacy 的 gender 字段） ----------
      _genderRow(context, s, t),
      SizedBox(height: 30.7 * s),

      // ---------- 个人简介（真实可编辑） ----------
      _bioField(context, s, t),
      SizedBox(height: 10.0 * s),
      _hint(context, s, t('epBioHint')),
      SizedBox(height: 31.6 * s),

      // ---------- 未绑定手机 / 绑定 ----------
      _phoneCard(context, s, t),
      SizedBox(height: 41.0 * s),

      // ---------- 二维码 + 邀请朋友（同一张灰卡，中间发丝线） ----------
      _greyCard(
        context,
        s,
        children: [
          _iconRow(
            context,
            s,
            height: 62.0,
            iconBg: Theme.of(context).brightness == Brightness.dark
                ? _kIconDarkLightMode
                : _kIconDark,
            icon: Icons.qr_code_2,
            title: t('epQrCode'),
            onTap: () => Navigator.of(context)
                .push(fadeScaleRoute(const MyQrPage(), scale: true)),
          ),
          Padding(
            padding: EdgeInsets.only(left: 71.6 * s),
            child: Container(
                height: 1.0 * s,
                color: context.v2IsDark ? _kRowHairDark : _kRowHair),
          ),
          _iconRow(
            context,
            s,
            height: 62.0,
            iconBg: _kIconGreen,
            icon: Icons.person_add_alt_1_outlined,
            title: t('epInviteFriends'),
            onTap: () => AppDialogs.toast(context, t('epInviteFriends')),
          ),
        ],
      ),
    ];
  }

  // --------------------------------------------------------------------------
  // 组件
  // --------------------------------------------------------------------------

  /// 可编辑输入行：高 67 / 圆角 13.5 / 浅灰填充 / 文字左内边距 26.5。
  Widget _editField(
    BuildContext context,
    double s, {
    required TextEditingController controller,
    int maxLength = 20,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: _kGutter * s),
      child: Container(
        height: _kFieldH * s,
        decoration: BoxDecoration(
          color: context.v2Fill,
          borderRadius: BorderRadius.circular(_kFieldR * s),
        ),
        padding: EdgeInsets.symmetric(horizontal: _kFieldTextX * s),
        alignment: Alignment.centerLeft,
        child: TextField(
          controller: controller,
          maxLines: 1,
          inputFormatters: [
            LengthLimitingTextInputFormatter(maxLength),
          ],
          textAlignVertical: TextAlignVertical.center,
          style: TextStyle(
            fontSize: _kBodySize * s,
            fontWeight: FontWeight.w500,
            height: 1.0,
            color: context.setTitle,
          ),
          decoration: InputDecoration.collapsed(
            hintText: '',
            hintStyle: TextStyle(
              fontSize: _kBodySize * s,
              height: 1.0,
              color: context.v2HintColor,
            ),
          ),
        ),
      ),
    );
  }

  /// 多行输入行：个人简介（高 128.3，占位文字用 v2MutedColor 实测 #6D737F）。
  Widget _bioField(BuildContext context, double s, _Tr t) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: _kGutter * s),
      child: Container(
        height: 128.3 * s,
        decoration: BoxDecoration(
          color: context.v2Fill,
          borderRadius: BorderRadius.circular(_kFieldR * s),
        ),
        padding: EdgeInsets.fromLTRB(
            _kFieldTextX * s, 14.0 * s, _kFieldTextX * s, 14.0 * s),
        child: TextField(
          controller: _bio,
          maxLines: null,
          inputFormatters: [LengthLimitingTextInputFormatter(100)],
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          style: TextStyle(
            fontSize: _kBodySize * s,
            fontWeight: FontWeight.w400,
            height: 1.2,
            color: context.setTitle,
          ),
          decoration: InputDecoration.collapsed(
            hintText: t('epBio'),
            hintStyle: TextStyle(
              fontSize: _kBodySize * s,
              fontWeight: FontWeight.w400,
              height: 1.2,
              color: context.v2MutedColor,
            ),
          ),
        ),
      ),
    );
  }

  /// 只读值行（用户名 / ID）：左侧可选标签 + 值 + 右侧复制图标。
  ///
  /// 对齐实测：行内文字左内边距 22.3（= 行样式卡同款），
  /// ID 标签与值之间固定 28.5（标签 ink 右 104.7 → 值 ink 左 135.0）。
  /// [tailInset]：尾部复制图标右内边距；实测**每行不同**——
  /// 用户名行 17.0（复制钮 ink 左 361.7），ID 行 22.0（ink 左 356.7，与 chevron 列对齐）。
  Widget _valueField(
    BuildContext context,
    double s, {
    String? label,
    double labelGap = 0,
    required String value,
    required String copyLabel,
    required String copyText,
    double tailInset = _kTailX,
    VoidCallback? onTapField,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: _kGutter * s),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTapField,
        child: Container(
          height: _kFieldH * s,
          decoration: BoxDecoration(
            color: context.v2Fill,
            borderRadius: BorderRadius.circular(_kFieldR * s),
          ),
          padding: EdgeInsets.only(left: _kRowLabelX * s, right: tailInset * s),
          child: Row(
            children: [
              if (label != null) ...[
                Text(
                  label,
                  style: TextStyle(
                    fontSize: _kBodySize * s,
                    fontWeight: FontWeight.w500,
                    height: 1.0,
                    color: context.setTitle,
                  ),
                ),
                SizedBox(width: labelGap * s),
              ],
              Expanded(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: _kBodySize * s,
                    fontWeight: FontWeight.w400,
                    height: 1.0,
                    color: context.setTitle,
                  ),
                ),
              ),
              SizedBox(width: 10 * s),
              // 复制图标：ink 17.0×20.3 ⇒ Material icon size 24（实测色 #9BA0AB）
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: copyText.isEmpty
                    ? null
                    : () async {
                        await Clipboard.setData(ClipboardData(text: copyText));
                        if (context.mounted) {
                          AppDialogs.toast(context,
                              AppLocalizations.of(context).t('profileCopied'));
                        }
                      },
                child: Semantics(
                  label: copyLabel,
                  button: true,
                  child: SizedBox(
                    width: 30 * s,
                    height: 30 * s,
                    child: Icon(Icons.copy_rounded,
                        size: 24 * s, color: context.v2HintColor),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 性别行：左侧「性别」+ 右侧三态分段控件（未知 / 男生 / 女生，默认未知）。
  ///
  /// 实测注：参考图里分段控件**内部与灰卡同色**、没有选中填充色差（裁图 `_z_gender.png`）。
  /// 选中态高亮仅作视觉反馈，选中数据源（`_gender`）不动；参考一致性让位于可用性。
  ///
  /// 性别走 `PUT /user/privacy` 的 `gender` 字段（male/female/secret）；
  /// 本机 `AppSettings.profileGender` 仅作接口拉取失败时的回显兜底。
  Widget _genderRow(BuildContext context, double s, _Tr t) {
    final border = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFFFFFFFF)
        : const Color(0xFF0C0D12);
    Widget seg(String text, String v) {
      final selected = _gender == v;
      // 2026-09-17 用户指定（三轮修正）：段内胶囊全部去掉——
      // 选中 = 黑色矩形填满整个分段（无边距/圆角，与分隔线齐平）；
      // 未选中 = 纯文字透明底（无描边胶囊）。外层胶囊容器用 clipBehavior
      // 裁剪，边缘段（未知/女生）选中时黑色自动被外框圆角裁齐。
      return Expanded(
        child: Semantics(
          label: text,
          button: true,
          selected: selected,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              setState(() => _gender = v);
            },
            child: Container(
              color: selected ? const Color(0xFF0C0D12) : Colors.transparent,
              alignment: Alignment.center,
              child: Text(
                text,
                style: TextStyle(
                  fontSize: _kBodySize * s,
                  fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                  height: 1.0,
                  color: selected ? Colors.white : context.v2HintColor,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: _kGutter * s),
      child: Container(
        height: 92.3 * s,
        decoration: BoxDecoration(
          color: context.v2Fill,
          borderRadius: BorderRadius.circular(_kFieldR * s),
        ),
        padding: EdgeInsets.only(left: _kRowLabelX * s, right: 20.4 * s),
        child: Row(
          children: [
            Text(
              t('epGender'),
              style: TextStyle(
                fontSize: _kBodySize * s,
                fontWeight: FontWeight.w400,
                height: 1.0,
                color: context.setTitle,
              ),
            ),
            const Spacer(),
            SizedBox(
              width: 245.3 * s,
              height: 51.3 * s,
              child: Container(
                clipBehavior: Clip.hardEdge, // 选中段黑色矩形按外框胶囊圆角裁齐
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(25.65 * s),
                  border: Border.all(color: border, width: 1.3 * s),
                ),
                child: Row(
                  children: [
                    seg(t('nsetUnknown'), ''),
                    Container(width: 1.3 * s, color: border),
                    seg(t('epMale'), 'male'),
                    Container(width: 1.3 * s, color: border),
                    seg(t('epFemale'), 'female'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 未绑定手机 / 绑定：灰卡高 67，左文字 22.3、右文字右内边距 22.0。
  ///
  /// 已绑定 → 显示掩码手机号；未绑定 → 显示「绑定」，点击进账号安全页走
  /// **真实**的 bind-phone 流程（POST /user/bind-phone[/send-code]），不做假绑定。
  Widget _phoneCard(BuildContext context, double s, _Tr t) {
    final bound = _phone.trim().isNotEmpty;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: bound
          ? null
          : () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AccountSecurityPage())),
      child: _greyCard(
        context,
        s,
        children: [
          Container(
            height: _kFieldH * s,
            padding: EdgeInsets.only(left: _kRowLabelX * s, right: _kTailX * s),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    bound ? t('epPhoneBound') : t('epPhoneUnbound'),
                    style: TextStyle(
                      fontSize: _kBodySize * s,
                      fontWeight: FontWeight.w400,
                      height: 1.0,
                      color: context.setTitle,
                    ),
                  ),
                ),
                Text(
                  bound ? _mask(_phone) : t('epBind'),
                  style: TextStyle(
                    fontSize: _kBodySize * s,
                    fontWeight: FontWeight.w400,
                    height: 1.0,
                    color: context.setTitle,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 带彩色圆角图标块的行：图标块 36×36 / 圆角 8 / 左内边距 20.3，文字 ink 94.3，右 chevron。
  Widget _iconRow(
    BuildContext context,
    double s, {
    required double height,
    required Color iconBg,
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: height * s,
        child: Row(
          children: [
            SizedBox(width: 20.3 * s),
            Container(
              width: 36 * s,
              height: 36 * s,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(8 * s),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 20 * s, color: Colors.white),
            ),
            SizedBox(width: 17.0 * s),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: _kBodySize * s,
                  fontWeight: FontWeight.w400,
                  height: 1.0,
                  color: context.setTitle,
                ),
              ),
            ),
            // chevron：ink 6.7×12.0 ⇒ size 24；右缘内边距 22.4
            Padding(
              padding: EdgeInsets.only(right: 22.4 * s),
              child: Icon(Icons.chevron_right,
                  size: 24 * s, color: context.v2HintColor),
            ),
          ],
        ),
      ),
    );
  }

  /// 浅灰填充圆角卡（宽 378.7 / 圆角 13.5）。
  Widget _greyCard(BuildContext context, double s,
      {required List<Widget> children}) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: _kGutter * s),
      child: Container(
        decoration: BoxDecoration(
          color: context.v2Fill,
          borderRadius: BorderRadius.circular(_kFieldR * s),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }

  /// 说明文字：16.5 / 行距 1.38 / 灰 #9AA0AA，左缘 26.5（ink 27.3）。
  Widget _hint(BuildContext context, double s, String text,
      {double rightPad = 0}) {
    return Padding(
      padding:
          EdgeInsets.only(left: _kHintX * s, right: (_kGutter + rightPad) * s),
      child: Text(
        text,
        style: TextStyle(
          fontSize: _kHintSize * s,
          fontWeight: FontWeight.w400,
          height: _kHintLH,
          color: context.v2HintColor,
        ),
      ),
    );
  }

  static String _mask(String phone) {
    if (phone.length <= 7) return phone;
    return '${phone.substring(0, 3)}****${phone.substring(phone.length - 4)}';
  }

  /// 头像：相册选图 → MinIO 上传 → 仅本地预览 URL。
  /// 与昵称/签名一起在用户点「完成」时一并 PUT（避免选完图不保存直接退页产生的脏数据）。
  /// 失败回滚到旧头像，toast 提示。
  Future<void> _pickAvatar() async {
    if (_uploadingAvatar) return;
    final t = AppLocalizations.of(context).t;
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return;
    setState(() => _uploadingAvatar = true);
    final oldAvatar = _avatar;
    try {
      final up = await ApiClient.instance.uploadXFile(
        picked,
        picked.name.isEmpty ? 'avatar.jpg' : picked.name,
        dir: 'avatar/',
      );
      if (!mounted) return;
      setState(() => _avatar = (up['url'] ?? '').toString());
      AppDialogs.toast(context, t('editProfileAvatarUploaded'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _avatar = oldAvatar); // 失败回滚
      AppDialogs.toast(context, _errMsg(e, t('editProfileAvatarUploadFailed')));
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }
}
