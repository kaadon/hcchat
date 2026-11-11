import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/conversation_service.dart';
import '../services/friend_service.dart';
import '../services/sound_service.dart';
import '../widgets/app_dialogs.dart';
import 'chat_page.dart';
import 'group_join_confirm_page.dart';
import 'qr_confirm_page.dart';
import 'user_qr_profile_page.dart';
import 'scan_camera_io.dart' if (dart.library.html) 'scan_camera_web.dart';

/// 移动端扫一扫（需求1）：扫 PC 端二维码 → 解析 ticket → 确认登录
/// - native：mobile_scanner 摄像头实时扫码
/// - H5：摄像头受限，弹输入框手动粘贴 ticket（兜底）
class ScanQrLoginPage extends StatefulWidget {
  const ScanQrLoginPage({super.key});

  @override
  State<ScanQrLoginPage> createState() => _ScanQrLoginPageState();
}

class _ScanQrLoginPageState extends State<ScanQrLoginPage> {
  final _api = ApiClient.instance;
  bool _processing = false;

  @override
  void dispose() {
    super.dispose();
  }

  /// 解析二维码内容（chatpulse://qr?ticket=xxx&secret=xxx）→ 提取 ticket
  String _extractTicket(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return raw.trim();
    return uri.queryParameters['ticket'] ?? raw.trim();
  }

  /// 识别群二维码深链（chatpulse://group?id=<会话ID>）→ 返回会话 ID，非群码返回 null
  String? _parseGroupConvId(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return null;
    if (uri.scheme == 'chatpulse' && uri.host == 'group') {
      final id = uri.queryParameters['id'] ?? '';
      return id.isEmpty ? null : id;
    }
    return null;
  }

  /// 识别个人二维码深链（chatpulse://user?uid=<用户ID>）→ 返回用户 ID，非个人码返回 null
  String? _parseUserUid(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return null;
    if (uri.scheme == 'chatpulse' && uri.host == 'user') {
      final uid = uri.queryParameters['uid'] ?? '';
      return uid.isEmpty ? null : uid;
    }
    return null;
  }

  /// 扫个人二维码：好友直接进好友资料页，非好友显示「添加到通讯录」（微信逻辑）
  Future<void> _openUserProfile(String uid) async {
    if (!mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => UserQrProfilePage(uid: uid)));
  }

  /// 扫群二维码进群：先拉群信息预览 → 二次确认页（微信式）→ 确认后加入
  Future<void> _joinGroup(String convId) async {
    final t = AppLocalizations.of(context).t;
    setState(() => _processing = true);
    try {
      final svc = ConversationService();
      // 第一步：群信息预览（群名/头像/成员数），不加入
      final preview = await svc.groupPreview(convId);
      if (!mounted) return;
      setState(() => _processing = false);
      // 第二步：二次确认页，点「加入群聊」才真正加入
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => GroupJoinConfirmPage(
              data: preview,
              onConfirm: () async {
                try {
                  // 2026-09-28 需求2：扫码进群 → 系统消息「通过二维码扫码入群」
                  final conv = await svc.joinGroup(convId, via: 'qrcode');
                  String myId = '';
                  try {
                    final p = await FriendService().profile();
                    myId = p['id']?.toString() ?? '';
                  } catch (_) {}
                  if (!mounted) return;
                  final name = conv['nameZh']?.toString() ??
                      conv['nameEn']?.toString() ??
                      '';
                  final item = ConvItem.fromJson(
                      {'conversation': conv, 'conversationName': name});
                  await Navigator.of(context).pushReplacement(MaterialPageRoute(
                      builder: (_) => ChatPage(conv: item, myId: myId)));
                } catch (e) {
                  if (mounted) {
                    // 超时/连接类错误给可读提示，不 dump 原始 DioException
                    final errText =
                        e is DioException && ApiClient.isTransient(e)
                            ? t('bootLoadFailed')
                            : e.toString().replaceFirst('Exception: ', '');
                    AppDialogs.toast(
                        context, t('groupQrJoinFailed', {'error': errText}));
                  }
                  rethrow;
                }
              })));
    } catch (e) {
      if (mounted) {
        setState(() => _processing = false);
        // 预览失败：超时/连接类错误给可读提示
        final errText = e is DioException && ApiClient.isTransient(e)
            ? t('bootLoadFailed')
            : e.toString().replaceFirst('Exception: ', '');
        AppDialogs.toast(context, t('groupQrJoinFailed', {'error': errText}));
      }
    }
  }

  /// 扫码成功：先上报"已扫描"（PC 端显示"已扫码，请在手机上确认"），
  /// 再进入二次确认页（微信式），用户点确认才真正 confirm 登录。
  Future<void> _onScanned(String raw) async {
    if (_processing) return;
    SoundService.instance.playScan(); // 扫码成功提示音
    // 群二维码优先路由：chatpulse://group?id=xxx → 进群
    final groupConvId = _parseGroupConvId(raw);
    if (groupConvId != null) {
      await _joinGroup(groupConvId);
      return;
    }
    // 个人二维码：chatpulse://user?uid=xxx → 好友资料/添加好友
    final userUid = _parseUserUid(raw);
    if (userUid != null) {
      await _openUserProfile(userUid);
      return;
    }
    final ticket = _extractTicket(raw);
    if (ticket.isEmpty) return;
    setState(() => _processing = true);
    try {
      final r =
          await _api.post('/api/v1/auth/qr/scanned', data: {'ticket': ticket});
      final code = (r.data as Map<String, dynamic>)['code'];
      if (!mounted) return;
      if (code != 0) {
        final t = AppLocalizations.of(context).t;
        setState(() => _processing = false);
        AppDialogs.toast(context, t('scanQrLoginFailed'));
        return;
      }
      if (mounted) setState(() => _processing = false);
      if (!mounted) return;
      await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => QrConfirmPage(ticket: ticket)));
    } catch (e) {
      if (mounted) {
        final t = AppLocalizations.of(context).t;
        setState(() => _processing = false);
        AppDialogs.toast(
            context,
            t('scanQrLoginError',
                {'error': e.toString().replaceFirst('Exception: ', '')}));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(t('scanQrLoginTitle'),
            style: const TextStyle(color: Colors.white)),
      ),
      // native：mobile_scanner 摄像头；H5：getUserMedia + jsQR 解码
      // （scan_camera_web.dart，失败态内置重试与手动输入，与扫码同路由）。
      // 群码/个人码/PC 登录 ticket 三种内容的路由全部在 _onScanned 统一处理。
      body: ScanCamera(onScan: _onScanned),
    );
  }
}
