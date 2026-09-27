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
    final items = <BiliVideoItem>[];
    final usedTitles = <String>{};

    Future<void> visit(Directory dir, {bool isRoot = false}) async {
      final List<FileSystemEntity> children;
      try {
        children = await dir.list(followLinks: false).toList();
      } on FileSystemException catch (e) {
        if (isRoot) rethrow;
        debugPrint("跳过无法读取的目录 ${dir.path}: $e");
        return;
      }
      // 文件系统不保证枚举顺序。排序后，同一缓存总会分配到相同的去重标题。
      children.sort((a, b) => a.path.compareTo(b.path));
      for (final entity in children) {
        if (entity is Directory) {
          await visit(entity);
          continue;
        }
        if (entity is! File || p.basename(entity.path) != 'video.m4s') continue;
        try {
          final audioPath = p.join(entity.parent.path, 'audio.m4s');
          if (await FileSystemEntity.type(audioPath, followLinks: false) !=
              FileSystemEntityType.file) {
            continue;
          }
          // Android 缓存: 分集/entry.json、分集/清晰度/video.m4s。
          final episodeDir = entity.parent.parent;
          final folderId = _safeTitle(p.basename(episodeDir.path), 'unknown');
          final entry = File(p.join(episodeDir.path, 'entry.json'));
          var title = "Untitled_$folderId";
          int? durationMs;
          if (await entry.exists()) {
            try {
              final json = jsonDecode(await entry.readAsString());
              if (json is Map) {
                title = _buildTitle(json, folderId);
                final duration = json['total_time_milli'];
                if (duration is num && duration.isFinite && duration > 0) {
                  durationMs = duration.toInt();
                }
              }
            } on FormatException catch (e) {
              debugPrint("无法解析 $entry: $e");
            } on FileSystemException catch (e) {
              debugPrint("无法读取 $entry: $e");
            }
          }
          final danmaku = File(p.join(episodeDir.path, 'danmaku.xml'));
          items.add(
            BiliVideoItem(
              title: _ensureUnique(title, folderId, usedTitles),
              videoPath: entity.path,
              audioPath: audioPath,
              danmakuPath: await danmaku.exists() ? danmaku.path : null,
              durationMs: durationMs,
            ),
          );
        } on FileSystemException catch (e) {
          debugPrint("跳过无法读取的缓存 ${entity.path}: $e");
        }
      }
    }

    // 根目录错误由界面明确报告，不能伪装成“扫描成功、零个项目”。
    await visit(Directory(rootPath), isRoot: true);
    return items;
  }

  // 为扩展名、去重序号与导出临时文件预留空间；UTF-8 截断不拆开汉字。
  static const int _maxTitleBytes = 180;

  static String _truncate(String value, int maxBytes) {
    final result = StringBuffer();
    var bytes = 0;
    for (final rune in value.runes) {
      final char = String.fromCharCode(rune);
      final length = utf8.encode(char).length;
      if (bytes + length > maxBytes) break;
      result.write(char);
      bytes += length;
    }
    return result.toString().replaceFirst(RegExp(r'[ .]+$'), '');
  }

  static String _safeTitle(String value, String fallback) {
    final sanitized = value
        .replaceAll(RegExp(r'[ \/\\:*?"<>|\x00-\x1F\x7F]'), '_')
        .trim()
        .replaceFirst(RegExp(r'[ .]+$'), '');
    return _truncate(sanitized.isEmpty ? fallback : sanitized, _maxTitleBytes);
  }

  static String? _text(dynamic value) => value is String ? value.trim() : null;

  // 从 entry.json 构造标题:总标题 + 分P/分集名(存在且与总标题不同才拼接)
  static String _buildTitle(dynamic json, String folderId) {
    final rawTitle = _text(json['title']);
    final String base = (rawTitle != null && rawTitle.isNotEmpty)
        ? rawTitle
        : "Untitled_$folderId";

    String? part;
    // UGC 多P:page_data.part / page_data.page
    final pageData = json['page_data'];
    if (pageData is Map) {
      final partName = _text(pageData['part']);
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
      final idxTitle = _text(ep['index_title']);
      final segs = [
        idx,
        idxTitle,
      ].where((e) => e != null && e.isNotEmpty).cast<String>();
      if (segs.isNotEmpty) part = segs.join('_');
    }

    final full = (part != null && part.isNotEmpty) ? "${base}_$part" : base;
    return _safeTitle(full, "Untitled_$folderId");
  }

  // 保证标题唯一,避免同名覆盖:先追加唯一目录ID,仍冲突再加序号
  static String _ensureUnique(String title, String folderId, Set<String> used) {
    title = _safeTitle(title, 'Untitled');
    if (used.add(title)) return title;
    final id = _truncate(folderId, 40);
    var n = 1;
    while (true) {
      final suffix = n == 1 ? "_$id" : "${id.isEmpty ? '' : '_$id'}_$n";
      final candidate =
          "${_truncate(title, _maxTitleBytes - utf8.encode(suffix).length)}$suffix";
      if (used.add(candidate)) return candidate;
      n++;
    }
  }
}
