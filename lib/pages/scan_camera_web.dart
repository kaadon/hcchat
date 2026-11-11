import 'dart:async' as async;
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';

/// jsQR 全局函数绑定（web/index.html vendor 的 jsQR 1.4.0，UMD 挂 window）。
@JS('jsQR')
external JSObject? _jsQr(
    JSUint8ClampedArray data, JSNumber width, JSNumber height, JSObject opts);

/// H5 摄像头扫码（与 native 的 mobile_scanner 版同接口：onScan 回调原始字符串）。
///
/// 实现：getUserMedia 后置摄像头 → `<video>` 经 HtmlElementView.fromTagName
/// 预览（onElementCreated 回调里挂流，不需要 platformViewRegistry）→
/// 每 250ms 抽帧画到离屏 canvas → window.jsQR（web/index.html 本地 vendor
/// 的 jsQR 1.4.0）解码 → 命中回调 onScan 并停流。
///
/// 识别内容路由（群码/个人码/PC 登录 ticket）由 ScanQrLoginPage._onScanned
/// 统一处理，本组件只负责「把摄像头像素变成字符串」。
///
/// 失败态（拒绝授权 / 非安全上下文 http / 不支持 getUserMedia）不白屏：
/// 给出原因 + 重试按钮 + 「手动输入二维码内容」入口（走同一个 onScan，
/// 粘贴的内容与扫码同路由）。浏览器摄像头仅在 https 或 localhost 暴露，
/// http IP 直连部署时必然走到失败态。
class ScanCamera extends StatefulWidget {
  final ValueChanged<String> onScan;
  const ScanCamera({super.key, required this.onScan});

  @override
  State<ScanCamera> createState() => _ScanCameraState();
}

