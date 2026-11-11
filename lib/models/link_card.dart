import 'dart:convert';

/// 链接卡片负载（type=11 消息 content / extra 存储的 JSON）。
///
/// 字段与后端 [GET /api/v1/link/meta] 返回保持一致：
/// - [url] 目标地址
/// - [title] / [description] 展示文案
/// - [icon] 卡片左侧图标（可空，回落默认链接图标）
/// - [inApp] 是否命中白名单、走应用内 WebView
/// - [displayName] 白名单展示名（防钓鱼，不显示裸域名）
/// - [domain] 真实域名（非白名单时页脚展示）
/// - [nativeBridge] 是否需要注入 JS 桥
/// - [matched] 是否匹配白名单
class LinkCardData {
  final String url;
  final String title;
  final String icon;
  final String description;
  final bool inApp;
  final String displayName;
  final String domain;
  final bool nativeBridge;
  final bool matched;
  final String image; // og:image 封面（后端新增字段）

  const LinkCardData({
    required this.url,
    this.title = '',
    this.icon = '',
    this.description = '',
    this.inApp = false,
    this.displayName = '',
    this.domain = '',
    this.nativeBridge = false,
    this.matched = false,
    this.image = '',
  });

  factory LinkCardData.fromJson(Map<String, dynamic> j) {
    return LinkCardData(
      url: (j['url'] ?? '').toString(),
      title: (j['title'] ?? '').toString(),
      icon: (j['icon'] ?? '').toString(),
      description: (j['description'] ?? '').toString(),
      inApp: j['inApp'] == true,
      displayName: (j['displayName'] ?? '').toString(),
      domain: (j['domain'] ?? '').toString(),
      nativeBridge: j['nativeBridge'] == true,
      matched: j['matched'] == true,
      image: (j['image'] ?? '').toString(),
    );
  }

  /// 容错解析：坏 JSON / 缺 url → 返回 null（调用方回落普通文本）。
  static LinkCardData? tryParse(String content) {
    if (content.isEmpty) return null;
    try {
      final j = jsonDecode(content);
      if (j is! Map) return null;
      final m = j.cast<String, dynamic>();
      final url = (m['url'] ?? '').toString();
      if (url.isEmpty) return null;
      return LinkCardData.fromJson(m);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'title': title,
        'icon': icon,
        'description': description,
        'inApp': inApp,
        'displayName': displayName,
        'domain': domain,
        'nativeBridge': nativeBridge,
        'matched': matched,
        'image': image,
      };

  String toJsonString() => jsonEncode(toJson());

  /// 页脚展示文案：白名单内显示 displayName，否则显示真实域名。
  String get footer {
    if (inApp && displayName.isNotEmpty) return displayName;
    return domain.isNotEmpty ? domain : _hostOf(url);
  }

  /// 顶栏/标题兜底名（displayName 为空时用 domain 或 url 主机名）。
  String get displayTitle {
    if (displayName.isNotEmpty) return displayName;
    if (domain.isNotEmpty) return domain;
    return _hostOf(url);
  }

  static String _hostOf(String url) {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }
}
