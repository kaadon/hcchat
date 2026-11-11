import 'dart:async';

import 'package:flutter/material.dart';

import '../services/conversation_service.dart';
import '../services/local_store.dart';
import '../l10n/app_locale.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';

/// 消息搜索（全局，仅自己参与的会话）。
/// 2026-09-29 会话内搜索：[convId]/[convName] 非空时只搜该会话的聊天记录
///（chat_page「…」菜单 / 群资料页入口），结果行显示发送人昵称+头像，
/// 点击 pop(该消息 msgId) 由聊天页原地跳转定位（不重开会话）。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.initialKeyword, this.convId, this.convName});

  /// 搜索模式（消息列表顶栏，十七批）带词跳入：预填并自动执行一次搜索
  final String? initialKeyword;

  /// 会话内搜索范围（2026-09-29）：非空 = 只搜该会话
  final String? convId;

  /// 会话内搜索的会话名（提示条展示用）
  final String? convName;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _svc = ConversationService();
  final _ctrl = TextEditingController();
  List<Map<String, dynamic>> _results = [];

  /// 本地搜索历史（最新的在前，落盘保存；退出登录时清空）
  List<String> _history = [];
  int _total = 0;
  bool _searched = false;
  bool _loading = false;

  bool get _scoped => (widget.convId ?? '').isNotEmpty;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    // 搜索模式带词跳入（十七批）：预填关键词并自动搜一次
    final kw = widget.initialKeyword?.trim() ?? '';
    if (kw.isNotEmpty) {
      _ctrl.text = kw;
      _search();
    }
  }

  Future<void> _loadHistory() async {
    try {
      final list = await LocalStore.loadSearchHistory();
      if (mounted) setState(() => _history = list);
    } catch (_) {}
  }

  Future<void> _clearHistory() async {
    await LocalStore.clearSearchHistory();
    if (mounted) setState(() => _history = []);
  }

  Future<void> _search() async {
    final kw = _ctrl.text.trim();
    if (kw.isEmpty) return;
    // 记录搜索历史（去重、最新在前、最多 10 条），下次进页还在。
    // 会话内搜索不写历史：范围局部，历史条目在全局搜索页会误导
    if (!_scoped) unawaited(LocalStore.addSearchHistory(kw));
    setState(() {
      _loading = true;
      _searched = true;
    });
    try {
      final data = await _svc.searchMessages(kw,
          convId: _scoped ? widget.convId : null);
      if (mounted) {
        setState(() {
          _results = (data['list'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>();
          _total = (data['total'] as num?)?.toInt() ?? 0;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _preview(Map<String, dynamic> m) {
    final t = AppLocalizations.of(context).t;
    final typeMap = {
      2: t('searchImage'),
      3: t('searchFile'),
      4: t('searchVoice'),
      5: t('searchVideo')
    };
    return (typeMap[(m['type'] as num?)?.toInt()] ?? '') +
        (m['content']?.toString() ?? '');
  }

  /// 发送人昵称：优先服务端补的 senderNickname，回落账号/占位
  String _senderName(Map<String, dynamic> m) {
    final t = AppLocalizations.of(context).t;
    final n = m['senderNickname']?.toString() ?? '';
    if (n.isNotEmpty) return n;
    final a = m['account']?.toString() ?? '';
    return a.isNotEmpty ? a : t('newConvUser');
  }

  /// 还没搜索时：有历史就展示历史（点一下直接搜），没有才显示引导文案
  Widget _buildHistoryOrTip() {
    final t = AppLocalizations.of(context).t;
    if (_history.isEmpty) {
      return Center(
          child: Text(t('searchEmptyTip'),
              style: TextStyle(color: context.cs.onSurfaceVariant)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 8, 4),
          child: Row(
            children: [
              Text(t('searchHistory'),
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: context.cs.onSurfaceVariant)),
              const Spacer(),
              TextButton(
                onPressed: _clearHistory,
                child: Text(t('searchClearHistory'),
                    style:
                        const TextStyle(fontSize: 13, color: AppTheme.primary)),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: _history.length,
            separatorBuilder: (_, __) =>
                Divider(height: 1, color: context.cs.outlineVariant),
            itemBuilder: (_, i) {
              final kw = _history[i];
              return ListTile(
                dense: true,
                leading: Icon(Icons.history,
                    size: 18, color: context.cs.onSurfaceVariant),
                title: Text(kw,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(fontSize: 14, color: context.cs.onSurface)),
                onTap: () {
                  _ctrl.text = kw;
                  _ctrl.selection = TextSelection.fromPosition(
                      TextPosition(offset: kw.length));
                  _search();
                },
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        titleSpacing: 12,
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          style: TextStyle(fontSize: 15, color: context.cs.onSurface),
          decoration: InputDecoration(
            hintText: _scoped
                ? (widget.convName ?? '').isEmpty
                    ? t('searchHint')
                    : t('searchInConv', {'name': widget.convName!})
                : t('searchHint'),
            hintStyle:
                TextStyle(fontSize: 15, color: context.cs.onSurfaceVariant),
            isDense: true,
            filled: true,
            fillColor: context.cs.surfaceContainer,
            prefixIcon: Icon(Icons.search,
                size: 20, color: context.cs.onSurfaceVariant),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              borderSide: BorderSide.none,
            ),
          ),
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
        ),
        actions: [
          TextButton(
              onPressed: _search,
              child: Text(t('searchAction'),
                  style: const TextStyle(color: AppTheme.primary))),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : !_searched
              ? _buildHistoryOrTip()
              : _results.isEmpty
                  ? Center(
                      child: Text(t('searchNoResults'),
                          style:
                              TextStyle(color: context.cs.onSurfaceVariant)))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                          child: Text(
                              t('searchResultCount', {'count': '$_total'}),
                              style: TextStyle(
                                  fontSize: 12,
                                  color: context.cs.onSurfaceVariant)),
                        ),
                        Expanded(
                          child: ListView.separated(
                            padding: const EdgeInsets.all(16),
                            itemCount: _results.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 10),
                            itemBuilder: (_, i) {
                              final m = _results[i];
                              final msgId =
                                  m['msgId']?.toString().replaceAll('"', '');
                              return InkWell(
                                // 2026-09-29 会话内搜索：点击回传 msgId，聊天页原地跳转定位
                                onTap: _scoped && (msgId?.isNotEmpty ?? false)
                                    ? () => Navigator.of(context).pop(msgId)
                                    : null,
                                borderRadius: BorderRadius.circular(12),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 12),
                                  decoration: BoxDecoration(
                                    color: context.cs.surface,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                        color: context.cs.outlineVariant),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      // 2026-09-29：发送人头像 + 昵称（服务端批量补发）
                                      AppAvatar(
                                        url: m['senderAvatar']?.toString() ?? '',
                                        name: _senderName(m),
                                        size: 34,
                                        background: AppTheme.primary,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(_senderName(m),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w600,
                                                    color: context
                                                        .cs.onSurfaceVariant)),
                                            const SizedBox(height: 4),
                                            Text(_preview(m),
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    fontSize: 14,
                                                    color:
                                                        context.cs.onSurface)),
                                            if (!_scoped) ...[
                                              const SizedBox(height: 4),
                                              Text(
                                                  t('searchConvLabel', {
                                                    'id':
                                                        '${m['conversationId']}'
                                                  }),
                                                  style: TextStyle(
                                                      fontSize: 12,
                                                      color: context.cs
                                                          .onSurfaceVariant)),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
    );
  }
}
