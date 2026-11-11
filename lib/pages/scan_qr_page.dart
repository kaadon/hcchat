import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';

/// 扫一扫占位页（V2.0 二维码功能后续接）
class ScanQrPage extends StatelessWidget {
  const ScanQrPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title:
            Text(t('scanQrTitle'), style: const TextStyle(color: Colors.white)),
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.qr_code_scanner, size: 96, color: Colors.white70),
            const SizedBox(height: 16),
            Text(
              t('scanQrPlaceholder'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 14, color: Colors.white60, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}
