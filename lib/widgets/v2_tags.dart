import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'v2_kit.dart';

// V2 复刻的小标签组（2026-09-14 批次：消息列表 / 通讯录两页共用）。
//
// 尺寸来自参考截图的像素级实测（逻辑 px，基准宽 420），全部经 `v2Scale` 等比缩放。
// 参考包里没有这几个标签的图片资源（`assets/icons` 下只有 tab_*.png），
// 所以直接用「填充块 + 文字」画，不用图标字体。

/// 蓝V 认证盾的蓝色（截图实测 #3A93EE；通讯录页实测 #4498ED，差异在 JPEG 噪声内）。
const Color kV2VerifiedBlue = Color(0xFF3A93EE);

/// 会话类型小徽章：群聊 = 红色圆底白图标；频道 = 蓝色圆底白图标。
///
/// 2026-09-15 第十七批（Telegram 风格参考截图）：原「实心蓝底文字『群聊』/
/// 浅蓝底文字『频道』」改为**小圆底图标徽章**——与参考图名称前的星形圆徽
/// 同构。圆 17、图标 ink 12；群聊沿用群名红 #DC4E52（深色 #FF7A7E），
/// 频道沿用主题蓝 AppTheme.primary #007AFF（深色 #409CFF），与两色频道名
/// 形成同色呼应。图标：群聊 `Icons.groups`；频道 `Icons.campaign`（与
/// 新建频道页头像同图标，广播语义辨识度最高）。位置由调用方统一放名称前
/// （chat_list_page 群/频道均已在名称前）。
class V2ConversationTag extends StatelessWidget {
  const V2ConversationTag({
    super.key,
    this.kind = V2ConversationTagKind.group,
  });

  final V2ConversationTagKind kind;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final dark = context.v2IsDark;
    final isGroup = kind == V2ConversationTagKind.group;
    final bg = isGroup
        ? (dark ? const Color(0xFFFF7A7E) : const Color(0xFFDC4E52))
        : (dark ? const Color(0xFF409CFF) : AppTheme.primary);
    return Container(
      width: 17 * s,
      height: 17 * s,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Icon(
        isGroup ? Icons.groups : Icons.campaign,
        size: 12 * s,
        color: Colors.white,
      ),
    );
  }
}

enum V2ConversationTagKind { group, channel }

/// 蓝V 认证盾（会话名后面的那枚）。
///
/// 实测 ink 18.0 × 20.7（宽/高 0.87 ⇒ 盾形，不是正圆徽章），
/// 所以选 Material 的 `verified_user`（盾 + 对勾），而不是 `verified`（圆徽章）。
class V2VerifiedShield extends StatelessWidget {
  const V2VerifiedShield({super.key, this.size = 24, this.color});

  /// 图标**盒子**尺寸（不是 ink 尺寸）。默认 24 时 ink 约 18×20.7，与实测一致。
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.verified_user,
      size: size * v2Scale(context),
      color: color ?? kV2VerifiedBlue,
    );
  }
}

/// 靓号皇冠徽（2026-09-15 第十四批）。
///
/// 用户拍板：蓝色勾保留给客服（[CertBadge]），靓号 `vipShortId` 改用**金色皇冠**
/// 区分。Material 无纯皇冠图标，取 `workspace_premium`（勋章绶带形，观感最接近）；
/// 金色 #F5A623，与蓝色客服勾明确区分。
const Color kV2VipGold = Color(0xFFF5A623);

class VipCrownBadge extends StatelessWidget {
  const VipCrownBadge({super.key, this.size = 24, this.color});

  /// 图标**盒子**尺寸（与 [V2VerifiedShield] 同口径）。
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.workspace_premium,
      size: size * v2Scale(context),
      color: color ?? kV2VipGold,
    );
  }
}

/// 客服认证徽（V 盾）公共判定 + 展示（2026-09-15 第十三批）。
/// 背景：用户反馈「客服账号没有勾图标」——通讯录里的勾此前只认
/// `vipShortId`（靓号），与客服身份无关。这里把「账号角色=客服才亮 V 盾」
/// 的判定抽成一处，供 消息列表 / 好友资料页 / 聊天窗口 复用。
///
/// ⚠️ role 语义：PublicUser.role = **账号角色**（1 普通 / 2 管理 / 3 客服，
/// im-server `RoleKefu=3`）。群成员列表里的 `role` 是**群内角色**
/// （1 群主 2 管理员 3 普通成员），同名不同义，**不得**传入本组件。
class CertBadge extends StatelessWidget {
  const CertBadge({super.key, required this.role, this.size = 24});

  /// 对方账号角色（PublicUser.role / 会话列表 peerRole），数字或字符串均可。
  final dynamic role;

  /// 图标盒子尺寸（与 [V2VerifiedShield] 同口径）。
  final double size;

  /// 是否客服（RoleKefu=3）。兼容数字 / 字符串两种下发形态。
  static bool isKefu(dynamic role) => role == 3 || role?.toString() == '3';

  @override
  Widget build(BuildContext context) {
    if (!isKefu(role)) return const SizedBox.shrink();
    // 样式与通讯录现有勾一致（V2VerifiedShield 默认蓝）
    return V2VerifiedShield(size: size);
  }
}