class _ScanCameraState extends State<ScanCamera> {
  async.Timer? _scanTimer;
  html.MediaStream? _stream;
  html.VideoElement? _video;
  html.CanvasElement? _canvas;
  String? _lastHit; // 去重：同一码 1.5s 内只报一次
  DateTime _lastHitAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _error = ''; // '', 'denied', 'insecure', 'unsupported', 'failed'
  bool _starting = false;
  bool _disposed = false;
  bool _manual = false; // 失败态的手动输入面板
  html.DivElement? _overlay; // DOM 取景框（Flutter 组件画在平台视图之下，必须走 DOM）
  String _hint = ''; // 取景框下方提示文案（build 时从 l10n 取）

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _disposed = true;
    _removeOverlay();
    _stop();
    super.dispose();
  }

  Future<void> _start() async {
    if (_starting || _disposed) return;
    _starting = true;
    if (mounted) setState(() => _error = '');
    try {
      final md = html.window.navigator.mediaDevices;
      if (md == null) {
        _fail('unsupported');
        return;
      }
      final stream = await md.getUserMedia({
        'video': {'facingMode': 'environment'},
        'audio': false,
      }).timeout(const Duration(seconds: 8));
      if (_disposed) {
        stream.getTracks().forEach((t) => t.stop());
        return;
      }
      _stream = stream;
      if (mounted) setState(() {}); // 触发 build 挂 HtmlElementView
    } catch (e) {
      if (_disposed) return;
      final msg = e.toString().toLowerCase();
      if (msg.contains('notallowed') ||
          msg.contains('permissiondenied') ||
          msg.contains('permission')) {
        _fail('denied');
      } else if (msg.contains('secure') || msg.contains('https')) {
        _fail('insecure');
      } else {
        _fail('failed');
      }
    } finally {
      _starting = false;
    }
  }

  /// HtmlElementView.fromTagName 创建 `<video>` 元素后的挂流回调。
  /// platform view 复用时可能重复调用，幂等处理。
  void _onVideoCreated(Object element) {
    if (_disposed) return;
    final video = element as html.VideoElement;
    if (identical(_video, video)) return;
    video
      ..autoplay = true
      ..muted = true
      ..setAttribute('playsinline', 'true')
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'cover'
      ..srcObject = _stream;
    _video = video;
    _canvas = html.CanvasElement(width: 480, height: 640);
    video.play().catchError((_) {});
    _ensureOverlay(); // 取景框做进 DOM：Flutter 层画的东西会被平台视图盖住
    // 250ms/帧：jsQR 单帧 480 宽解码 ~10-30ms，足够实时
    _scanTimer?.cancel();
    _scanTimer = async.Timer.periodic(
        const Duration(milliseconds: 250), (_) => _decodeFrame());
  }

  // ---- DOM 取景框（2026-09-21 需求）----
  //
  // 为什么不用 Flutter CustomPaint：Flutter Web 的 HtmlElementView 是合成层的
  // 「洞」，Dart 侧画的 Widget/Canvas 都在该 DOM 元素之下 → 此前的四角框
  // 实际渲染时被 video 完全盖住（用户看到的就是「没有框」）。
  // 改为向 document.body 插一个 fixed 定位的覆盖 div：暗色遮罩（box-shadow 大半径）
  // + 四角白框 + 框下提示文案，pointer-events:none 不挡手势。
  static const _kOverlayId = 'qr_scan_reticle_overlay';

  void _ensureOverlay() {
    if (_disposed || _overlay != null) return;
    // 平台视图复用/页面回退时可能残留旧节点，先清再建
    html.document.getElementById(_kOverlayId)?.remove();
    final root = html.DivElement()..id = _kOverlayId;
    final s = root.style;
    s.position = 'fixed';
    s.left = '50%';
    s.top = '50%';
    s.transform = 'translate(-50%, -50%)';
    s.setProperty('width', 'min(74vw, 74vh)');
    s.setProperty('aspect-ratio', '1 / 1');
    s.borderRadius = '18px';
    // 外圈暗色遮罩：大半径 box-shadow 铺满屏幕，只留取景框内透亮
    s.boxShadow = '0 0 0 9999px rgba(0, 0, 0, 0.45)';
    s.pointerEvents = 'none';
    s.zIndex = '2147483000';
    // 四角白框：四个子 div 各画两条边
    const len = 34.0, w = 4.0;
    final specs = [
      ['top', 'left', 'Top', 'Left'],
      ['top', 'right', 'Top', 'Right'],
      ['bottom', 'left', 'Bottom', 'Left'],
      ['bottom', 'right', 'Bottom', 'Right'],
    ];
    for (final spec in specs) {
      final c = html.DivElement();
      c.style.position = 'absolute';
      c.style.setProperty('width', '${len}px');
      c.style.setProperty('height', '${len}px');
      // 垂直边 / 水平边 / 圆角跟随方位（spec[2]=垂直方位大写，spec[3]=水平方位大写）
      c.style.setProperty('border-${spec[0]}', '${w}px solid #FFFFFF');
      c.style.setProperty('border-${spec[1]}', '${w}px solid #FFFFFF');
      c.style.setProperty('border${spec[2]}${spec[3]}Radius', '18px');
      c.style.setProperty(spec[0], '-3px');
      c.style.setProperty(spec[1], '-3px');
      root.append(c);
    }
    // 框下提示文案（文案由 build 时按当前语言刷新，见 _syncHint）
    final hint = html.DivElement();
    hint.style.position = 'absolute';
    hint.style.top = '100%';
    hint.style.left = '0';
    hint.style.setProperty('width', '100%');
    hint.style.marginTop = '18px';
    hint.style.textAlign = 'center';
    hint.style.color = 'rgba(255,255,255,0.72)';
    hint.style.fontSize = '13px';
    hint.text = _hint;
    hint.className = 'qr-scan-reticle-hint';
    root.append(hint);
    html.document.body?.append(root);
    _overlay = root;
  }

  /// 语言切换/首帧后同步提示文案
  void _syncHint() {
    final hint = html.document
        .querySelector('#$_kOverlayId .qr-scan-reticle-hint');
    if (hint != null && _hint.isNotEmpty) hint.text = _hint;
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
    html.document.getElementById(_kOverlayId)?.remove();
  }

  void _fail(String code) {
    if (_disposed || !mounted) return;
    setState(() {
      _error = code;
      _manual = false;
    });
  }

  /// 抽当前帧 → jsQR 解码
  void _decodeFrame() {
    final video = _video;
    final canvas = _canvas;
    if (_disposed || video == null || canvas == null) return;
    if (video.readyState < 2 || video.videoWidth == 0) return;
    try {
      final vw = video.videoWidth, vh = video.videoHeight;
      // 等比缩到 480 宽（解码面积小、识别距离足够）
      final scale = 480 / vw;
      final w = 480, h = (vh * scale).round();
      if (canvas.width != w || canvas.height != h) {
        canvas.width = w;
        canvas.height = h;
      }
      final ctx = canvas.context2D;
      ctx.drawImageScaled(video, 0, 0, w, h);
      final data = ctx.getImageData(0, 0, w, h);
      // jsQR(data, width, height, options) → {data: 文本} | null
      final result = _jsQr(data.data.toJS, w.toJS, h.toJS,
          {'inversionAttempts': 'dontInvert'}.jsify() as JSObject);
      if (result == null || result.isUndefinedOrNull) return;
      final text = (result['data'] as JSString?)?.toDart;
      if (text == null || text.isEmpty) return;
      final now = DateTime.now();
      if (text == _lastHit &&
          now.difference(_lastHitAt).inMilliseconds < 1500) {
        return; // 同一码去重
      }
      _lastHit = text;
      _lastHitAt = now;
      _stop();
      widget.onScan(text);
    } catch (_) {
      // 单帧解码异常静默忽略（下一帧重试）
    }
  }

  void _stop() {
    _scanTimer?.cancel();
    _scanTimer = null;
    _removeOverlay(); // 命中码停流时同步撤掉取景框
    try {
      _video?.pause();
      _video?.srcObject = null;
    } catch (_) {}
    try {
      _stream?.getTracks().forEach((t) => t.stop());
    } catch (_) {}
    _stream = null;
    _video = null;
    _canvas = null;
  }

  String _errText(String Function(String key) t) {
    switch (_error) {
      case 'denied':
        return t('scanWebDenied');
      case 'insecure':
        return t('scanWebInsecure');
      case 'unsupported':
        return t('scanWebUnsupported');
      default:
        return t('scanWebFailed');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    _hint = t('scanWebHint'); // 供 DOM 取景框下方文案使用（语言切换跟随）
    if (_video != null) _syncHint();
    return Container(
      color: Colors.black,
      width: double.infinity,
      height: double.infinity,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 摄像头预览（video 元素在 onElementCreated 里挂流）
          if (_stream != null)
            Positioned.fill(
              child: HtmlElementView.fromTagName(
                tagName: 'video',
                onElementCreated: _onVideoCreated,
              ),
            ),
          // 取景框 + 暗色遮罩 + 提示文案在 DOM 层（_ensureOverlay），
          // Flutter 层画不上来（平台视图合成特性），故此处不再放 Widget 版
          // 失败态 / 手动输入
          if (_error.isNotEmpty || _manual) _buildFallback(t),
        ],
      ),
    );
  }

  Widget _buildFallback(String Function(String key) t) {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.82),
        padding: const EdgeInsets.symmetric(horizontal: 28),
        alignment: Alignment.center,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.photo_camera_back,
                  size: 56, color: Colors.white54),
              const SizedBox(height: 14),
              if (_error.isNotEmpty)
                Text(_errText(t),
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _starting
                          ? null
                          : () {
                              setState(() {
                                _error = '';
                                _manual = false;
                              });
                              _start();
                            },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white38),
                      ),
                      child: Text(t('scanWebRetry')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => setState(() => _manual = !_manual),
                      child: Text(t('scanWebManualBtn')),
                    ),
                  ),
                ],
              ),
              if (_manual) ...[
                const SizedBox(height: 16),
                _ManualInput(
                  onSubmit: (raw) {
                    if (raw.trim().isEmpty) return;
                    setState(() => _manual = false);
                    widget.onScan(raw.trim());
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 手动输入二维码内容（粘贴 ticket / 深链）——与扫码同路由
class _ManualInput extends StatefulWidget {
  final ValueChanged<String> onSubmit;
  const _ManualInput({required this.onSubmit});

  @override
  State<_ManualInput> createState() => _ManualInputState();
}

class _ManualInputState extends State<_ManualInput> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Column(
      children: [
        TextField(
          controller: _ctrl,
          autofocus: true,
          maxLines: 2,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            hintText: t('scanQrLoginPasteTicket'),
            hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
            filled: true,
            fillColor: const Color(0xFF2A2A2A),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => widget.onSubmit(_ctrl.text),
            child: Text(t('scanQrLoginConfirmBtn')),
          ),
        ),
      ],
    );
  }
}

