import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class FFmpegService {
  static const platform = MethodChannel('com.bili_merger/video');

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
