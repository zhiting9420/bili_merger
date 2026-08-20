import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 烧录前由原生侧准备好的运行环境。
class BurnEnv {
  /// 释放好的字体所在目录,原样传给 ass 滤镜的 `fontsdir=`。
  final String fontsDir;

  /// 可写的临时目录,用来放这一轮烧录的 .ass —— 烧录的产物是自带弹幕的单个 MP4,
  /// 不该在用户的输出目录里留下外挂字幕。
  final String workDir;

  /// 内置字体的家族名。ASS 样式里的 Fontname 必须与它一字不差,
  /// 否则 libass(无 fontconfig)匹配不到,汉字全变方框。
  final String fontFamily;

  const BurnEnv({
    required this.fontsDir,
    required this.workDir,
    required this.fontFamily,
  });
}

class FFmpegService {
  static const platform = MethodChannel('com.bili_merger/video');

  /// 烧录进度回调:(videoPath, 0.0~1.0)。由原生侧主动推送。
  static void Function(String videoPath, double progress)? onBurnProgress;

  static bool _handlerInstalled = false;

  static void _ensureHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    platform.setMethodCallHandler((call) async {
      if (call.method == 'burnProgress') {
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        final path = args['videoPath'] as String?;
        final progress = (args['progress'] as num?)?.toDouble();
        if (path != null && progress != null) {
          onBurnProgress?.call(path, progress);
        }
      }
      return null;
    });
  }

  static Future<bool> mergeVideoAudio(
    String videoPath,
    String audioPath,
    String outputPath,
  ) async {
    try {
      final bool result = await platform.invokeMethod('mergeVideoAudio', {
        'videoPath': videoPath,
        'audioPath': audioPath,
        'outputPath': outputPath,
      });
      return result;
    } on PlatformException catch (e) {
      debugPrint("Failed to merge video: '${e.message}'.");
      return false;
    }
  }

  /// 释放内置字体并拿到工作目录。整批烧录前调一次即可(原生侧自身做了幂等)。
  static Future<BurnEnv?> prepareBurn() async {
    try {
      _ensureHandler();
      final map = await platform.invokeMapMethod<String, String>('prepareBurn');
      if (map == null) return null;
      return BurnEnv(
        fontsDir: map['fontsDir']!,
        workDir: map['workDir']!,
        fontFamily: map['fontFamily']!,
      );
    } catch (e) {
      debugPrint("prepareBurn failed: '$e'.");
      return null;
    }
  }

  /// 把 [assPath] 的弹幕烧进画面,输出单个自带弹幕的 MP4。
  ///
  /// 返回实际使用的编码器名(`h264_mediacodec` / `libx264`),失败返回 null。
  /// 原生侧优先硬编,失败会自动用 libx264 重跑一次,这里不需要再管。
  static Future<String?> burnDanmaku({
    required String videoPath,
    required String audioPath,
    required String assPath,
    required String outputPath,
    required int durationMs,
    required int bitrateKbps,
    required String label,
  }) async {
    try {
      _ensureHandler();
      return await platform.invokeMethod<String>('burnDanmaku', {
        'videoPath': videoPath,
        'audioPath': audioPath,
        'assPath': assPath,
        'outputPath': outputPath,
        'durationMs': durationMs,
        'bitrateKbps': bitrateKbps,
        'label': label,
      });
    } on PlatformException catch (e) {
      debugPrint("Failed to burn danmaku: '${e.message}'.");
      return null;
    }
  }

  /// 整批烧录结束,撤掉前台服务与通知栏进度。
  static Future<void> finishBurnSession() async {
    try {
      await platform.invokeMethod('finishBurnSession');
    } catch (e) {
      debugPrint("finishBurnSession failed: '$e'.");
    }
  }

  /// 一批任务开始前调用,复位原生侧的取消标记。
  static Future<void> beginSession() async {
    try {
      await platform.invokeMethod('beginSession');
    } catch (e) {
      debugPrint("Failed to begin session: '$e'.");
    }
  }

  /// 中断当前正在进行的合并(结束 ffmpeg 子进程)。
  static Future<void> cancelMerge() async {
    try {
      await platform.invokeMethod('cancelMerge');
    } catch (e) {
      debugPrint("Failed to cancel merge: '$e'.");
    }
  }

  /// 抽取视频缩略图,返回缓存的图片路径(失败返回 null)。native 侧已做缓存与去重。
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
