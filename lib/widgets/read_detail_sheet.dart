import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/conversation_service.dart';
import 'app_avatar.dart';

/// 群消息「已读详情」底部面板（L1）。
///
/// 调用 GET /api/v1/message/receipts 一次拿齐：
///   - receipts：已读成员名单（按隐私开关过滤，关闭回执者不出现）；
///     服务端已补齐 nickname/avatar（群昵称优先，回落用户昵称）
///   - readCount：已读人数（含关闭回执者，分母准）
///   - memberCount：群成员总数
/// 昵称回落链：服务端 nickname → [memberNameOf]（本地群成员缓存）→ userId。
class ReadDetailSheet extends StatefulWidget {
  final String convId;
  final String msgId;
  final String myId;
  final String Function(String) memberNameOf;

  const ReadDetailSheet({
    super.key,
    required this.convId,
    required this.msgId,
    required this.myId,
    required this.memberNameOf,
  });

  @override
  State<ReadDetailSheet> createState() => _ReadDetailSheetState();
}

class _ReadDetailSheetState extends State<ReadDetailSheet> {
  bool _loading = true;
  String _err = '';
  Map<String, dynamic>? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await ConversationService().receipts(
        widget.convId,
        widget.msgId,
      );
      if (mounted) setState(() {
        _data = d;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        _err = e.toString();
        _loading = false;
      });
    }
  }

  /// readAt 是服务端下发的 UTC RFC3339（如 2026-09-23T05:31:07.925Z），
  /// 直接显示是 UTC 时刻且格式错；解析后转本地时区「yyyy-MM-dd HH:mm」。
  String _fmtReadAt(String raw) {
    final dt = DateTime.tryParse(raw);
    if (dt == null) return raw;
    final l = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final receipts = ((_data?['receipts'] as List?) ?? [])
        .whereType<Map>()
        .toList();
    final readCount = (_data?['readCount'] as num?)?.toInt() ?? 0;

    return SafeArea(
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.72,
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t('chatActionReadDetail'),
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              t('chatReadCount', {'read': '$readCount'}),
              style: const TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const Divider(height: 18),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(28),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_err.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_err,
                    style: const TextStyle(color: Colors.red)),
              )
            else if (receipts.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(t('chatReadNone'),
                    style: const TextStyle(color: Colors.grey)),
              )
            else
              Expanded(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: receipts.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final r = receipts[i];
                    final uid = r['userId']?.toString() ?? '';
                    final serverName = r['nickname']?.toString() ?? '';
                    final name = serverName.isNotEmpty
                        ? serverName
                        : (widget.memberNameOf(uid).isNotEmpty
                            ? widget.memberNameOf(uid)
                            : uid);
                    final avatar = r['avatar']?.toString() ?? '';
                    final readAt = _fmtReadAt(r['readAt']?.toString() ?? '');
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: AppAvatar(url: avatar, name: name, size: 40),
                      title: Text(name),
                      subtitle: Text(readAt,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey)),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
