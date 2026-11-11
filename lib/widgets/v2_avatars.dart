import 'package:flutter/material.dart';

import '../theme/app_theme.dart'; // context.v2*（AppV2Colors 扩展）
import 'v2_kit.dart';

// 注册页第 2 步「选择一个头像」的 6 张内置预设头像。
//
// 资源位置：`im-app/assets/images/default_avatars/avatar_1..6.png`（512×512 RGBA），
// 目录已在 `pubspec.yaml` 的 assets 白名单里登记 —— 新增/替换图片时记得同步。
//
// 为什么「预设头像」也要真上传成 URL：`user.avatar` 在多端（im-app / im-pc / im-uniapp）
// 都按 URL 渲染，存一个自定义协议（如 `preset://avatar_1`）会让未适配的端渲染成破图。
// 所以注册成功后由 register_page 把选中的 PNG 字节 POST 到 `/api/v1/upload`，
// 再 `PUT /api/v1/user/profile` 写回 URL，各端无需改动。

/// 6 张预设头像资源路径（顺序即界面顺序）。
const List<String> kV2AvatarAssets = <String>[
  'assets/images/default_avatars/avatar_1.png',
  'assets/images/default_avatars/avatar_2.png',
  'assets/images/default_avatars/avatar_3.png',
  'assets/images/default_avatars/avatar_4.png',
  'assets/images/default_avatars/avatar_5.png',
  'assets/images/default_avatars/avatar_6.png',
];

/// 圆形头像（纯图片，尺寸按参考截图逻辑 px 传入，内部自动乘 [v2Scale]）。
///
/// [badge] 会叠在右下角（预设头像预览用的相机徽标、候选项用的对勾都用它）。
class V2AvatarCircle extends StatelessWidget {
  const V2AvatarCircle({
    super.key,
    required this.index,
    required this.size,
    this.badge,
  });

  /// 预设头像下标（0 起，越界自动取模）。
  final int index;

  /// 逻辑直径（未缩放）。
  final double size;

  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final d = size * s;
    return SizedBox(
      width: d,
      height: d,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipOval(
            child: Image.asset(
              kV2AvatarAssets[index % kV2AvatarAssets.length],
              width: d,
              height: d,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                width: d,
                height: d,
                color: context.v2Fill,
                alignment: Alignment.center,
                child: Icon(Icons.person_rounded,
                    size: d * 0.5, color: context.v2HintColor),
              ),
            ),
          ),
          if (badge != null)
            Positioned(right: -2 * s, bottom: -2 * s, child: badge!),
        ],
      ),
    );
  }
}

/// 头像候选项：选中时外圈近黑描边 + 右下角近黑对勾（实测：候选直径 67、间距 10）。
class V2AvatarOption extends StatelessWidget {
  const V2AvatarOption({
    super.key,
    required this.index,
    required this.selected,
    required this.onTap,
    this.size = 67,
  });

  final int index;
  final bool selected;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final ring = 2.5 * s;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: selected ? EdgeInsets.all(ring) : EdgeInsets.zero,
        decoration: selected
            ? BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: context.v2ActionBg, width: ring),
              )
            : null,
        child: V2AvatarCircle(
          index: index,
          size: size,
          badge: selected ? const V2CheckBadge(size: 21) : null,
        ),
      ),
    );
  }
}

/// 右下角近黑圆形对勾徽标（选中态）。
class V2CheckBadge extends StatelessWidget {
  const V2CheckBadge({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final d = size * s;
    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: context.v2ActionBg,
        border: Border.all(color: context.v2Bg, width: 1.5 * s),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.check_rounded, size: d * 0.66, color: context.v2ActionFg),
    );
  }
}

/// 预览大圆右下角的相机徽标（点击进入相册）。
class V2CameraBadge extends StatelessWidget {
  const V2CameraBadge({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final d = size * s;
    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: context.v2ActionBg,
        border: Border.all(color: context.v2Bg, width: 2 * s),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.photo_camera_rounded,
          size: d * 0.54, color: context.v2ActionFg),
    );
  }
}
