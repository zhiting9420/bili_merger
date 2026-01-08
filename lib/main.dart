import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';

import 'utils/bili_scanner.dart';
import 'utils/xml_to_ass.dart';
import 'services/ffmpeg_service.dart';
import 'services/settings_service.dart';

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
      return const MaterialApp(home: Scaffold(body: Center(child: CircularProgressIndicator())));
    }

    return MaterialApp(
      title: 'Bili Merger',
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

  final List<Widget> _pages = [
    const HomeView(),
    const SettingsView(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: _pages,
      ),
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
    final settings = context.watch<SettingsService>();

    return Scaffold(
      appBar: AppBar(title: const Text("Bili Merger", style: TextStyle(fontWeight: FontWeight.bold)), centerTitle: true),
      body: Column(
        children: [
          _buildHeroCard(context, state),
          Expanded(
            child: state.scanning
                ? const Center(child: CircularProgressIndicator())
                : state.items.isEmpty
                    ? const Center(child: Text("请选择输入目录并开始扫描"))
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: state.items.length,
                        itemBuilder: (context, index) {
                          final item = state.items[index];
                          final status = state.itemStatus[item.videoPath];
                          return Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              title: Text(item.title),
                              subtitle: Text(status ?? (item.danmakuPath != null ? "含弹幕" : "无弹幕")),
                              trailing: _buildStatusIcon(status),
                            ),
                          );
                        },
                      ),
          ),
        ],
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
    if (status == "Success") return const Icon(Icons.check_circle, color: Colors.green);
    if (status == "Failed") return const Icon(Icons.error, color: Colors.red);
    if (status == "Processing...") return const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
    return const Icon(Icons.chevron_right);
  }

  Widget _buildHeroCard(BuildContext context, AppState state) {
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            ElevatedButton.icon(
              onPressed: state.processing ? null : () async {
                await _requestPermissions();
                String? path = await FilePicker.platform.getDirectoryPath();
                if (path != null) {
                  state.inputDir = path;
                  state.scanning = true;
                  try {
                    state.items = await BiliScanner.scanDirectory(path, state.outputDir ?? path);
                    state.addLog("扫描完成，找到 ${state.items.length} 个项目");
                  } finally {
                    state.scanning = false;
                  }
                }
              },
              icon: const Icon(Icons.folder),
              label: Text(state.inputDir == null ? "选择输入目录" : "输入: ${state.inputDir!.split(Platform.pathSeparator).last}"),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: state.processing ? null : () async {
                String? path = await FilePicker.platform.getDirectoryPath();
                if (path != null) {
                  state.outputDir = path;
                  state.addLog("选择输出目录: $path");
                }
              },
              icon: const Icon(Icons.output),
              label: Text(state.outputDir == null ? "选择输出目录" : "输出: ${state.outputDir!.split(Platform.pathSeparator).last}"),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startMerge(BuildContext context) async {
    final state = context.read<AppState>();
    final settings = context.read<SettingsService>();

    if (state.outputDir == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("请先选择输出目录")));
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

      bool currentOk = true;
      if (settings.parseDanmaku && item.danmakuPath != null) {
        try {
          final xml = await File(item.danmakuPath!).readAsString();
          final ass = XmlToAssConverter.convert(xml, options: settings.danmakuOptions);
          await File("${state.outputDir}/${item.title}.ass").writeAsString(ass);
        } catch (e) {
          state.addLog("弹幕生成失败: $e");
        }
      }

      final ok = await FFmpegService.mergeVideoAudio(item.videoPath, item.audioPath, outPath);
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
                const Text("失败项目:", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
                ...failedTitles.map((t) => Text("• $t", style: const TextStyle(fontSize: 12))),
              ],
            ],
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("好的"))],
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
        title: const Text("高级设置"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: "恢复默认设置",
            onPressed: () {
              settings.resetToDefaults();
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("已恢复默认设置")));
            },
          ),
        ],
      ),
      body: ListView(
        children: [
          _buildSectionHeader(context, "弹幕开关"),
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
            
            const Divider(),
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
                          content: const Text("注意：.ass 弹幕文件依赖播放器环境。如果播放器未安装对应字体，会回退到系统默认字体。建议使用 MX Player 或弹弹 Play 以获得更好展示。"),
                          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("知道了"))],
                        ),
                      );
                    },
                  ),
                  DropdownButton<String>(
                    value: ["黑体", "微软雅黑", "思源黑体", "圆体"].contains(settings.fontName) ? settings.fontName : "微软雅黑",
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
              0.5, 2.0, 0.1,
              (v) => settings.speed = v,
              "${settings.speed.toStringAsFixed(1)}x",
              Icons.speed,
            ),
            _buildSlider(
              context,
              "透明度",
              settings.opacity,
              0.1, 1.0, 0.05,
              (v) => settings.opacity = v,
              "${(settings.opacity * 100).toInt()}%",
              Icons.opacity,
            ),
            _buildSlider(
              context,
              "字体大小",
              settings.fontSize.toDouble(),
              20, 100, 2,
              (v) => settings.fontSize = v.toInt(),
              "${settings.fontSize} px",
              Icons.format_size,
            ),
            
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("弹幕画质 (PlayResY)", style: TextStyle(fontWeight: FontWeight.bold)),
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
                  const Text("显示区域 (高度比例)", style: TextStyle(fontWeight: FontWeight.bold)),
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
          _buildSectionHeader(context, "关于作者"),
          ListTile(
            leading: const Icon(Icons.favorite, color: Colors.red),
            title: const Text("赞赏作者"),
            subtitle: const Text("如果您觉得好用，可以请作者喝杯咖啡~"),
            onTap: () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text("感谢您的支持"),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset("assets/alipay_qr.jpg"),
                      const SizedBox(height: 12),
                      const Text("打开支付宝 [扫一扫]", style: TextStyle(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("好的")),
                  ],
                ),
              );
            },
          ),
          const ListTile(title: Text("版本"), subtitle: Text("v1.3.0 (Advanced)")),
          ListTile(
            title: const Text("作者"),
            subtitle: const Text("至庭 (点击复制 GitHub 项目地址)"),
            onTap: () {
              const url = "https://github.com/zhiting9420/bili_merger";
              Clipboard.setData(const ClipboardData(text: url));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("已复制项目地址到剪贴板")),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildColorOption(BuildContext context, SettingsService settings, int colorValue) {
    final isSelected = settings.seedColorValue == colorValue;
    return GestureDetector(
      onTap: () => settings.seedColorValue = colorValue,
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: Color(colorValue),
          shape: BoxShape.circle,
          border: isSelected ? Border.all(color: Theme.of(context).colorScheme.outline, width: 2) : null,
        ),
        child: isSelected ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
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

  Widget _buildSlider(BuildContext context, String title, double value, double min, double max, double divisions, Function(double) onChanged, String display, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Column(
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              Text(display, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
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
