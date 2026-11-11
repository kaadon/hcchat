import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/conversation_service.dart';
import '../services/friend_service.dart';
import '../theme/app_theme.dart';
import '../utils/breakpoints.dart';
import '../widgets/app_avatar.dart';

/// 群发助手（微信式，两步）：
/// 1. 选择联系人：好友多选（搜索 / 全选）
/// 2. 编辑内容：一条消息逐个发到每位好友各自的单聊会话
///
/// 每位好友收到的是普通私聊消息（独立会话，无任何群发标记）。
/// 发送走 createDirect + sendRaw(type=1 文本 / type=2 图片)，与转发到好友的链路一致。
/// 内容二选一：选了图片发图片（忽略文字），未选图发文本。
class MassMessagePage extends StatefulWidget {
  const MassMessagePage({super.key});

  @override
  State<MassMessagePage> createState() => _MassMessagePageState();
}

class _MassMessagePageState extends State<MassMessagePage> {
  final _friendSvc = FriendService();
  final _convSvc = ConversationService();
  final _picker = ImagePicker();
  final _searchCtrl = TextEditingController();
  final _contentCtrl = TextEditingController();

  // 内容：图片与文本二选一，选了图片发图片（忽略文字）
  XFile? _image;
  Uint8List? _imageBytes; // 预览用（Image.memory，兼容 web）
  bool _uploading = false; // 点发送后先上传图片，期间禁操作

  int _step = 1; // 1=选择联系人 2=编辑并发送
  List<Map<String, dynamic>> _friends = [];
  final Set<String> _selectedIds = {}; // 选中的好友 id（雪花字符串）
  bool _loading = true;
  bool _loadFailed = false;

  // 发送状态
  bool _sending = false;
  bool _finished = false; // 本轮发送已完成（展示结果）
  int _total = 0;
  int _done = 0;
  int _ok = 0;
  final List<String> _failedNames = [];

