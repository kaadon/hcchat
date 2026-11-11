import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'storage_compat.dart';

import 'api_client.dart';
import 'user_cache.dart';

/// E2EE 端到端加密服务（2026-09-18 §36 定稿，type=13 仅单聊文本）。
///
/// 架构：X25519 身份密钥（私钥仅本机 secure storage）+ 每条消息随机
/// AES-256-GCM 会话密钥（对方/自己公钥各 ECIES 包裹一份，随消息下发）。
/// 私钥备份：登录密码派生 KEK（PBKDF2-SHA256 + HKDF "e2ee-kek-v1"）加密后
/// 上云 —— 服务端只存密文，无法解密；换设备凭登录密码解锁备份恢复私钥。
///
/// 线格式（与 PC/H5 严格一致）：
/// - 公钥/私钥：base64(32B 裸值)；
/// - 备份 JSON：{v,kdf,it,salt,hkdf,pub,n,ct}，ct = AES-GCM 密文||16B tag
///   （WebCrypto 原生格式，跨端互通）；
/// - 消息 content：{v,kid,n,c,kw:[{u,ep,n,c},...]}；
/// - ECIES 包裹：临时 X25519 密钥对 → shared=ECDH(eph_priv, target_pub) →
///   KEK=HKDF-SHA256(shared, salt=空, info="e2ee-wrap-v1") → AES-GCM 包 32B 会话密钥。
class E2eeService {
  E2eeService._();
  static final instance = E2eeService._();

  static const int _kdfIters = 100000; // PBKDF2 迭代（纯 Dart 实现，取移动端可接受的 10 万）
  static const String _hkdfInfo = 'e2ee-kek-v1';
  static const String _wrapInfo = 'e2ee-wrap-v1';

  final _api = ApiClient.instance;
  static const _storage = CompatStorage();

  final Random _rand = Random.secure();
  final X25519 _x25519 = X25519();
  final AesGcm _aes = AesGcm.with256bits();

  int? _uid;
  String? _privB64; // 本机私钥（base64 32B，仅 secure storage / 内存）
  String? _pubB64;
  String mode = ''; // off / server / e2ee（后台加密方式）
  bool e2eeOn = true; // 用户级开关（服务端值）
  bool hasKeysRemote = false;
  bool hasBackupRemote = false;

  /// 私钥是否已在本机就绪（解密/加密可用）
  final ValueNotifier<bool> ready = ValueNotifier(false);

  /// 解密结果缓存（msgId → 明文），避免列表滚动反复 ECDH
  final Map<String, String> _plainCache = {};
  final Set<String> _inflight = {};

  /// 解密失败 key（ready 状态下仍解不开：密钥轮换/版本不符），
  /// 用于区分「未解锁（可点按解锁）」与「解密失败（解锁也没用）」两种占位。
  final Set<String> _failKeys = {};

  /// 渲染层同步入口：命中缓存直接返回明文；
  /// 未命中触发异步解密（完成后 onDone 回调让页面 setState 重绘），期间返回占位文案。
  /// 非 JSON 加密体（本地乐观明文/老数据）原样返回。
  /// - 未解锁（!ready）或解密中 → [lockedText]（点按可弹解锁）；
  /// - 已就绪但解密失败 → [failedText]（如「密钥解密失败」，解锁无意义）。
  String plainFor(String content, String cacheKey,
      {required String lockedText,
      String? failedText,
      void Function(String?)? onDone}) {
    if (!content.startsWith('{')) return content;
    try {
      final j = jsonDecode(content);
      if (j is! Map || j['kw'] == null) return content;
    } catch (_) {
      return content;
    }
    final hit = _plainCache[cacheKey];
    if (hit != null) return hit;
    if (_failKeys.contains(cacheKey)) return failedText ?? lockedText;
    if (_inflight.contains(cacheKey)) return lockedText;
    _inflight.add(cacheKey);
    decryptText(content, cacheKey: cacheKey).then((v) {
      _inflight.remove(cacheKey);
      // 只在「本机已就绪却仍解不开」时记失败；未就绪保持锁定文案（可解锁）
      if (v == null && ready.value) {
        _failKeys.add(cacheKey);
      } else if (v != null) {
        _failKeys.remove(cacheKey);
      }
      onDone?.call(v);
    });
    return lockedText;
  }

