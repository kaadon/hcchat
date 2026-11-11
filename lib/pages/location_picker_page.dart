import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../theme/app_theme.dart';
import 'location_picker_map_io.dart'
    if (dart.library.html) 'location_picker_map_web.dart';

/// 地图引擎配置（/auth/config 下发，选点页与位置气泡共用，进程内缓存）。
/// 2026-09-22 需求1：后台可选谷歌 / 高德双引擎（sys_config map_engine）。
/// 各 key 为空的行为：
///   - 谷歌引擎：googleMapsApiKey 空 → 选点页提示不可用、气泡回落纯文字卡；
///   - 高德引擎：amapJsKey 空 → 同上；amapWebKey 空 → 仅气泡缩略图回落。
class MapConfig {
  final String engine; // 后台原样下发：'amap' = 高德，其余（含空）= 谷歌
  final String googleKey;
  final String amapJsKey; // 「Web端(JS API)」类型
  final String amapJscode; // 配套安全密钥 securityJsCode（2021-12 后申请必填）
  final String amapWebKey; // 「Web服务」类型，气泡静态图

  const MapConfig({
    this.engine = '',
    this.googleKey = '',
    this.amapJsKey = '',
    this.amapJscode = '',
    this.amapWebKey = '',
  });

  bool get isAmap => engine == 'amap';

  /// 选点页 WebView 用的 JS key（按引擎取对应配置）
  String get jsKey => isAmap ? amapJsKey : googleKey;

  /// 位置气泡静态图用的 key（按引擎取对应配置）
  String get staticKey => isAmap ? amapWebKey : googleKey;

  static MapConfig? _cached;
  static Future<MapConfig> get() async {
    if (_cached != null) return _cached!;
    try {
      final r = await ApiClient.instance.get('/api/v1/auth/config');
      final d = (r.data as Map?)?['data'];
      final m = d is Map ? d : const {};
      _cached = MapConfig(
        engine: (m['mapEngine'] ?? '').toString(),
        googleKey: (m['googleMapsApiKey'] ?? '').toString(),
        amapJsKey: (m['amapJsKey'] ?? '').toString(),
        amapJscode: (m['amapJscode'] ?? '').toString(),
        amapWebKey: (m['amapWebKey'] ?? '').toString(),
      );
    } catch (_) {
      _cached = const MapConfig();
    }
    return _cached!;
  }
}

/// 位置消息选点页（2026-09-21 需求1，「收藏」入口替换为「位置」）。
///
/// 方案：在线地图 JS API（而非原生地图 SDK）；App=WebView，H5=iframe：
///   - 引擎由后台 sys_config map_engine 选择（2026-09-22 需求1）：谷歌 / 高德；
///   - key 等配置经 /auth/config **运行时热下发**——原生 SDK 要求 key 烧死在
///     Manifest/Info.plist 里，换 key 要重打包；
///   - webview_flutter 依赖本就存在（发现页网页小程序），零新增原生依赖。
///
/// 交互（微信式，两引擎一致）：地图上固定一枚中心大头针，拖动地图选点；
/// 停稳后反解地名；点「发送」回传 {lat,lng,name,address}。
/// 定位：高德用 AMap.Geolocation 插件、谷歌用 HTML5 geolocation（Android 端
/// 同时申请运行时定位权限并放行 WebView 授权弹窗）；拿不到定位则停在默认
/// 中心让用户手动拖动，不阻断选点。
/// 坐标系备注：高德全境 GCJ-02；谷歌境外 WGS-84、境内同样偏移为 GCJ-02，
/// 消息 content 原样存所选引擎坐标，跳转地图 App 时同系不偏移。
class LocationPickerPage extends StatefulWidget {
  const LocationPickerPage({super.key});

  @override
  State<LocationPickerPage> createState() => _LocationPickerPageState();
}

