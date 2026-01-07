import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

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
          seedColor: Colors.deepPurple,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
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
    const ProgressView(),
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
            icon: Icon(Icons.analytics_outlined),
            selectedIcon: Icon(Icons.analytics),
            label: '进度',
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
    for (var item in state.items) {
      final outPath = "${state.outputDir}/${item.title}.mp4";
      state.itemStatus[item.videoPath] = "Processing...";
      state.addLog("正在合并: ${item.title}");

      if (settings.parseDanmaku && item.danmakuPath != null) {
        try {
          final xml = await File(item.danmakuPath!).readAsString();
          final ass = XmlToAssConverter.convert(xml, options: settings.danmakuOptions);
          await File("${state.outputDir}/${item.title}.ass").writeAsString(ass);
        } catch (e) {
          state.addLog("弹幕失败: $e");
        }
      }

      final ok = await FFmpegService.mergeVideoAudio(item.videoPath, item.audioPath, outPath);
      if (ok) {
        success++;
        state.itemStatus[item.videoPath] = "Success";
      } else {
        state.itemStatus[item.videoPath] = "Failed";
      }
    }

    state.processing = false;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("合并结束"),
        content: Text("成功: $success / ${state.items.length}"),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("好的"))],
      ),
    );
  }
}

class ProgressView extends StatelessWidget {
  const ProgressView({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text("执行进度")),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: state.logs.length,
        itemBuilder: (context, index) => Text(state.logs[index], style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
      ),
    );
  }
}

class SettingsView extends StatelessWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    return Scaffold(
      appBar: AppBar(title: const Text("设置")),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text("解析弹幕"),
            value: settings.parseDanmaku,
            onChanged: (v) => settings.parseDanmaku = v,
          ),
          if (settings.parseDanmaku) ...[
            ListTile(title: Text("字体大小: ${settings.fontSize}")),
            Slider(value: settings.fontSize.toDouble(), min: 20, max: 80, onChanged: (v) => settings.fontSize = v.toInt()),
            ListTile(title: Text("透明度: ${(settings.opacity * 100).toInt()}%")),
            Slider(value: settings.opacity, min: 0.1, max: 1.0, onChanged: (v) => settings.opacity = v),
          ],
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
          const Divider(),
          const ListTile(title: Text("版本"), subtitle: Text("v1.2.0")),
          const ListTile(title: Text("作者"), subtitle: Text("至庭")),
        ],
      ),
    );
  }
}
