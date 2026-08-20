import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'utils/bili_scanner.dart';
import 'utils/xml_to_ass.dart';
import 'services/ffmpeg_service.dart';
import 'services/settings_service.dart';
import 'services/update_service.dart';

/// 应用信息。发布到你自己的仓库前，把 author / githubUrl 换成你的信息。
class AppInfo {
  static const String name = "BiliMerger";
  static const String subtitle = "哔哩哔哩缓存视频和弹幕提取工具";
  static const String version = "1.1.0";
  static const String author = "至庭";
  static const String repo = "zhiting9420/bili_merger";
  static const String githubUrl = "https://github.com/$repo";
}

/// 合并方式。两条路径的产物完全不同,所以在开始前必须让用户明确选一次。
enum MergeMode {
  /// 快速合并:`-c copy` 直接封装,秒级完成,弹幕另存为外挂 .ass。
  fast,

  /// 弹幕烧录:弹幕画进画面像素,输出单个自带弹幕的 MP4,需要重新编码。
  burn,
}

/// 在后台 isolate 中转换弹幕(供 compute 使用),避免大文件阻塞 UI 线程。
DanmakuResult _convertDanmaku((String, DanmakuOptions) args) =>
    XmlToAssConverter.convertWithStats(args.$1, options: args.$2);

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsService()),
        ChangeNotifierProvider(create: (_) => AppState()),
      ],
      child: const MyApp(),
    ),
  );
}

class AppState extends ChangeNotifier {
  String? _inputDir;
  String? _outputDir;
  List<BiliVideoItem> _items = [];
  bool _scanning = false;
  bool _processing = false;
  final List<String> _logs = [];
  final Map<String, String> _itemStatus = {};
  // 勾选待合并的视频,以 videoPath 为键。扫描后默认全选。
  final Set<String> _selected = {};
  // 用户点了「中断导出」。当前条目会被立即结束,剩余条目不再开始。
  bool _cancelRequested = false;
  // 烧录进度 0.0~1.0,以 videoPath 为键。只有烧录模式会填,快速合并是秒级的没必要。
  final Map<String, double> _itemProgress = {};

  String? get inputDir => _inputDir;
  String? get outputDir => _outputDir;
  List<BiliVideoItem> get items => _items;
  bool get scanning => _scanning;
  bool get processing => _processing;
  List<String> get logs => _logs;
  Map<String, String> get itemStatus => _itemStatus;
  Set<String> get selected => _selected;
  bool get cancelRequested => _cancelRequested;
  Map<String, double> get itemProgress => _itemProgress;

  /// 传 null 表示这一条已经结束,把进度条撤掉。
  void setItemProgress(String videoPath, double? value) {
    if (value == null) {
      if (_itemProgress.remove(videoPath) == null) return;
    } else {
      _itemProgress[videoPath] = value;
    }
    notifyListeners();
  }

  set cancelRequested(bool value) {
    _cancelRequested = value;
    notifyListeners();
  }

  bool isSelected(BiliVideoItem item) => _selected.contains(item.videoPath);
  int get selectedCount => _selected.length;
  bool get allSelected =>
      _items.isNotEmpty && _selected.length == _items.length;

  List<BiliVideoItem> get selectedItems =>
      _items.where((i) => _selected.contains(i.videoPath)).toList();

  void toggleSelected(BiliVideoItem item) {
    if (!_selected.remove(item.videoPath)) {
      _selected.add(item.videoPath);
    }
    notifyListeners();
  }

  void setAllSelected(bool value) {
    _selected.clear();
    if (value) {
      _selected.addAll(_items.map((i) => i.videoPath));
    }
    notifyListeners();
  }

  set inputDir(String? value) {
    _inputDir = value;
    notifyListeners();
  }

  set outputDir(String? value) {
    _outputDir = value;
    notifyListeners();
  }

  set items(List<BiliVideoItem> value) {
    _items = value;
    // 新一轮扫描的结果默认全选。
    _selected
      ..clear()
      ..addAll(value.map((i) => i.videoPath));
    notifyListeners();
  }

  set scanning(bool value) {
    _scanning = value;
    notifyListeners();
  }

  set processing(bool value) {
    _processing = value;
    notifyListeners();
  }