class _LocationPickerPageState extends State<LocationPickerPage> {
  String? _mapHtml;
  MapConfig _cfg = const MapConfig();
  bool _loadFailed = false;
  // 地图 Key 校验失败（谷歌 gm_authFailure / 高德 alert 劫持上报）：
  // key 无效 / Key 类型不对 /（谷歌）未启用 API、未绑结算 /（高德）缺 jscode
  bool _authFailed = false;
  // 定位失败标记（拿不到定位时提示用户手动选点，而非静默停在默认中心）
  bool _geoFailed = false;
  // 高德具体错误码（USERKEY_PLAT_NOMATCH / INVALID_USER_SCODE 等），提示条
  // 显示原文便于对照后台配置排查（2026-09-22：2.0 鉴权错多数不弹 alert，
  // 靠 Geocoder 错误回调 + 瓦片超时兜底抓取）
  String _authMsg = '';
  // JS 侧反解后持续回传的最新选点（bridge 是单向的，本地缓存最新值）
  Map<String, dynamic> _picked = {};
  bool _sending = false;
  final _mapCtrl = LocationMapController();
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  List<Map<String, dynamic>> _hits = [];
  bool _searching = false;
  String _searchErr = '';


  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    // 1) 拿地图引擎配置（/auth/config 下发，MapConfig 进程内缓存）
    _cfg = await MapConfig.get();
    if (!mounted) return;
    if (_cfg.jsKey.isEmpty) {
      setState(() => _loadFailed = true);
      return;
    }
    // 2) 定位权限：App WebView 里定位会二次弹授权；H5 由浏览器自己弹
    if (!kIsWeb) {
      try {
        await Permission.locationWhenInUse.request();
      } catch (_) {}
      if (!mounted) return;
    }
    // 3) 组 HTML（按引擎）；地图宿主：App=WebView / H5=iframe
    final lang = Localizations.localeOf(context).languageCode;
    final html = _cfg.isAmap
        ? _buildAmapHtml(_cfg.amapJsKey, _cfg.amapJscode)
        : _buildGoogleHtml(_cfg.googleKey, lang);
    setState(() => _mapHtml = html);
  }

  void _onBridgeMessage(String message) {
    try {
      final j = jsonDecode(message);
      if (j is! Map) return;
      if (j['authFailed'] == true) {
        debugPrint('[loc] gm_authFailure');
        if (mounted) setState(() => _authFailed = true);
        return;
      }
      if (j['amapAlert'] != null) {
        final msg = j['amapAlert'].toString();
        debugPrint('[loc] amap alert: $msg');
        // PROBE 是诊断探测，不把黄条当成鉴权失败（成功也会回传）
        if (msg.startsWith('PROBE ')) return;
        if (mounted) {
          setState(() {
            _authFailed = true;
            _authMsg = msg;
          });
        }
        return;
      }
      if (j['geoFailed'] != null) {
        debugPrint('[loc] geolocation failed code=${j['geoFailed']}');
        if (mounted) setState(() => _geoFailed = true);
        return;
      }
      if (mounted) setState(() => _picked = Map<String, dynamic>.from(j));
    } catch (_) {}
  }

  /// 谷歌引擎 HTML：Maps JS API + Geocoder 反解 + HTML5 geolocation
  static String _buildGoogleHtml(String key, String lang) {
    // HTML 模板里不能出现 '</script>' 之外的 Dart 插值坑：key 直接拼 URL。
    return '''<!DOCTYPE html>
<html><head>
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<style>
  html,body,#map{height:100%;margin:0;padding:0}
  #pin{position:absolute;left:50%;top:50%;transform:translate(-50%,-100%);z-index:9;
       pointer-events:none;filter:drop-shadow(0 2px 3px rgba(0,0,0,.4))}
  #pin svg{width:34px;height:44px}
</style>
<script>
// H5 iframe：无 WebView JavaScriptChannel 时，经 parent.postMessage 回传；
// App WebView 已注入 LocationBridge，本 polyfill 不会覆盖。
(function(){
  if (window.LocationBridge) return;
  window.LocationBridge = {
    postMessage: function(msg){
      try {
        parent.postMessage(JSON.stringify({source:'LocationBridge', payload: String(msg)}), '*');
      } catch(e){}
    }
  };
})();
</script>
<script src="https://maps.googleapis.com/maps/api/js?key=$key&language=$lang"></script>
</head><body>
<div id="map"></div>
<div id="pin"><svg viewBox="0 0 24 24" fill="#EA4335"><path d="M12 0C7 0 3.4 3.8 3.4 8.6 3.4 15 12 24 12 24s8.6-9 8.6-15.4C20.6 3.8 17 0 12 0zm0 12.2a3.6 3.6 0 1 1 0-7.2 3.6 3.6 0 0 1 0 7.2z"/></svg></div>
<script>
// Key 校验失败回调：key 无效/未启用 API/未绑结算/应用限制不匹配时触发
window.gm_authFailure = function(){
  LocationBridge.postMessage(JSON.stringify({authFailed:true}));
};
var map, geocoder, timer=null, lastJson='';
function init(){
  map = new google.maps.Map(document.getElementById('map'), {
    center:{lat:31.2304,lng:121.4737}, zoom:15, disableDefaultUI:true,
    zoomControl:true, clickableIcons:false
  });
  geocoder = new google.maps.Geocoder();
  // 中心点变化：防抖 400ms，停稳后反解地名并回传
  map.addListener('center_changed', function(){
    if (timer) clearTimeout(timer);
    timer = setTimeout(reverse, 400);
  });
  // 尝试 HTML5 定位（WebView 已放行授权；失败不阻断，留世界视图手动拖）
  try {
    navigator.geolocation.getCurrentPosition(function(p){
      map.setCenter({lat:p.coords.latitude, lng:p.coords.longitude});
    }, function(err){
      // 失败上报诊断（权限被拒 code=1 / 不可用 code=2 / 超时 code=3）
      LocationBridge.postMessage(JSON.stringify({geoFailed: (err && err.code) || -1}));
    }, {enableHighAccuracy:true, timeout:8000, maximumAge:30000});
  } catch(e){}
  reverse();
}
function reverse(){
  var c = map.getCenter();
  var loc = {lat:c.lat(), lng:c.lng()};
  var done = function(name, addr){
    var j = JSON.stringify({lat:loc.lat, lng:loc.lng, name:name, address:addr});
    if (j === lastJson) return; // 没变化不重复回传
    lastJson = j;
    LocationBridge.postMessage(j);
  };
  geocoder.geocode({location:loc, language:'$lang'}, function(res, st){
    if (st === 'OK' && res && res.length){
      var a = res[0].formatted_address || '';
      var n = '';
      var comps = res[0].address_components || [];
      // 短地名优先取 POI/地标级，否则第一个成分
      for (var i=0;i<comps.length;i++){
        var types = comps[i].types || [];
        if (types.indexOf('point_of_interest')>=0 || types.indexOf('establishment')>=0 ||
            types.indexOf('premise')>=0 || types.indexOf('sublocality')>=0){
          n = comps[i].short_name || ''; break;
        }
      }
      if (!n && comps.length) n = comps[0].short_name || '';
      done(n, a);
    } else { done('', ''); }
  });
}
function moveToLocation(lng, lat){
  if (!map) return;
  try {
    map.setZoom(16);
    map.setCenter({lat: Number(lat), lng: Number(lng)});
  } catch(e){}
}
window.moveToLocation = moveToLocation;
window.addEventListener('message', function(ev){
  try {
    var d = typeof ev.data === 'string' ? JSON.parse(ev.data) : ev.data;
    if (d && d.cmd === 'moveTo' && d.lng != null && d.lat != null) {
      moveToLocation(d.lng, d.lat);
    }
  } catch(e){}
});
window.addEventListener('load', init);
</script>
</body></html>''';
  }

  /// 高德引擎 HTML：AMap JS API 2.0 + Geocoder 反解 + AMap.Geolocation 定位。
  /// 要点：
  ///   - `_AMapSecurityConfig` 必须在 JS API 脚本之前注入（安全密钥校验时机）；
  ///   - 高德 2.0 多数鉴权错误（USERKEY_PLAT_NOMATCH / INVALID_USER_SCODE）
  ///     **不弹 alert、只打 console**，所以除劫持 alert 外还有三路兜底上报：
  ///     window.onerror / 瓦片 complete 超时 / Geocoder 错误回调带错误码；
  ///   - 坐标经纬序为 [lng, lat]（与谷歌 {lat,lng} 相反，勿混）；
  ///   - moveend = 地图停稳，直接反解中心点（无需再防抖）。
  static String _buildAmapHtml(String key, String jscode) {
    final sc = jsonEncode(jscode); // 注入 JS 字符串做转义
    return '''<!DOCTYPE html>
<html><head>
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<style>
  html,body,#map{height:100%;margin:0;padding:0}
  #pin{position:absolute;left:50%;top:50%;transform:translate(-50%,-100%);z-index:9;
       pointer-events:none;filter:drop-shadow(0 2px 3px rgba(0,0,0,.4))}
  #pin svg{width:34px;height:44px}
</style>
<script>
// H5 iframe：无 WebView JavaScriptChannel 时，经 parent.postMessage 回传；
// App WebView 已注入 LocationBridge，本 polyfill 不会覆盖。
(function(){
  if (window.LocationBridge) return;
  window.LocationBridge = {
    postMessage: function(msg){
      try {
        parent.postMessage(JSON.stringify({source:'LocationBridge', payload: String(msg)}), '*');
      } catch(e){}
    }
  };
})();
</script>
<script>
window._AMapSecurityConfig = { securityJsCode: $sc };
window.alert = function(msg){
  try { LocationBridge.postMessage(JSON.stringify({amapAlert: String(msg)})); } catch(e){}
};
// 2.0 鉴权/运行时错误不弹 alert 时经此兜底上报具体错误文本
window.onerror = function(msg){
  try { LocationBridge.postMessage(JSON.stringify({amapAlert: 'JS: ' + String(msg)})); } catch(e){}
};
</script>
<script src="https://webapi.amap.com/maps?v=2.0&key=$key&plugin=AMap.Geocoder,AMap.Geolocation"></script>
</head><body>
<div id="map"></div>
<div id="pin"><svg viewBox="0 0 24 24" fill="#EA4335"><path d="M12 0C7 0 3.4 3.8 3.4 8.6 3.4 15 12 24 12 24s8.6-9 8.6-15.4C20.6 3.8 17 0 12 0zm0 12.2a3.6 3.6 0 1 1 0-7.2 3.6 3.6 0 0 1 0 7.2z"/></svg></div>
<script>
var map, geocoder, lastJson='', mapReady=false;
function init(){
  if (typeof AMap === 'undefined') {
    LocationBridge.postMessage(JSON.stringify({amapAlert: 'AMAP_JS_NOT_LOADED'}));
    return;
  }
  map = new AMap.Map('map', { zoom:15, center:[121.4737,31.2304], viewMode:'2D' });
  // complete = 底图瓦片加载成功（隐含 JS Key+安全密钥校验通过）
  map.on('complete', function(){ mapReady = true; });
  // 15 秒瓦片仍未加载 = 大概率 Key 类型不对（USERKEY_PLAT_NOMATCH 不弹
  // alert 也不报给 Geocoder 之外的通道），超时上报显性化
  setTimeout(function(){
    if (!mapReady) {
      LocationBridge.postMessage(JSON.stringify({amapAlert: 'AMAP_TILES_NOT_LOADED'}));
    }
  }, 15000);
  // 直接探测 REST 接口：Geocoder 回调拿不到具体原因时（result 为空），
  // 从 restapi 原始返回里看高德原话（2.0 插件服务就是走这个域）
  setTimeout(function(){
    try {
      var jc = (window._AMapSecurityConfig && window._AMapSecurityConfig.securityJsCode) || '';
      fetch('https://restapi.amap.com/v3/geocode/regeo?key=$key&location=121.4737,31.2304&jscode=' + encodeURIComponent(jc))
        .then(function(r){
          return r.text().then(function(t){
            LocationBridge.postMessage(JSON.stringify({amapAlert: 'PROBE http=' + r.status + ' ' + t.slice(0, 160)}));
          });
        })
        .catch(function(e){
          LocationBridge.postMessage(JSON.stringify({amapAlert: 'PROBE net-fail: ' + e}));
        });
    } catch(e){}
  }, 2500);
  geocoder = new AMap.Geocoder({});
  // 中心点停稳：反解地名并回传
  map.on('moveend', reverse);
  // 定位到当前位置（高德 Geolocation 走系统定位，失败不阻断）
  try {
    var geo = new AMap.Geolocation({ enableHighAccuracy:true, timeout:10000, convert:true, needAddress:false });
    geo.getCurrentPosition(function(status, result){
      if (status === 'complete' && result && result.position) {
        // result.position 已按 convert:true 转为 GCJ-02（与高德底图同系），直接居中
        map.setCenter([result.position.lng, result.position.lat]);
        // 精度兜底：IP 定位（无卫星/基站定位）误差大，提示用户手动校正
        var lt = result.location_type || '';
        if (lt === 'ip') {
          LocationBridge.postMessage(JSON.stringify({geoFailed: 'ip-fallback'}));
        }
      } else {
        LocationBridge.postMessage(JSON.stringify({geoFailed: (result && result.info) || 'error'}));
      }
    });
  } catch(e){
    LocationBridge.postMessage(JSON.stringify({geoFailed: 'exception'}));
  }
  reverse();
}
function reverse(){
  var c = map.getCenter();
  var loc = {lat:c.getLat(), lng:c.getLng()};
  var done = function(name, addr){
    var j = JSON.stringify({lat:loc.lat, lng:loc.lng, name:name, address:addr});
    if (j === lastJson) return; // 没变化不重复回传
    lastJson = j;
    LocationBridge.postMessage(j);
  };
  geocoder.getAddress([loc.lng, loc.lat], function(status, result){
    if (status === 'complete' && result && result.regeocode) {
      var rg = result.regeocode;
      var addr = rg.formattedAddress || '';
      // 短地名优先取附近 POI/AOI，否则回落地名地址本身
      var name = '';
      if (rg.pois && rg.pois.length && rg.pois[0].name) name = rg.pois[0].name;
      else if (rg.aois && rg.aois.length && rg.aois[0].name) name = rg.aois[0].name;
      done(name, addr);
    } else {
      // status='error' 时把 result 全量上报：有的失败场景 result 为空
      // （连 info 都没有），只报兜底码定位不了原因；全量 JSON 里若有
      // info/infocode 可直接对照后台配置。'no_data' 是正常无结果，不上报
      if (status === 'error') {
        var detail = '';
        try { detail = JSON.stringify(result) || ''; } catch(e){}
        LocationBridge.postMessage(JSON.stringify({amapAlert: detail ? detail : 'RE_GEO_EMPTY'}));
      }
      done('', '');
    }
  });
}

function moveToLocation(lng, lat){
  if (!map) return;
  try {
    map.setZoom(16);
    map.setCenter([Number(lng), Number(lat)]);
  } catch(e){}
}
window.moveToLocation = moveToLocation;
window.addEventListener('message', function(ev){
  try {
    var d = typeof ev.data === 'string' ? JSON.parse(ev.data) : ev.data;
    if (d && d.cmd === 'moveTo' && d.lng != null && d.lat != null) {
      moveToLocation(d.lng, d.lat);
    }
  } catch(e){}
});
window.addEventListener('load', init);

</script>
</body></html>''';
  }


  Future<void> _runSearch(String raw) async {
    final kw = raw.trim();
    if (kw.isEmpty) {
      setState(() {
        _hits = [];
        _searchErr = '';
      });
      return;
    }
    setState(() {
      _searching = true;
      _searchErr = '';
    });
    try {
      final list = _cfg.isAmap
          ? await _searchAmap(kw)
          : await _searchGoogle(kw);
      if (!mounted) return;
      setState(() {
        _hits = list;
        _searching = false;
        if (list.isEmpty) _searchErr = 'none';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _hits = [];
        _searching = false;
        _searchErr = e.toString();
      });
    }
  }

  Future<List<Map<String, dynamic>>> _searchAmap(String kw) async {
    final key = _cfg.amapWebKey;
    if (key.isEmpty) return [];
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
    ));
    final r = await dio.get(
      'https://restapi.amap.com/v3/place/text',
      queryParameters: {
        'key': key,
        'keywords': kw,
        'offset': 15,
        'page': 1,
        'extensions': 'base',
      },
    );
    final data = r.data;
    if (data is! Map) return [];
    if ('${data['status']}' != '1') {
      throw Exception('${data['info'] ?? 'search failed'}');
    }
    final pois = data['pois'];
    if (pois is! List) return [];
    final out = <Map<String, dynamic>>[];
    for (final p in pois) {
      if (p is! Map) continue;
      final loc = (p['location'] ?? '').toString(); // "lng,lat"
      final parts = loc.split(',');
      if (parts.length != 2) continue;
      final lng = double.tryParse(parts[0].trim());
      final lat = double.tryParse(parts[1].trim());
      if (lat == null || lng == null) continue;
      final name = (p['name'] ?? '').toString();
      final addr = (p['address'] ?? p['pname'] ?? '').toString();
      final district = (p['adname'] ?? '').toString();
      final fullAddr = [
        if (addr.isNotEmpty) addr,
        if (district.isNotEmpty && !addr.contains(district)) district,
      ].join(' ');
      out.add({
        'lat': lat,
        'lng': lng,
        'name': name,
        'address': fullAddr.isNotEmpty ? fullAddr : addr,
      });
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _searchGoogle(String kw) async {
    final key = _cfg.googleKey;
    if (key.isEmpty) return [];
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
    ));
    final r = await dio.get(
      'https://maps.googleapis.com/maps/api/geocode/json',
      queryParameters: {'address': kw, 'key': key, 'language': 'zh-CN'},
    );
    final data = r.data;
    if (data is! Map) return [];
    if ((data['status'] ?? '') != 'OK') {
      final st = data['status']?.toString() ?? 'ERR';
      if (st == 'ZERO_RESULTS') return [];
      throw Exception(st);
    }
    final results = data['results'];
    if (results is! List) return [];
    final out = <Map<String, dynamic>>[];
    for (final p in results.take(15)) {
      if (p is! Map) continue;
      final geo = p['geometry'];
      if (geo is! Map) continue;
      final loc = geo['location'];
      if (loc is! Map) continue;
      final lat = (loc['lat'] as num?)?.toDouble();
      final lng = (loc['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      out.add({
        'lat': lat,
        'lng': lng,
        'name': (p['formatted_address'] ?? kw).toString(),
        'address': (p['formatted_address'] ?? '').toString(),
      });
    }
    return out;
  }

  void _pickHit(Map<String, dynamic> hit) {
    final lat = (hit['lat'] as num).toDouble();
    final lng = (hit['lng'] as num).toDouble();
    setState(() {
      _picked = Map<String, dynamic>.from(hit);
      _hits = [];
      _searchCtrl.text = (hit['name'] ?? '').toString();
      _searchFocus.unfocus();
    });
    _mapCtrl.moveTo(lat, lng);
  }

  Future<void> _send() async {
    if (_picked.isEmpty || _sending) return;
    _sending = true;
    final pid = _picked['lat']?.toString() ?? '';
    if (pid.isEmpty) {
      _sending = false;
      return;
    }
    Navigator.of(context).pop(_picked);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      appBar: AppBar(
        title: Text(t('chatLocationTitle')),
        actions: [
          TextButton(
            onPressed: _picked.isEmpty ? null : _send,
            child: Text(t('chatLocationSend'),
                style: TextStyle(
                    color: _picked.isEmpty
                        ? context.cs.onSurfaceVariant
                        : AppTheme.primary)),
          ),
        ],
      ),
      // Column 而非 Stack：H5 的 HtmlElementView 是合成层「洞」，叠在上面的
      // Flutter 控件会被盖住；提示条/选点条放上下方才能看见。
      body: Column(
        children: [
          if (_authFailed)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(10),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 8,
                      offset: Offset(0, 2))
                ],
              ),
              child: Text(
                  _cfg.isAmap
                      ? (_authMsg.isNotEmpty
                          ? '${t('chatLocationAmapAuthFailed')}\n${t('chatLocationAmapErrCode')} $_authMsg'
                          : t('chatLocationAmapAuthFailed'))
                      : t('chatLocationAuthFailed'),
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF8A5A00), height: 1.4)),
            ),
          if (_geoFailed)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
              decoration: BoxDecoration(
                color: const Color(0xFFE3F2FD),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(t('chatLocationGeoFailed'),
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF0D47A1), height: 1.4)),
            ),

          // 搜索框（放地图上方：H5 HtmlElementView 不能被 Flutter 控件叠盖）
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Material(
              elevation: 1,
              borderRadius: BorderRadius.circular(10),
              color: context.cs.surface,
              child: TextField(
                controller: _searchCtrl,
                focusNode: _searchFocus,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: t('chatLocationSearchHint'),
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _searchCtrl.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() {
                              _hits = [];
                              _searchErr = '';
                            });
                          },
                        ),
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: _runSearch,
              ),
            ),
          ),
          if (_searching)
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (_hits.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: Material(
                color: context.cs.surface,
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _hits.length,
                  separatorBuilder: (_, __) =>
                      Divider(height: 1, color: context.cs.outlineVariant),
                  itemBuilder: (_, i) {
                    final h = _hits[i];
                    final name = (h['name'] ?? '').toString();
                    final addr = (h['address'] ?? '').toString();
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.place_outlined, size: 20),
                      title: Text(name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: addr.isEmpty
                          ? null
                          : Text(addr,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => _pickHit(h),
                    );
                  },
                ),
              ),
            )
          else if (_searchErr == 'none')
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(t('chatLocationSearchEmpty'),
                    style: TextStyle(
                        fontSize: 12, color: context.cs.onSurfaceVariant)),
              ),
            ),
          Expanded(
            child: _mapHtml != null
                ? LocationMapHost(
                    html: _mapHtml!,
                    baseUrl: _cfg.isAmap
                        ? 'https://www.hchat.top'
                        : 'https://maps.googleapis.com',
                    controller: _mapCtrl,
                    onBridgeMessage: _onBridgeMessage,
                    onLoadError: () {
                      if (mounted) setState(() => _loadFailed = true);
                    },
                  )
                : !_loadFailed
                    ? const Center(child: CircularProgressIndicator())
                    : Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(t('chatLocationUnavailable'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: context.cs.onSurfaceVariant)),
                        ),
                      ),
          ),
          if (_picked.isNotEmpty) _pickedBar(t),
        ],
      ),
    );
  }

  Widget _pickedBar(String Function(String) t) {
    final name = (_picked['name'] ?? '').toString();
    final addr = (_picked['address'] ?? '').toString();
    final title = name.isNotEmpty
        ? name
        : (addr.isNotEmpty ? addr : t('chatLocationUntitled'));
    return Container(
      color: context.cs.surface,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          if (addr.isNotEmpty && addr != title)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(addr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12, color: context.cs.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }
}
