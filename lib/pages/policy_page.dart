import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../theme/app_theme.dart';

/// 政策/条款详情页（隐私政策 / 服务条款）
class PolicyPage extends StatelessWidget {
  final String title;
  final String content;

  /// 软件名（后台配置品牌名）：渲染时替换文案中的默认名 "ChatPulse"；
  /// 空则回落默认名
  final String appName;

  const PolicyPage({
    super.key,
    required this.title,
    required this.content,
    this.appName = '',
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = appName.isNotEmpty ? appName : 'ChatPulse';
    final body =
        _localizedPolicyContent(context, content).replaceAll('ChatPulse', name);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(title: Text(title)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          ),
          child: Text(
            body,
            style: TextStyle(
              fontSize: 14,
              color: scheme.onSurface,
              height: 1.8,
            ),
          ),
        ),
      ),
    );
  }
}

/// 已收录的政策文档按词条本地化渲染；未收录的内容原样返回
String _localizedPolicyContent(BuildContext context, String raw) {
  if (raw == kPrivacyPolicy) return localizedPrivacyPolicy(context);
  if (raw == kTermsOfService) return localizedTermsOfService(context);
  return raw;
}

/// 隐私政策全文（中文原文，供调用方与 zh 环境使用）
const String kPrivacyPolicy = '''
隐私政策

生效日期：2026 年 8 月 31 日

ChatPulse（以下简称“我们”或“本应用”）高度重视用户的个人信息保护。本隐私政策旨在向您说明我们如何收集、使用、存储、共享和保护您的个人信息，以及您所享有的相关权利。请您在使用本应用前仔细阅读本政策。

一、我们收集的信息
1. 账号信息：当您注册或使用本应用时，我们会收集您的手机号、昵称、头像等账号基本信息，用于创建账号和身份识别。
2. 通讯录与好友关系：为便于您与同事、朋友沟通，我们会在您授权后访问您的通讯录或根据您主动添加的好友关系建立联系人列表。
3. 消息内容：您在使用单聊、群聊、朋友圈等功能时发送的文字、图片、语音、视频、文件等内容，仅在实现通信目的所必需的范围内进行处理和存储。
4. 设备与日志信息：为保障服务安全与稳定，我们可能收集设备型号、操作系统版本、网络类型、IP 地址、崩溃日志等信息。
5. 音视频通话：语音/视频通话过程中，我们需要访问您的麦克风、摄像头权限，通话内容仅用于实时传输，不会未经授权留存。

二、信息的使用
1. 向您提供即时通讯、朋友圈、钱包红包/转账、语音/视频通话等服务。
2. 保障账号安全，防止欺诈、滥用及其他违法违规行为。
3. 优化产品体验，修复故障，提升服务稳定性。
4. 在法律法规允许的范围内，向您发送服务通知、安全提示等必要信息。

三、信息的存储与保护
1. 我们采用加密传输、访问控制、数据脱敏等技术措施保护您的个人信息。
2. 消息内容存储期限遵循服务器策略及法律法规要求，超出必要期限后将进行删除或匿名化处理。
3. 我们严格限制内部人员对用户信息的访问权限，仅授权人员在履行职责所必需时方可访问。

四、信息的共享与披露
1. 未经您的同意，我们不会向第三方共享、转让或公开披露您的个人信息，但法律法规另有规定或政府机关依法要求的除外。
2. 我们可能与关联公司或服务提供商在必要范围内共享匿名化或去标识化的数据，以改进服务。

五、您的权利
1. 您有权访问、更正、删除您的个人信息。
2. 您有权撤回部分授权（如通讯录、相机、麦克风等），但可能影响相关功能的正常使用。
3. 您有权注销账号，注销后我们将按照法律法规要求处理您的信息。

六、未成年人保护
本应用主要面向企业用户及成年人。若您是未成年人，请在监护人陪同下使用，并在监护人同意的前提下提供个人信息。

七、政策更新
我们可能会根据法律法规变化或服务调整适时修订本隐私政策。更新后的政策将在本页面公布，重大变更将以显著方式提示您。

如您对本隐私政策有任何疑问，请联系企业管理员或我们的客服团队。
''';

