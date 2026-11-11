import 'package:flutter/material.dart';

/// Web 端：网页由 iframe 覆盖层承载（web_browser_web.dart），无需原生内容
Widget buildNativeWebView(String url) => const SizedBox.shrink();
