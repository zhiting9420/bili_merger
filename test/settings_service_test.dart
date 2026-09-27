import 'package:bili_merger/services/settings_service.dart';
import 'package:bili_merger/utils/xml_to_ass.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('preference load failure leaves usable default settings', (
    tester,
  ) async {
    SharedPreferences.resetStatic();
    const channel = MethodChannel('plugins.flutter.io/shared_preferences');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'unavailable'),
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    final settings = SettingsService();
    addTearDown(settings.dispose);

    await tester.pump();

    expect(settings.isInitialized, isTrue);
    expect(settings.fontSize, 50);
    settings.speed = 1.5;
    expect(settings.danmakuOptions.duration, closeTo(10 / 1.5, 0.001));
    settings.resetToDefaults();
    expect(settings.speed, 1.25);
  });

  testWidgets('malformed preference types fall back independently', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'parse_danmaku': 'false',
      'font_size': 'large',
      'opacity': false,
      'danmaku_filter': 'all',
      'danmaku_speed': 2,
      'bold': true,
    });
    final settings = SettingsService();
    addTearDown(settings.dispose);

    await tester.pump();

    expect(settings.isInitialized, isTrue);
    expect(settings.parseDanmaku, isTrue);
    expect(settings.fontSize, 50);
    expect(settings.opacity, 0.8);
    expect(settings.filter, DanmakuFilter.all);
    expect(settings.speed, 2);
    expect(settings.bold, isTrue);
  });

  testWidgets(
    'restored values stay within controls and finite ASS parameters',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'font_size': 500,
        'danmaku_speed': 0.0,
        'opacity': 1.5,
        'duration': double.infinity,
        'area': 0.4,
      });
      final settings = SettingsService();
      addTearDown(settings.dispose);

      await tester.pump();

      expect(settings.fontSize, 100);
      expect(settings.speed, 0.5);
      expect(settings.opacity, 1);
      expect(settings.duration, 10);
      expect(settings.area, 0.5);
      expect(settings.danmakuOptions.duration.isFinite, isTrue);
    },
  );

  testWidgets('setters normalize invalid numbers before storing them', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    addTearDown(settings.dispose);
    await tester.pump();

    settings.fontSize = -5;
    settings.speed = double.nan;
    settings.opacity = double.negativeInfinity;
    settings.duration = -2;
    settings.area = 0.3;

    expect(settings.fontSize, 20);
    expect(settings.speed, 1.25);
    expect(settings.opacity, 0.8);
    expect(settings.duration, 10);
    expect(settings.area, 0.5);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('font_size'), 20);
    expect(prefs.getDouble('danmaku_speed'), 1.25);
    expect(prefs.getDouble('opacity'), 0.8);
  });

  testWidgets(
    'disposing during initialization does not notify a dead service',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      SettingsService().dispose();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('burn export keeps user parameters and overrides only its font', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'font_size': 64,
      'font_name': '思源黑体',
      'duration': 12.0,
      'danmaku_speed': 1.5,
      'opacity': 0.6,
      'area': 0.75,
      'bold': true,
      'no_overlap': false,
      'danmaku_filter': DanmakuFilter.featured.index,
      'danmaku_dedupe': false,
    });
    final settings = SettingsService();
    addTearDown(settings.dispose);
    await tester.pump();

    for (final options in [
      settings.danmakuOptions,
      settings.burnDanmakuOptions('Bundled Font'),
    ]) {
      expect(options.fontSize, 64);
      expect(options.duration, 8);
      expect(options.opacity, 0.6);
      expect(options.area, 0.75);
      expect(options.bold, isTrue);
      expect(options.noOverlap, isFalse);
      expect(options.filter, DanmakuFilter.featured);
      expect(options.dedupe, isFalse);
    }
    expect(settings.danmakuOptions.fontName, '思源黑体');
    expect(
      settings.burnDanmakuOptions('Bundled Font').fontName,
      'Bundled Font',
    );
  });
}
