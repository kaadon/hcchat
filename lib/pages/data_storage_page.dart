import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../l10n/app_locale.dart';
import '../services/local_store.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/v2_kit.dart';
import '../widgets/v2_settings.dart';

// ============================================================================
// 数据和存储页（像素级复刻，2026-09-14）
//
// 参考截图：clipboard-2026-09-14T15-15-58-764Z-2ada88cc.jpg
// （物理 1260 / DPR 3 ⇒ 逻辑 420×2049.3）。
// 逐元素测量见 `UI-ref/measure/audit_chatset_storage.md`。
//
// 本页与共享库 `v2_settings.dart` 的差异（共享文件不改，用局部 `_k*` 覆盖）：
//   · AppBar：**纯白条带**（状态栏 59.3 + 标题区 56 + 7.7，实测白到 y=123.0）
//     + 细雪佛龙返回箭头（ink 11.7×20.3、左缘 30.0）⇒
//     V2SetScaffold(bg:#F3F2F7, headerBg:#FFFFFF, headerExtra:7.7,
//     backSpec: V2SetBackSpec.chevron)。共享库已为此扩展参数。
//   · 分组标题：ink 左缘 **42.0**、字号 16.6、色 #9A9DA7（B 型）
//   · 行主标题 20.3 / 纯黑；副标题 17.8 / #6C717B，行盒步进 23.0
//   · 尾部灰字原实测左对齐在 x=200.7；2026-09-15 按用户反馈改为
//     随箭头一起贴行右缘（Spacer 推右）
//   · 箭头色 **#BFBFBF**（比共享的 #6C727E 浅得多）、ink 7.7×12.3
//   · 分隔线实测 #F5F5F5（共享 #F3F3F3，差 2，保留共享值）
//
// 卡片实测（y 全程，逻辑 px）：
//   存储 187.3..482.3（295.0 = 164.6 + 0.7 + 64.5 + 0.7 + 64.5）
//   本机账号数据 546.7..753.3（206.6 = 114.3 + 0.7 + 91.3）
//   自动下载媒体 953.7..1202.7（249.0 = 3×82.5 + 2×0.7）
//   网络 1323.0..1518.0（195.0 = 3×64.5 + 2×0.7）
//   保存 1582.3..1679.7（97.4）
//   数据使用 1744.0..1900.3（156.3 = 91.3 + 0.7 + 64.3）
// ============================================================================

// ---------- 页面 ----------
const Color _kPageBg = Color(0xFFF3F2F7);
const Color _kHeaderBg = Color(0xFFFFFFFF);
const double _kHeaderExtra = 7.7; // 56 高标题区之下继续白底的高度（实测白条带到 123.0）
const double _kPadTop = 34.6; // 白条带底 → 首个分组标题盒（实测标题 ink 158.3）

// ---------- 分组标题（B 型）----------
const double _kLabelX = 42.0;
const double _kLabelSize = 16.6;
const Color _kLabelColor = Color(0xFF9A9DA7);
const double _kGapBeforeLabel = 35.0; // 卡片底 → 标题盒（实测 ink 距 35.7）
const double _kGapBeforeLabelAfterNote = 33.1; // 说明段底 → 标题盒（说明末行盒下沿留白更小）
const double _kGapAfterLabel = 13.0; // 标题盒底 → 卡片（实测 ink 距 13.7）

// ---------- 说明灰字 ----------
const double _kNoteSize = 16.7;
const double _kNoteLineH = 23.8;
const double _kNoteLeft = 41.0;
const double _kNoteRight = 20.7;
const Color _kNoteColor = Color(0xFF9B9FA8);
const double _kGapBeforeNote = 10.5; // 卡片底 → 说明段盒（实测 ink 距 14.7）
const double _kGapBetweenNotes = 8.4; // 两段说明之间

// ---------- 行 ----------
const double _kTitleSize = 20.3;
const double _kTitlePadL = 21.3; // 卡左 20.7 → 标题盒 42.0
const double _kTitleColW = 158.7; // 标题盒 42.0 → 尾部灰字左缘 200.7
const double _kSubSize = 17.8;
const double _kSubLineH = 23.0; // 副标题行盒步进（实测 23.0）
const double _kSubGap = 7.6; // 主标题盒底 → 副标题盒（实测 ink 距 11.6）
const double _kTailSize = 17.5;
const double _kSwitchInset = 25.3; // 开关右缘距卡右（开关 x 307.0..374.0）
const double _kChevronInset = 20.75; // 箭头盒右缘距卡右（ink 右 370.4）
const double _kChevronSize = 24.0; // ink 7.7×12.3
const Color _kChevronColor = Color(0xFFBFBFBF);
const Color _kInk = Color(0xFF000000);

