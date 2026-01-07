import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;

class BiliVideoItem {
  final String title;
  final String videoPath;
  final String audioPath;
  final String? danmakuPath;
  final String outputPath; // Desired output path for mp4
  final String? assPath;   // Desired output path for ass

  BiliVideoItem({
    required this.title,
    required this.videoPath,
    required this.audioPath,
    this.danmakuPath,
    required this.outputPath,
    this.assPath,
  });
}

class BiliScanner {
  static Future<List<BiliVideoItem>> scanDirectory(String rootPath, String outputDir) async {
    final List<BiliVideoItem> items = [];
    final dir = Directory(rootPath);

    if (!await dir.exists()) return [];

    // Use BFS or DFS to traverse. 
    // Since we are looking for specific files, recursive list is easiest but might be slow on huge dirs.
    // Optimization: We know structure is usually number/entry.json + number/quality/video.m4s
    // But let's stick to the user's find script logic: find "$BASE_DIR" -name "video.m4s"

    try {
      final List<FileSystemEntity> entities = await dir.list(recursive: true).toList();
      
      for (var entity in entities) {
        if (entity is File && p.basename(entity.path) == 'video.m4s') {
          final videoFile = entity;
          final parentDir = videoFile.parent;
          
          final audioPath = p.join(parentDir.path, 'audio.m4s');
          if (await File(audioPath).exists()) {
            // Found a pair
             
            // Try to find metadata in grandparent (standard android download structure)
            // parent = '80' (quality), grandparent = '123456' (avid/epid)
            // entry.json usually in grandparent or parent?
            // User script: cd "$current_dir" (where video is) -> then entry_json="../entry.json"
            // So entry.json is in grandparent of video.m4s.
            
            final grandParentDir = parentDir.parent;
            final entryJsonPath = p.join(grandParentDir.path, 'entry.json');
            final danmakuXmlPath = p.join(grandParentDir.path, 'danmaku.xml');
            
            String title = "Unknown_${grandParentDir.path.split(Platform.pathSeparator).last}";
            
            if (await File(entryJsonPath).exists()) {
               try {
                 final content = await File(entryJsonPath).readAsString();
                 final json = jsonDecode(content);
                 final rawTitle = json['title'] as String?;
                 if (rawTitle != null && rawTitle.isNotEmpty) {
                   title = rawTitle.replaceAll(RegExp(r'[ \/\\:*?"<>|]'), '_');
                 }
               } catch (e) {
                 print("Error reading entry.json: $e");
               }
            } else {
               // Fallback title
                title = "Untitled_${grandParentDir.path.split(Platform.pathSeparator).last}";
            }
            
            items.add(BiliVideoItem(
              title: title,
              videoPath: videoFile.path,
              audioPath: audioPath,
              danmakuPath: (await File(danmakuXmlPath).exists()) ? danmakuXmlPath : null,
              outputPath: p.join(outputDir, "$title.mp4"),
              assPath: (await File(danmakuXmlPath).exists()) ? p.join(outputDir, "$title.ass") : null,
            ));
          }
        }
      }
    } catch (e) {
      print("Scan error: $e");
    }

    return items;
  }
}
