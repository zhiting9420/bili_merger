import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'services/ffmpeg_service.dart';
import 'utils/bili_scanner.dart';
import 'utils/xml_to_ass.dart';

enum MergeMode { fast, burn }

class ExportResult {
  final int success;
  final int cancelled;
  final List<String> failed;
  final List<String> warnings;
  final bool wasCancelled;
  const ExportResult(
    this.success,
    this.cancelled,
    this.failed,
    this.warnings,
    this.wasCancelled,
  );
}

DanmakuResult _convertDanmaku((String, DanmakuOptions) args) =>
    XmlToAssConverter.convertWithStats(args.$1, options: args.$2);

class AppState extends ChangeNotifier {
  String? _inputDir;
  String? _outputDir;
  List<BiliVideoItem> _items = [];
  bool _scanning = false;
  bool _processing = false;
  bool _choosing = false;
  bool _cancelRequested = false;
  bool _disposed = false;
  bool _finishing = false;
  Future<void>? _cancelFuture;
  final List<String> _logs = [];
  final Map<String, String> _itemStatus = {};
  final Set<String> _selected = {};
  final Map<String, double> _itemProgress = {};

  String? get inputDir => _inputDir;
  String? get outputDir => _outputDir;
  List<BiliVideoItem> get items => List.unmodifiable(_items);
  bool get scanning => _scanning;
  bool get processing => _processing;
  bool get busy => _processing || _scanning || _choosing;
  List<String> get logs => List.unmodifiable(_logs);
  Map<String, String> get itemStatus => Map.unmodifiable(_itemStatus);
  bool get cancelRequested => _cancelRequested;
  bool get canCancel => _processing && !_cancelRequested && !_finishing;
  Map<String, double> get itemProgress => Map.unmodifiable(_itemProgress);
  int get selectedCount => _selected.length;
  bool get allSelected =>
      _items.isNotEmpty && _selected.length == _items.length;
  bool isSelected(BiliVideoItem item) => _selected.contains(item.videoPath);
  List<BiliVideoItem> get selectedItems =>
      _items.where((i) => _selected.contains(i.videoPath)).toList();

  bool beginChoosing() {
    if (busy) return false;
    _choosing = true;
    notifyListeners();
    return true;
  }

  void endChoosing() {
    _choosing = false;
    notifyListeners();
  }

  void toggleSelected(BiliVideoItem item) {
    if (busy) return;
    if (!_selected.remove(item.videoPath)) _selected.add(item.videoPath);
    notifyListeners();
  }

  void setAllSelected(bool value) {
    if (busy) return;
    _selected.clear();
    if (value) _selected.addAll(_items.map((i) => i.videoPath));
    notifyListeners();
  }

  set outputDir(String? value) {
    if (_processing) return;
    _outputDir = value;
    notifyListeners();
  }

  set items(List<BiliVideoItem> value) {
    _items = List.of(value);
    _itemStatus.clear();
    _itemProgress.clear();
    _selected
      ..clear()
      ..addAll(value.map((i) => i.videoPath));
    notifyListeners();
  }

  Future<void> scan(String path) async {
    if (_processing || _scanning) return;
    _scanning = true;
    _inputDir = path;
    items = [];
    try {
      items = await BiliScanner.scanDirectory(path);
      addLog('扫描完成，找到 ${_items.length} 个项目');
    } finally {
      _scanning = false;
      notifyListeners();
    }
  }

  void setItemProgress(String videoPath, double? value) {
    if (value == null) {
      if (_itemProgress.remove(videoPath) == null) return;
    } else if (_itemStatus[videoPath] == 'Processing...' && value.isFinite) {
      _itemProgress[videoPath] = value.clamp(0, 1);
    } else {
      return;
    }
    notifyListeners();
  }

  void addLog(String message) {
    final time = DateTime.now().toString().split(' ')[1].split('.')[0];
    _logs.add('[$time] $message');
    if (_logs.length > 500) _logs.removeAt(0);
    notifyListeners();
  }

  Future<void> cancelExport() async {
    if (!canCancel) return;
    _cancelRequested = true;
    addLog('正在中断导出…');
    _cancelFuture = FFmpegService.cancelMerge().catchError((Object e) {
      addLog('中断请求失败: $e');
    });
    await _cancelFuture;
  }

