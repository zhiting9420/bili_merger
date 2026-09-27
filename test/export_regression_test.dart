import 'dart:async';
import 'dart:io';

import 'package:bili_merger/main.dart';
import 'package:bili_merger/app_state.dart';
import 'package:bili_merger/services/ffmpeg_service.dart';
import 'package:bili_merger/services/settings_service.dart';
import 'package:bili_merger/utils/bili_scanner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('repeat export preserves an existing MP4 and ASS', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('bili-export-test-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final existing = File('${dir.path}/sample.mp4');
    existing.writeAsStringSync('previous video');
    File('${dir.path}/sample.ass').writeAsStringSync('previous subtitle');
    SharedPreferences.setMockInitialValues({'parse_danmaku': false});
    final settings = SettingsService();
    final state = AppState()
      ..outputDir = dir.path
      ..items = [
        BiliVideoItem(
          title: 'sample',
          videoPath: '/video',
          audioPath: '/audio',
        ),
      ];
    final mergeCalled = Completer<String>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FFmpegService.platform, (call) async {
          if (call.method == 'mergeVideoAudio') {
            mergeCalled.complete(
              (call.arguments as Map)['outputPath'] as String,
            );
            return true;
          }
          if (call.method == 'extractThumbnail') return null;
          return true;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FFmpegService.platform, null);
      state.dispose();
      settings.dispose();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: state),
          ChangeNotifierProvider.value(value: settings),
        ],
        child: const MaterialApp(home: HomeView()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('合并选中 1 个'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('快速合并'));
    for (
      var i = 0;
      i < 100 && (!mergeCalled.isCompleted || state.processing);
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(mergeCalled.isCompleted, isTrue, reason: state.logs.join('\n'));
    final output = await mergeCalled.future;
    await tester.pumpAndSettle();
    expect(output, isNot(existing.path));
    expect(existing.readAsStringSync(), 'previous video');
  });
}
