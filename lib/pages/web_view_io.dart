import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../l10n/app_locale.dart';
import '../theme/app_theme.dart';

/// Native（Android/iOS）：内置 WebView 打开网页小程序
Widget buildNativeWebView(String url) => _AppWebView(url: url);

class _AppWebView extends StatefulWidget {
  final String url;
  const _AppWebView({required this.url});

  @override
  State<_AppWebView> createState() => _AppWebViewState();
}

class _AppWebViewState extends State<_AppWebView> {
  late final WebViewController _controller;
  bool _loading = true;
  String _error = '';
  int _autoRetry = 0; // 首次加载失败自动重试次数（最多 1 次）
  bool _loadedOnce = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) {
            _loadedOnce = true;
            setState(() => _loading = false);
          }
        },
        onWebResourceError: (e) {
          // -1/-3 = ERR_ABORTED 等正常中断，忽略
          if (!mounted ||
              _error.isNotEmpty ||
              e.errorCode == -3 ||
              e.errorCode == -1) {
            return;
          }
          // PlatformView 尚未就绪时的首次失败 → 自动重试一次（解决"首次进入加载失败需手动重试"）
          if (!_loadedOnce && _autoRetry < 1) {
            _autoRetry++;
            Future.delayed(const Duration(milliseconds: 500), () {
              if (mounted) {
                _controller.loadRequest(Uri.parse(widget.url));
              }
            });
            return;
          }
          setState(() {
            _error = e.description.isEmpty
                ? AppLocalizations.of(context)
                    .t('webViewLoadFailedWithCode', {'code': '${e.errorCode}'})
                : e.description;
          });
        },
      ));
    // 延迟加载：等 PlatformView 就绪后再 loadRequest，降低首次失败率
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted) _controller.loadRequest(Uri.parse(widget.url));
      });
    });
  }

  /// ORB（ERR_BLOCKED_BY_ORB）：Chrome 90+ 的安全嗅探拦截，
  /// 常见于服务器返回的 Content-Type 不是 text/html（如 octet-stream / text/plain）。
  String get _hint {
    final t = AppLocalizations.of(context).t;
    if (_error.contains('ERR_BLOCKED_BY_ORB') ||
        _error.contains('BLOCKED_BY_ORB')) {
      return t('webViewHintOrb');
    }
    if (_error.contains('ERR_CLEARTEXT_NOT_PERMITTED')) {
      return t('webViewHintCleartext');
    }
    return t('webViewHintDefault');
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
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
              Text(t('webViewLoadFailed'),
                  style:
                      const TextStyle(fontSize: 15, color: Color(0xFF6B7480))),
              const SizedBox(height: 6),
              Text(_error,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF9AA3AE))),
              const SizedBox(height: 10),
              Text(_hint,
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF9AA3AE))),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: () {
                  // 重新加载（不跳外部浏览器，必须在内置 WebView 内解决）
                  setState(() {
                    _error = '';
                    _loading = true;
                    _controller.loadRequest(Uri.parse(widget.url));
                  });
                },
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(t('webViewRetry')),
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
          const Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }
}