// ---------- 行高 ----------
const double _kHStorage = 164.6; // 「已使用存储空间」块（标题 + 进度条 + 图例）
const double _kHChevron = 64.5; // 单行 + 箭头 ／ 单行红字（内容垂直居中）
const double _kHSwitch = 82.5; // 单行 + 开关
const double _kSubPadTop = 22.2; // 标题 + 副标题行的上内边距
const double _kSubPadBottom = 18.2; // ⇒ 1 行副标题 91.3 / 2 行 114.3
const double _kSavePadTop = 14.75; // 「保存到相册」行（开关 + 2 行副标题）上内边距
const double _kSavePadBottom = 8.75; // ⇒ 行高 97.4（实测比普通副标题行矮 16.9）

// ---------- 存储块内部 ----------
const double _kStorageTopPad = 25.1; // 卡顶 → 标题盒（实测 ink 25.7）
const double _kStorageTitleBarGap = 23.35; // 标题盒底 → 进度条（实测 232.65→256.0）
const double _kStorageBarLegendGap = 21.7; // 进度条底 → 图例（实测 271.0→292.7 ink）
const double _kStorageBottomPad = 21.4; // 图例底 → 卡尾（合计 164.6）
const double _kBarH = 15.0;
const double _kBarRadius = 7.5;
const Color _kBarTrack = Color(0xFFF0F0F0);
const double _kBarLeftInset = 20.0; // 进度条 / 图例左内缩（页面 40.7）
const double _kBarRightInset = 20.8; // 进度条右内缩（右缘 378.5）
const double _kLegendLabelSize = 13.8;
const double _kLegendValueSize = 17.3;
const double _kLegendLabelGap = 6.65;
const double _kLegendDot = 13.3;
const double _kLegendDotGap = 6.0;
const double _kTitleRightInset = 21.0; // 「1.0 MB」右内缩（右缘 378.3）

// ---------- 图例 / 进度条色（实测）----------
const Color _kDotImage = Color(0xFF2196F3);
const Color _kDotVideo = Color(0xFF4CB050);
const Color _kDotFile = Color(0xFFFF9700);
const Color _kDotCache = Color(0xFF9E9E9E);

Color _cInk(BuildContext c) => c.v2IsDark ? const Color(0xFFF2F2F7) : _kInk;
Color _cSub(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF98989F) : const Color(0xFF6C717B);
Color _cMuted(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF8E8E93) : _kLabelColor;

/// 说明灰字（实测 #9B9FA8，与分组标题 #9A9DA7 差 1，保留两份实测值）
Color _cNote(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF8E8E93) : _kNoteColor;

/// 数据和存储（构造函数无参可 push；[onBack] 可选，便于宿主自定义返回）
class DataStoragePage extends StatefulWidget {
  const DataStoragePage({super.key, this.onBack});

  final VoidCallback? onBack;

  @override
  State<DataStoragePage> createState() => _DataStoragePageState();
}

class _DataStoragePageState extends State<DataStoragePage> {
  final AppSettings _set = AppSettings.instance;

  /// 本机存储统计（字节）。全部来自真实数据，取不到时为 0（不编假数据）。
  int _imageBytes = 0;
  int _videoBytes = 0;
  int _fileBytes = 0;
  int _cacheBytes = 0;

  @override
  void initState() {
    super.initState();
    _set.addListener(_onChanged);
    _loadUsage();
  }