  String _t(String key, [Map<String, String>? params]) =>
      AppLocalizations.of(context).t(key, params);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _contentCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final friends = await _friendSvc.list();
      if (!mounted) return;
      setState(() {
        _friends = friends;
        // 清掉已不是好友的选中项
        _selectedIds.removeWhere((id) => !friends.any((f) => _fid(f) == id));
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  /// 好友 id（雪花字符串）
  String _fid(Map<String, dynamic> u) => (u['id'] ?? '').toString();

  /// 好友显示名：备注优先
  String _friendName(Map<String, dynamic> u) {
    final r = u['remark']?.toString() ?? '';
    if (r.isNotEmpty) return r;
    return (u['nickname'] ?? u['account'] ?? '').toString();
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _friends;
    return _friends
        .where((u) =>
            ('${_friendName(u)} ${(u['account'] ?? '')}'.toLowerCase())
                .contains(q))
        .toList();
  }

  void _toggle(Map<String, dynamic> u) {
    if (_sending) return;
    setState(() {
      final id = _fid(u);
      if (!_selectedIds.add(id)) _selectedIds.remove(id);
    });
  }

  void _toggleSelectAll(bool? v) {
    if (_sending) return;
    setState(() {
      if (v == true) {
        for (final f in _filtered) {
          _selectedIds.add(_fid(f));
        }
      } else {
        _selectedIds.clear();
      }
    });
  }

  bool get _allFilteredSelected =>
      _filtered.isNotEmpty &&
      _filtered.every((f) => _selectedIds.contains(_fid(f)));

  void _goCompose() {
    if (_selectedIds.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_t('massNeedSelect'))));
      return;
    }
    setState(() => _step = 2);
  }

  /// 从相册选图（与聊天页发图一致：压缩到 1920 / 质量 85）
  Future<void> _pickImage() async {
    if (_sending || _uploading || _finished) return;
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      setState(() {
        _image = picked;
        _imageBytes = bytes;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_t('massImageFailed'))));
      }
    }
  }

  void _removeImage() {
    if (_sending || _uploading || _finished) return;
    setState(() {
      _image = null;
      _imageBytes = null;
    });
  }

  /// 群发：逐位好友 createDirect + sendRaw(type=1 文本 / type=2 图片)，失败继续下一位，最后汇总
  Future<void> _sendAll() async {
    final content = _contentCtrl.text.trim();
    if (_image == null && content.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_t('massContentRequired'))));
      return;
    }
    // 图片先上传一次（同一 URL 群发给每位好友），失败停留在编辑页
    final hasImage = _image != null;
    String imageUrl = '';
    if (hasImage) {
      setState(() => _uploading = true);
      try {
        final up = await ApiClient.instance.uploadXFile(
            _image!, _image!.name.isEmpty ? 'image.jpg' : _image!.name);
        imageUrl = (up['url'] ?? '').toString();
        if (imageUrl.isEmpty) throw Exception('empty url');
      } catch (_) {
        if (!mounted) return;
        setState(() => _uploading = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_t('massImageFailed'))));
        return;
      }
      if (!mounted) return;
      setState(() => _uploading = false);
    }
    final targets =
        _friends.where((f) => _selectedIds.contains(_fid(f))).toList();
    setState(() {
      _sending = true;
      _finished = false;
      _total = targets.length;
      _done = 0;
      _ok = 0;
      _failedNames.clear();
    });
    for (final f in targets) {
      try {
        final conv = await _convSvc.createDirect(_fid(f));
        final convId = conv['id']?.toString() ?? '';
        if (convId.isEmpty) throw Exception('empty convId');
        // 图片与文字都发：先图后文各一条（与聊天页发图/发文一致）
        if (hasImage) await _convSvc.sendRaw(convId, 2, imageUrl);
        if (content.isNotEmpty) await _convSvc.sendRaw(convId, 1, content);
        _ok++;
      } catch (_) {
        _failedNames.add(_friendName(f));
      }
      if (!mounted) return;
      setState(() => _done++);
    }
    if (!mounted) return;
    setState(() {
      _sending = false;
      _finished = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.cs;
    final wide = Breakpoints.isWide(context);
    // 发送中禁止返回（逐条进行中，中断会造成半发状态）
    return PopScope(
      canPop: !_sending && !_uploading,
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          title: Text(_t(wide
              ? 'massTitle'
              : (_step == 1 ? 'massStepPick' : 'massStepCompose'))),
        ),
        // pad/横屏：左右双栏（左选人 / 右编辑发送）；窄屏：两步式限宽居中
        body: wide
            ? _buildWideBody(scheme)
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    children: [
                      Expanded(
                        child: _step == 1
                            ? _buildPickStep(scheme)
                            : _buildComposeStep(scheme),
                      ),
                      _buildBottomBar(scheme),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  // ---------- 宽屏双栏：左选人（常驻） / 右编辑发送 ----------

  Widget _buildWideBody(ColorScheme scheme) {
    return Row(
      children: [
        // 左栏：选人（固定宽，与主界面会话列表列一致）
        SizedBox(
          width: Breakpoints.listPaneWidth,
          child: Column(
            children: [
              Expanded(child: _buildPickStep(scheme)),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                      _t('massSelected', {'n': '${_selectedIds.length}'}),
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                ),
              ),
            ],
          ),
        ),
        VerticalDivider(width: 1, color: scheme.outlineVariant),
        // 右栏：编辑发送（内容限宽居中）
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: _buildComposeStep(scheme, canEditTargets: false),
            ),
          ),
        ),
      ],
    );
  }

  // ---------- 第一步：选择联系人 ----------

  Widget _buildPickStep(ColorScheme scheme) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (_) => setState(() {}),
            decoration: AppTheme.authInput(
                hint: _t('newConvSearchHint'), icon: Icons.search),
          ),
        ),
        if (_friends.isNotEmpty)
          ListTile(
            leading: Icon(Icons.select_all, color: scheme.onSurfaceVariant),
            title: Text(_t('massSelectAll'),
                style: TextStyle(fontSize: 15, color: scheme.onSurface)),
            subtitle: _selectedIds.isEmpty
                ? null
                : Text(_t('massSelected', {'n': '${_selectedIds.length}'}),
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
            trailing: Checkbox(
              value: _allFilteredSelected,
              onChanged: _toggleSelectAll,
            ),
            onTap: () => _toggleSelectAll(!_allFilteredSelected),
          ),
        Divider(height: 1, color: scheme.outlineVariant),
        Expanded(child: _buildFriendList(scheme)),
      ],
    );
  }

  Widget _buildFriendList(ColorScheme scheme) {
    if (_loading) return const LinearProgressIndicator(minHeight: 2);
    if (_loadFailed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_t('massLoadFailed'),
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            TextButton(onPressed: _load, child: Text(_t('massRetry'))),
          ],
        ),
      );
    }
    final friends = _filtered;
    if (friends.isEmpty) {
      return Center(
        child: Text(_t('massEmptyFriends'),
            style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    return ListView.separated(
      itemCount: friends.length,
      separatorBuilder: (_, __) => Divider(
          height: 1, indent: 68, endIndent: 16, color: scheme.outlineVariant),
      itemBuilder: (_, i) {
        final u = friends[i];
        final name = _friendName(u);
        final avatar = (u['avatar'] ?? '').toString();
        final checked = _selectedIds.contains(_fid(u));
        return ListTile(
          onTap: () => _toggle(u),
          leading: _Avatar(avatar: avatar, name: name),
          title: Text(name,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
          subtitle: (u['account'] ?? '').toString().isEmpty
              ? null
              : Text((u['account'] ?? '').toString(),
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          trailing: Checkbox(
            value: checked,
            onChanged: (_) => _toggle(u),
          ),
        );
      },
    );
  }

  // ---------- 第二步：编辑并发送（微信式） ----------

  Widget _buildComposeStep(ColorScheme scheme, {bool canEditTargets = true}) {
    final targets =
        _friends.where((f) => _selectedIds.contains(_fid(f))).toList();
    final namesText = targets.map(_friendName).join('、');
    final bool busy = _sending || _uploading || _finished;
    return Column(
      children: [
        // 收信人条（窄屏点击回步骤1 改选人；双栏下选人常驻左栏，不可点）
        Material(
          color: scheme.surface,
          child: InkWell(
            onTap: (busy || !canEditTargets)
                ? null
                : () => setState(() => _step = 1),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_t('massSendToN', {'n': '${targets.length}'}),
                            style: TextStyle(
                                fontSize: 12, color: scheme.onSurfaceVariant)),
                        const SizedBox(height: 2),
                        Text(namesText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15)),
                      ],
                    ),
                  ),
                  if (canEditTargets)
                    Icon(Icons.chevron_right,
                        size: 22, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ),
        Divider(height: 1, color: scheme.outlineVariant),
        // 中部留白（聊天背景感）
        const Expanded(child: SizedBox()),
        // 上传中细进度条
        if (_uploading) const LinearProgressIndicator(minHeight: 2),
        // 发送进度 / 结果（输入栏上方）
        if (_sending || _finished)
          Container(
            width: double.infinity,
            color: scheme.surface,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_sending) ...[
                  Text(
                      _t('massSending', {'done': '$_done', 'total': '$_total'}),
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                      value: _total == 0 ? null : _done / _total, minHeight: 3),
                ],
                if (_finished) ...[
                  Text(_t('massResultOk', {'ok': '$_ok'}),
                      style: TextStyle(
                          fontSize: 13,
                          color: AppTheme.primary,
                          fontWeight: FontWeight.w600)),
                  if (_failedNames.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                        _t('massResultFail', {
                          'n': '${_failedNames.length}',
                          'names': _failedNames.take(5).join('、') +
                              (_failedNames.length > 5 ? '…' : '')
                        }),
                        style: TextStyle(fontSize: 13, color: scheme.error)),
                  ],
                ],
              ],
            ),
          ),
        // 已选图片预览条（输入栏上方）
        _buildImagePreview(scheme),
        // 底部聊天式输入栏
        _buildInputBar(scheme),
      ],
    );
  }

  // ---------- 已选图片预览条（输入栏上方，微信式草稿） ----------

  Widget _buildImagePreview(ColorScheme scheme) {
    final enabled = !_sending && !_uploading && !_finished;
    final bytes = _imageBytes;
    if (bytes == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(bytes,
                  width: 84,
                  height: 84,
                  fit: BoxFit.cover,
                  gaplessPlayback: true),
            ),
            if (enabled)
              Positioned(
                right: -6,
                top: -6,
                child: GestureDetector(
                  onTap: _removeImage,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: scheme.onSurfaceVariant,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.close, size: 13, color: scheme.surface),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---------- 底部聊天式输入栏（选图 + 输入 + 发送） ----------

  Widget _buildInputBar(ColorScheme scheme) {
    final enabled = !_sending && !_uploading && !_finished;
    final hasContent = _contentCtrl.text.trim().isNotEmpty || _image != null;
    return Container(
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Row(
            children: [
              IconButton(
                onPressed: enabled ? _pickImage : null,
                tooltip: _t('massAddImage'),
                icon: Icon(Icons.add_photo_alternate_outlined,
                    size: 26, color: scheme.onSurfaceVariant),
              ),
              Expanded(
                child: TextField(
                  controller: _contentCtrl,
                  enabled: enabled,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 2000,
                  style: const TextStyle(fontSize: 15),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: _t('massContentHint'),
                    counterText: '',
                    isDense: true,
                    filled: true,
                    fillColor: scheme.surfaceContainerHighest,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _finished
                  ? FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 38),
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        textStyle: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      child: Text(_t('massDone')),
                    )
                  : FilledButton(
                      onPressed: (enabled && hasContent) ? _sendAll : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 38),
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        textStyle: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      child: Text(_t('massSendBtn')),
                    ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 底部按钮（仅步骤1：下一步；步骤2 发送在聊天式输入栏） ----------

  Widget _buildBottomBar(ColorScheme scheme) {
    if (_step == 2) return const SizedBox.shrink();
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: SizedBox(
        width: double.infinity,
        height: 48,
        child: FilledButton(
          onPressed: _goCompose,
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.primary,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: Text(_t('massNext', {'n': '${_selectedIds.length}'}),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}

/// 圆形头像：占位为「首字母色块」，加载中/失败/无头像均显示它
class _Avatar extends StatelessWidget {
  final String avatar;
  final String name;
  const _Avatar({required this.avatar, required this.name});

  @override
  Widget build(BuildContext context) {
    return AppAvatar(
      url: avatar,
      name: name,
      size: 42,
      background: AppTheme.primary,
    );
  }
}
