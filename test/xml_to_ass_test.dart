import 'package:bili_merger/utils/xml_to_ass.dart';
import 'package:flutter_test/flutter_test.dart';

String xml(List<String> nodes) => '<i>${nodes.join()}</i>';
String d(String time, String text, {int mode = 1, int color = 16777215}) =>
    '<d p="$time,$mode,25,$color">$text</d>';
List<String> events(DanmakuResult result) => result.ass
    .split('\n')
    .where((line) => line.startsWith('Dialogue:'))
    .toList();

void main() {
  test('opposite directions cannot meet on an occupied track', () {
    final result = XmlToAssConverter.convertWithStats(
      xml([d('0', '甲'), d('1', '乙', mode: 6)]),
      options: const DanmakuOptions(area: 0.25),
    );
    final tracks = events(result)
        .map(
          (line) => RegExp(r'\\move\([^,]+,(\d+),').firstMatch(line)!.group(1),
        )
        .toList();
    expect(result.kept, 2);
    expect(tracks.toSet(), hasLength(2));
  });

  test('opposite directions reuse a track only after the previous exit', () {
    final result = XmlToAssConverter.convertWithStats(
      xml([d('0', '甲'), d('1', '乙', mode: 6), d('20', '丙', mode: 6)]),
      options: const DanmakuOptions(area: 0.06),
    );
    expect(result.kept, 2);
    expect(result.overflow, 1);
    expect(events(result).last, endsWith('丙'));
  });

  test(
    'same direction comments can reuse a track before the previous exit',
    () {
      final result = XmlToAssConverter.convertWithStats(
        xml([d('0', '甲'), d('1', '乙')]),
        options: const DanmakuOptions(area: 0.06),
      );
      expect(result.kept, 2);
      expect(result.overflow, 0);
    },
  );

  test('dedupe retains earliest timestamp regardless of XML order', () {
    final result = XmlToAssConverter.convertWithStats(
      xml([d('10', '相同'), d('1', '相同')]),
    );
    expect(events(result).single, contains(',0:00:01.00,'));
    expect(result.deduped, 1);
  });

  test('bad timestamps do not discard valid comments', () {
    final result = XmlToAssConverter.convertWithStats(
      xml([
        d('1', '有效'),
        d('NaN', '坏时间一'),
        d('Infinity', '坏时间二'),
        d('-1', '坏时间三'),
        d('invalid', '坏时间四'),
      ]),
    );
    expect(result.kept, 1);
    expect(result.filtered, 4);
    expect(events(result).single, endsWith('有效'));
  });

  test('malformed XML reports failure instead of empty successful ASS', () {
    expect(
      () => XmlToAssConverter.convertWithStats('<i><d>'),
      throwsA(isA<Exception>()),
    );
    expect(XmlToAssConverter.convertWithStats('<i/>').kept, 0);
  });

  test('escaped full width characters determine the rendered width', () {
    final result = XmlToAssConverter.convertWithStats(xml([d('0', r'{\}')]));
    expect(events(result).single, contains('｛＼｝'));
    final endpoint = int.parse(
      RegExp(
        r'\\move\(1920,\d+,(-\d+),',
      ).firstMatch(events(result).single)!.group(1)!,
    );
    expect(-endpoint, greaterThanOrEqualTo(150));
  });

  test('wide Latin letters are not estimated as half a font size', () {
    final result = XmlToAssConverter.convertWithStats(xml([d('0', 'WWWW')]));
    final endpoint = int.parse(
      RegExp(
        r'\\move\(1920,\d+,(-\d+),',
      ).firstMatch(events(result).single)!.group(1)!,
    );
    expect(-endpoint, greaterThanOrEqualTo(180));
  });

  test('opacity applies to outlines as well as the fill', () {
    final result = XmlToAssConverter.convertWithStats(
      '<i/>',
      options: const DanmakuOptions(opacity: 0),
    );
    final style = result.ass
        .split('\n')
        .firstWhere((line) => line.startsWith('Style: Roll,'));
    final fields = style.split(',');
    expect(fields[3], '&HFFFFFFFF');
    expect(fields[5], '&HFF000000');
  });
}
