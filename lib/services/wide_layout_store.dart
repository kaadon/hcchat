import 'dart:async';

import 'package:flutter/material.dart';

import '../pages/chat_page.dart';
import '../services/conversation_service.dart';
import '../services/msg_height_cache.dart';
import '../utils/breakpoints.dart';
import '../widgets/transitions.dart';

/// 右栏一个保活页面条目（key 用于 IndexedStack 保活与选中态判断）
class PaneEntry {
  final String key;
  final Widget page;
  const PaneEntry({required this.key, required this.page});
}

/// 宽屏（折叠屏展开/平板）双栏布局的右栏内容分发层。
///
/// - 窄屏：openConversation / openDetail 与旧版完全一致（push 整页）；
/// - 宽屏：更新 [currentKey] 通知右栏（WideChatPane）切换内容，不走路由，
///   左侧列表列保持不动 —— 微信 iPad 版同款交互。
///
/// 右栏可承载任意页面：聊天（chat:xxx）、朋友圈（moments）、
/// 扫一扫（scan）、内置浏览器（web:url）、我的/设置等二级页。
class WideLayoutStore extends ChangeNotifier {
  WideLayoutStore._();
  static final instance = WideLayoutStore._();

  /// 右栏当前条目 key（null = 空态占位）
  String? currentKey;

  /// 右栏保活队列（LRU 上限见 _maxKeep），切换不丢滚动位置与输入框草稿
  final List<PaneEntry> keep = [];
  static const int _maxKeep = 3;

  /// 打开会话：窄屏 push 整页；宽屏更新右栏。
  void openConversation(BuildContext context, ConvItem conv, String myId) {
    // 残余跳修复：预热实测高度内存层（幂等，几毫秒；晚一拍也由
    // ChatPage initState 的兜底预热覆盖后续 build）
    unawaited(MsgHeightCache.ensureLoaded());
    if (!Breakpoints.isWide(context)) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ChatPage(conv: conv, myId: myId)),
      );
      return;
    }
    openPage(
      ChatPage(
        key: ValueKey('wide-chat:${conv.id}'),
        conv: conv,
        myId: myId,
        embedded: true,
      ),
      paneKey: 'chat:${conv.id}',
    );
  }

  /// 宽屏右栏打开任意页面（发现页/我的页的二级页等）
  void openPage(Widget page, {required String paneKey}) {
    currentKey = paneKey;
    keep.removeWhere((e) => e.key == paneKey);
    keep.insert(0, PaneEntry(key: paneKey, page: page));
    while (keep.length > _maxKeep) {
      keep.removeLast();
    }
    notifyListeners();
  }

  /// 统一导航入口：宽屏在右栏打开（左侧列表不动），窄屏 push 整页。
  ///
  /// 返回 Future 与 Navigator.push 一致 —— 窄屏 await 到页面关闭；
  /// 宽屏立即完成（右栏页面没有"关闭"概念，返回键是关右栏）。
  Future<void> openDetail(BuildContext context, Widget page,
      {String? paneKey, bool fadeScale = false}) {
    if (Breakpoints.isWide(context)) {
      openPage(page, paneKey: paneKey ?? 'page:${page.runtimeType}');
      return Future.value();
    }
    return Navigator.push(
      context,
      // fadeScale: true → 淡入+0.96→1 微缩放（二维码页动效规范，2026-09-20）
      fadeScale
          ? fadeScaleRoute(page, scale: true)
          : MaterialPageRoute(builder: (_) => page),
    );
  }

  /// 清空右栏（宽屏返回键两段式的第一段）
  void closePane() {
    currentKey = null;
    notifyListeners();
  }
}

/// 页面级返回统一入口：宽屏右栏页面 → 清右栏；窄屏整页 → 正常 pop。
///
/// 【重要】右栏页面不在 Navigator 栈上（渲染在 HomeShell 内部）——
/// 直接 `Navigator.pop` 会把根路由 HomeShell 弹掉 → **黑屏卡死**。
/// 所以能被 openDetail 打开的页面，自定义返回按钮一律调这个。
/// 右栏页面里再 push 的二级页（ModalRoute.isFirst == false）仍走正常 pop。
void closeDetail(BuildContext context) {
  final route = ModalRoute.of(context);
  final isRootRoute = route == null || route.isFirst;
  if (isRootRoute &&
      Breakpoints.isWide(context) &&
      WideLayoutStore.instance.currentKey != null) {
    WideLayoutStore.instance.closePane();
    return;
  }
  Navigator.of(context).pop();
}
