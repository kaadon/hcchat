import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/conversation_service.dart';
import '../theme/app_theme.dart';
import '../widgets/v2_kit.dart';

/// 「新建频道」sheet 的全局开关。
///
/// sheet **不走 showModalBottomSheet**：参考图实测 sheet 铺到屏底、遮罩 black54，
/// 但白色导航胶囊不被压暗 ⇒ 导航必须画在 sheet 层之上（measure_channel.md §0/§11.3-2）。
/// 所以由 `home_shell` 在自己的 Stack 里挂 scrim + 面板；chat_list_page 的
/// 「+」宫格第四项只调 [show]，home_shell 监听 [open] 渲染图层。
class CreateChannelSheetController {
  CreateChannelSheetController._();

  static final ValueNotifier<bool> open = ValueNotifier(false);

  static void show() => open.value = true;
  static void hide() => open.value = false;
}

// sheet 在 home_shell 里全局常驻单例，交互状态放文件级 ValueNotifier，
// 让组件保持 StatelessWidget（team-lead 指定）；UI 用 ValueListenableBuilder 驱动。
final TextEditingController _nameCtrl = TextEditingController(text: '');
final TextEditingController _shortIdCtrl = TextEditingController(text: '');
final ValueNotifier<bool> _isPublic = ValueNotifier<bool>(true);
final ValueNotifier<bool> _canCreate = ValueNotifier<bool>(false);

/// 自定义频道 ID 格式（与后端契约一致）：3-20 位字母/数字/下划线
final RegExp _shortIdReg = RegExp(r'^[A-Za-z0-9_]{3,20}$');

