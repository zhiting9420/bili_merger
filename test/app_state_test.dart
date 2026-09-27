import 'dart:async';
import 'dart:io';

import 'package:bili_merger/app_state.dart';
import 'package:bili_merger/services/ffmpeg_service.dart';
import 'package:bili_merger/utils/bili_scanner.dart';
import 'package:bili_merger/utils/xml_to_ass.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppState state;
  late List<String> calls;
  late Future<Object?> Function(MethodCall) handler;

  BiliVideoItem item(String title, {String? xml}) => BiliVideoItem(
    title: title,
    videoPath: '${directory.path}/$title-video.m4s',
    audioPath: '${directory.path}/$title-audio.m4s',
    danmakuPath: xml,
  );
  Future<ExportResult> run({
    MergeMode mode = MergeMode.fast,
    bool subtitles = true,
  }) => state.export(
    mode: mode,
    parseDanmaku: subtitles,
    options: const DanmakuOptions(),
  );

  Future<Object?> native(MethodCall call) async {
    if (call.method == 'prepareBurn') {
      return {'workDir': directory.path, 'fontFamily': 'BiliDanmaku'};
    }
    if (call.method == 'mergeVideoAudio' || call.method == 'burnDanmaku') {
      await File(
        (call.arguments as Map)['outputPath'] as String,
      ).writeAsString('exported video');
      return call.method == 'burnDanmaku' ? 'libx264' : true;
    }
    return null;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bili-state-');
    state = AppState()..outputDir = directory.path;
    calls = [];
    handler = native;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FFmpegService.platform, (call) async {
          calls.add(call.method);
          return handler(call);
        });
  });
  tearDown(() async {
    state.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FFmpegService.platform, null);
    await directory.delete(recursive: true);
  });

  test('rescan clears old success status and stale progress', () async {
    final video = item('one');
    state.items = [video];
    expect((await run()).success, 1);
    expect(state.itemStatus[video.videoPath], 'Success');
    state.items = [video];
    state.setItemProgress(video.videoPath, 0.8);
    expect(state.itemStatus, isEmpty);
    expect(state.itemProgress, isEmpty);
  });

  test(
    'existing subtitle reserves the pair name and preserves old content',
    () async {
      final previous = File('${directory.path}/one.ass');
      await previous.writeAsString('previous subtitle');
      state.items = [item('one')];
      expect((await run()).success, 1);
      expect(await previous.readAsString(), 'previous subtitle');
      expect(
        await File('${directory.path}/one (2).mp4').readAsString(),
        'exported video',
      );
      expect(await File('${directory.path}/one.mp4').exists(), isFalse);
    },
  );

  test('failed video leaves no subtitle and next video still runs', () async {
    final xml = File('${directory.path}/danmaku.xml');
    await xml.writeAsString('<i><d p="1,1,25,16777215">test</d></i>');
    state.items = [item('bad', xml: xml.path), item('good')];
    handler = (call) async {
      if (call.method == 'mergeVideoAudio' &&
          (call.arguments as Map)['videoPath'].toString().contains('/bad-')) {
        throw PlatformException(code: 'EXPORT_ERROR', message: 'broken input');
      }
      return native(call);
    };
    final result = await run();
    expect(result.success, 1);
    expect(result.failed, ['bad']);
    expect(await File('${directory.path}/bad.ass').exists(), isFalse);
    expect(state.processing, isFalse);
    expect(calls.last, 'finishSession');
    expect(state.logs.any((line) => line.contains('broken input')), isTrue);
  });

  test(
    'begin failure unlocks state without finishing an unowned session',
    () async {
      state.items = [item('one')];
      handler = (call) async {
        if (call.method == 'beginSession') {
          throw PlatformException(code: 'BUSY');
        }
        return native(call);
      };
      await expectLater(run(), throwsA(isA<PlatformException>()));
      expect(state.processing, isFalse);
      expect(calls, ['beginSession']);
      handler = native;
      expect((await run()).success, 1);
    },
  );

  test(
    'prepare failure still finishes the session and unlocks controls',
    () async {
      state.items = [item('one', xml: '/unused.xml')];
      handler = (call) async {
        if (call.method == 'prepareBurn') {
          throw PlatformException(code: 'FONT_ERROR');
        }
        return native(call);
      };
      await expectLater(
        run(mode: MergeMode.burn),
        throwsA(isA<PlatformException>()),
      );
      expect(state.processing, isFalse);
      expect(state.itemProgress, isEmpty);
      expect(FFmpegService.onBurnProgress, isNull);
      expect(calls.last, 'finishSession');
    },
  );

  test(
    'cancel during preparation skips export and permits a fresh batch',
    () async {
      final preparing = Completer<void>();
      final prepared = Completer<Object?>();
      state.items = [item('one', xml: '/unused.xml'), item('two')];
      handler = (call) async {
        if (call.method == 'prepareBurn') {
          preparing.complete();
          return prepared.future;
        }
        return native(call);
      };
      final pending = run(mode: MergeMode.burn);
      await preparing.future;
      await state.cancelExport();
      prepared.complete({
        'workDir': directory.path,
        'fontFamily': 'BiliDanmaku',
      });
      final result = await pending;
      expect(result.wasCancelled, isTrue);
      expect(result.cancelled, 2);
      expect(result.failed, isEmpty);
      expect(calls, isNot(contains('mergeVideoAudio')));
      expect(calls, isNot(contains('burnDanmaku')));
      handler = native;
      state.items = [item('retry')];
      expect((await run()).success, 1);
    },
  );

  test('controls remain locked until an in-flight cancel finishes', () async {
    final merging = Completer<void>();
    final merged = Completer<Object?>();
    final cancelDone = Completer<void>();
    state.items = [item('one')];
    handler = (call) async {
      if (call.method == 'mergeVideoAudio') {
        merging.complete();
        return merged.future;
      }
      if (call.method == 'cancelMerge') {
        await cancelDone.future;
        return null;
      }
      return native(call);
    };
    final pending = run();
    await merging.future;
    final cancellation = state.cancelExport();
    merged.completeError(PlatformException(code: 'CANCELLED'));
    await Future<void>.delayed(Duration.zero);
    expect(state.processing, isTrue);
    await expectLater(run(), throwsStateError);
    cancelDone.complete();
    await cancellation;
    final result = await pending;
    expect(result.cancelled, 1);
    expect(state.processing, isFalse);
  });

  test(
    'invalid XML reports a subtitle warning in fast mode and fails burn mode',
    () async {
      final xml = File('${directory.path}/danmaku.xml');
      await xml.writeAsString('<broken');
      state.items = [item('fast', xml: xml.path)];
      final result = await run();
      expect(result.success, 1);
      expect(result.warnings, hasLength(1));
      expect(await File('${directory.path}/fast.ass').exists(), isFalse);
      state.items = [item('burn', xml: xml.path)];
      final burn = await run(mode: MergeMode.burn);
      expect(burn.success, 0);
      expect(burn.failed, ['burn']);
      expect(await File('${directory.path}/burn.mp4').exists(), isFalse);
    },
  );
  test(
    'finishing a batch rejects late cancellation before a new batch',
    () async {
      final finishing = Completer<void>();
      final finished = Completer<void>();
      state.items = [item('one')];
      handler = (call) async {
        if (call.method == 'finishSession') {
          finishing.complete();
          await finished.future;
          return null;
        }
        return native(call);
      };
      final pending = run();
      await finishing.future;
      await state.cancelExport();
      expect(calls, isNot(contains('cancelMerge')));
      expect(state.canCancel, isFalse);
      expect(state.processing, isTrue);
      finished.complete();
      expect((await pending).success, 1);
      expect(state.processing, isFalse);
    },
  );
}