  @override
  void dispose() {
    _set.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 统计本机存储：
  /// · 图片 / 视频 / 文件 = 会话缓存里记录到的媒体体积（消息 `type` + `file.size`）
  /// · 缓存 = Hive 两个 box（conv_messages / local_meta）已落盘的 UTF-8 字节数
  ///
  /// 为什么不复用 `LocalStore`：本页只需要「只读统计」与「清消息缓存」两个能力，
  /// LocalStore 的公开 API 都不提供；为避免并行开发中改动共享 service 文件，
  /// 这里只用 Hive 的公开 API（`Hive.isBoxOpen` / `Hive.lazyBox`）。
  Future<void> _loadUsage() async {
    var image = 0, video = 0, file = 0, cache = 0;
    try {
      if (Hive.isBoxOpen('conv_messages')) {
        final box = Hive.lazyBox<String>('conv_messages');
        for (final key in box.keys) {
          final raw = await box.get(key);
          if (raw == null || raw.isEmpty) continue;
          cache += utf8.encode(raw).length;
          try {
            final data = jsonDecode(raw);
            if (data is! List) continue;
            for (final m in data) {
              if (m is! Map) continue;
              final f = m['file'];
              if (f is! Map) continue;
              final size = (f['size'] as num?)?.toInt() ?? 0;
              if (size <= 0) continue;
              switch (m['type']?.toString()) {
                case 'image':
                  image += size;
                  break;
                case 'video':
                  video += size;
                  break;
                case 'file':
                  file += size;
                  break;
              }
            }
          } catch (_) {
            // 单条脏数据不影响整体统计
          }
        }
      }
      if (Hive.isBoxOpen('local_meta')) {
        final box = Hive.lazyBox<String>('local_meta');
        for (final key in box.keys) {
          final raw = await box.get(key);
          if (raw != null && raw.isNotEmpty) cache += utf8.encode(raw).length;
        }
      }
    } catch (_) {
      // 拿不到就整块显示 0 B
    }
    if (!mounted) return;
    setState(() {
      _imageBytes = image;
      _videoBytes = video;
      _fileBytes = file;
      _cacheBytes = cache;
    });
  }

  int get _totalBytes => _imageBytes + _videoBytes + _fileBytes + _cacheBytes;

  static String _fmtBytes(int b) {
    if (b <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = b.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${i == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)} ${units[i]}';
  }

  Future<void> _clearCache() async {
    final t = AppLocalizations.of(context).t;
    final yes = await AppDialogs.confirm(
      context,
      title: t('dsClearCache'),
      message: t('dsNoteTwoOps'),
      confirmText: t('dialogsConfirm'),
      danger: true,
    );
    if (yes != true) return;
    try {
      if (Hive.isBoxOpen('conv_messages')) {
        await Hive.lazyBox<String>('conv_messages').clear();
      }
    } catch (_) {}
    await _loadUsage();
  }

  Future<void> _clearLocalData() async {
    final t = AppLocalizations.of(context).t;
    final yes = await AppDialogs.confirm(
      context,
      title: t('dsClearLocal'),
      message: t('dsClearLocalDesc'),
      confirmText: t('dialogsConfirm'),
      danger: true,
    );
    if (yes != true) return;
    await LocalStore.clearUserData();
    await _loadUsage();
  }

  Future<void> _resetIdentity() async {
    final t = AppLocalizations.of(context).t;
    final yes = await AppDialogs.confirm(
      context,
      title: t('dsResetIdentity'),
      message: t('dsResetIdentityDesc'),
      confirmText: t('dialogsConfirm'),
      danger: true,
    );
    if (yes != true) return;
    // 项目里还没有端到端加密身份 / 密钥库服务，接入前只提示（未接后端）
    if (mounted) {
      AppDialogs.toast(
          context, t('meComingSoonSuffix', {'name': t('dsResetIdentity')}));
    }
  }

  Future<void> _resetNetUsage() async {
    final t = AppLocalizations.of(context).t;
    final yes = await AppDialogs.confirm(
      context,
      title: t('dsResetNetUsage'),
      confirmText: t('dialogsConfirm'),
      danger: true,
    );
    if (yes != true) return;
    await _set.resetNetUsage();
    if (mounted) setState(() {});
  }

  /// 网络组三行的下载策略选择（0 不下载 / 1 仅下载图片 / 2 下载所有媒体）
  Future<void> _pickPolicy(int which) async {
    final t = AppLocalizations.of(context).t;
    final cur = which == 0
        ? _set.autoDownloadWifi
        : (which == 1 ? _set.autoDownloadMobile : _set.autoDownloadRoaming);
    await AppDialogs.actionSheet(context, actions: [
      for (final i in const [2, 1, 0])
        DialogAction(
          label: i == 2
              ? t('dsDlAll')
              : (i == 1 ? t('dsDlImagesOnly') : t('dsDlNone')),
          icon: cur == i ? Icons.check : null,
          onTap: () => _set.setAutoDownloadPolicy(which, i),
        ),
    ]);
  }

  String _policyLabel(String Function(String, [Map<String, String>?]) t,
      int value) {
    if (value == 2) return t('dsDlAll');
    if (value == 1) return t('dsDlImagesOnly');
    return t('dsDlNone');
  }

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final t = AppLocalizations.of(context).t;

    return V2SetScaffold(
      title: t('meRowStorage'),
      onBack: widget.onBack,
      bg: _kPageBg,
      headerBg: _kHeaderBg,
      headerExtra: _kHeaderExtra,
      backSpec: V2SetBackSpec.chevron,
      padding: EdgeInsets.only(top: _kPadTop * s, bottom: 40 * s),
      children: [
        // ===== 存储 =====
        _Label(t('dsGrpStorage')),
        SizedBox(height: _kGapAfterLabel * s),
        V2SetCard(rows: [
          // 已使用存储空间 + 占比条 + 图例（一整块，行高 165.0）
          SizedBox(
            height: _kHStorage * s,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: _kStorageTopPad * s),
                Padding(
                  padding: EdgeInsets.only(
                      left: _kTitlePadL * s, right: _kTitleRightInset * s),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          t('dsUsedSpace'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: _kTitleSize * s,
                            height: 1.0,
                            color: _cInk(context),
                          ),
                        ),
                      ),
                      Text(
                        _fmtBytes(_totalBytes),
                        style: TextStyle(
                          fontSize: _kTitleSize * s,
                          fontWeight: FontWeight.w600,
                          height: 1.0,
                          color: _cInk(context),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: _kStorageTitleBarGap * s),
                Padding(
                  padding: EdgeInsets.only(
                      left: _kBarLeftInset * s, right: _kBarRightInset * s),
                  child: _UsageBar(
                    segments: [
                      (_kDotImage, _imageBytes),
                      (_kDotVideo, _videoBytes),
                      (_kDotFile, _fileBytes),
                      (_kDotCache, _cacheBytes),
                    ],
                  ),
                ),
                SizedBox(height: _kStorageBarLegendGap * s),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: _kBarLeftInset * s),
                  child: _UsageLegend(
                    items: [
                      (_kDotImage, t('dsImage'), _imageBytes),
                      (_kDotVideo, t('dsVideo'), _videoBytes),
                      (_kDotFile, t('dsFile'), _fileBytes),
                      (_kDotCache, t('dsLegendCache'), _cacheBytes),
                    ],
                    format: _fmtBytes,
                  ),
                ),
                SizedBox(height: _kStorageBottomPad * s),
              ],
            ),
          ),
          _DsRow(
            title: t('dsClearCache'),
            height: _kHChevron,
            tail: _fmtBytes(_cacheBytes),
            showChevron: true,
            onTap: _clearCache,
          ),
        ]),

        // ===== 本机账号数据 =====
        SizedBox(height: _kGapBeforeLabel * s),
        _Label(t('dsGrpLocalData')),
        SizedBox(height: _kGapAfterLabel * s),
        V2SetCard(rows: [
          _DsRow(
            title: t('dsClearLocal'),
            subtitle: t('dsClearLocalDesc'),
            danger: true,
            padTop: _kSubPadTop,
            padBottom: _kSubPadBottom,
            onTap: _clearLocalData,
          ),
          _DsRow(
            title: t('dsResetIdentity'),
            subtitle: t('dsResetIdentityDesc'),
            danger: true,
            padTop: _kSubPadTop,
            padBottom: _kSubPadBottom,
            onTap: _resetIdentity,
          ),
        ]),
        SizedBox(height: _kGapBeforeNote * s),
        _Note(t('dsNoteTwoOps')),
        SizedBox(height: _kGapBetweenNotes * s),
        _Note(t('dsNoteRecover')),

        // ===== 自动下载媒体 =====
        SizedBox(height: _kGapBeforeLabelAfterNote * s),
        _Label(t('dsGrpAutoDownload')),
        SizedBox(height: _kGapAfterLabel * s),
        V2SetCard(rows: [
          _DsRow(
            title: t('dsImage'),
            height: _kHSwitch,
            trailing: V2SetSwitch(
              value: _set.autoDownloadImage,
              onChanged: _set.setAutoDownloadImage,
            ),
          ),
          _DsRow(
            title: t('dsVideo'),
            height: _kHSwitch,
            trailing: V2SetSwitch(
              value: _set.autoDownloadVideo,
              onChanged: _set.setAutoDownloadVideo,
            ),
          ),
          _DsRow(
            title: t('dsFile'),
            height: _kHSwitch,
            trailing: V2SetSwitch(
              value: _set.autoDownloadFile,
              onChanged: _set.setAutoDownloadFile,
            ),
          ),
        ]),
        SizedBox(height: _kGapBeforeNote * s),
        _Note(t('dsAutoDownloadNote')),

        // ===== 网络 =====
        SizedBox(height: _kGapBeforeLabelAfterNote * s),
        _Label(t('dsGrpNetwork')),
        SizedBox(height: _kGapAfterLabel * s),
        V2SetCard(rows: [
          _DsRow(
            title: t('dsOnWifi'),
            height: _kHChevron,
            tail: _policyLabel(t, _set.autoDownloadWifi),
            showChevron: true,
            onTap: () => _pickPolicy(0),
          ),
          _DsRow(
            title: t('dsOnMobile'),
            height: _kHChevron,
            tail: _policyLabel(t, _set.autoDownloadMobile),
            showChevron: true,
            onTap: () => _pickPolicy(1),
          ),
          _DsRow(
            title: t('dsOnRoaming'),
            height: _kHChevron,
            tail: _policyLabel(t, _set.autoDownloadRoaming),
            showChevron: true,
            onTap: () => _pickPolicy(2),
          ),
        ]),

        // ===== 保存 =====
        SizedBox(height: _kGapBeforeLabel * s),
        _Label(t('dsGrpSave')),
        SizedBox(height: _kGapAfterLabel * s),
        V2SetCard(rows: [
          _DsRow(
            title: t('momentsSaveToAlbum'),
            subtitle: t('dsSaveToAlbumDesc'),
            padTop: _kSavePadTop,
            padBottom: _kSavePadBottom,
            trailing: V2SetSwitch(
              value: _set.saveToAlbum,
              onChanged: _set.setSaveToAlbum,
            ),
          ),
        ]),

        // ===== 数据使用 =====
        SizedBox(height: _kGapBeforeLabel * s),
        _Label(t('dsGrpDataUsage')),
        SizedBox(height: _kGapAfterLabel * s),
        V2SetCard(rows: [
          _DsRow(
            title: t('dsNetUsage'),
            subtitle: t('dsNetUsageDesc', {
              'sent': _fmtBytes(_set.netSentBytes),
              'recv': _fmtBytes(_set.netRecvBytes),
            }),
            padTop: _kSubPadTop,
            padBottom: _kSubPadBottom,
            showChevron: true,
            onTap: _resetNetUsage,
          ),
          // 红色行：实测左对齐（不是居中）
          _DsRow(
            title: t('dsResetNetUsage'),
            height: _kHChevron,
            danger: true,
            onTap: _resetNetUsage,
          ),
        ]),
      ],
    );
  }
}