  void addLog(String message) {
    final time = DateTime.now().toString().split(' ')[1].split('.')[0];
    _logs.add("[$time] $message");
    notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    if (!settings.isInitialized) {
      return const MaterialApp(
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    return MaterialApp(
      title: AppInfo.name,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Color(settings.seedColorValue),
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Color(settings.seedColorValue),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const MainScaffold(),
    );
  }
}

class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  int _selectedIndex = 0;

  final List<Widget> _pages = [const HomeView(), const SettingsView()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _selectedIndex, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}

class HomeView extends StatelessWidget {
  const HomeView({super.key});

  Future<void> _requestPermissions() async {
    if (await Permission.manageExternalStorage.request().isGranted) {
    } else if (await Permission.storage.request().isGranted) {}
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Column(
                children: [
                  _buildDirTile(context, state, isInput: true),
                  const SizedBox(height: 12),
                  _buildDirTile(context, state, isInput: false),
                ],
              ),
            ),
            if (!state.scanning && state.items.isNotEmpty)
              _buildSelectionBar(context, state),
            Expanded(
              child: state.scanning
                  ? const Center(child: CircularProgressIndicator())
                  : state.items.isEmpty
                  ? _buildEmpty(context)
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
                      itemCount: state.items.length,
                      itemBuilder: (context, index) {
                        final item = state.items[index];
                        final status = state.itemStatus[item.videoPath];
                        final checked = state.isSelected(item);
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            onTap: state.processing
                                ? null
                                : () => state.toggleSelected(item),
                            leading: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Checkbox(
                                  value: checked,
                                  onChanged: state.processing
                                      ? null
                                      : (_) => state.toggleSelected(item),
                                ),
                                _VideoThumb(item.videoPath),
                              ],
                            ),
                            title: Text(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: _buildItemSubtitle(state, item, status),
                            trailing: _buildStatusIcon(status),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: state.processing
          ? FloatingActionButton.extended(
              onPressed: state.cancelRequested
                  ? null
                  : () => _cancelMerge(context),
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
              icon: state.cancelRequested
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.stop_circle_outlined),
              label: Text(
                state.cancelRequested
                    ? "正在中断…"
                    : (state.itemProgress.isEmpty
                          ? "导出中 · 点击中断"
                          : "烧录中 · 点击中断"),
              ),
            )
          : state.items.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: state.selectedCount == 0
                  ? null
                  : () => _startMerge(context),
              backgroundColor: state.selectedCount == 0
                  ? Theme.of(context).disabledColor
                  : null,
              label: Text(
                state.selectedCount == 0
                    ? "未选择视频"
                    : "合并选中 ${state.selectedCount} 个",
              ),
              icon: const Icon(Icons.merge),
            )
          : null,
    );
  }

  /// 列表顶部的全选工具条:显示勾选进度,一键全选/全不选。
  Widget _buildSelectionBar(BuildContext context, AppState state) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Row(
        children: [
          Checkbox(
            value: state.allSelected
                ? true
                : (state.selectedCount == 0 ? false : null),
            tristate: true,
            onChanged: state.processing
                ? null
                : (_) => state.setAllSelected(!state.allSelected),
          ),
          Expanded(
            child: Text(
              "已选 ${state.selectedCount} / ${state.items.length} 个视频",
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          TextButton(
            onPressed: state.processing
                ? null
                : () => state.setAllSelected(!state.allSelected),
            child: Text(state.allSelected ? "全不选" : "全选"),
          ),
        ],
      ),
    );
  }

  /// 烧录时把状态行换成进度条。快速合并没有进度可言(几秒就完事),仍显示原来的文案。
  Widget _buildItemSubtitle(
    AppState state,
    BiliVideoItem item,
    String? status,
  ) {
    final progress = state.itemProgress[item.videoPath];
    if (progress == null) return Text(status ?? _itemSubtitle(item));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text("烧录中 ${(progress * 100).toStringAsFixed(0)}%"),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(value: progress, minHeight: 5),
        ),
      ],
    );
  }

  Widget _buildStatusIcon(String? status) {
    if (status == "Success") {
      return const Icon(Icons.check_circle, color: Colors.green);
    }
    if (status == "Failed") return const Icon(Icons.error, color: Colors.red);
    if (status == "Cancelled") {
      return const Icon(Icons.block, color: Colors.orange);
    }
    if (status == "Processing...") {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return const Icon(Icons.chevron_right);
  }

  String _itemSubtitle(BiliVideoItem item) {
    final parts = <String>[];
    if (item.durationMs != null && item.durationMs! > 0) {
      parts.add(_fmtDuration(item.durationMs!));
    }
    parts.add(item.danmakuPath != null ? "含弹幕" : "无弹幕");
    return parts.join("  ·  ");
  }

  static String _fmtDuration(int ms) {
    final total = ms ~/ 1000;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? "$h:$mm:$ss" : "$m:$ss";
  }

  Future<void> _pickDir(
    BuildContext context,
    AppState state,
    bool isInput,
  ) async {
    if (isInput) {
      await _requestPermissions();
      final path = await FilePicker.platform.getDirectoryPath();
      if (path == null) return;
      state.inputDir = path;
      state.scanning = true;
      try {
        state.items = await BiliScanner.scanDirectory(path);
        state.addLog("扫描完成，找到 ${state.items.length} 个项目");
      } finally {
        state.scanning = false;
      }
    } else {
      final path = await FilePicker.platform.getDirectoryPath();
      if (path == null) return;
      state.outputDir = path;
      state.addLog("选择输出目录: $path");
    }
  }

  Widget _buildDirTile(
    BuildContext context,
    AppState state, {
    required bool isInput,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final path = isInput ? state.inputDir : state.outputDir;
    final selected = path != null;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: state.processing
            ? null
            : () => _pickDir(context, state, isInput),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          child: Row(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isInput ? Icons.folder_open : Icons.drive_folder_upload,
                  color: scheme.onPrimaryContainer,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isInput ? "输入目录" : "输出目录",
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      selected
                          ? path.split(Platform.pathSeparator).last
                          : (isInput ? "点击选择 B 站缓存目录" : "点击选择保存位置"),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.video_library_outlined,
            size: 76,
            color: scheme.outlineVariant,
          ),
          const SizedBox(height: 16),
          Text(
            "选择 B 站缓存目录开始",
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 15),
          ),
          const SizedBox(height: 6),
          Text(
            "扫描到的视频会显示在这里",
            style: TextStyle(color: scheme.outline, fontSize: 13),
          ),
        ],
      ),
    );
  }

  /// 中断导出:结束当前 ffmpeg 子进程,剩余条目不再开始。
  Future<void> _cancelMerge(BuildContext context) async {
    final state = context.read<AppState>();
    state.cancelRequested = true;
    state.addLog("正在中断导出…");
    await FFmpegService.cancelMerge();
  }

  /// 把毫秒粗略说成「X 分钟 / X 小时 Y 分钟」,用于耗时预估,不需要精确到秒。
  static String _fmtRoughDuration(int ms) {
    final min = (ms / 60000).ceil().clamp(1, 1 << 30);
    if (min < 60) return "$min 分钟";
    final h = min ~/ 60;
    final m = min % 60;
    return m == 0 ? "$h 小时" : "$h 小时 $m 分钟";
  }

  /// 耗时区间。两端都不足一小时时合并单位,读作「2～10 分钟」而不是「2 分钟～10 分钟」。
  static String _fmtEstimateRange(int loMs, int hiMs) {
    final lo = (loMs / 60000).ceil().clamp(1, 1 << 30);
    final hi = (hiMs / 60000).ceil().clamp(1, 1 << 30);
    if (lo == hi) return _fmtRoughDuration(hiMs);
    if (hi < 60) return "$lo～$hi 分钟";
    return "${_fmtRoughDuration(loMs)}～${_fmtRoughDuration(hiMs)}";
  }

  /// 烧录目标码率。
  ///
  /// MediaCodec 不支持 CRF,必须给一个绝对码率;直接写死会让低码率的缓存视频白白膨胀。
  /// 这里按「源视频实际码率」推算:B 站缓存多为 HEVC,同画质换成 H.264 大约要多花
  /// 1.6~2 倍码率,再加上烧进画面的弹幕本身是高频细节,取 2.5 倍并夹在合理区间。
  static int _targetBitrateKbps(BiliVideoItem item) {
    try {
      final durSec = (item.durationMs ?? 0) / 1000.0;
      if (durSec <= 1) return 4000;
      final bytes = File(item.videoPath).lengthSync();
      final srcKbps = bytes * 8 / durSec / 1000;
      return (srcKbps * 2.5).round().clamp(2000, 10000);
    } catch (_) {
      return 4000;
    }
  }

  /// 开始前让用户选合并方式。两者产物差别很大(外挂字幕 vs 烧进像素),
  /// 而且烧录是分钟级的,不该让用户点一下才发现要等半小时。
  Future<MergeMode?> _askMergeMode(
    BuildContext context,
    List<BiliVideoItem> targets,
  ) {
    final scheme = Theme.of(context).colorScheme;
    // 烧录不可逆,所以把当前生效的筛选模式直接摆在弹窗里,不让用户点下去才发现不对。
    final settings = context.read<SettingsService>();
    final featured = settings.filter == DanmakuFilter.featured;
    // 「解析并合并弹幕」是弹幕功能的总开关。它关着时设置页会隐藏整个筛选区,
    // 此时若还允许烧录,弹幕会被永久烧进画面,而弹窗里「可在设置页更改」
    // 的指引指向一个看不见的开关。
    final danmakuOff = !settings.parseDanmaku;
    final filterLine = featured
        ? "本次使用「精选弹幕」— 静止不飘,约保留两成,遮挡最小。"
        : "本次使用「全部弹幕」— 含滚动弹幕,约保留七成,会明显遮挡画面。";
    final totalMs = targets.fold<int>(0, (sum, i) => sum + (i.durationMs ?? 0));
    final withDanmaku = targets.where((i) => i.danmakuPath != null).length;
    // 给区间而不是单点:实测骁龙 8 Gen2 级机型硬件编码约 9~11 倍实时速度(下界取 10 倍),
    // 而低端机或回退到 libx264 时会掉到 2 倍上下(上界)。报单点必然在一头骗人。
    final estimate = totalMs > 0
        ? "预计 ${_fmtEstimateRange(totalMs ~/ 10, totalMs ~/ 2)}"
        : "耗时取决于视频总时长";

    Widget option({
      required IconData icon,
      required String title,
      required String desc,
      required Color color,
      required VoidCallback? onTap,
    }) {
      return Card(
        elevation: 0,
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Opacity(
            opacity: onTap == null ? 0.45 : 1,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, color: color, size: 26),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          desc,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.45,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return showDialog<MergeMode>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("选择合并方式"),
        contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              option(
                icon: Icons.flash_on,
                color: scheme.primary,
                title: "快速合并",
                desc:
                    "直接封装,不重新编码,几秒完成。\n"
                    "弹幕另存为 .ass 外挂字幕,需要播放器支持才能看到。",
                onTap: () => Navigator.pop(ctx, MergeMode.fast),
              ),
              const SizedBox(height: 4),
              option(
                icon: Icons.local_fire_department,
                color: scheme.error,
                title: "弹幕烧录",
                desc: danmakuOff
                    ? "设置页的「解析并合并弹幕」当前是关闭的,先打开才能烧录。"
                    : withDanmaku == 0
                    ? "所选视频都没有弹幕缓存,无法烧录。"
                    : "弹幕直接画进画面,输出单个 MP4,任何播放器都能看到。\n"
                          "需要逐帧重新编码,$estimate(取决于机型与弹幕密度),"
                          "并且会明显发热耗电。\n"
                          "$filterLine(可在设置页更改)",
                onTap: (withDanmaku == 0 || danmakuOff)
                    ? null
                    : () => Navigator.pop(ctx, MergeMode.burn),
              ),
              if (withDanmaku > 0 && withDanmaku < targets.length)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    "注意:$withDanmaku / ${targets.length} 个视频有弹幕缓存,"
                    "其余会按快速合并处理。",
                    style: TextStyle(fontSize: 12, color: scheme.error),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("取消"),
          ),
        ],
      ),
    );
  }

  /// 烧录单个视频。返回是否成功。
  ///
  /// .ass 写在原生给的私有工作目录里、跑完即删 —— 烧录的产物就是自带弹幕的单个 MP4,
  /// 不该再往用户的输出目录丢外挂字幕。
  Future<bool> _burnOne(
    AppState state,
    SettingsService settings,
    BurnEnv env,
    BiliVideoItem item,
    String outPath,
    int index,
    int total,
  ) async {
    final assFile = File("${env.workDir}/burn.ass");
    try {
      if (item.danmakuPath == null) {
        state.addLog("无弹幕缓存,按快速合并处理: ${item.title}");
        return await FFmpegService.mergeVideoAudio(
          item.videoPath,
          item.audioPath,
          outPath,
        );
      }

      final xml = await File(item.danmakuPath!).readAsString();
      final result = await compute(_convertDanmaku, (
        xml,
        settings.burnDanmakuOptions(env.fontFamily),
      ));
      await assFile.writeAsString(result.ass);
      state.addLog(result.summary);

      state.setItemProgress(item.videoPath, 0.0);
      final encoder = await FFmpegService.burnDanmaku(
        videoPath: item.videoPath,
        audioPath: item.audioPath,
        assPath: assFile.path,
        outputPath: outPath,
        durationMs: item.durationMs ?? 0,
        bitrateKbps: _targetBitrateKbps(item),
        label: "($index/$total) ${item.title}",
      );
      if (encoder == null) return false;
      state.addLog(
        "烧录完成(${encoder == 'h264_mediacodec' ? '硬件编码' : '软件编码'}): ${item.title}",
      );
      return true;
    } catch (e) {
      state.addLog("烧录失败: $e");
      return false;
    } finally {
      state.setItemProgress(item.videoPath, null);
      try {
        if (await assFile.exists()) await assFile.delete();
      } catch (_) {}
    }
  }

  Future<void> _startMerge(BuildContext context) async {
    final state = context.read<AppState>();
    final settings = context.read<SettingsService>();
    final messenger = ScaffoldMessenger.of(context);

    if (state.outputDir == null) {
      messenger.showSnackBar(const SnackBar(content: Text("请先选择输出目录")));
      return;
    }

    final targets = state.selectedItems;
    if (targets.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text("请先勾选要合并的视频")));
      return;
    }

    final mode = await _askMergeMode(context, targets);
    if (mode == null) return;

    // 立刻占位:下面还有请求通知权限、释放 4MB 字体这两个 await,
    // 期间若按钮仍可点,第二次点击会并发跑起第二轮循环,两轮写同一个输出文件,
    // 还会互相把 processing / cancelRequested 和前台服务掀掉。
    state.processing = true;
    state.cancelRequested = false;
    await FFmpegService.beginSession();

    BurnEnv? env;
    if (mode == MergeMode.burn) {
      // 通知权限只决定通知栏进度条可见与否,拒绝了照样能烧,所以不检查结果。
      await Permission.notification.request();
      env = await FFmpegService.prepareBurn();
      if (env == null) {
        state.processing = false;
        messenger.showSnackBar(
          const SnackBar(content: Text("烧录环境准备失败:内置字体释放不出来")),
        );
        return;
      }
      FFmpegService.onBurnProgress = state.setItemProgress;
    }

    state.clearLogs();
    state.addLog(
      "本次${mode == MergeMode.burn ? '烧录' : '合并'} "
      "${targets.length} / ${state.items.length} 个视频",
    );

    int success = 0;
    int skipped = 0;
    List<String> failedTitles = [];

    for (var i = 0; i < targets.length; i++) {
      final item = targets[i];
      if (state.cancelRequested) {
        skipped++;
        state.itemStatus[item.videoPath] = "Cancelled";
        continue;
      }
      final outPath = "${state.outputDir}/${item.title}.mp4";
      state.itemStatus[item.videoPath] = "Processing...";
      state.addLog("正在${mode == MergeMode.burn ? '烧录' : '合并'}: ${item.title}");

      bool ok;
      if (mode == MergeMode.burn) {
        ok = await _burnOne(
          state,
          settings,
          env!,
          item,
          outPath,
          i + 1,
          targets.length,
        );
      } else {
        if (settings.parseDanmaku && item.danmakuPath != null) {
          try {
            final xml = await File(item.danmakuPath!).readAsString();
            // 放到后台 isolate 转换,避免大弹幕文件阻塞 UI
            final result = await compute(_convertDanmaku, (
              xml,
              settings.danmakuOptions,
            ));
            await File(
              "${state.outputDir}/${item.title}.ass",
            ).writeAsString(result.ass);
            state.addLog(result.summary);
          } catch (e) {
            state.addLog("弹幕生成失败: $e");
          }
        }
        ok = await FFmpegService.mergeVideoAudio(
          item.videoPath,
          item.audioPath,
          outPath,
        );
      }

      if (ok) {
        success++;
        state.itemStatus[item.videoPath] = "Success";
      } else if (state.cancelRequested) {
        // 中断导致的失败不算错误,半成品文件已由原生侧删除。
        state.itemStatus[item.videoPath] = "Cancelled";
        state.addLog("已中断: ${item.title}");
      } else {
        state.itemStatus[item.videoPath] = "Failed";
        failedTitles.add(item.title);
      }
    }

    if (mode == MergeMode.burn) {
      FFmpegService.onBurnProgress = null;
      await FFmpegService.finishBurnSession();
    }

    final wasCancelled = state.cancelRequested;
    state.processing = false;
    state.cancelRequested = false;

    if (context.mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
            wasCancelled
                ? "已中断"
                : (failedTitles.isEmpty ? "全部任务完成" : "合并任务结束"),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                wasCancelled
                    ? "已中断 — 成功 $success / ${targets.length}，未处理 $skipped 个"
                    : "成功: $success / ${targets.length}",
              ),
              if (failedTitles.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  "失败项目:",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.red,
                  ),
                ),
                ...failedTitles.map(
                  (t) => Text("• $t", style: const TextStyle(fontSize: 12)),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("好的"),
            ),
          ],
        ),
      );
    }
  }
}

