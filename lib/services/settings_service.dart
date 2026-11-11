import 'dart:convert';

import 'package:flutter/material.dart';
import 'storage_compat.dart';

/// 全局设置（本地持久化）：深色模式 + 系统通知开关
class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  final _storage = const CompatStorage();

  /// 深色模式（false=浅色，true=深色）
  bool dark = false;

  /// 系统通知：新消息悬浮窗 + 提示音（false=静默）
  bool notifications = true;

  /// 来消息提示音（SoundService.notifyTones 的 key，默认 'msg_in' =「默认」铃声）。
  /// 用户在「通知和声音 → 提示音」里选择，本地持久化（键 set_notify_tone）。
  String notifyTone = 'msg_in';

  /// 是否已同意《用户服务协议》和《隐私政策》
  /// （App Store 审核合规：登录/注册前必须主动勾选；勾选一次后本地记住，
  /// 不再要求重复勾选。仅存本地标记，不参与服务端鉴权。）
  bool policyAgreed = false;

  /// AI 翻译：自动翻译开关（默认关。开启后外来文本消息自动显示译文）
  bool aiAutoTranslate = false;

  /// AI 翻译目标语种：'' = 跟随我的语言（App 界面语言），否则 zh/zhT/en/ja
  String aiTranslateLang = '';

  /// 编辑资料页性别（'' = 未知 / 'male' / 'female'）。
  /// 后端 User 模型暂无 gender 字段，先只存本机；
  /// TODO 等后端 PUT /user/privacy（gender `*string`）落地后迁移到服务端。
  String profileGender = '';

  // ===== 聊天设置页（chat_settings_page.dart）=====

  /// 消息预览：在通知中显示消息内容（截图：开）
  bool chatMsgPreview = true;

  /// 链接预览：在消息中显示网页预览（截图：开）
  bool chatLinkPreview = true;

  /// 聊天背景索引 0..11（见 chat_settings_page.dart 的 kChatBgPresets，8+ 为纯色预设）。
  /// 默认 0 = 浅色（维持现行界面，用户主动设置后才换——需求是「支持设置」不是「默认换肤」）；
  /// 参考截图里的 3（深色涂鸦）只是截图用户当时的选择，不作默认。
  int chatBackground = 0;

  /// 气泡颜色索引 0..9（见 chat_settings_page.dart 的 kChatBubblePresets，
  /// 5×2 网格逐格 PIL 取色；每组 = 收/发成对颜色）。
  /// 默认 9 = 「默认」白 / #D4D3D8（与参考图预览卡一致，也是网格里选中项）。
  int chatBubbleColor = 9;

  /// 字体大小档位 0..6（截图滑块在第 3 档 ⇒ 2）
  int chatFontLevel = 2;

  /// 自定义聊天背景（「从相册选择」选图的本地路径；'' = 用 [chatBackground] 预设）。
  ///
  /// ⚠️ 存的是 image_picker 给的**缓存目录**路径，系统清缓存后文件会丢 ——
  /// chat_page 读不到文件时自动回退预设渐变（优雅降级，不会白屏）；
  /// 等引入 path_provider 后再复制到文档目录做永久化。
  String chatCustomBgPath = '';

  /// 媒体：自动下载图片 / 视频 / 文件（截图：图片开、视频关、文件关）
  ///
  /// 三项是「数据和存储」页「自动下载媒体」卡片的同一组开关，故放一起；
  /// 键名沿用 `set_auto_dl_*`（不是通知偏好的 `set_notify_prefs`——
  /// 那组会被「重置所有通知设置」整体清掉，自动下载项不该被它连带重置）。
  bool autoDownloadImage = true;
  bool autoDownloadVideo = false;
  bool autoDownloadFile = false;

  // ===== 数据和存储页（data_storage_page.dart）=====

  /// 各网络下的自动下载策略：0 = 不下载，1 = 仅下载图片，2 = 下载所有媒体
  int autoDownloadWifi = 2;
  int autoDownloadMobile = 1;
  int autoDownloadRoaming = 0;

  /// 保存到相册：自动把收到的图片和视频存到相册（截图：关）
  bool saveToAlbum = false;

  /// 网络使用统计（字节；当前无后端统计，保持 0）
  int netSentBytes = 0;
  int netRecvBytes = 0;

  /// 「通知和声音」页的分项开关（key → 值）。
  ///
  /// 为什么用一张 Map 而不是十几个 bool 字段：这些开关只被通知页读写、
  /// 语义上是同一组「通知分类偏好」，一次 JSON 落盘（键 `set_notify_prefs`）
  /// 就能整体读写与重置；键名与默认值由页面定义（见 notification_settings_page.dart）。
  Map<String, bool> notifyPrefs = <String, bool>{};

  /// 读单个通知偏好（缺省时返回 [def]，页面传自己的默认值）
  bool notifyPref(String key, bool def) => notifyPrefs[key] ?? def;

  bool _loaded = false;
  bool get loaded => _loaded;

  Future<void> init() async {
    try {
      dark = (await _storage.read(key: 'set_dark')) == '1';
      notifications = (await _storage.read(key: 'set_notify')) != '0';
      notifyTone = await _storage.read(key: 'set_notify_tone') ?? 'msg_in';
      policyAgreed = (await _storage.read(key: 'set_policy_agreed')) == '1';
      aiAutoTranslate = (await _storage.read(key: 'set_ai_auto')) == '1';
      aiTranslateLang = await _storage.read(key: 'set_ai_lang') ?? '';
      profileGender = await _storage.read(key: 'set_profile_gender') ?? '';
      chatMsgPreview = (await _storage.read(key: 'set_chat_msg_preview')) != '0';
      chatLinkPreview =
          (await _storage.read(key: 'set_chat_link_preview')) != '0';
      chatBackground = _intOf(await _storage.read(key: 'set_chat_bg'), 0);
      // v2 键：第九批把气泡颜色从 2 个色圆扩成 10 组成对预设，索引语义已变，
      // 沿用旧键 `set_chat_bubble` 会把旧值 0/1 误映射到新配色 ⇒ 换新键，
      // 老用户（无 v2 值）落到默认档 9。
      chatBubbleColor = _intOf(await _storage.read(key: 'set_chat_bubble_v2'), 9);
      chatFontLevel = _intOf(await _storage.read(key: 'set_chat_font'), 2);
      chatCustomBgPath =
          await _storage.read(key: 'set_chat_custom_bg') ?? '';
      autoDownloadImage = (await _storage.read(key: 'set_auto_dl_image')) != '0';
      autoDownloadVideo = (await _storage.read(key: 'set_auto_dl_video')) == '1';
      autoDownloadFile = (await _storage.read(key: 'set_auto_dl_file')) == '1';
      autoDownloadWifi = _intOf(await _storage.read(key: 'set_auto_dl_wifi'), 2);
      autoDownloadMobile =
          _intOf(await _storage.read(key: 'set_auto_dl_mobile'), 1);
      autoDownloadRoaming =
          _intOf(await _storage.read(key: 'set_auto_dl_roaming'), 0);
      saveToAlbum = (await _storage.read(key: 'set_save_album')) == '1';
      netSentBytes = _intOf(await _storage.read(key: 'set_net_sent'), 0);
      netRecvBytes = _intOf(await _storage.read(key: 'set_net_recv'), 0);
      final raw = await _storage.read(key: 'set_notify_prefs');
      if (raw != null && raw.isNotEmpty) {
        final m = jsonDecode(raw);
        if (m is Map) {
          notifyPrefs = <String, bool>{
            for (final e in m.entries) e.key.toString(): e.value == true,
          };
        }
      }
    } catch (_) {}
    _loaded = true;
    notifyListeners();
  }

  Future<void> setDark(bool v) async {
    if (dark == v) return;
    dark = v;
    try {
      await _storage.write(key: 'set_dark', value: v ? '1' : '0');
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setNotifications(bool v) async {
    if (notifications == v) return;
    notifications = v;
    try {
      await _storage.write(key: 'set_notify', value: v ? '1' : '0');
    } catch (_) {}
    notifyListeners();
  }

  /// 选择来消息提示音（key 见 SoundService.notifyTones；未知 key 播放时会回退默认铃声）
  Future<void> setNotifyTone(String v) async {
    if (notifyTone == v) return;
    notifyTone = v;
    try {
      await _storage.write(key: 'set_notify_tone', value: v);
    } catch (_) {}
    notifyListeners();
  }

  /// 记录「已同意协议」。写入失败不阻塞流程（下次进来重新勾一次即可）。
  Future<void> setPolicyAgreed(bool v) async {
    if (policyAgreed == v) return;
    policyAgreed = v;
    try {
      await _storage.write(key: 'set_policy_agreed', value: v ? '1' : '0');
    } catch (_) {}
    notifyListeners();
  }

  /// AI 翻译自动开关
  Future<void> setAiAutoTranslate(bool v) async {
    if (aiAutoTranslate == v) return;
    aiAutoTranslate = v;
    try {
      await _storage.write(key: 'set_ai_auto', value: v ? '1' : '0');
    } catch (_) {}
    notifyListeners();
  }

  /// AI 翻译目标语种（'' = 跟随我的语言）
  Future<void> setAiTranslateLang(String v) async {
    if (aiTranslateLang == v) return;
    aiTranslateLang = v;
    try {
      await _storage.write(key: 'set_ai_lang', value: v);
    } catch (_) {}
    notifyListeners();
  }

  /// 编辑资料页性别（'' = 未知 / 'male' / 'female'）
  Future<void> setProfileGender(String v) async {
    if (profileGender == v) return;
    profileGender = v;
    try {
      await _storage.write(key: 'set_profile_gender', value: v);
    } catch (_) {}
    notifyListeners();
  }

  /// 写单个通知偏好（通知和声音页的开关，重启后保持）
  Future<void> setNotifyPref(String key, bool v) async {
    if (notifyPrefs[key] == v) return;
    notifyPrefs = Map<String, bool>.from(notifyPrefs)..[key] = v;
    try {
      await _storage.write(
          key: 'set_notify_prefs', value: jsonEncode(notifyPrefs));
    } catch (_) {}
    notifyListeners();
  }

  /// 清空全部分项通知偏好（「重置所有通知设置」→ 回到各开关的默认值）
  Future<void> resetNotifyPrefs() async {
    if (notifyPrefs.isEmpty) return;
    notifyPrefs = <String, bool>{};
    try {
      await _storage.delete(key: 'set_notify_prefs');
    } catch (_) {}
    notifyListeners();
  }

  // ===== 聊天设置页 / 数据和存储页 =====

  /// 读整数设置（缺省 / 脏数据 → [fallback]）
  int _intOf(String? raw, int fallback) => int.tryParse(raw ?? '') ?? fallback;

  Future<void> _putBool(String key, bool v) async {
    try {
      await _storage.write(key: key, value: v ? '1' : '0');
    } catch (_) {}
  }

  Future<void> _putInt(String key, int v) async {
    try {
      await _storage.write(key: key, value: '$v');
    } catch (_) {}
  }

  Future<void> setChatMsgPreview(bool v) async {
    if (chatMsgPreview == v) return;
    chatMsgPreview = v;
    await _putBool('set_chat_msg_preview', v);
    notifyListeners();
  }

  Future<void> setChatLinkPreview(bool v) async {
    if (chatLinkPreview == v) return;
    chatLinkPreview = v;
    await _putBool('set_chat_link_preview', v);
    notifyListeners();
  }

  /// 选择聊天背景（0..11，8+ 为纯色预设）
  Future<void> setChatBackground(int i) async {
    if (chatBackground == i) return;
    chatBackground = i;
    await _putInt('set_chat_bg', i);
    notifyListeners();
  }

  /// 选择气泡颜色（0..9，见 kChatBubblePresets）
  Future<void> setChatBubbleColor(int i) async {
    if (chatBubbleColor == i) return;
    chatBubbleColor = i;
    await _putInt('set_chat_bubble_v2', i);
    notifyListeners();
  }

  /// 字体大小档位（0..6）
  Future<void> setChatFontLevel(int i) async {
    if (chatFontLevel == i) return;
    chatFontLevel = i;
    await _putInt('set_chat_font', i);
    notifyListeners();
  }

  /// 自定义聊天背景（'' = 恢复用 [chatBackground] 预设）。
  /// 路径变化即通知，聊天页监听 [AppSettings] 后即时生效。
  Future<void> setChatCustomBgPath(String p) async {
    if (chatCustomBgPath == p) return;
    chatCustomBgPath = p;
    try {
      await _storage.write(key: 'set_chat_custom_bg', value: p);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setAutoDownloadImage(bool v) async {
    if (autoDownloadImage == v) return;
    autoDownloadImage = v;
    await _putBool('set_auto_dl_image', v);
    notifyListeners();
  }

  Future<void> setAutoDownloadVideo(bool v) async {
    if (autoDownloadVideo == v) return;
    autoDownloadVideo = v;
    await _putBool('set_auto_dl_video', v);
    notifyListeners();
  }

  /// 「自动下载媒体 → 文件」（截图：关）
  Future<void> setAutoDownloadFile(bool v) async {
    if (autoDownloadFile == v) return;
    autoDownloadFile = v;
    await _putBool('set_auto_dl_file', v);
    notifyListeners();
  }

  /// 设置某网络下的自动下载策略（which: 0=Wi-Fi 1=移动网络 2=漫游）
  Future<void> setAutoDownloadPolicy(int which, int v) async {
    switch (which) {
      case 0:
        if (autoDownloadWifi == v) return;
        autoDownloadWifi = v;
        await _putInt('set_auto_dl_wifi', v);
        break;
      case 1:
        if (autoDownloadMobile == v) return;
        autoDownloadMobile = v;
        await _putInt('set_auto_dl_mobile', v);
        break;
      default:
        if (autoDownloadRoaming == v) return;
        autoDownloadRoaming = v;
        await _putInt('set_auto_dl_roaming', v);
    }
    notifyListeners();
  }

  Future<void> setSaveToAlbum(bool v) async {
    if (saveToAlbum == v) return;
    saveToAlbum = v;
    await _putBool('set_save_album', v);
    notifyListeners();
  }

  /// 「重置网络使用统计」：本地计数清零
  Future<void> resetNetUsage() async {
    netSentBytes = 0;
    netRecvBytes = 0;
    await _putInt('set_net_sent', 0);
    await _putInt('set_net_recv', 0);
    notifyListeners();
  }
}
