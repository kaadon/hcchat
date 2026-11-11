import 'package:flutter/material.dart';

import '../../l10n/app_locale.dart';
import '../../theme/app_theme.dart';
import '../media_filter_page.dart';

// ============================================================================
// 群「查看媒体」页（2026-09-29）。
//
// 根因修复：原「查看媒体」跳 GroupFilePage（群文件云盘表，只有走「文件」按钮
// 上传的才入库），聊天里发的图片/视频查不到 → 空数据。本页改按**消息扫描**
// （GET /message/filter，与群资料页媒体卡计数同源），5 个类型 Tab。
//
// Tab 内容复用 MediaFilterPage（embedded 模式，无 Scaffold/AppBar）。
// ============================================================================

/// 群媒体页：照片 | 视频 | 文件 | 链接 | 语音
class GroupMediaPage extends StatelessWidget {
  /// 初始 Tab：0 照片 / 1 视频 / 2 文件 / 3 链接 / 4 语音
  final int initialTab;
  final String convId;
  final String convName;

  const GroupMediaPage({
    super.key,
    required this.convId,
    this.convName = '',
    this.initialTab = 0,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    // type 取值与 filterMsgTypes（API.md :1382）一一对应
    final tabs = <(String, String)>[
      ('image', t('gmTabPhotos')),
      ('video', t('gmTabVideos')),
      ('file', t('gmTabFiles')),
      ('link', t('gmTabLinks')),
      ('voice', t('gmTabVoice')),
    ];
    final initial = initialTab >= 0 && initialTab < tabs.length ? initialTab : 0;
    return DefaultTabController(
      length: tabs.length,
      initialIndex: initial,
      child: Scaffold(
        backgroundColor: context.cs.surface,
        appBar: AppBar(
          title: Text(t('groupMenuMedia')),
          bottom: TabBar(
            isScrollable: true,
            labelColor: AppTheme.primary,
            unselectedLabelColor: context.cs.onSurfaceVariant,
            indicatorColor: AppTheme.primary,
            dividerColor: context.cs.onSurfaceVariant.withValues(alpha: 0.08),
            tabs: [for (final tab in tabs) Tab(text: tab.$2)],
          ),
        ),
        body: TabBarView(
          children: [
            for (final tab in tabs)
              MediaFilterPage(
                title: tab.$2,
                convId: convId,
                type: tab.$1,
                embedded: true,
              ),
          ],
        ),
      ),
    );
  }
}
