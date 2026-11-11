import 'api_client.dart';

/// AI 翻译服务（后端 POST /api/v1/translate，DeepSeek/OpenAI 兼容）
///
/// 注意（铁律）：后端业务错误是 HTTP 200 + code != 0，必须检查 body['code']，
/// 只看 statusCode 会把失败当成功。
class TranslateService {
  final _api = ApiClient.instance;

  /// 翻译文本。
  /// [targetLang]: zh / zhT / en / ja（空 = 服务端回落 zh）
  /// [auto]: true 走自动翻译额度，false 走手动翻译额度（服务端分别计数）
  /// 命中服务端缓存时不消耗额度。失败抛 Exception(message)。
  Future<String> translate(String text, String targetLang,
      {bool auto = false}) async {
    final r = await _api.post('/api/v1/translate', data: {
      'text': text,
      'targetLang': targetLang,
      'auto': auto,
    });
    final body = r.data;
    if (body is Map && body['code'] == 0) {
      final data = body['data'];
      if (data is Map && data['text'] != null) {
        return data['text'].toString();
      }
      throw Exception('翻译结果为空');
    }
    throw Exception(
        (body is Map && body['message'] != null ? body['message'] : '翻译失败')
            .toString());
  }

  /// 当日用量与限额（设置页展示）。
  /// 返回字段：autoUsed / autoLimit(0=关闭) / manualUsed / manualLimit(0=不限) / configured
  Future<Map<String, dynamic>> usage() async {
    final r = await _api.get('/api/v1/translate/usage');
    final body = r.data;
    if (body is Map && body['code'] == 0 && body['data'] is Map) {
      return Map<String, dynamic>.from(body['data'] as Map);
    }
    throw Exception('获取用量失败');
  }
}
