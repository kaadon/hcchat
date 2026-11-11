import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/app_locale.dart';
import '../services/conversation_service.dart';
import '../theme/app_theme.dart';

/// 群二维码：群管理页展示/分享。
/// 内容为深链 chatpulse://group?id=<会话ID>，
/// 群成员扫码（扫一扫识别该格式）→ 服务端校验"二维码进群"开关 → 进群。
class GroupQrPage extends StatelessWidget {
  final ConvItem conv;
  const GroupQrPage({super.key, required this.conv});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final data = 'chatpulse://group?id=${conv.id}';
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(title: Text(t('groupQrTitle'))),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(conv.conversationName,
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: context.cs.onSurface)),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: QrImageView(
                data: data,
                size: 240,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square, color: Colors.black),
                dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Colors.black),
              ),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(t('groupQrHint'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.6,
                      color: context.cs.onSurfaceVariant)),
            ),
          ],
        ),
      ),
    );
  }
}