/// 服务条款全文（中文原文，供调用方与 zh 环境使用）
const String kTermsOfService = '''
服务条款

生效日期：2026 年 8 月 31 日

欢迎使用 ChatPulse！本服务条款（以下简称“本条款”）由您与本应用运营方共同缔结，具有合同效力。请您在使用本应用前仔细阅读并充分理解本条款。

一、服务说明
1. ChatPulse 是一款面向企业及团队用户的即时通讯应用，提供单聊、群聊、语音/视频通话、朋友圈、文件传输、钱包红包/转账等功能。
2. 我们可能根据运营需要对服务功能进行升级、调整或暂停，并会尽可能提前通知您。

二、账号注册与使用
1. 您应使用真实、准确、完整的信息注册账号，并对账号下的所有行为承担法律责任。
2. 您不得将账号转让、出租、出借或以其他方式提供给他人使用。
3. 如发现账号被盗用或存在安全风险，应立即通知我们或企业管理员。

三、用户行为规范
1. 您应遵守国家法律法规，不得利用本应用从事违法违规活动。
2. 禁止发送、传播含有暴力、色情、赌博、诈骗、诽谤、侵犯他人知识产权或其他违法违规内容的信息。
3. 禁止干扰、破坏本应用的正常运行，包括但不限于恶意攻击服务器、破解、逆向工程等行为。

四、知识产权
1. 本应用的界面设计、程序代码、商标、标识及相关内容的所有权和知识产权归我们或相关权利人所有。
2. 您在使用本应用过程中产生的原创内容知识产权归您所有，但您授予我们为提供服务所必需的有限使用权。

五、免责条款
1. 因不可抗力、系统维护、网络故障、第三方原因等导致的服务中断或数据丢失，我们不承担责任，但会尽力恢复服务。
2. 您理解并同意，互联网服务存在一定风险，您应自行判断和承担使用本应用的风险。

六、账号注销与服务终止
1. 您可随时申请注销账号，注销后相关数据将按照法律法规及本应用规则处理。
2. 如您违反本条款，我们有权依据情节严重程度采取限制功能、暂停或终止服务等措施。

七、条款变更与法律适用
1. 我们可能根据法律法规或服务变化适时修订本条款，并在本页面公布。
2. 本条款的订立、执行和解释均适用中华人民共和国法律。

如您对本服务条款有任何疑问，请联系企业管理员或我们的客服团队。
''';

/// 本地化隐私政策全文（段落与 [kPrivacyPolicy] 一一对应）
String localizedPrivacyPolicy(BuildContext context) {
  final t = AppLocalizations.of(context).t;
  return [
    t('policyPrivacyTitle'),
    t('policyPrivacyEffectiveDate'),
    t('policyPrivacyIntro'),
    [
      t('policyPrivacyS1Title'),
      t('policyPrivacyS1Item1'),
      t('policyPrivacyS1Item2'),
      t('policyPrivacyS1Item3'),
      t('policyPrivacyS1Item4'),
      t('policyPrivacyS1Item5'),
    ].join('\n'),
    [
      t('policyPrivacyS2Title'),
      t('policyPrivacyS2Item1'),
      t('policyPrivacyS2Item2'),
      t('policyPrivacyS2Item3'),
      t('policyPrivacyS2Item4'),
    ].join('\n'),
    [
      t('policyPrivacyS3Title'),
      t('policyPrivacyS3Item1'),
      t('policyPrivacyS3Item2'),
      t('policyPrivacyS3Item3'),
    ].join('\n'),
    [
      t('policyPrivacyS4Title'),
      t('policyPrivacyS4Item1'),
      t('policyPrivacyS4Item2'),
    ].join('\n'),
    [
      t('policyPrivacyS5Title'),
      t('policyPrivacyS5Item1'),
      t('policyPrivacyS5Item2'),
      t('policyPrivacyS5Item3'),
    ].join('\n'),
    [
      t('policyPrivacyS6Title'),
      t('policyPrivacyS6Body'),
    ].join('\n'),
    [
      t('policyPrivacyS7Title'),
      t('policyPrivacyS7Body'),
    ].join('\n'),
    t('policyPrivacyContact'),
  ].join('\n\n');
}

/// 本地化服务条款全文（段落与 [kTermsOfService] 一一对应）
String localizedTermsOfService(BuildContext context) {
  final t = AppLocalizations.of(context).t;
  return [
    t('policyTermsTitle'),
    t('policyTermsEffectiveDate'),
    t('policyTermsIntro'),
    [
      t('policyTermsS1Title'),
      t('policyTermsS1Item1'),
      t('policyTermsS1Item2'),
    ].join('\n'),
    [
      t('policyTermsS2Title'),
      t('policyTermsS2Item1'),
      t('policyTermsS2Item2'),
      t('policyTermsS2Item3'),
    ].join('\n'),
    [
      t('policyTermsS3Title'),
      t('policyTermsS3Item1'),
      t('policyTermsS3Item2'),
      t('policyTermsS3Item3'),
    ].join('\n'),
    [
      t('policyTermsS4Title'),
      t('policyTermsS4Item1'),
      t('policyTermsS4Item2'),
    ].join('\n'),
    [
      t('policyTermsS5Title'),
      t('policyTermsS5Item1'),
      t('policyTermsS5Item2'),
    ].join('\n'),
    [
      t('policyTermsS6Title'),
      t('policyTermsS6Item1'),
      t('policyTermsS6Item2'),
    ].join('\n'),
    [
      t('policyTermsS7Title'),
      t('policyTermsS7Item1'),
      t('policyTermsS7Item2'),
    ].join('\n'),
    t('policyTermsContact'),
  ].join('\n\n');
}
