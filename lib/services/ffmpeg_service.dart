import 'package:flutter/services.dart';

class FFmpegService {
  static const platform = MethodChannel('com.bili_merger/video');

  static Future<bool> mergeVideoAudio(String videoPath, String audioPath, String outputPath) async {
    try {
      final bool result = await platform.invokeMethod('mergeVideoAudio', {
        'videoPath': videoPath,
        'audioPath': audioPath,
        'outputPath': outputPath,
      });
      return result;
    } on PlatformException catch (e) {
      print("Failed to merge video: '${e.message}'.");
      return false;
    }
  }
}
