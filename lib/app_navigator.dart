import 'package:flutter/material.dart';

/// 全局 Navigator Key
/// 用途：来电页挂在 MaterialApp.builder 上（在 Navigator 之上），
/// 接听后需要用这个 key 把通话页 push 进 Navigator。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
