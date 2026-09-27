import 'dart:convert';
import 'dart:io';
import 'package:bili_merger/utils/bili_scanner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('bili-scanner-test-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  Future<void> cache(String id, Map<String, Object?> metadata) async {
    final media = Directory('${root.path}/$id/80');
    await media.create(recursive: true);
    await File('${media.path}/video.m4s').writeAsBytes([0]);
    await File('${media.path}/audio.m4s').writeAsBytes([0]);
    await File(
      '${root.path}/$id/entry.json',
    ).writeAsString(jsonEncode(metadata));
  }

  test('long titles remain writable and distinct after truncation', () async {
    for (final id in ['1', '2']) {
      await cache(id, {
        'title': '主' * 70,
        'page_data': {'part': '分' * 70},
      });
    }
    final found = await BiliScanner.scanDirectory(root.path);
    expect(found, hasLength(2));
    expect(found.map((item) => item.title).toSet(), hasLength(2));
    for (final item in found) {
      expect(utf8.encode(item.title).length, lessThanOrEqualTo(180));
      await File('${root.path}/${item.title}.mp4').writeAsBytes([0]);
    }
  });

  test(
    'titles remove controls and trailing dots with a nonempty fallback',
    () async {
      await cache('1', {'title': '名字\u0000\n...'});
      await cache('2', {'title': '...'});
      final found = await BiliScanner.scanDirectory(root.path);
      for (final item in found) {
        expect(item.title, isNotEmpty);
        expect(item.title, isNot(matches(RegExp(r'[\x00-\x1F\x7F]'))));
        expect(item.title.endsWith('.'), isFalse);
        await File('${root.path}/${item.title}.mp4').writeAsBytes([0]);
      }
    },
  );

  test('invalid optional duration does not erase a valid title', () async {
    await cache('1', {'title': '有效标题', 'total_time_milli': 'broken'});
    final item = (await BiliScanner.scanDirectory(root.path)).single;
    expect(item.title, '有效标题');
    expect(item.durationMs, isNull);
  });

  test(
    'unreadable child does not hide valid sibling caches',
    () async {
      await cache('1', {'title': '有效'});
      final blocked = await Directory('${root.path}/blocked').create();
      await Process.run('chmod', ['000', blocked.path]);
      try {
        expect(await BiliScanner.scanDirectory(root.path), hasLength(1));
      } finally {
        await Process.run('chmod', ['700', blocked.path]);
      }
    },
    skip: Platform.isWindows,
  );

  test('missing root reports a scan failure', () async {
    await expectLater(
      BiliScanner.scanDirectory('${root.path}/missing'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('scanner ignores symlinks outside the selected tree', () async {
    final external = await Directory.systemTemp.createTemp('bili-external-');
    try {
      await File('${external.path}/video.m4s').writeAsBytes([0]);
      await File('${external.path}/audio.m4s').writeAsBytes([0]);
      await Link('${root.path}/linked').create(external.path);
      expect(await BiliScanner.scanDirectory(root.path), isEmpty);
    } finally {
      await external.delete(recursive: true);
    }
  }, skip: Platform.isWindows);

  test(
    'same titles get stable names independent of directory creation order',
    () async {
      await cache('2', {'title': '相同'});
      await cache('1', {'title': '相同'});
      final found = await BiliScanner.scanDirectory(root.path);
      expect(found.first.videoPath, contains('/1/80/video.m4s'));
      expect(found.map((item) => item.title), ['相同', '相同_2']);
    },
  );
}
