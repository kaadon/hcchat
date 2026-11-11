import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../theme/app_theme.dart';

/// 协议勾选行（登录 / 注册页共用，App Store 审核合规）
///
/// 交互约定：
/// - 默认不勾选（iOS 审核要求用户主动同意，不允许默认勾上）；
/// - 未勾选时点了登录/注册，外部把 [warn] 置 true：
///   本组件自动播放「淡红底高亮 + 横向抖动」，同时外部配 Toast 提示；
/// - 用户勾选后外部把 [warn] 置 false，红色态立即解除。
class AgreementCheckbox extends StatefulWidget {
  const AgreementCheckbox({
    super.key,
    required this.checked,
    required this.onToggle,
    required this.onOpenTerms,
    required this.onOpenPrivacy,
    this.warn = false,
    this.plain = false,
    this.checkColor,
  });

  /// 是否已勾选
  final bool checked;

  /// 勾选状态变化（点勾选框或整行文字区域触发）
  final ValueChanged<bool> onToggle;

  /// 点击《用户服务协议》
  final VoidCallback onOpenTerms;

  /// 点击《隐私政策》
  final VoidCallback onOpenPrivacy;

  /// 错误提示态：淡红底 + 抖动（由外部在拦截提交时置 true）
  final bool warn;

  /// 无底版模式：去掉灰底与内间距，直接落在页面底色上（V2 登录/注册页版式，
  /// 截图中协议行是白底裸文字，没有任何背景块）。默认 false 保持旧页面观感不变。
  final bool plain;

  /// 勾选框选中色。默认沿用品牌蓝；V2 页面传近黑以贴合单色版式。
  final Color? checkColor;

  @override
  State<AgreementCheckbox> createState() => _AgreementCheckboxState();
}

class _AgreementCheckboxState extends State<AgreementCheckbox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );
  late final Animation<double> _shakeAnim =
      Tween(begin: 0.0, end: 1.0).animate(
    CurvedAnimation(parent: _shake, curve: _ShakeCurve()),
  );

  // 链接点击识别器（需要在 dispose 释放）
  TapGestureRecognizer? _termsTap;
  TapGestureRecognizer? _privacyTap;

  bool _wasWarn = false;

  @override
  void didUpdateWidget(covariant AgreementCheckbox old) {
    super.didUpdateWidget(old);
    // warn 从 false → true 时抖一下；勾选解除 warn 后自动恢复常色
    if (widget.warn && !_wasWarn) {
      _shake.forward(from: 0);
    }
    _wasWarn = widget.warn;
  }

  @override
  void dispose() {
    _shake.dispose();
    _termsTap?.dispose();
    _privacyTap?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final warn = widget.warn;

    // 错误态配色（红色只在拦截提示这一刻出现，平时页面保持单色克制）
    final Color warnBg =
        isDark ? AppTheme.danger.withValues(alpha: 0.15) : const Color(0xFFFFF0EF);
    final Color bodyColor = warn ? AppTheme.danger : scheme.onSurfaceVariant;
    final Color linkColor = warn ? AppTheme.danger : AppTheme.primary;
    final Color borderColor = warn ? AppTheme.danger : const Color(0xFFC7CCD4);
    final Color tick = widget.checkColor ?? AppTheme.primary;

    _termsTap ??= TapGestureRecognizer()..onTap = widget.onOpenTerms;
    _privacyTap ??= TapGestureRecognizer()..onTap = widget.onOpenPrivacy;
    // 外部回调可能重建，保持 recognizer 指向最新回调
    _termsTap!.onTap = widget.onOpenTerms;
    _privacyTap!.onTap = widget.onOpenPrivacy;

    return AnimatedBuilder(
      animation: _shakeAnim,
      builder: (context, child) {
        // 横向抖动：-5 → +5 → -3 → +3 → 0
        final dx = _shakeAnim.value < 1
            ? 5.0 * _shakeCurveOffset(_shakeAnim.value)
            : 0.0;
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: widget.plain
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          // 常态：与输入框一致的灰底（白卡片上的可点区域，风格统一）
          // 报错态：淡红底高亮
          // plain 模式：完全无底版，直接落在页面底色上
          color: widget.plain
              ? (warn ? warnBg : Colors.transparent)
              : (warn
                  ? warnBg
                  : isDark
                      ? scheme.surfaceContainerHighest
                      : const Color(0xFFF7F8FA)),
          borderRadius: BorderRadius.circular(widget.plain ? 0 : 12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ===== 勾选框 =====
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onToggle(!widget.checked),
              child: Padding(
                padding: const EdgeInsets.only(top: 1, right: 8),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 17,
                  height: 17,
                  decoration: BoxDecoration(
                    color: widget.checked ? tick : Colors.transparent,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: widget.checked ? tick : borderColor,
                      width: 1.5,
                    ),
                  ),
                  child: AnimatedScale(
                    scale: widget.checked ? 1.0 : 0.4,
                    duration: const Duration(milliseconds: 150),
                    child: const Icon(Icons.check_rounded,
                        size: 12, color: Colors.white),
                  ),
                ),
              ),
            ),
            // ===== 协议文案（可点整行切换，链接单独跳转） =====
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => widget.onToggle(!widget.checked),
                child: Text.rich(
                  TextSpan(
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: bodyColor,
                    ),
                    children: [
                      TextSpan(text: '${_prefix(context)} '),
                      TextSpan(
                        text: _termsLabel(context),
                        style: TextStyle(
                            color: linkColor, fontWeight: FontWeight.w500),
                        recognizer: _termsTap,
                      ),
                      TextSpan(text: ' ${_andLabel(context)} '),
                      TextSpan(
                        text: _privacyLabel(context),
                        style: TextStyle(
                            color: linkColor, fontWeight: FontWeight.w500),
                        recognizer: _privacyTap,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 文案直接读 l10n（词条已存在四语词典）
  String _prefix(BuildContext context) =>
      AppLocalizations.of(context).t('termsPrefix');

  String _termsLabel(BuildContext context) =>
      AppLocalizations.of(context).t('termsOfService');

  String _andLabel(BuildContext context) =>
      AppLocalizations.of(context).t('termsAnd');

  String _privacyLabel(BuildContext context) =>
      AppLocalizations.of(context).t('privacyPolicy');

  /// 抖动位移（-1~+1 归一化，外部乘以振幅）：
  /// 0 → -1 → +1 → -0.6 → +0.6 → 0 的衰减往返，各段线性过渡保证连续
  double _shakeCurveOffset(double t) {
    if (t < 0.2) return -t / 0.2; // 0 → -1
    if (t < 0.4) return -1 + 2 * (t - 0.2) / 0.2; // -1 → +1
    if (t < 0.6) return 1 - 1.6 * (t - 0.4) / 0.2; // +1 → -0.6
    if (t < 0.8) return -0.6 + 1.2 * (t - 0.6) / 0.2; // -0.6 → +0.6
    return 0.6 * (1 - (t - 0.8) / 0.2); // +0.6 → 0
  }
}

/// 抖动缓动（线性即可，位移曲线自己在 _shakeCurveOffset 里画）
class _ShakeCurve extends Curve {
  @override
  double transform(double t) => t;
}
