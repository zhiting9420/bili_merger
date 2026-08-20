import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';

class BiliVideoItem {
  final String title;
  final String videoPath;
  final String audioPath;
  final String? danmakuPath;
  final int? durationMs; // 视频时长(毫秒),来自 entry.json

  BiliVideoItem({
    required this.title,
    required this.videoPath,
    required this.audioPath,
    this.danmakuPath,
    this.durationMs,
  });
}

class BiliScanner {
  static Future<List<BiliVideoItem>> scanDirectory(String rootPath) async {
    final List<BiliVideoItem> items = [];
    final Set<String> usedTitles = {}; // 防止多P/合集同名导致输出文件互相覆盖
    final dir = Directory(rootPath);

    if (!await dir.exists()) return [];

    // Use BFS or DFS to traverse.
    // Since we are looking for specific files, recursive list is easiest but might be slow on huge dirs.
    // Optimization: We know structure is usually number/entry.json + number/quality/video.m4s
    // But let's stick to the user's find script logic: find "$BASE_DIR" -name "video.m4s"

    try {
      final List<FileSystemEntity> entities = await dir
          .list(recursive: true)
          .toList();

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

            final String folderId = p.basename(grandParentDir.path);
            String title;
            int? durationMs;

            if (await File(entryJsonPath).exists()) {
              try {
                final content = await File(entryJsonPath).readAsString();
                final json = jsonDecode(content);
                title = _buildTitle(json, folderId);
                durationMs = (json['total_time_milli'] as num?)?.toInt();
              } catch (e) {
                debugPrint("Error reading entry.json: $e");
                title = "Untitled_$folderId";
              }
            } else {
              title = "Untitled_$folderId";
            }

            // 多P/合集的顶层标题相同,若不去重会生成同名 mp4 互相覆盖
            title = _ensureUnique(title, folderId, usedTitles);

            final hasDanmaku = await File(danmakuXmlPath).exists();
            items.add(
              BiliVideoItem(
                title: title,
                videoPath: videoFile.path,
                audioPath: audioPath,
                danmakuPath: hasDanmaku ? danmakuXmlPath : null,
                durationMs: durationMs,
              ),
            );
          }
        }
      }
    } catch (e) {
      debugPrint("Scan error: $e");
    }

    return items;
  }

  // 替换文件名非法字符
  static String _sanitize(String s) =>
      s.replaceAll(RegExp(r'[ \/\\:*?"<>|]'), '_').trim();

  // 从 entry.json 构造标题:总标题 + 分P/分集名(存在且与总标题不同才拼接)
  static String _buildTitle(dynamic json, String folderId) {
    final rawTitle = (json['title'] as String?)?.trim();
    final String base = (rawTitle != null && rawTitle.isNotEmpty)
        ? rawTitle
        : "Untitled_$folderId";

    String? part;
    // UGC 多P:page_data.part / page_data.page
    final pageData = json['page_data'];
    if (pageData is Map) {
      final partName = (pageData['part'] as String?)?.trim();
      final page = pageData['page'];
      if (partName != null && partName.isNotEmpty && partName != base) {
        part = partName;
      } else if (page != null && page.toString() != '1') {
        part = 'P$page';
      }
    }
    // 番剧/合集:ep.index + ep.index_title
    final ep = json['ep'];
    if (part == null && ep is Map) {
      final idx = ep['index']?.toString().trim();
      final idxTitle = (ep['index_title'] as String?)?.trim();
      final segs = [
        idx,
        idxTitle,
      ].where((e) => e != null && e.isNotEmpty).cast<String>();
      if (segs.isNotEmpty) part = segs.join('_');
    }

    final full = (part != null && part.isNotEmpty) ? "${base}_$part" : base;
    return _sanitize(full);
  }

  // 保证标题唯一,避免同名覆盖:先追加唯一目录ID,仍冲突再加序号
  static String _ensureUnique(String title, String folderId, Set<String> used) {
    if (!used.contains(title)) {
      used.add(title);
      return title;
    }
    String candidate = "${title}_$folderId";
    int n = 2;
    while (used.contains(candidate)) {
      candidate = "${title}_${folderId}_$n";
      n++;
    }
    used.add(candidate);
    return candidate;
  }
}
