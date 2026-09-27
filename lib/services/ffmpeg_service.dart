import 'package:flutter/services.dart';

class BurnEnv {
  final String workDir;
  final String fontFamily;
  const BurnEnv({required this.workDir, required this.fontFamily});
}

/// MethodChannel 错误交给批处理统一显示和清理，不在这里吞掉。
class FFmpegService {
  static const platform = MethodChannel('com.bili_merger/video');
  static void Function(String videoPath, double progress)? onBurnProgress;

  static Future<void> beginSession({required String label}) async {
    platform.setMethodCallHandler((call) async {
      if (call.method == 'burnProgress' && call.arguments is Map) {
        final args = call.arguments as Map;
        final path = args['videoPath'];
        final progress = args['progress'];
        if (path is String && progress is num && progress.isFinite) {
          onBurnProgress?.call(path, progress.toDouble());
        }
      }
    });
    await platform.invokeMethod<void>('beginSession', {'label': label});
  }

  static Future<void> finishSession() =>
      platform.invokeMethod<void>('finishSession');
  static Future<void> cancelMerge() =>
      platform.invokeMethod<void>('cancelMerge');

  static Future<void> mergeVideoAudio(
    String videoPath,
    String audioPath,
    String outputPath,
  ) async {
    final success = await platform.invokeMethod<bool>('mergeVideoAudio', {
      'videoPath': videoPath,
      'audioPath': audioPath,
      'outputPath': outputPath,
    });
    if (success != true) throw StateError('合并未完成');
  }

  static Future<BurnEnv> prepareBurn() async {
    final map = await platform.invokeMapMethod<String, String>('prepareBurn');
    final workDir = map?['workDir'];
    final fontFamily = map?['fontFamily'];
    if (workDir == null || fontFamily == null) throw StateError('烧录环境准备失败');
    return BurnEnv(workDir: workDir, fontFamily: fontFamily);
  }

  static Future<String> burnDanmaku({
    required String videoPath,
    required String audioPath,
    required String assPath,
    required String outputPath,
    required int durationMs,
    required int bitrateKbps,
    required String label,
  }) async {
    final encoder = await platform.invokeMethod<String>('burnDanmaku', {
      'videoPath': videoPath,
      'audioPath': audioPath,
      'assPath': assPath,
      'outputPath': outputPath,
      'durationMs': durationMs,
      'bitrateKbps': bitrateKbps,
      'label': label,
    });
    if (encoder == null) throw StateError('烧录未完成');
    return encoder;
  }

  static Future<String?> extractThumbnail(String videoPath) async {
    try {
      return await platform.invokeMethod<String>('extractThumbnail', {
        'videoPath': videoPath,
      });
    } catch (_) {
      return null;
    }
  }
}
