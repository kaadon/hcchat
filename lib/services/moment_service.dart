import 'api_client.dart';
import '../l10n/app_locale.dart';

/// 朋友圈 / 钱包接口封装
class MomentService {
  MomentService._();
  static final MomentService instance = MomentService._();
  final _api = ApiClient.instance;

  /// 朋友圈时间线：{total, list:[{id,userId,senderName,senderAvatar,assistant,images,likeCount,liked,hidden,mine,content,createdAt}]}
  Future<Map<String, dynamic>> list({int page = 1, int size = 20}) async {
    final r =
        await _api.get('/api/v1/moments', query: {'page': page, 'size': size});
    return ((r.data['data'] as Map<String, dynamic>?) ?? {});
  }

  /// 查看指定用户的朋友圈（好友资料页入口）：GET /api/v1/moments/:ownerId
  Future<Map<String, dynamic>> listByUser(String ownerId,
      {int page = 1, int size = 20}) async {
    final r = await _api
        .get('/api/v1/moments/$ownerId', query: {'page': page, 'size': size});
    return ((r.data['data'] as Map<String, dynamic>?) ?? {});
  }

  /// 发布朋友圈
  Future<void> publish(String content, List<String> images) async {
    await _api
        .post('/api/v1/moments', data: {'content': content, 'images': images});
  }

  /// 点赞 / 取消（toggle），返回点赞后状态
  Future<bool> like(String postId) async {
    final r = await _api.post('/api/v1/moments/$postId/like');
    return (((r.data['data'] as Map<String, dynamic>?) ?? {})['liked'] == true);
  }

  /// 发表评论：POST /api/v1/moments/:id/comment，body {content}
  /// 成功返回服务端评论数据 {ID, PostID, UserID, Content, CreatedAt}
  Future<Map<String, dynamic>> comment(String postId, String content) async {
    final r = await _api
        .post('/api/v1/moments/$postId/comment', data: {'content': content});
    final body = r.data as Map<String, dynamic>? ?? {};
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw Exception((body['message'] ?? 'comment failed').toString());
    }
    return ((body['data'] as Map<String, dynamic>?) ?? {});
  }

  /// 删除自己的评论：DELETE /api/v1/moments/comment/:cid
  /// （服务端仅允许删除自己的评论，他人评论会返回业务错误）
  Future<void> deleteComment(String commentId) async {
    final r = await _api.delete('/api/v1/moments/comment/$commentId');
    final body = r.data as Map<String, dynamic>? ?? {};
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw Exception((body['message'] ?? 'delete comment failed').toString());
    }
  }

  /// 我的钱包：{balance, records:[{id,type,typeName,amount,balance,title,createdAt}]}
  Future<Map<String, dynamic>> wallet() async {
    final r = await _api.get('/api/v1/wallet/me');
    return ((r.data['data'] as Map<String, dynamic>?) ?? {});
  }

  /// 领取红包（后端结算冻结资金并分配）：返回详情 + myAmount
  /// 业务错误（已领完 / 已过期退回 / 旧数据）必须抛出来，
  /// 否则会拿着空 data 显示「拆到 ¥0」——以前就是这么骗人的。
  Future<Map<String, dynamic>> redPacketClaim(String msgId) async {
    final r = await _api.post('/api/v1/wallet/redpacket/$msgId/claim');
    final body = r.data as Map<String, dynamic>? ?? {};
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw Exception(
          (body['message'] ?? AppLocalizations.instance.t('svcClaimFailed'))
              .toString());
    }
    return ((body['data'] as Map<String, dynamic>?) ?? {});
  }

  /// 红包领取详情：{senderName,note,mode,totalAmount,count,claimedCnt,status,expireAt,list:[...]}
  Future<Map<String, dynamic>> redPacketDetail(String msgId) async {
    final r = await _api.get('/api/v1/wallet/redpacket/$msgId');
    final body = r.data as Map<String, dynamic>? ?? {};
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw Exception(
          (body['message'] ?? AppLocalizations.instance.t('svcQueryFailed'))
              .toString());
    }
    return ((body['data'] as Map<String, dynamic>?) ?? {});
  }

  /// 账单：时间筛选 + 分页 {total, list}
  Future<Map<String, dynamic>> records({
    String? start,
    String? end,
    int page = 1,
    int size = 20,
  }) async {
    final r = await _api.get('/api/v1/wallet/records', query: {
      if (start != null && start.isNotEmpty) 'start': start,
      if (end != null && end.isNotEmpty) 'end': end,
      'page': page,
      'size': size,
    });
    return ((r.data['data'] as Map<String, dynamic>?) ?? {});
  }
}