  /// 发送侧「无痕」用：服务端回显替换本地乐观气泡时，把已知明文直接种进
  /// 缓存，回显首帧即是明文，避免闪一下「加密消息 点按解锁」占位。
  void primePlain(String cacheKey, String plain) {
    if (cacheKey.isEmpty || plain.isEmpty) return;
    _plainCache[cacheKey] = plain;
    _failKeys.remove(cacheKey);
  }

  /// 解锁成功后由页面调用：占位态消息重绘时会重新解密
  void invalidateCache() {
    _plainCache.clear();
    _failKeys.clear();
  }

  String _kPriv(int uid) => 'e2ee_priv_$uid';
  String _kPub(int uid) => 'e2ee_pub_$uid';

  bool get isReady => ready.value;

  // ============ 生命周期 ============

  /// 登录/冷启动后调用：按缓存 uid 装载本机私钥（不弹任何 UI）。
  Future<void> ensureLoaded() async {
    // uid 兜底（2026-09-18 修复）：登录页 setupAfterLogin 是 unawaited，
    // 触发时资料往往还没拉过、UserCache.myId 为 null —— 不补拉会导致
    // 建钥后 _persistLocal 静默跳过（无 uid），本机私钥永远落不了地，
    // ready 恒 false → 发送全降级明文（而服务端 hasKeys=true、开关照常显示）。
    if ((UserCache.myId ?? '').isEmpty) {
      try {
        await UserCache.myProfile(() async {
          final r = await _api.get('/api/v1/user/profile');
          final d = (r.data as Map?)?['data'];
          return d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
        });
      } catch (_) {}
    }
    final idStr = UserCache.myId;
    final uid = int.tryParse(idStr ?? '');
    if (uid == null) return;
    if (_uid == uid && ready.value) return;
    if (_uid != uid) {
      _uid = uid;
      _privB64 = null;
      _pubB64 = null;
      ready.value = false;
      _plainCache.clear();
      try {
        _privB64 = await _storage.read(key: _kPriv(uid));
        _pubB64 = await _storage.read(key: _kPub(uid));
      } catch (_) {}
      // 配对校验（2026-09-18）：脏备份恢复流程可能把「公钥当私钥」落过本机，
      // 这种 priv 无法解任何消息却让 ready=true —— 启动时校验一次配对，
      // 不配对视为未就绪（走备份自愈/解锁弹窗恢复）。
      if (_privB64 != null &&
          _privB64!.isNotEmpty &&
          _pubB64 != null &&
          _pubB64!.isNotEmpty) {
        final ok = await _pubMatches(_privB64!, _pubB64!);
        if (!ok) _privB64 = null;
      }
      ready.value = _privB64 != null;
    }
  }

  /// 登出/换号：清内存与 secure storage 里的本机私钥（LocalStore.clearUserData 调用）。
  /// 兼容 ensureLoaded 未跑过的场景：同时按 UserCache.myId 兜底删。
  Future<void> resetLocal() async {
    final uids = <int>{
      if (_uid != null) _uid!,
      int.tryParse(UserCache.myId ?? '') ?? -1,
    }..remove(-1);
    _uid = null;
    _privB64 = null;
    _pubB64 = null;
    ready.value = false;
    _plainCache.clear();
    for (final uid in uids) {
      try {
        await _storage.delete(key: _kPriv(uid));
        await _storage.delete(key: _kPub(uid));
      } catch (_) {}
    }
  }

  // ============ 建钥 / 解锁 / 改密 ============

  Future<Map<String, dynamic>?> _me() async {
    try {
      final r = await _api.get('/api/v1/e2ee/me');
      final d = r.data['data'];
      return d is Map ? Map<String, dynamic>.from(d) : null;
    } catch (_) {
      return null;
    }
  }

  /// 账号安全页/设置页用：本人密钥状态（mode/e2eeOn/hasKeys/hasBackup/publicKey）
  Future<Map<String, dynamic>?> meInfo() => _me();

