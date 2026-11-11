/// 用户信息全局缓存（外购缓存方案 4.3「UserCache」的精简落地版）
///
/// - 我的资料（/user/profile）：首页/通讯录/聊天页/扫码确认/通话服务各自拉一遍，
///   其实都只是为了拿 myId / 头像 —— 进程内缓存后，一次登录会话只拉一次。
/// - 他人资料（/user/:id）：带 24h TTL（资料会改，不能永久缓存）。
/// - 退出登录 / 被踢下线时调 clear()，防止换账号串数据。
class UserCache {
  UserCache._();

  static final Map<String, Map<String, dynamic>> _users = {};
  static final Map<String, DateTime> _at = {};
  static Map<String, dynamic>? _myProfile;
  static const _ttl = Duration(hours: 24);

  static String? get myId => _myProfile?['id']?.toString();
  static String? get myAvatar => _myProfile?['avatar']?.toString();
  static Map<String, dynamic>? get myProfileData => _myProfile;

  /// 我的资料：进程内缓存，命中直接返回；未命中走 fetch 并缓存
  static Future<Map<String, dynamic>> myProfile(
      Future<Map<String, dynamic>> Function() fetch) async {
    final c = _myProfile;
    if (c != null) return c;
    final p = await fetch();
    setMyProfile(p);
    return p;
  }

  /// 拉到我的资料后写入缓存（id 为空不缓存）
  static void setMyProfile(Map<String, dynamic> p) {
    if ((p['id']?.toString() ?? '').isNotEmpty) _myProfile = p;
  }

  /// 他人资料：24h TTL
  static Map<String, dynamic>? get(String userId) {
    final at = _at[userId];
    if (at == null) return null;
    if (DateTime.now().difference(at) > _ttl) {
      _users.remove(userId);
      _at.remove(userId);
      return null;
    }
    return _users[userId];
  }

  static void put(String userId, Map<String, dynamic> u) {
    _users[userId] = u;
    _at[userId] = DateTime.now();
  }

  /// 退出登录 / 被踢下线时调用，防止换账号串数据
  static void clear() {
    _users.clear();
    _at.clear();
    _myProfile = null;
  }
}