  Future<ExportResult> export({
    required MergeMode mode,
    required bool parseDanmaku,
    required DanmakuOptions options,
  }) async {
    if (busy) throw StateError('已有任务正在运行');
    final directory = _outputDir;
    final targets = selectedItems;
    if (directory == null || targets.isEmpty) throw StateError('请选择输出目录和视频');
    if (mode == MergeMode.burn && !parseDanmaku) throw StateError('弹幕功能已关闭');
    _processing = true;
    _cancelRequested = false;
    _cancelFuture = null;
    _logs.clear();
    _itemProgress.clear();
    for (final item in targets) {
      _itemStatus.remove(item.videoPath);
    }
    addLog('本次${mode == MergeMode.burn ? '烧录' : '合并'} ${targets.length} 个视频');
    var started = false;
    var success = 0;
    var cancelled = 0;
    final failed = <String>[];
    final warnings = <String>[];
    try {
      await FFmpegService.beginSession(label: '正在准备导出 ${targets.length} 个视频');
      started = true;
      BurnEnv? env;
      if (!_cancelRequested && mode == MergeMode.burn) {
        env = await FFmpegService.prepareBurn();
      }
      FFmpegService.onBurnProgress = setItemProgress;
      for (var i = 0; i < targets.length; i++) {
        final item = targets[i];
        if (_cancelRequested) {
          cancelled++;
          _itemStatus[item.videoPath] = 'Cancelled';
          continue;
        }
        _itemStatus[item.videoPath] = 'Processing...';
        addLog('正在导出: ${item.title}');
        File? temporaryAss;
        try {
          final base = await _availableBase(directory, item.title);
          final burn = mode == MergeMode.burn && item.danmakuPath != null;
          String? subtitle;
          if (parseDanmaku && item.danmakuPath != null) {
            try {
              final xml = await File(item.danmakuPath!).readAsString();
              final result = await compute(_convertDanmaku, (
                xml,
                burn ? options.withFont(env!.fontFamily) : options,
              ));
              subtitle = result.ass;
              addLog(result.summary);
            } catch (e) {
              if (burn) rethrow;
              warnings.add('${item.title}: 弹幕转换失败，视频仍可导出');
              addLog('弹幕转换失败: $e');
            }
          }
          if (_cancelRequested) {
            cancelled++;
            _itemStatus[item.videoPath] = 'Cancelled';
            continue;
          }
          if (burn) {
            temporaryAss = File('${env!.workDir}/burn.ass');
            await temporaryAss.writeAsString(subtitle!);
            if (_cancelRequested) {
              cancelled++;
              _itemStatus[item.videoPath] = 'Cancelled';
              continue;
            }
            setItemProgress(item.videoPath, 0);
            final encoder = await FFmpegService.burnDanmaku(
              videoPath: item.videoPath,
              audioPath: item.audioPath,
              assPath: temporaryAss.path,
              outputPath: '$base.mp4',
              durationMs: item.durationMs ?? 0,
              bitrateKbps: _targetBitrateKbps(item),
              label: '(${i + 1}/${targets.length}) ${item.title}',
            );
            addLog('烧录完成(${encoder == 'h264_mediacodec' ? '硬件编码' : '软件编码'})');
          } else {
            await FFmpegService.mergeVideoAudio(
              item.videoPath,
              item.audioPath,
              '$base.mp4',
            );
            if (subtitle != null) {
              final ass = File('$base.ass');
              var created = false;
              try {
                await ass.create(exclusive: true);
                created = true;
                await ass.writeAsString(subtitle);
              } catch (e) {
                if (created) {
                  try {
                    await ass.delete();
                  } catch (_) {}
                }
                warnings.add('${item.title}: 视频已保存，外挂字幕保存失败');
                addLog('弹幕保存失败: $e');
              }
            }
          }
          success++;
          _itemStatus[item.videoPath] = 'Success';
          addLog('已保存: $base.mp4');
        } catch (e) {
          if (_cancelRequested) {
            cancelled++;
            _itemStatus[item.videoPath] = 'Cancelled';
          } else {
            failed.add(item.title);
            _itemStatus[item.videoPath] = 'Failed';
            addLog('${item.title}: $e');
          }
        } finally {
          setItemProgress(item.videoPath, null);
          if (temporaryAss != null) {
            try {
              if (await temporaryAss.exists()) await temporaryAss.delete();
            } catch (e) {
              addLog('临时字幕清理失败: $e');
            }
          }
        }
      }
      return ExportResult(
        success,
        cancelled,
        failed,
        warnings,
        _cancelRequested,
      );
    } finally {
      _finishing = true;
      notifyListeners();
      await _cancelFuture;
      FFmpegService.onBurnProgress = null;
      if (started) {
        try {
          await FFmpegService.finishSession();
        } catch (e) {
          addLog('导出会话清理失败: $e');
        }
      }
      _itemProgress.clear();
      _processing = false;
      _finishing = false;
      _cancelRequested = false;
      notifyListeners();
    }
  }

  static Future<String> _availableBase(String directory, String title) async {
    var base = p.join(directory, title);
    for (
      var index = 2;
      await FileSystemEntity.type('$base.mp4', followLinks: false) !=
              FileSystemEntityType.notFound ||
          await FileSystemEntity.type('$base.ass', followLinks: false) !=
              FileSystemEntityType.notFound;
      index++
    ) {
      base = p.join(directory, '$title ($index)');
    }
    return base;
  }

  static int _targetBitrateKbps(BiliVideoItem item) {
    try {
      final seconds = (item.durationMs ?? 0) / 1000;
      if (seconds <= 1) return 4000;
      return (File(item.videoPath).lengthSync() * 8 / seconds / 1000 * 2.5)
          .round()
          .clamp(2000, 10000);
    } catch (_) {
      return 4000;
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_processing) unawaited(cancelExport());
    super.dispose();
  }
}
