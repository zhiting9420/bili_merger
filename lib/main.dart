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
  static const String version = "1.0.0";
  static const String author = "至庭";
  static const String repo = "zhiting9420/bili_merger";
  static const String githubUrl = "https://github.com/$repo";
}

/// 在后台 isolate 中转换弹幕(供 compute 使用),避免大文件阻塞 UI 线程。
String _convertDanmaku((String, DanmakuOptions) args) =>
    XmlToAssConverter.convert(args.$1, options: args.$2);

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

  String? get inputDir => _inputDir;
  String? get outputDir => _outputDir;
  List<BiliVideoItem> get items => _items;
  bool get scanning => _scanning;
  bool get processing => _processing;
  List<String> get logs => _logs;
  Map<String, String> get itemStatus => _itemStatus;

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
            Expanded(
              child: state.scanning
                  ? const Center(child: CircularProgressIndicator())
                  : state.items.isEmpty
                  ? _buildEmpty(context)
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: state.items.length,
                      itemBuilder: (context, index) {
                        final item = state.items[index];
                        final status = state.itemStatus[item.videoPath];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: _VideoThumb(item.videoPath),
                            title: Text(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(status ?? _itemSubtitle(item)),
                            trailing: _buildStatusIcon(status),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: state.items.isNotEmpty && !state.processing
          ? FloatingActionButton.extended(
              onPressed: () => _startMerge(context),
              label: const Text("开始合并"),
              icon: const Icon(Icons.merge),
            )
          : null,
    );
  }

  Widget _buildStatusIcon(String? status) {
    if (status == "Success") {
      return const Icon(Icons.check_circle, color: Colors.green);
    }
    if (status == "Failed") return const Icon(Icons.error, color: Colors.red);
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

  Future<void> _startMerge(BuildContext context) async {
    final state = context.read<AppState>();
    final settings = context.read<SettingsService>();

    if (state.outputDir == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("请先选择输出目录")));
      return;
    }

    state.processing = true;
    state.clearLogs();

    int success = 0;
    List<String> failedTitles = [];

    for (var item in state.items) {
      final outPath = "${state.outputDir}/${item.title}.mp4";
      state.itemStatus[item.videoPath] = "Processing...";
      state.addLog("正在合并: ${item.title}");

      if (settings.parseDanmaku && item.danmakuPath != null) {
        try {
          final xml = await File(item.danmakuPath!).readAsString();
          // 放到后台 isolate 转换,避免大弹幕文件阻塞 UI
          final ass = await compute(_convertDanmaku, (
            xml,
            settings.danmakuOptions,
          ));
          await File("${state.outputDir}/${item.title}.ass").writeAsString(ass);
        } catch (e) {
          state.addLog("弹幕生成失败: $e");
        }
      }

      final ok = await FFmpegService.mergeVideoAudio(
        item.videoPath,
        item.audioPath,
        outPath,
      );
      if (ok) {
        success++;
        state.itemStatus[item.videoPath] = "Success";
      } else {
        state.itemStatus[item.videoPath] = "Failed";
        failedTitles.add(item.title);
      }
    }

    state.processing = false;

    if (context.mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(failedTitles.isEmpty ? "全部任务完成" : "合并任务结束"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("成功: $success / ${state.items.length}"),
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
            _buildSectionHeader(context, "精细过滤 (B站原生)"),
            SwitchListTile(
              title: const Text("显示滚动弹幕"),
              subtitle: const Text("普通飞过的弹幕"),
              value: settings.showScroll,
              onChanged: (v) => settings.showScroll = v,
            ),
            SwitchListTile(
              title: const Text("显示固定弹幕"),
              subtitle: const Text("顶部/底部的悬浮弹幕"),
              value: settings.showFixed,
              onChanged: (v) => settings.showFixed = v,
            ),
            SwitchListTile(
              title: const Text("防止弹幕重叠"),
              subtitle: const Text("智能分配轨道，避免同屏滚动弹幕叠在一起"),
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
                            "注意：.ass 弹幕文件依赖播放器环境。如果播放器未安装对应字体，会回退到系统默认字体。建议使用 MX Player 或弹弹 Play 以获得更好展示。",
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
              "${settings.speed.toStringAsFixed(1)}x",
              Icons.speed,
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
            ),

            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "弹幕画质 (PlayResY)",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 720, label: Text("720P")),
                      ButtonSegment(value: 1080, label: Text("1080P")),
                      ButtonSegment(value: 1440, label: Text("2K")),
                      ButtonSegment(value: 2160, label: Text("4K")),
                    ],
                    selected: {settings.resY},
                    onSelectionChanged: (Set<int> val) {
                      settings.resY = val.first;
                      settings.resX = (val.first * 16 / 9).round();
                    },
                  ),
                ],
              ),
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
    IconData icon,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Column(
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