/// 新建频道 bottom sheet —— V2 像素级复刻 2026-09-15
///
/// 基准：`UI-ref/measure/measure_channel.md`（参考图 1260×2750 / DPR3 / 逻辑 420×916.7）。
/// 本组件是 sheet 面板本身（不含遮罩）：高度由 home_shell 给定 = 屏高 85%
/// （实测 779.11/916.7 = 0.8500），顶部圆角 R20.5、面底 #F6F7F9、三边出血到屏底。
/// 所有内部坐标均为「sheet 局部坐标」= 截图绝对 y − 137.59（sheet 顶边）。
/// 2026-09-15 第十批：真机（360 逻辑宽）上「公开/私密」两行曾贴近/超出 85% 屏高
/// （键盘弹出时必溢出），把各段**间距**压缩（实测值优先保留：描述框 123.22 不动），
/// 并在 home_shell 侧把 sheet 高度钳制在可视区内 + 本组件可滚动兜底。
/// 间距改前/改后：头栏顶 40.2→32、头栏→头像 61.7→36、头像→描述 20.5→14、
/// 描述→公开行 37.28→20、公开→私密 33.33→20、尾部弹性空白→固定 24。
class CreateChannelSheet extends StatelessWidget {
  const CreateChannelSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    // 参考包没有深色截图：深色值按「同层次」推导（measure_channel.md §11.3-4），
    // 全部标注 derived，不作实测。
    final dark = context.v2IsDark;
    final cSheet = dark ? const Color(0xFF1C1C1E) : const Color(0xFFF6F7F9); // 实测 #F6F7F9
    final cAction = dark ? const Color(0xFFF2F3F5) : const Color(0xFF0B0C11); // 实测 #0B0C11 ≈ v2Action
    final cTitle = dark ? const Color(0xFFF5F6F8) : const Color(0xFF121824); // 实测 #121824
    final cSub = dark ? const Color(0xFF98989F) : const Color(0xFF6C727E); // 实测 #6C727E ≈ v2Muted
    final cHint = context.v2HintColor; // 创建禁用态实测 #9CA2AB ≈ v2Hint
    final cBlockSel = dark ? const Color(0xFF48484A) : const Color(0xFFD3D4D8); // 选中图标块/头像圆 实测 #D3D4D8
    final cBlockIdle = dark ? const Color(0xFF2C2C2E) : const Color(0xFFF1F2F4); // 未选中块 实测 #F1F2F4 = v2FieldFill
    final cField = context.v2Fill; // 字段填充 实测 #F1F2F4 = v2FieldFill
    final cRadioStroke = context.v2HintColor; // 未选中单选描边 实测 #9CA2AE ≈ v2Hint

    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        color: cSheet,
        // 顶部圆角实测 R20.58 → 20.5（最小二乘 SSE 1.47）
        borderRadius: BorderRadius.vertical(top: Radius.circular(20.5 * s)),
      ),
      child: SingleChildScrollView(
        // 滚动兜底：键盘弹出 / 极矮屏时 85% 高度装不下全部内容，
        // 可滚动而不是黄黑条纹（优先保证默认状态一屏全可见，见各段间距注释）。
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
          _header(context, t, s, cAction, cTitle, cHint),
          // 头栏 → 头像圆：实测 61.7，压缩到 36（真机 360×~780 上私密行曾被顶出屏）
          SizedBox(height: 36 * s),
          _avatarRow(context, s, cAction, cTitle, cSub, cField, cBlockSel),
          // 头像圆底 → 描述框顶：实测 20.64 → 14
          SizedBox(height: 14 * s),
          _descField(context, s, cSub, cField),
          // 描述框底 → 自定义 ID 行：新增行沿用「描述→公开行」的 20 间距量级
          SizedBox(height: 20 * s),
          _shortIdField(context, s, cSub, cField, cTitle),
          // 自定义 ID 行底 → 公开行图标块顶（原「描述→公开行」20 的节奏）
          SizedBox(height: 20 * s),
          _typeRow(
            context: context,
            s: s,
            selected: true,
            icon: Icons.public,
            blockColor: cBlockSel,
            iconColor: cAction,
            title: t('chcPublicTitle'),
            subtitle: t('chcPublicDesc'),
            titleColor: cTitle,
            subColor: cSub,
            actionColor: cAction,
            radioStroke: cRadioStroke,
          ),
          // 公开块底 → 私密块顶：实测 33.33 → 20
          SizedBox(height: 20 * s),
          _typeRow(
            context: context,
            s: s,
            selected: false,
            icon: Icons.lock_outline,
            blockColor: cBlockIdle,
            iconColor: cHint,
            title: t('chcPrivateTitle'),
            subtitle: t('chcPrivateDesc'),
            titleColor: cTitle,
            subColor: cSub,
            actionColor: cAction,
            radioStroke: cRadioStroke,
          ),
          // 底部再留一段安全空隙（原为弹性 Expanded，滚动环境下无界高度会报错）
          SizedBox(height: 24 * s),
          ],
        ),
      ),
    );
  }

  /// 头栏：取消（左）/ 新建频道（绝对居中）/ 创建（右，名称为空时禁用）。
  /// ink 基准（sheet 局部 y）：顶 41.74；取消/创建 fontSize 19、标题 21.7 w600。
  /// 对称性复核：取消 ink 左 43.67，创建 ink 右 376.33 = 420 − 43.67 ✓ 完全对称。
  Widget _header(BuildContext context, String Function(String) t, double s,
      Color cAction, Color cTitle, Color cHint) {
    return Padding(
      // 取消文字盒左 ≈ 41.5（ink 43.67 − CJK 侧边距 ≈2）；顶部 40.2 → 32（压缩，真机高度兜底）
      padding: EdgeInsets.fromLTRB(41.5 * s, 32 * s, 41.5 * s, 0),
      child: SizedBox(
        height: 22 * s,
        child: Stack(
          children: [
            // 取消
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: CreateChannelSheetController.hide,
                child: Text(
                  t('chatListCancel'), // 复用现有「取消」词条
                  style: TextStyle(
                      fontSize: 19 * s,
                      height: 1.0,
                      color: cAction), // w400
                ),
              ),
            ),
            // 标题：ink 中心 = 210.0 = 屏中心（绝对居中）
            Center(
              child: Text(
                t('chcTitle'),
                style: TextStyle(
                    fontSize: 21.7 * s,
                    height: 1.0,
                    fontWeight: FontWeight.w600,
                    color: cTitle),
              ),
            ),
            // 创建：禁用态 #9CA2AB（名称为空时），可用态近黑
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: ValueListenableBuilder<bool>(
                valueListenable: _canCreate,
                builder: (context, can, _) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: can ? () => _create(context) : null,
                  child: Text(
                    t('chcCreate'),
                    style: TextStyle(
                        fontSize: 19.3 * s,
                        height: 1.0,
                        color: can ? cAction : cHint),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 头像圆（∅90 / #D3D4D8 / Icons.campaign 37）+ 频道名称框（268.56×62.92 / R24.7）。
  /// 两者同一中线（圆心 y = 框心 y = 305.61/305.63）。
  Widget _avatarRow(BuildContext context, double s, Color cAction,
      Color cTitle, Color cSub, Color cField, Color cBlock) {
    return Padding(
      // 头像圆左缘 20.5；名称框右缘 399.28 → 距右 20.72
      padding: EdgeInsets.fromLTRB(20.5 * s, 0, 20.72 * s, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 90 * s,
            height: 90 * s,
            decoration: BoxDecoration(
              color: cBlock,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(Icons.campaign,
                size: 37 * s, color: cAction), // 实测 size ≈ 36.7
          ),
          SizedBox(width: 20.4 * s), // 圆右缘 110.33 → 框左缘 130.72
          Expanded(
            child: Container(
              height: 62.92 * s,
              decoration: BoxDecoration(
                color: cField,
                // 实测 R24.65（描述框 25.86 同量级 → 报告建议统一 25，此处保留实测）
                borderRadius: BorderRadius.circular(24.7 * s),
              ),
              alignment: Alignment.centerLeft,
              padding: EdgeInsets.only(left: 26 * s), // caret 左内边距 26.0
              child: TextField(
                controller: _nameCtrl,
                onChanged: (v) => _canCreate.value = v.trim().isNotEmpty,
                style: TextStyle(fontSize: 22.7 * s, color: cTitle, height: 1.0),
                cursorColor: cAction,
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  hintText: AppLocalizations.of(context).t('chcNameHint'),
                  // 占位字号实测 22.7（描述框 21.5，两框确实不同，见 §4.3）
                  hintStyle:
                      TextStyle(fontSize: 22.7 * s, height: 1.0, color: cSub),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 频道描述（可选）多行框：379.00×123.22 / R25.86 / 文本左 27.1 上 20.3。
  Widget _descField(BuildContext context, double s, Color cSub, Color cField) {
    return Padding(
      // 框左缘 20.28、右缘 399.28 → 距右 20.72
      padding: EdgeInsets.fromLTRB(20.28 * s, 0, 20.72 * s, 0),
      child: Container(
        height: 123.22 * s,
        decoration: BoxDecoration(
          color: cField,
          borderRadius: BorderRadius.circular(25.9 * s), // 实测 R25.86
        ),
        padding: EdgeInsets.fromLTRB(27.1 * s, 20.3 * s, 20 * s, 12 * s),
        child: TextField(
          expands: true,
          maxLines: null,
          minLines: null,
          keyboardType: TextInputType.multiline,
          textAlignVertical: TextAlignVertical.top,
          style: TextStyle(fontSize: 21.5 * s, height: 1.0, color: cSub),
          decoration: InputDecoration(
            isCollapsed: true,
            border: InputBorder.none,
            hintText: AppLocalizations.of(context).t('chcDescHint'),
            hintStyle: TextStyle(fontSize: 21.5 * s, height: 1.0, color: cSub),
          ),
        ),
      ),
    );
  }

  /// 自定义频道 ID（选填）输入行：标签 + 单行框。
  /// 样式随本页现有表单行（cField 填充 / R24.7 圆角 / 描述框同款左右出血 20.28/20.72），
  /// 仅新增文案（词条见 UI-ref/l10n-inbox/channel-ui-cu16.tsv），不改既有实测值。
  Widget _shortIdField(
      BuildContext context, double s, Color cSub, Color cField, Color cTitle) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20.28 * s, 0, 20.72 * s, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            AppLocalizations.of(context).t('chcShortIdLabel'),
            style: TextStyle(fontSize: 17 * s, height: 1.0, color: cSub),
          ),
          SizedBox(height: 8 * s),
          Container(
            height: 56 * s,
            decoration: BoxDecoration(
              color: cField,
              borderRadius: BorderRadius.circular(24.7 * s), // 与名称框同款
            ),
            alignment: Alignment.centerLeft,
            padding: EdgeInsets.only(left: 26 * s), // 与名称框 caret 左内边距一致
            child: TextField(
              controller: _shortIdCtrl,
              maxLength: 20,
              keyboardType: TextInputType.text,
              enableSuggestions: false,
              autocorrect: false,
              style: TextStyle(fontSize: 19 * s, color: cTitle, height: 1.0),
              cursorColor: cTitle,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                counterText: '',
                hintText: AppLocalizations.of(context).t('chcShortIdHint'),
                hintStyle: TextStyle(fontSize: 19 * s, height: 1.0, color: cSub),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 公开/私密选择行：同一控件的两种状态（measure_channel.md §6/§7）。
  /// 选中：图标块 #D3D4D8 + 近黑图标、实心近黑单选 + 白对勾；
  /// 未选中：图标块 #F1F2F4 + 浅灰图标、空心描边单选（2.5 / #9CA2AE）。
  Widget _typeRow({
    required BuildContext context,
    required double s,
    required bool selected,
    required IconData icon,
    required Color blockColor,
    required Color iconColor,
    required String title,
    required String subtitle,
    required Color titleColor,
    required Color subColor,
    required Color actionColor,
    required Color radioStroke,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 20.33 * s), // 块左 20.33 / 单选右缘 399.67
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _isPublic.value = selected,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 圆形图标块：选中 54.33 / 未选中 53.67（同一规格，噪声差）
            Container(
              width: (selected ? 54.33 : 53.67) * s,
              height: (selected ? 54.33 : 53.67) * s,
              decoration: BoxDecoration(color: blockColor, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Icon(icon, size: 26 * s, color: iconColor), // ink 23 → size≈26（派生）
            ),
            SizedBox(width: 21.5 * s), // 块右缘 74.5 → 文字 96.0
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                        fontSize: (selected ? 20.3 : 20.4) * s, // 实测 20.3/20.4
                        height: 1.0,
                        fontWeight: FontWeight.w600,
                        color: titleColor),
                  ),
                  SizedBox(height: 9.7 * s), // 标题 ink 底 → 副标题 ink 顶 11.67（去 ink 偏差）
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 17.9 * s, height: 1.0, color: subColor),
                  ),
                ],
              ),
            ),
            SizedBox(width: 12 * s),
            _radio(selected: selected, s: s, actionColor: actionColor, stroke: radioStroke),
          ],
        ),
      ),
    );
  }

  /// 单选（外径 28.67）：选中 = 实心 #0C0D12 + 白对勾；未选中 = 2.5 描边空心。
  Widget _radio(
      {required bool selected,
      required double s,
      required Color actionColor,
      required Color stroke}) {
    return Container(
      width: 28.67 * s,
      height: 28.67 * s,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? actionColor : Colors.transparent,
        border: selected
            ? null
            : Border.all(color: stroke, width: 2.5 * s), // 实测描边 2.5
      ),
      alignment: Alignment.center,
      child: selected
          ? Icon(Icons.check, size: 16 * s, color: Colors.white, weight: 700)
          : null,
    );
  }

  /// 创建：调预留的 service 方法（端点由 be-channel 并行开发，见 conversation_service.createChannel）。
  Future<void> _create(BuildContext context) async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    // 自定义 ID 预校验（选填）：填了但不符格式 → 本地提示，不发请求
    final shortId = _shortIdCtrl.text.trim();
    if (shortId.isNotEmpty && !_shortIdReg.hasMatch(shortId)) {
      final t = AppLocalizations.of(context).t;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(t('chcShortIdInvalid'))),
      );
      return;
    }
    // await 前把 ctx 相关的都取好，避免 BuildContext 跨 async gap
    final t = AppLocalizations.of(context).t;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ConversationService()
          .createChannel(name, isPublic: _isPublic.value, shortId: shortId);
      _nameCtrl.clear();
      _shortIdCtrl.clear();
      _canCreate.value = false;
      _isPublic.value = true;
      CreateChannelSheetController.hide();
      // 创建成功后会话列表刷新：chat_list_page 的 _load 链路（type==3 渲染分支已预留）
    } on ApiException catch (e) {
      // 业务失败（含 3008 自定义 ID 已被使用）：优先展示后端 message
      messenger?.showSnackBar(
        SnackBar(content: Text(e.message.isNotEmpty ? e.message : t('chcCreateFailed'))),
      );
    } catch (_) {
      // 端点未就绪/网络失败：只提示，不破坏 sheet 状态
      messenger?.showSnackBar(
        SnackBar(content: Text(t('chcCreateFailed'))),
      );
    }
  }
}