  /// 登录成功后调用（**仅密码登录/注册路径**，手里还有明文密码）：
  /// 首次建钥（生成 X25519 对 + 密码 KEK 备份上云）或换设备直接解锁备份。
  /// 全程静默失败 —— E2EE 不是登录的必要条件。
  Future<void> setupAfterLogin(String password) async {
    await ensureLoaded();
    final me = await _me();
    if (me == null) return;
    mode = (me['mode'] ?? '').toString();
    e2eeOn = me['e2eeOn'] != false;
    hasKeysRemote = me['hasKeys'] == true;
    hasBackupRemote = me['hasBackup'] == true;
    if (mode != 'e2ee') return; // 后台未开端到端：不做任何事
    try {
      if (hasKeysRemote) {
        if (ready.value) return; // 本机私钥已就绪
        // 换设备/清存储/老版本脏备份：手里有登录密码 → 从备份恢复私钥
        //（含自愈：旧版 wrapPriv 参数写反产生的脏备份，详见 _restorePrivFromBackup）
        final priv = await _restorePrivFromBackup(me, password);
        if (priv == null) return; // 密码不对/备份损坏：留给聊天页解锁弹窗兜底
        _privB64 = priv;
        _pubB64 = (me['publicKey'] ?? '').toString();
        await _persistLocal();
        return;
      }
      // 首次建钥：生成密钥对 → 备份 → 上云
      final kp = await _genKeypair();
      // 2026-09-18 修复：此前写成 wrapPriv(kp.$2, kp.$1, password) —— pub/priv
      // 传反，备份里 ct=公钥、pub 字段=私钥。本机私钥仍正确（加密不受影响），
      // 但从备份恢复出来的「私钥」其实是公钥 → 解密全失败（老用户全锁死根因）。
      final enc = await wrapPriv(kp.$1, kp.$2, password);
      if (enc == null) return;
      final r = await _api.put('/api/v1/e2ee/keys', data: {
        'publicKey': kp.$1,
        'encPriv': enc,
      });
      if ((r.data['code'] ?? -1) != 0) return;
      _privB64 = kp.$2;
      _pubB64 = kp.$1;
      await _persistLocal();
      hasKeysRemote = true;
      hasBackupRemote = true;
    } catch (_) {}
  }

  /// 游客登录后调用（2026-09-18）：游客没有登录密码，备份用一次性随机口令
  /// 包裹。同设备复用游客账号走本机私钥（secure storage）；换设备 = 新游客
  /// 账号（游客绑定 deviceId），不会走到「新设备解锁备份」那条路，所以
  /// 一次性口令不影响任何真实场景。
  Future<void> setupForGuest() async {
    await setupAfterLogin(base64Url.encode(_randBytes(24)));
  }

  // ============ 跨设备恢复（申请从旧设备恢复，2026-09-18）============

  String?
      _recoverEphPriv; // 本次恢复申请的一次性临时私钥（内存态，用完即弃）  /// 新设备：发起恢复申请。生成一次性临时密钥对，把临时公钥连同设备名
  /// 上报服务端；服务端会推给本账号所有在线设备等待批准。
  /// 返回 requestId（失败返回 null）。
  Future<String?> startRecovery(String deviceName) async {
    await ensureLoaded();
    try {
      final kp = await _genKeypair();
      final r = await _api.post('/api/v1/e2ee/recover/request',
          data: {'newPub': kp.$1, 'deviceName': deviceName});
      if ((r.data['code'] ?? -1) != 0) return null;
      final id = ((r.data['data'] as Map?)?['requestId'] ?? '').toString();
      if (id.isEmpty) return null;
      _recoverEphPriv = kp.$2;
      return id;
    } catch (_) {
      return null;
    }
  }