// ============================================================================
// 本页私有组件
// ============================================================================

/// 分组小标题：ink 左缘 42.0 / 字号 16.6 / #9A9DA7（复用共享组件，只覆盖参数）。
class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => V2SetSectionLabel(
        text,
        left: _kLabelX,
        fontSize: _kLabelSize,
        color: _cMuted(context),
      );
}

/// 页面级说明灰字：左 41.0 / 右 20.7 / 字号 16.7 / 行距 23.8 / #9B9FA8。
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return Padding(
      padding: EdgeInsets.only(left: _kNoteLeft * s, right: _kNoteRight * s),
      child: Text(
        text,
        style: TextStyle(
          fontSize: _kNoteSize * s,
          height: _kNoteLineH / _kNoteSize,
          color: _cNote(context),
        ),
      ),
    );
  }
}

/// 存储占比条：圆角 7.5 / 高 15.0 / 轨道 #F0F0F0，各分类按真实字节分段。
class _UsageBar extends StatelessWidget {
  const _UsageBar({required this.segments});

  /// (颜色, 字节数)
  final List<(Color, int)> segments;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final total = segments.fold<int>(0, (a, b) => a + b.$2);
    return ClipRRect(
      borderRadius: BorderRadius.circular(_kBarRadius * s),
      child: SizedBox(
        height: _kBarH * s,
        child: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: _kBarTrack)),
            Positioned.fill(
              child: Row(
                children: [
                  for (final seg in segments)
                    if (seg.$2 > 0)
                      Expanded(flex: seg.$2, child: ColoredBox(color: seg.$1)),
                  // 全为 0 时整条留轨道色（不编造占比）
                  if (total <= 0) const Spacer(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 图例：4 等分列，每列 = 彩色圆点 + （标签 / 体积）两行。
class _UsageLegend extends StatelessWidget {
  const _UsageLegend({required this.items, required this.format});

  /// (颜色, 标签, 字节数)
  final List<(Color, String, int)> items;
  final String Function(int) format;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return Row(
      children: [
        for (final it in items)
          Expanded(
            child: Row(
              children: [
                Container(
                  width: _kLegendDot * s,
                  height: _kLegendDot * s,
                  decoration:
                      BoxDecoration(color: it.$1, shape: BoxShape.circle),
                ),
                SizedBox(width: _kLegendDotGap * s),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        it.$2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: _kLegendLabelSize * s,
                          height: 1.0,
                          color: _cMuted(context),
                        ),
                      ),
                      SizedBox(height: _kLegendLabelGap * s),
                      Text(
                        format(it.$3),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: _kLegendValueSize * s,
                          fontWeight: FontWeight.w600,
                          height: 1.0,
                          color: _cInk(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 设置行：主标题 + 可选副标题 + 可选尾部灰字（**左对齐固定列**）+ 开关 / 箭头。
///
/// 垂直排布两种：
/// · 无副标题：固定 [height] 垂直居中（开关行 82.5 / 箭头行 64.5）
/// · 有副标题：不下固定高度，用 [padTop] / [padBottom] 精确对齐（危险行、保存行）
class _DsRow extends StatelessWidget {
  const _DsRow({
    required this.title,
    this.subtitle,
    this.height,
    this.tail,
    this.trailing,
    this.showChevron = false,
    this.onTap,
    this.danger = false,
    this.padTop = 0,
    this.padBottom = 0,
  });

  final String title;
  final String? subtitle;
  final double? height;
  final String? tail;
  final Widget? trailing;
  final bool showChevron;
  final VoidCallback? onTap;
  final bool danger;
  final double padTop;
  final double padBottom;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final ink = danger ? context.setDanger : _cInk(context);
    final subC = danger ? context.setDanger : _cSub(context);
    final rightInset = showChevron ? _kChevronInset : _kSwitchInset;
    final hasSub = subtitle != null && subtitle!.isNotEmpty;

    final textColumn = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: _kTitleSize * s, height: 1.0, color: ink),
        ),
        if (hasSub) ...[
          SizedBox(height: _kSubGap * s),
          Text(
            subtitle!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: _kSubSize * s,
              height: _kSubLineH / _kSubSize,
              color: subC,
            ),
          ),
        ],
      ],
    );

    final Widget body;
    if (hasSub) {
      body = Padding(
        padding: EdgeInsets.only(
            left: _kTitlePadL * s,
            right: rightInset * s,
            top: padTop * s,
            bottom: padBottom * s),
        child: Row(
          children: [
            Expanded(child: textColumn),
            if (trailing != null) trailing!,
            if (showChevron)
              Padding(
                padding: EdgeInsets.only(left: 12 * s),
                child: const V2SetChevron(
                    size: _kChevronSize, color: _kChevronColor),
              ),
          ],
        ),
      );
    } else {
      body = Padding(
        padding: EdgeInsets.only(left: _kTitlePadL * s, right: rightInset * s),
        child: SizedBox(
          height: (height ?? _kHChevron) * s,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(width: _kTitleColW * s, child: textColumn),
              // 把尾部灰字 + 箭头推到行右缘（与有副标题行的 Expanded 行尾一致）
              const Spacer(),
              if (tail != null)
                Text(
                  tail!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: _kTailSize * s,
                    height: 1.0,
                    color: danger ? context.setDanger : _cSub(context),
                  ),
                ),
              if (trailing != null) trailing!,
              if (showChevron)
                Padding(
                  padding: EdgeInsets.only(left: 12 * s),
                  child: const V2SetChevron(
                      size: _kChevronSize, color: _kChevronColor),
                ),
            ],
          ),
        ),
      );
    }

    if (onTap == null) return body;
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, child: body),
    );
  }
}
