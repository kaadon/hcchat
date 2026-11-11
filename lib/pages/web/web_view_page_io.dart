import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/app_locale.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_dialogs.dart';
import '../../widgets/web_capsule.dart';

/// 应用内 WebView 壳（链接卡片蓝边态点击进入）。
///
/// 关键行为：
/// 1. 顶栏只显示 [displayName]（不展示完整地址，防钓鱼）；
/// 2. 仅当 [nativeBridge]==true 时注入 `window.IM_BRIDGE` 桥（带会话鉴权，
///    方法体先打印/预留，重点保证"只有白名单 nativeBridge 为真才注入"）；
/// 3. 拦截 `window.open` → 通过 JS 通道回传 URL，由原生侧用系统浏览器打开；
/// 4. 外链（非同域）直接丢系统浏览器，留在 WebView 内防钓鱼；
/// 5. 顶部加载进度条。
class InAppWebViewPage extends StatefulWidget {
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
  State<InAppWebViewPage> createState() => _InAppWebViewPageState();
}

class _InAppWebViewPageState extends State<InAppWebViewPage> {
  late final WebViewController _controller;
  bool _loading = true;
  double _progress = 0;
  String _error = '';

  // window.open → 系统浏览器的 JS 通道名（webview_flutter 注入为 IMExternal.postMessage）
  static const String _jsChannel = 'IMExternal';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p / 100.0);
        },
        onPageStarted: (_) {
          if (mounted) setState(() => _loading = true);
        },
        onPageFinished: (url) async {
          if (!mounted) return;
          setState(() => _loading = false);
          // 常驻：拦截 window.open → 系统浏览器
          await _controller.runJavaScript(_windowOpenOverrideJs());
          // 仅白名单 nativeBridge 时注入 IM_BRIDGE 桥
          if (widget.nativeBridge) {
            await _controller.runJavaScript(_bridgeJs());
          }
        },
        onWebResourceError: (e) {
          if (!mounted || _error.isNotEmpty) return;
          // -1/-3 为正常中断（如用户主动停载），忽略
          if (e.errorCode == -1 || e.errorCode == -3) return;
          setState(() => _error = e.description.isNotEmpty
              ? e.description
              : '加载失败（${e.errorCode}）');
        },
        onNavigationRequest: (req) {
          // 外链（非同域）直接丢系统浏览器，留在 WebView 内防钓鱼
          if (req.isMainFrame && !_sameHost(req.url, widget.url)) {
            _openExternal(req.url);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..addJavaScriptChannel(_jsChannel,
          onMessageReceived: (msg) => _openExternal(msg.message));
    // 延迟加载：等 PlatformView 就绪后再 loadRequest，降低首次失败率
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted) _controller.loadRequest(Uri.parse(widget.url));
      });
    });
  }

  /// 注入 JS：覆盖 window.open，把 URL 通过通道丢给原生侧用系统浏览器打开。
  /// 通道名与 [_jsChannel] 保持一致（webview_flutter 注入为 IMExternal.postMessage）。
  String _windowOpenOverrideJs() => '''
(function(){
  if (window.__imOpenHooked) return;
  window.__imOpenHooked = true;
  window.open = function(u, t){ if (u) IMExternal.postMessage(String(u)); return null; };
})();
''';

  /// 注入 JS 桥骨架（仅 nativeBridge==true 时调用）。
  /// 业务方法体先打印/预留，真实鉴权由原生侧实现。
  String _bridgeJs() => '''
window.IM_BRIDGE = {
  getToken: function(){ console.log('IM_BRIDGE.getToken called'); return ''; },
  getUserInfo: function(){ console.log('IM_BRIDGE.getUserInfo called'); return {}; },
  share: function(payload){ console.log('IM_BRIDGE.share', payload); },
  close: function(){ console.log('IM_BRIDGE.close called'); },
  openUrl: function(url){ console.log('IM_BRIDGE.openUrl', url); if (url) window.open(url, '_blank'); }
};
''';

  bool _sameHost(String a, String b) {
    try {
      return Uri.parse(a).host == Uri.parse(b).host;
    } catch (_) {
      return false;
    }
  }

  Future<void> _openExternal(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.displayName.isNotEmpty
        ? widget.displayName
        : (widget.domain ?? '网页');
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: context.cs.surface,
        elevation: 0.5,
        shadowColor: Colors.black.withValues(alpha: 0.05),
        // 左：返回（微信细箭头）。WebView 有历史 → 网页内后退；无 → 关闭页面
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              size: 20, color: Color(0xFF111111)),
          onPressed: () async {
            if (await _controller.canGoBack()) {
              await _controller.goBack();
            } else if (mounted) {
              Navigator.of(context).pop();
            }
          },
        ),
        title: Text(title,
            style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w500,
                color: Color(0xFF111111))),
        centerTitle: true,
        // 右：与发现页内置浏览器一致的微信胶囊（··· 菜单 / ⭕ 关闭）
        actions: [
          WebBrowserCapsule(
            onMore: _showMenu,
            onClose: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline,
                  size: 48, color: Color(0xFF9AA3AE)),
              const SizedBox(height: 12),
              const Text('页面加载失败',
                  style: TextStyle(fontSize: 15, color: Color(0xFF6B7480))),
              const SizedBox(height: 6),
              Text(_error,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF9AA3AE))),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: () {
                  setState(() {
                    _error = '';
                    _loading = true;
                    _controller.loadRequest(Uri.parse(widget.url));
                  });
                },
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新加载'),
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
    return Stack(
      children: [
        WebViewWidget(controller: _controller),
        if (_loading)
          Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(
              value: _progress > 0 ? _progress : null,
              minHeight: 2,
              color: AppTheme.primary,
              backgroundColor: AppTheme.primary.withValues(alpha: 0.15),
            ),
          ),
      ],
    );
  }

  void _showMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: ctx.cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: context.cs.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: Icon(Icons.copy_outlined, color: context.cs.onSurface),
                title: const Text('复制链接'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  Clipboard.setData(ClipboardData(text: widget.url));
                  AppDialogs.toast(context, '链接已复制');
                },
              ),
              ListTile(
                leading: Icon(Icons.open_in_browser_outlined,
                    color: context.cs.onSurface),
                title: const Text('用浏览器打开'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _openExternal(widget.url);
                },
              ),
              ListTile(
                leading: Icon(Icons.refresh, color: context.cs.onSurface),
                title: const Text('刷新'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _controller.reload();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