  /// 新设备：轮询恢复结果（2s 一次，[timeout] 内未完成返回 false）。
  /// approved 且解包校验通过 → 私钥落本机、ready=true，返回 true。
  Future<bool> waitRecovery(String requestId,
      {Duration timeout = const Duration(minutes: 10)}) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      await Future<void>.delayed(const Duration(seconds: 2));
      try {
        final r = await _api
            .get('/api/v1/e2ee/recover/status', query: {'id': requestId});
        if ((r.data['code'] ?? -1) != 0) continue;
        final d = r.data['data'];
        if (d is! Map) continue;
        final status = (d['status'] ?? '').toString();
        if (status == 'approved') {
          final eph = _recoverEphPriv;
          _recoverEphPriv = null;
          final payload = d['payload'];
          final me = await _me();
          final serverPub = (me?['publicKey'] ?? '').toString();
          if (payload is Map && eph != null && eph.isNotEmpty) {
            final privB64 = await _unwrapWith(
              base64.decode((payload['c'] ?? '').toString()),
              base64.decode((payload['ep'] ?? '').toString()),
              base64.decode((payload['n'] ?? '').toString()),
              base64.decode(eph),
            );
            // 双重校验：恢复出的私钥必须与服务端公钥配对，杜绝串包/脏数据
            if (privB64 != null && await _pubMatches(privB64, serverPub)) {
              _privB64 = privB64;
              _pubB64 = serverPub;
              await _persistLocal();
              return true;
            }
          }
          return false;
        }
        if (status == 'rejected' || status == 'expired') {
          _recoverEphPriv = null;
          return false;
        }
      } catch (_) {}
    }
    _recoverEphPriv = null;
    return false;
  }

  /// 旧设备：批准/拒绝恢复申请。批准时用自己的身份私钥解出私钥字节、
  /// 用申请方（新设备）的临时公钥 ECIES 包裹回传 —— 私钥明文不经服务端。
  Future<bool> respondRecovery(
      String requestId, String newPub, bool approve) async {
    try {
      Map<String, dynamic>? payload;
      if (approve) {
        final priv = _privB64;
        if (priv == null || priv.isEmpty) return false;
        payload =
            await _wrap(base64.decode(priv), newPub, (_uid ?? 0).toString());
      }
      final r = await _api.put('/api/v1/e2ee/recover/approve', data: {
        'requestId': requestId,
        'approve': approve,
        'payload': payload
      });
      return (r.data['code'] ?? -1) == 0;
    } catch (_) {
      return false;
    }
  }

  /// 用指定私钥（而非本机 _privB64）拆 ECIES 包裹 —— 恢复流程专用：
  /// 新设备拿「一次性临时私钥」拆旧设备回传的私钥密文。
  Future<String?> _unwrapWith(List<int> wrapped, List<int> epPub,
      List<int> nonce, List<int> myPriv) async {
    try {
      final kp = await _x25519.newKeyPairFromSeed(myPriv);
      final shared = await _x25519.sharedSecretKey(
        keyPair: kp,
        remotePublicKey: SimplePublicKey(epPub, type: KeyPairType.x25519),
      );
      final kek = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
          .deriveKey(secretKey: shared, info: utf8.encode(_wrapInfo))
          .then((k) => k.extractBytes());
      if (wrapped.length <= 16) return null;
      final mac = Mac(wrapped.sublist(wrapped.length - 16));
      final plain = await _aes.decrypt(
        SecretBox(wrapped.sublist(0, wrapped.length - 16),
            nonce: nonce, mac: mac),
        secretKey: SecretKey(kek),
      );
      return base64.encode(plain);
    } catch (_) {
      return null;
    }
  }

  /// 从备份恢复私钥（带历史脏备份自愈）。
  ///
  /// 自愈背景：旧版 setupAfterLogin 调 wrapPriv 时 pub/priv 传反，产生的备份
  /// ct 里包的是**公钥**、pub 字段里放的是**私钥**。从这种备份解出的「私钥」
  /// 实为公钥 → 解密永远失败。这里解出后先用「priv 能否推导出服务端公钥」
  /// 校验；不匹配则尝试备份 JSON 的 pub 字段（正是真私钥），校验通过即取用，
  /// 并立即把**正确的**备份重写上云（公钥不变，历史消息继续可解）。
  Future<String?> _restorePrivFromBackup(
      Map<String, dynamic> me, String password) async {
    final enc = (me['encPriv'] ?? '').toString();
    if (enc.isEmpty) return null;
    final serverPub = (me['publicKey'] ?? '').toString();
    var priv = await unwrapPriv(enc, password);
    if (priv == null) return null; // 密码错误/备份损坏
    if (serverPub.isEmpty || await _pubMatches(priv, serverPub)) return priv;
    // 脏备份自愈：ct 解出来是公钥 → 从 pub 字段捞真私钥
    try {
      final bj = jsonDecode(enc);
      final cand = (bj is Map ? bj['pub'] : '')?.toString() ?? '';
      if (cand.isNotEmpty && await _pubMatches(cand, serverPub)) {
        priv = cand;
        final fixed = await wrapPriv(serverPub, priv, password);
        if (fixed != null) {
          try {
            await _api.put('/api/v1/e2ee/backup', data: {'encPriv': fixed});
          } catch (_) {} // 重写失败不影响本次恢复（下次登录再试）
        }
        return priv;
      }
    } catch (_) {}
    return null; // 彻底恢复不了（真·备份损坏）：留解锁弹窗/重新建钥兜底
  }

  /// 私钥与公钥是否配对：由 priv（作 seed）推导公钥与 pub 比对。
  Future<bool> _pubMatches(String privB64, String pubB64) async {
    try {
      final kp = await _x25519.newKeyPairFromSeed(base64.decode(privB64));
      return base64.encode((await kp.extractPublicKey()).bytes) == pubB64;
    } catch (_) {
      return false;
    }
  }

  /// 换设备无密码场景：弹窗拿到密码后解锁备份（聊天页首次遇到加密消息时调用）。
  /// 返回 true = 解锁成功（ready 变 true，消息可解）。
  Future<bool> unlockWithPassword(String password) async {
    await ensureLoaded();
    final me = await _me();
    if (me == null) return false;
    // 顺手刷新后台加密方式缓存（与登录路径 setupAfterLogin 同口径）
    mode = (me['mode'] ?? '').toString();
    e2eeOn = me['e2eeOn'] != false;
    final priv = await _restorePrivFromBackup(me, password);
    if (priv == null) return false;
    _privB64 = priv;
    _pubB64 = (me['publicKey'] ?? '').toString();
    await _persistLocal();
    return true;
  }

  /// 改密码：用旧密码解出私钥 → 新密码重包裹（re-wrap）。
  /// 返回 null = 无备份（无需同步）；抛异常 = 旧密码解不开备份（调用方提示）。
  /// 服务端 ChangePassword 会把该密文与密码 hash 同事务落库（§36）。
  Future<String?> rewrapForPasswordChange(
      {required String oldPassword, required String newPassword}) async {
    final me = await _me();
    if (me == null) return null;
    if (me['hasBackup'] != true) return null;
    final enc = (me['encPriv'] ?? '').toString();
    if (enc.isEmpty) return null;
    final priv = await unwrapPriv(enc, oldPassword);
    if (priv == null) {
      throw Exception('旧密码无法解开端到端加密备份');
    }
    final pub = (me['publicKey'] ?? '').toString();
    final rewrapped = await wrapPriv(pub, priv, newPassword);
    if (rewrapped == null) throw Exception('重新加密端到端备份失败');
    return rewrapped;
  }

  /// 用户级开关（设置页）：返回是否成功。
  Future<bool> setToggle(bool on) async {
    try {
      final r = await _api.put('/api/v1/e2ee/toggle', data: {'on': on});
      if ((r.data['code'] ?? -1) != 0) return false;
      e2eeOn = on;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<(String, String)> _genKeypair() async {
    final kp = await _x25519.newKeyPair();
    final pub = base64.encode((await kp.extractPublicKey()).bytes);
    final priv = base64.encode(await kp.extractPrivateKeyBytes());
    return (pub, priv);
  }

  Future<void> _persistLocal() async {
    // uid 兜底：_uid 未及赋值时按 UserCache 再解析一次（防竞态把私钥丢本机）
    final uid = _uid ?? int.tryParse(UserCache.myId ?? '');
    if (uid != null) _uid = uid;
    if (uid == null) return;
    try {
      await _storage.write(key: _kPriv(uid), value: _privB64 ?? '');
      await _storage.write(key: _kPub(uid), value: _pubB64 ?? '');
    } catch (_) {}
    ready.value = _privB64 != null;
  }

  // ============ 加解密（聊天链路）============

  /// 发送方入口：能加密返回 type=13 content JSON；不能（后台模式非 e2ee /
  /// 未就绪/无对方公钥/开关关）返回 null，调用方降级普通文本 type=1。
  Future<String?> encryptForChat(String text,
      {required String peerUid, required String myUid}) async {
    await ensureLoaded();
    // 后台「加密方式」总开关：非 e2ee 一律明文（2026-09-21 补）。
    // mode 在登录/会话页打开时从 /e2ee/me 刷新，后台切走后最迟下次进会话生效。
    if (mode != 'e2ee') return null;
    if (!ready.value || !e2eeOn || peerUid.isEmpty || myUid.isEmpty) {
      return null;
    }
    try {
      final pk = await _api.get('/api/v1/e2ee/pubkey/$peerUid');
      final d = pk.data['data'];
      if (d is! Map) return null;
      if (d['e2eeOn'] != true) return null;
      final peerPub = (d['publicKey'] ?? '').toString();
      if (peerPub.isEmpty || _pubB64 == null || _pubB64!.isEmpty) return null;
      return encryptText(text,
          peerPubB64: peerPub,
          myPubB64: _pubB64!,
          peerUid: peerUid,
          myUid: myUid);
    } catch (_) {
      return null;
    }
  }

  /// 加密一条文本 → type=13 content JSON（见类注释线格式）。
  Future<String?> encryptText(String text,
      {required String peerPubB64,
      required String myPubB64,
      required String peerUid,
      required String myUid}) async {
    try {
      final sessionKey = _randBytes(32);
      final nonce = _randBytes(12);
      final payload = utf8.encode(jsonEncode({'t': text}));
      final box = await _aes.encrypt(payload,
          secretKey: SecretKey(sessionKey), nonce: nonce);
      final kid = _randBytes(8);
      final kw = <Map<String, dynamic>>[
        await _wrap(sessionKey, peerPubB64, peerUid),
        await _wrap(sessionKey, myPubB64, myUid),
      ];
      return jsonEncode({
        'v': 1,
        'kid': base64.encode(kid),
        'n': base64.encode(nonce),
        'c': base64.encode([...box.cipherText, ...box.mac.bytes]),
        'kw': kw,
      });
    } catch (_) {
      return null;
    }
  }

  /// 解密 type=13 content → 明文；失败返回 null（调用方显示占位/解锁入口）。
  Future<String?> decryptText(String content, {String? cacheKey}) async {
    if (cacheKey != null && _plainCache.containsKey(cacheKey)) {
      return _plainCache[cacheKey];
    }
    await ensureLoaded();
    final priv = _privB64;
    final uid = _uid;
    if (priv == null || uid == null) return null;
    try {
      final j = jsonDecode(content);
      if (j is! Map) return null;
      final kw = j['kw'];
      if (kw is! List || kw.isEmpty) return null;
      Map<String, dynamic>? mine;
      for (final e in kw) {
        if (e is Map && e['u']?.toString() == uid.toString()) {
          mine = Map<String, dynamic>.from(e);
          break;
        }
      }
      if (mine == null) return null;
      // 拆封：ECDH(我的私钥, 临时公钥) → KEK → 会话密钥
      final sessionKey = await _unwrap(
          base64.decode((mine['c'] ?? '').toString()),
          base64.decode((mine['ep'] ?? '').toString()),
          base64.decode((mine['n'] ?? '').toString()));
      if (sessionKey == null) return null;
      final nonce = base64.decode((j['n'] ?? '').toString());
      final ct = base64.decode((j['c'] ?? '').toString());
      if (ct.length <= 16) return null;
      final mac = Mac(ct.sublist(ct.length - 16));
      final plain = await _aes.decrypt(
        SecretBox(ct.sublist(0, ct.length - 16), nonce: nonce, mac: mac),
        secretKey: SecretKey(sessionKey),
      );
      final obj = jsonDecode(utf8.decode(plain));
      final text = obj is Map ? (obj['t'] ?? '').toString() : '';
      if (cacheKey != null) _plainCache[cacheKey] = text;
      return text;
    } catch (_) {
      return null;
    }
  }

  // ============ 密码 KEK（备份包裹）============

  /// 私钥备份：PBKDF2(password, salt) → HKDF → KEK → AES-GCM(priv)
  Future<String?> wrapPriv(
      String pubB64, String privB64, String password) async {
    try {
      final salt = _randBytes(16);
      final kek = await _deriveKekFromPassword(password, salt);
      final nonce = _randBytes(12);
      final box = await _aes.encrypt(base64.decode(privB64),
          secretKey: SecretKey(kek), nonce: nonce);
      return jsonEncode({
        'v': 1,
        'kdf': 'pbkdf2-sha256',
        'it': _kdfIters,
        'salt': base64.encode(salt),
        'hkdf': _hkdfInfo,
        'pub': pubB64,
        'n': base64.encode(nonce),
        'ct': base64.encode([...box.cipherText, ...box.mac.bytes]),
      });
    } catch (_) {
      return null;
    }
  }

  /// 解开私钥备份；密码错误/AES 校验失败返回 null。
  Future<String?> unwrapPriv(String encJson, String password) async {
    try {
      final j = jsonDecode(encJson);
      if (j is! Map) return null;
      final it = (j['it'] as num?)?.toInt() ?? _kdfIters;
      final salt = base64.decode((j['salt'] ?? '').toString());
      final nonce = base64.decode((j['n'] ?? '').toString());
      final ct = base64.decode((j['ct'] ?? '').toString());
      if (ct.length <= 16) return null;
      final kek = await _deriveKekFromPassword(password, salt, iters: it);
      final mac = Mac(ct.sublist(ct.length - 16));
      final plain = await _aes.decrypt(
        SecretBox(ct.sublist(0, ct.length - 16), nonce: nonce, mac: mac),
        secretKey: SecretKey(kek),
      );
      return base64.encode(plain);
    } catch (_) {
      return null;
    }
  }

  Future<List<int>> _deriveKekFromPassword(String password, List<int> salt,
      {int iters = _kdfIters}) async {
    final ikm = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iters,
      bits: 256,
    ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
    return Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(
            secretKey: ikm,
            nonce: utf8.encode('chatpulse-e2ee'),
            info: utf8.encode(_hkdfInfo))
        .then((k) => k.extractBytes());
  }

  // ============ ECIES 包裹 / 拆封 ============

  /// 包一段 32B 会话密钥给目标公钥：{u, ep, n, c}
  Future<Map<String, dynamic>> _wrap(
      List<int> sessionKey, String targetPubB64, String uid) async {
    final eph = await _x25519.newKeyPair();
    final ephPub = base64.encode((await eph.extractPublicKey()).bytes);
    final shared = await _x25519.sharedSecretKey(
      keyPair: eph,
      remotePublicKey: SimplePublicKey(base64.decode(targetPubB64),
          type: KeyPairType.x25519),
    );
    final kek = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(secretKey: shared, info: utf8.encode(_wrapInfo))
        .then((k) => k.extractBytes());
    final nonce = _randBytes(12);
    final box =
        await _aes.encrypt(sessionKey, secretKey: SecretKey(kek), nonce: nonce);
    return {
      'u': uid,
      'ep': ephPub,
      'n': base64.encode(nonce),
      'c': base64.encode([...box.cipherText, ...box.mac.bytes]),
    };
  }

  /// 拆封：kek=HKDF(ECDH(myPriv, ep))，AES-GCM 解出 32B 会话密钥。
  Future<List<int>?> _unwrap(
      List<int> wrapped, List<int> epPub, List<int> nonce) async {
    try {
      if (_privB64 == null) return null;
      final myKp = await _x25519.newKeyPairFromSeed(base64.decode(_privB64!));
      final shared = await _x25519.sharedSecretKey(
        keyPair: myKp,
        remotePublicKey: SimplePublicKey(epPub, type: KeyPairType.x25519),
      );
      final kek = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
          .deriveKey(secretKey: shared, info: utf8.encode(_wrapInfo))
          .then((k) => k.extractBytes());
      if (wrapped.length <= 16) return null;
      final mac = Mac(wrapped.sublist(wrapped.length - 16));
      return await _aes.decrypt(
        SecretBox(wrapped.sublist(0, wrapped.length - 16),
            nonce: nonce, mac: mac),
        secretKey: SecretKey(kek),
      );
    } catch (_) {
      return null;
    }
  }

  List<int> _randBytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => _rand.nextInt(256)));
}
