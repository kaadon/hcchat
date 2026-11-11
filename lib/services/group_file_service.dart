import 'package:dio/dio.dart';

import 'api_client.dart';
import 'conversation_service.dart';
import 'local_store.dart';
import '../models/link_card.dart';

/// 群文件云盘 + 文件预览 + 链接元信息 + 网页白名单 的网络层封装。
///
/// 所有请求统一走 [ApiClient]（自带 401 刷新、瞬时重试、token 注入）。
class GroupFileService {
  GroupFileService._();
  static final GroupFileService instance = GroupFileService._();

  final Dio _dio = ApiClient.instance.dio;
  final _api = ApiClient.instance;

  // ===================== 群文件列表 =====================

  /// [GET /api/v1/conversation/:convId/files]
  /// [category] 过滤：image / doc / video；[keyword] 文件名搜索；[sort] time / size。
  Future<GroupFileList> listFiles(String convId,
      {String? category, String? keyword, String? sort}) async {
    final query = <String, dynamic>{};
    if (category != null && category.isNotEmpty) query['category'] = category;
    if (keyword != null && keyword.isNotEmpty) query['keyword'] = keyword;
    if (sort != null && sort.isNotEmpty) query['sort'] = sort;
    final r = await _dio.get('/api/v1/conversation/$convId/files',
        queryParameters: query,
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    final body = r.data as Map<String, dynamic>;
    _assertCode(body);
    return GroupFileList.fromJson(body['data'] ?? {});
  }

  // ===================== 文件预览 =====================

  /// [GET /api/v1/files/:fileId/preview]
  /// 返回 {status:'ready'|'processing', url}。
  /// 后端 409/422（不支持预览）→ 抛 [ApiException]，前端据此展示「暂不支持预览」。
  Future<Map<String, dynamic>> preview(String fileId) async {
    final r = await _dio.get('/api/v1/files/$fileId/preview',
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    final body = r.data as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code == 409 || code == 422) {
      throw ApiException(code, (body['message'] ?? '暂不支持预览').toString());
    }
    _assertCode(body);
    return (body['data'] as Map<String, dynamic>? ?? {});
  }

  /// [GET /api/v1/files/:fileId/thumb]
  /// 返回视频首帧封面签名直链（大视频由服务端 ffmpeg 抽帧生成，微信式）。
  /// 非视频 / 抽帧失败 / 未生成 → 返回空串（调用方回落深色占位）。
  Future<String> thumbUrl(String fileId) async {
    final r = await _dio.get('/api/v1/files/$fileId/thumb',
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    final body = r.data as Map<String, dynamic>;
    _assertCode(body);
    final data = (body['data'] as Map<String, dynamic>? ?? {});
    return (data['thumbUrl'] ?? '').toString();
  }

  /// [GET /api/v1/files/:fileId/download]
  /// 返回后端签名的免鉴权直链（相对路径，调用方用 _abs 拼 apiBase）。
  /// 与 preview 解耦：即使预览返回 409（不支持预览），下载依然可用。
  Future<String> downloadUrl(String fileId) async {
    final r = await _dio.get('/api/v1/files/$fileId/download',
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    final body = r.data as Map<String, dynamic>;
    _assertCode(body);
    final data = (body['data'] as Map<String, dynamic>? ?? {});
    return (data['url'] ?? '').toString();
  }

  // ===================== 链接元信息 =====================

  /// [GET /api/v1/link/meta?url=]
  /// 命中白名单 → 返回 [LinkCardData]；403 / 429 / 网络错误 → 返回 null（调用方降级普通文本）。
  Future<LinkCardData?> linkMeta(String url) async {
    try {
      final r = await _dio.get('/api/v1/link/meta',
          queryParameters: {'url': url},
          options: Options(
              headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
      final body = r.data as Map<String, dynamic>;
      final code = (body['code'] as num?)?.toInt() ?? 0;
      if (code != 0) return null; // 403/429/其它业务码 → 降级
      final data = (body['data'] as Map<String, dynamic>? ?? {});
      if (data.isEmpty) return null;
      return LinkCardData.fromJson(data);
    } on DioException catch (e) {
      final status = e.response?.statusCode ?? 0;
      if (status == 403 || status == 429) return null;
      return null; // 网络/瞬时错误一律降级为普通文本
    } catch (_) {
      return null;
    }
  }

  // ===================== 网页白名单（后台） =====================

  Future<List<WhitelistItem>> listWhitelist({String? domain}) async {
    final query = <String, dynamic>{};
    if (domain != null && domain.isNotEmpty) query['domain'] = domain;
    final r = await _dio.get('/api/v1/admin/web-whitelist',
        queryParameters: query,
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    final body = r.data as Map<String, dynamic>;
    _assertCode(body);
    return ((body['data'] as List<dynamic>? ?? [])
            .whereType<Map>())
        .map((e) => WhitelistItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<void> createWhitelist(WhitelistItem item) async {
    final r = await _dio.post('/api/v1/admin/web-whitelist',
        data: item.toJson(),
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    _assertCode(r.data as Map<String, dynamic>);
  }

  Future<void> updateWhitelist(WhitelistItem item) async {
    final r = await _dio.put('/api/v1/admin/web-whitelist/${item.id}',
        data: item.toJson(),
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    _assertCode(r.data as Map<String, dynamic>);
  }

  Future<void> deleteWhitelist(String id) async {
    final r = await _dio.delete('/api/v1/admin/web-whitelist/$id',
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    _assertCode(r.data as Map<String, dynamic>);
  }

  void _assertCode(Map<String, dynamic> body) {
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw ApiException(code, (body['message'] ?? '请求失败').toString());
    }
  }
}

/// 群文件列表项。
class GroupFileItem {
  final String fileId;
  final String name;
  final int size; // 字节
  final String uploaderName;
  final String uploadedAt; // ISO 时间
  final String category; // image | doc | video | other
  final String? thumbnailUrl;
  final String url;

  const GroupFileItem({
    required this.fileId,
    required this.name,
    this.size = 0,
    this.uploaderName = '',
    this.uploadedAt = '',
    this.category = 'other',
    this.thumbnailUrl,
    this.url = '',
  });

  factory GroupFileItem.fromJson(Map<String, dynamic> j) {
    return GroupFileItem(
      fileId: (j['fileId'] ?? j['id'] ?? '').toString(),
      name: (j['name'] ?? j['fileName'] ?? '').toString(),
      size: _int(j['size']),
      uploaderName: (j['uploaderName'] ?? j['uploader'] ?? '').toString(),
      uploadedAt: (j['uploadedAt'] ?? j['createdAt'] ?? '').toString(),
      category: (j['category'] ?? _guessCategory(j['name'])).toString(),
      thumbnailUrl: (j['thumbnailUrl'] ?? j['thumb'] ?? '').toString(),
      url: (j['url'] ?? '').toString(),
    );
  }

  static String _guessCategory(dynamic name) {
    final n = (name ?? '').toString().toLowerCase();
    if (n.endsWith('.png') ||
        n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.gif') ||
        n.endsWith('.webp') ||
        n.endsWith('.bmp')) {
      return 'image';
    }
    if (n.endsWith('.mp4') ||
        n.endsWith('.mov') ||
        n.endsWith('.avi') ||
        n.endsWith('.mkv') ||
        n.endsWith('.webm')) {
      return 'video';
    }
    return 'doc';
  }

  static int _int(dynamic v) => v is num ? v.toInt() : 0;
}

/// 群文件列表（含用量配额）。
class GroupFileList {
  final int usedBytes;
  final int totalBytes; // -1 = 不限
  final List<GroupFileItem> files;

  const GroupFileList({
    this.usedBytes = 0,
    this.totalBytes = -1,
    this.files = const [],
  });

  bool get unlimited => totalBytes < 0;

  factory GroupFileList.fromJson(dynamic data) {
    if (data is List) {
      return GroupFileList(
        files: data
            .whereType<Map>()
            .map((e) => GroupFileItem.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
    }
    final m = (data as Map<String, dynamic>? ?? {});
    final files = ((m['files'] as List<dynamic>? ??
                m['list'] as List<dynamic>? ??
                const <dynamic>[])
            .whereType<Map>())
        .map((e) => GroupFileItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();

    // 配额：优先 data.quota.{totalBytes,usedBytes}，其次顶层字段，兼容 quota_bytes==-1（不限）
    int total = -1;
    int used = 0;
    final quota = m['quota'] as Map<String, dynamic>?;
    if (quota != null) {
      total = _int(quota['totalBytes'] ?? quota['quota_bytes']);
      used = _int(quota['usedBytes'] ?? quota['used_bytes']);
    }
    if (m['quota_bytes'] == -1) {
      total = -1;
    } else if (m['totalBytes'] != null ||
        m['quota_bytes'] != null ||
        m['total'] != null) {
      total = _int(m['totalBytes'] ?? m['quota_bytes'] ?? m['total']);
    }
    if (m['usedBytes'] != null || m['used_bytes'] != null || m['used'] != null) {
      used = _int(m['usedBytes'] ?? m['used_bytes'] ?? m['used']);
    }
    return GroupFileList(usedBytes: used, totalBytes: total, files: files);
  }

  static int _int(dynamic v) => v is num ? v.toInt() : 0;
}

/// 网页白名单条目。
class WhitelistItem {
  final String id;
  final String domain;
  final String displayName;
  final bool enabled;
  final bool nativeBridge;

  const WhitelistItem({
    this.id = '',
    required this.domain,
    this.displayName = '',
    this.enabled = true,
    this.nativeBridge = false,
  });

  factory WhitelistItem.fromJson(Map<String, dynamic> j) {
    return WhitelistItem(
      id: (j['id'] ?? '').toString(),
      domain: (j['domain'] ?? '').toString(),
      displayName: (j['displayName'] ?? '').toString(),
      enabled: j['enabled'] != false,
      nativeBridge: j['nativeBridge'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'domain': domain,
        'displayName': displayName,
        'enabled': enabled,
        'nativeBridge': nativeBridge,
      };

  WhitelistItem copyWith({
    String? id,
    String? domain,
    String? displayName,
    bool? enabled,
    bool? nativeBridge,
  }) =>
      WhitelistItem(
        id: id ?? this.id,
        domain: domain ?? this.domain,
        displayName: displayName ?? this.displayName,
        enabled: enabled ?? this.enabled,
        nativeBridge: nativeBridge ?? this.nativeBridge,
      );
}
