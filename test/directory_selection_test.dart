import 'dart:io';
import 'package:bili_merger/app_state.dart';
import 'package:bili_merger/main.dart';
import 'package:bili_merger/services/ffmpeg_service.dart';
import 'package:bili_merger/widgets/directory_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Future<void> finishIo(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

void main() {
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  late Directory root;
  late AppState state;
  late bool granted;
  late int requests;
  setUp(() {
    root = Directory.systemTemp.createTempSync('bili-picker-');
    Directory('${root.path}/Download').createSync();
    state = AppState();
    granted = true;
    requests = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          FFmpegService.platform,
          (call) async => call.method == 'storageInfo'
              ? {
                  'sdk': 37,
                  'roots': [root.path],
                }
              : null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissions, (call) async {
          if (call.method == 'checkPermissionStatus') return granted ? 1 : 0;
          if (call.method == 'requestPermissions') {
            requests++;
            return {22: 0};
          }
          throw StateError('Unexpected permission call: ${call.method}');
        });
  });
  tearDown(() {
    state.dispose();
    root.deleteSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FFmpegService.platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissions, null);
  });
  Future<void> openHome(WidgetTester tester) => tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: const MaterialApp(home: HomeView()),
    ),
  );

  testWidgets(
    'granted all-files permission selects Download directly and cleans write probe',
    (tester) async {
      await openHome(tester);
      await tester.tap(find.text('输出目录'));
      await finishIo(tester);
      expect(find.byType(LocalDirectoryPicker), findsOneWidget);
      expect(requests, 0);
      await tester.tap(find.text('Download'));
      await finishIo(tester);
      await tester.tap(find.text('选择此文件夹'));
      await finishIo(tester);
      expect(state.outputDir, '${root.path}/Download');
      expect(state.busy, isFalse);
      expect(Directory(state.outputDir!).listSync(), isEmpty);
    },
  );

  testWidgets('cancel unlocks selection and storage root can be selected', (
    tester,
  ) async {
    await openHome(tester);
    await tester.tap(find.text('输入目录'));
    await finishIo(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(state.busy, isFalse);
    await tester.tap(find.text('输出目录'));
    await finishIo(tester);
    await tester.tap(find.text('选择此文件夹'));
    await finishIo(tester);
    expect(state.outputDir, root.path);
    expect(state.busy, isFalse);
  });

  testWidgets(
    'denied permission shows error and permits retry after granting',
    (tester) async {
      granted = false;
      await openHome(tester);
      await tester.tap(find.text('输出目录'));
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(state.busy, isFalse);
      expect(find.textContaining('需要开启所有文件访问权限'), findsOneWidget);
      granted = true;
      await tester.tap(find.text('输出目录'));
      await finishIo(tester);
      expect(find.byType(LocalDirectoryPicker), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'missing directory cannot be selected and parent navigation recovers',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: LocalDirectoryPicker(
            roots: [root.path],
            initialPath: '${root.path}/missing',
          ),
        ),
      );
      await finishIo(tester);
      expect(find.textContaining('无法读取此文件夹'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('上一级'));
      await finishIo(tester);
      expect(find.text('Download'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    },
  );
}
