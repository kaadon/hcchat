import 'package:dio/dio.dart';

import 'api_client.dart';
import 'conversation_service.dart' show ApiException;
import 'user_cache.dart';

class FriendRequest {
  final String id; // 字符串 ID（H5 精度安全）
  final String fromUser;
  final String message;
  final int status;
  final String fromUserName; // 申请人昵称（后端 incoming 接口已注入）
  final String fromUserAccount; // 申请人账号
  final String fromUserAvatar; // 申请人头像
  final int source; // 申请来源：1=搜索 2=扫码 3=名片（旧数据兜底 1）

  FriendRequest.fromJson(Map<String, dynamic> j)
      : id = j['id']?.toString() ?? '',
        fromUser = j['fromUser']?.toString() ?? '',
        message = j['message']?.toString() ?? '',
        status = (j['status'] as num?)?.toInt() ?? 0,
        fromUserName = j['fromUserName']?.toString() ?? '',
        fromUserAccount = j['fromUserAccount']?.toString() ?? '',
        fromUserAvatar = j['fromUserAvatar']?.toString() ?? '',
        source = (j['source'] as num?)?.toInt() ?? 1;
}

class FriendService {
  final Dio _dio = ApiClient.instance.dio;
  final _api = ApiClient.instance;

  /// 业务 code 校验：服务端失败时返回 code!=0 + data:null（HTTP 仍是 200），
  /// 不检查会把失败静默解析成"空列表"（表现为明明有好友却显示 0）
  void _ensureOk(Map<String, dynamic> body) {
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw Exception(body['message']?.toString() ?? 'request failed ($code)');
    }
  }

  Future<List<Map<String, dynamic>>> list() async {
    final r = await _dio.get('/api/v1/friend/list',
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    final body = r.data as Map<String, dynamic>;
    _ensureOk(body);
    return ((body['data'] as List<dynamic>? ?? []))
        .map((e) => e as Map<String, dynamic>)
        .toList();
  }

  Future<List<Map<String, dynamic>>> search(String kw) async {
    final r = await _dio.get('/api/v1/user/search',
        queryParameters: {'kw': kw},
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return ((r.data as Map<String, dynamic>)['data'] as List<dynamic>? ?? [])
        .map((e) => e as Map<String, dynamic>)
        .toList();
  }

  Future<List<FriendRequest>> incoming() async {
    final r = await _dio.get('/api/v1/friend/request/incoming',
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    final body = r.data as Map<String, dynamic>;
    _ensureOk(body);
    return ((body['data'] as List<dynamic>? ?? []))
        .map((e) => FriendRequest.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 所有 ID 参数为 String（雪花精度安全）
  /// source：1=搜索添加（默认）2=扫码添加 3=名片
  /// 返回 null=申请成功；否则返回服务端错误信息（空串=服务端没给 message，调用方用兜底文案）
  Future<String?> request(String toId, {String message = '', int source = 1}) async {
    final r = await _dio.post('/api/v1/friend/request',
        data: {'toId': toId, 'message': message, 'source': source},
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    final body = r.data as Map<String, dynamic>;
    if (body['code'] == 0) return null;
    final msg = body['message']?.toString() ?? '';
    return msg;
  }

  Future<bool> handle(String reqId, bool agree) async {
    final r = await _dio.post(
        '/api/v1/friend/request/$reqId/handle?agree=${agree ? 1 : 0}',
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return (r.data as Map<String, dynamic>)['code'] == 0;
  }

  Future<bool> delete(String friendId) async {
    final r = await _dio.delete('/api/v1/friend/$friendId',
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return (r.data as Map<String, dynamic>)['code'] == 0;
  }

  Future<bool> setRemark(String friendId, String remark) async {
    final r = await _dio.put('/api/v1/friend/$friendId/remark',
        data: {'remark': remark},
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return (r.data as Map<String, dynamic>)['code'] == 0;
  }

  Future<bool> blacklistAdd(String blockId) async {
    final r = await _dio.post('/api/v1/friend/blacklist',
        data: {'blockId': blockId},
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return (r.data as Map<String, dynamic>)['code'] == 0;
  }

  /// 发送原始类型消息（如名片 type=10，content=JSON 字符串）。
  /// 好友资料页「转发名片」专用；不改动 conversation_service.dart（归 chat 侧维护），
  /// 复用同一 dio + Authorization 封装直接调 /api/v1/message/send。
  Future<bool> sendRaw(String conversationId, int type, String content,
      {String? clientMsgId}) async {
    final r = await _dio.post('/api/v1/message/send',
        data: {
          'conversationId': conversationId,
          'type': type,
          'content': content,
          'clientMsgId': clientMsgId,
        },
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    final body = r.data as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? 0;
    return code == 0;
  }

  Future<Map<String, dynamic>> profile() async {
    final r = await _dio.get('/api/v1/user/profile',
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    final body = r.data as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) throw ApiException(code, body['message']?.toString() ?? '');
    // 防「未登录」闪现：data 为 null 时返回空 Map 而非抛 CastError
    // （旧写法 `['data'] as Map` 在 data:null 时直接崩，me_page 重试耗尽就卡在"未登录"）。
    final d = (body['data'] as Map?)?.cast<String, dynamic>() ?? {};
    return d;
  }

  /// 按 ID 查用户公开资料（GET /user/:id，服务端附带在线状态）。
  /// 扫个人二维码落地页用（判断好友/陌生人）。
  /// 带 24h 进程内缓存：同一用户短时间内重复查看不再重复请求
  /// （在线状态可能略滞后，可下拉刷新强刷——此处调用场景均无强刷入口，可接受）
  Future<Map<String, dynamic>> userDetail(String userId) async {
    final cached = UserCache.get(userId);
    if (cached != null) return cached;
    final r = await _api.get('/api/v1/user/$userId');
    final body = r.data as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) throw ApiException(code, body['message']?.toString() ?? '');
    final d = ((body['data'] as Map?) ?? {}).cast<String, dynamic>();
    if (d.isNotEmpty) UserCache.put(userId, d);
    return d;
  }

  /// 共同群组列表（2026-09-15 第十二批二轮：好友资料页「共同群组」）。
  /// 契约（API.md :837）：`GET /api/v1/user/:id/mutual-groups` → 轻量群卡
  /// `[{id(群会话ID雪花字符串), name, nameEn, avatar, memberCount}]`，
  /// 按成员数降序；仅统计 type=2 且未解散的群。
  Future<List<Map<String, dynamic>>> mutualGroups(String userId) async {
    final r = await _api.get('/api/v1/user/$userId/mutual-groups');
    final body = r.data as Map<String, dynamic>;
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) throw ApiException(code, body['message']?.toString() ?? '');
    return ((body['data'] as List<dynamic>?) ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// 更新资料（昵称/签名/头像）
  /// 签名用可空参数：null=不改；空串=清空签名（服务端 signature 为指针语义）
  Future<bool> updateProfile(
      {String? nickname,
      String? signature,
      String? avatar,
      String? gender}) async {
    final data = <String, dynamic>{};
    if (nickname != null && nickname.isNotEmpty) data['nickname'] = nickname;
    if (signature != null) data['signature'] = signature;
    if (avatar != null && avatar.isNotEmpty) data['avatar'] = avatar;
    // 后端 User 模型暂无 gender 字段，会静默丢弃（无害）；
    // TODO 等后端 PUT /user/privacy（gender `*string`）落地后改走该接口。
    if (gender != null && gender.isNotEmpty) data['gender'] = gender;
    final r = await _dio.put('/api/v1/user/profile',
        data: data,
        options: Options(
            headers: {'Authorization': 'Bearer ${await _api.readToken()}'}));
    return (r.data as Map<String, dynamic>)['code'] == 0;
  }
}
