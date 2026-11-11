import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme/app_theme.dart';

/// Web 端兜底：webview_flutter 不支持 Web 平台，
/// 直接提示并在系统浏览器打开链接（保持与 web_view_web 一致的降级策略）。
class InAppWebViewPage extends StatelessWidget {
  final String url;
  final String displayName;
  final bool nativeBridge;
  final String? domain;

  const InAppWebViewPage({
    super.key,
    required this.url,
    required this.displayName,
    this.nativeBridge = false,
    this.domain,
  });

  @override
  Widget build(BuildContext context) {
    final title =
        displayName.isNotEmpty ? displayName : (domain ?? '网页');
    return Scaffold(
      appBar: AppBar(
        backgroundColor: context.cs.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 26, color: Color(0xFF111111)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(title,
            style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: Color(0xFF111111))),
        centerTitle: true,
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('当前平台暂不支持内置浏览',
                style: TextStyle(fontSize: 15, color: Color(0xFF6B7480))),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () =>
                  launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.open_in_browser_outlined, size: 18),
              label: const Text('打开链接'),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