class SettingsView extends StatelessWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    return Scaffold(
      appBar: AppBar(
        title: const Text("设置"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: "恢复默认设置",
            onPressed: () {
              settings.resetToDefaults();
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text("已恢复默认设置")));
            },
          ),
        ],
      ),
      body: ListView(
        children: [
          // 个性化与弹幕开关无关，放最上方，避免关闭弹幕后无法修改主题
          _buildSectionHeader(context, "个性化"),
          ListTile(
            leading: const Icon(Icons.palette),
            title: const Text("主题色彩"),
            subtitle: const Text("选择你喜欢的 App 配色"),
            trailing: Wrap(
              spacing: 8,
              children: [
                _buildColorOption(context, settings, 0xFFFB7299), // Bili Pink
                _buildColorOption(context, settings, 0xFF2196F3), // Blue
                _buildColorOption(context, settings, 0xFF9C27B0), // Purple
                _buildColorOption(context, settings, 0xFF4CAF50), // Green
              ],
            ),
          ),
          const Divider(),
          _buildSectionHeader(context, "弹幕"),
          SwitchListTile(
            title: const Text("解析并合并弹幕"),
            subtitle: const Text("启用后将生成 ASS 弹幕文件"),
            secondary: const Icon(Icons.subtitles),
            value: settings.parseDanmaku,
            onChanged: (v) => settings.parseDanmaku = v,
          ),
          if (settings.parseDanmaku) ...[
            const Divider(),
            _buildSectionHeader(context, "弹幕筛选"),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: SegmentedButton<DanmakuFilter>(
                segments: const [
                  ButtonSegment(
                    value: DanmakuFilter.featured,
                    icon: Icon(Icons.star_outline),
                    label: Text("精选弹幕"),
                  ),
                  ButtonSegment(
                    value: DanmakuFilter.all,
                    icon: Icon(Icons.forum_outlined),
                    label: Text("全部弹幕"),
                  ),
                ],
                selected: {settings.filter},
                onSelectionChanged: (v) => settings.filter = v.first,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(
                settings.filter == DanmakuFilter.featured
                    ? "只保留彩色、顶部/底部、以及 B 站权重最高档的弹幕，"
                          "滤掉刷屏的普通白色滚动弹幕。实测约保留两成，画面清爽很多。\n"
                          "外挂 .ass 与弹幕烧录都按这个设置来。"
                    : "在精选的基础上加回普通滚动弹幕，还原 B 站的观看体验。\n"
                          "外挂 .ass 与弹幕烧录都按这个设置来；烧进画面不可逆，请谨慎。",
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            SwitchListTile(
              title: const Text("同款弹幕去重"),
              subtitle: const Text("内容完全相同的弹幕只保留最早的一条"),
              value: settings.dedupe,
              onChanged: (v) => settings.dedupe = v,
            ),
            SwitchListTile(
              title: const Text("防止弹幕重叠"),
              subtitle: const Text("按轨道排布并保证互不遮挡；显示区域放不下的弹幕会被舍弃"),
              value: settings.noOverlap,
              onChanged: (v) => settings.noOverlap = v,
            ),

            const Divider(),
            _buildSectionHeader(context, "弹幕字体"),
            ListTile(
              leading: const Icon(Icons.font_download),
              title: const Text("弹幕字体"),
              subtitle: Text("当前: ${settings.fontName}"),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.info_outline, size: 18),
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text("关于字体渲染"),
                          content: const Text(
                            "注意：.ass 弹幕文件依赖播放器环境。如果播放器未安装对应字体，会回退到系统默认字体。建议使用 MX Player 或弹弹 Play 以获得更好展示。\n\n"
                            "这里的选择只影响「快速合并」导出的外挂 .ass。「弹幕烧录」固定使用随应用打包的中文字体，"
                            "因为内置 ffmpeg 没有 fontconfig，只能认这一份字体，换成别的会渲染成方框。",
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text("知道了"),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  DropdownButton<String>(
                    value:
                        ["黑体", "微软雅黑", "思源黑体", "圆体"].contains(settings.fontName)
                        ? settings.fontName
                        : "微软雅黑",
                    items: ["黑体", "微软雅黑", "思源黑体", "圆体"].map((String value) {
                      return DropdownMenuItem<String>(
                        value: value,
                        child: Text(value),
                      );
                    }).toList(),
                    onChanged: (String? newValue) {
                      if (newValue != null) settings.fontName = newValue;
                    },
                  ),
                ],
              ),
            ),

            const Divider(),
            _buildSectionHeader(context, "弹幕参数"),
            _buildSlider(
              context,
              "弹幕速度",
              settings.speed,
              0.5,
              2.0,
              0.1,
              (v) => settings.speed = v,
              "${settings.speed.toStringAsFixed(2)}x",
              Icons.speed,
              hint: "越快则轨道周转越快,同屏弹幕更少、能保留的弹幕更多,播放也更流畅",
            ),
            _buildSlider(
              context,
              "透明度",
              settings.opacity,
              0.1,
              1.0,
              0.05,
              (v) => settings.opacity = v,
              "${(settings.opacity * 100).toInt()}%",
              Icons.opacity,
            ),
            _buildSlider(
              context,
              "字体大小",
              settings.fontSize.toDouble(),
              20,
              100,
              2,
              (v) => settings.fontSize = v.toInt(),
              "${settings.fontSize} px",
              Icons.format_size,
              hint:
                  "弹幕高度约占画面 ${(settings.fontSize / 1080 * 100).toStringAsFixed(1)}%"
                  "（B 站默认观感在 4% 左右）",
            ),

            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "显示区域 (高度比例)",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<double>(
                    segments: const [
                      ButtonSegment(value: 0.25, label: Text("1/4")),
                      ButtonSegment(value: 0.5, label: Text("半屏")),
                      ButtonSegment(value: 0.75, label: Text("3/4")),
                      ButtonSegment(value: 1.0, label: Text("全屏")),
                    ],
                    selected: {settings.area},
                    onSelectionChanged: (Set<double> val) {
                      settings.area = val.first;
                    },
                  ),
                ],
              ),
            ),
          ],
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text("关于"),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const AboutPage())),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildColorOption(
    BuildContext context,
    SettingsService settings,
    int colorValue,
  ) {
    final isSelected = settings.seedColorValue == colorValue;
    return GestureDetector(
      onTap: () => settings.seedColorValue = colorValue,
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: Color(colorValue),
          shape: BoxShape.circle,
          border: isSelected
              ? Border.all(
                  color: Theme.of(context).colorScheme.outline,
                  width: 2,
                )
              : null,
        ),
        child: isSelected
            ? const Icon(Icons.check, size: 14, color: Colors.white)
            : null,
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
          fontSize: 14,
        ),
      ),
    );
  }

  Widget _buildSlider(
    BuildContext context,
    String title,
    double value,
    double min,
    double max,
    double divisions,
    Function(double) onChanged,
    String display,
    IconData icon, {
    String? hint,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              Text(
                display,
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: ((max - min) / divisions).round(),
            onChanged: onChanged,
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                hint,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  Future<void> _open(BuildContext context, String url) async {
    bool ok = false;
    try {
      ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      ok = false;
    }
    if (!ok && context.mounted) {
      final messenger = ScaffoldMessenger.of(context);
      await Clipboard.setData(ClipboardData(text: url));
      messenger.showSnackBar(
        const SnackBar(content: Text("无法打开浏览器，已复制链接到剪贴板")),
      );
    }
  }

  Future<void> _checkUpdate(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text("正在检查更新…"), duration: Duration(seconds: 1)),
    );
    final r = await UpdateService.check(AppInfo.repo, AppInfo.version);
    if (!context.mounted) return;
    if (!r.ok) {
      messenger.showSnackBar(const SnackBar(content: Text("检查更新失败，请检查网络后重试")));
      return;
    }
    if (!r.hasUpdate) {
      messenger.showSnackBar(
        SnackBar(content: Text("当前已是最新版本 (v${AppInfo.version})")),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("有可用更新"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("当前版本：v${AppInfo.version}"),
              const SizedBox(height: 2),
              Text("最新版本：v${r.latestVersion}"),
              if (r.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(r.notes),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("以后再说"),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _open(context, r.apkUrl ?? r.pageUrl);
            },
            child: const Text("前往更新"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text("关于")),
      body: ListView(
        children: [
          const SizedBox(height: 24),
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Image.asset("assets/icon.png", width: 96, height: 96),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            AppInfo.name,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            AppInfo.subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            "Version ${AppInfo.version}",
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 24),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: const Text("作者"),
                  subtitle: const Text(AppInfo.author),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.code),
                  title: const Text("GitHub"),
                  trailing: const Icon(Icons.open_in_new, size: 20),
                  onTap: () => _open(context, AppInfo.githubUrl),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.refresh),
                  title: const Text("检查更新"),
                  subtitle: const Text("点击检查是否有新版本"),
                  onTap: () => _checkUpdate(context),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: const Text("隐私协议"),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PrivacyPage()),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("隐私协议")),
      body: const SingleChildScrollView(
        padding: EdgeInsets.all(20),
        child: Text(
          "${AppInfo.name} 隐私协议\n\n"
          "本应用是一款完全在本地运行的工具，用于将您设备上已缓存的哔哩哔哩音视频文件合并为完整视频。\n\n"
          "1. 信息收集\n"
          "本应用不收集、不存储、不上传任何个人信息或使用数据，也不含任何统计、广告或第三方追踪 SDK。\n\n"
          "2. 权限说明\n"
          "存储访问权限仅用于读取您主动选择的缓存目录，以及将合并结果写入您指定的输出目录；本应用不会访问上述范围之外的文件。\n\n"
          "3. 网络\n"
          "合并与弹幕转换全程离线完成。仅当您主动点击“GitHub / 检查更新”等链接时，才会调用系统浏览器访问对应网页。\n\n"
          "4. 数据安全\n"
          "所有处理均在本地设备完成，文件不会离开您的设备。\n\n"
          "如对本协议有疑问，可通过项目 GitHub 页面反馈。",
          style: TextStyle(height: 1.6),
        ),
      ),
    );
  }
}

/// 列表里的视频缩略图:进入视口时用内置 ffmpeg 抽一帧,native 侧已缓存。
class _VideoThumb extends StatefulWidget {
  final String videoPath;
  const _VideoThumb(this.videoPath);

  @override
  State<_VideoThumb> createState() => _VideoThumbState();
}

class _VideoThumbState extends State<_VideoThumb> {
  String? _path;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final path = await FFmpegService.extractThumbnail(widget.videoPath);
    if (mounted) {
      setState(() {
        _path = path;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget child;
    if (_path != null) {
      child = Image.file(
        File(_path!),
        width: 72,
        height: 48,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    } else {
      child = Container(
        width: 72,
        height: 48,
        color: scheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: SizedBox(
          width: 18,
          height: 18,
          child: _loading
              ? const CircularProgressIndicator(strokeWidth: 2)
              : Icon(
                  Icons.movie_outlined,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
        ),
      );
    }
    return ClipRRect(borderRadius: BorderRadius.circular(6), child: child);
  }
}
