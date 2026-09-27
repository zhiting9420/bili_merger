import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bili_merger/services/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final (latest, current, newer) in [
    ('v1.1.1', '1.1.0+2', true),
    ('1.1.0+9', '1.1.0+2', false),
    ('1.1.0', '1.1.0-rc.1', true),
    ('1.1.0-rc.1', '1.1.0', false),
    ('1.1.0-beta.11', '1.1.0-beta.2', true),
    ('1.1.0-beta', '1.1.0-alpha', true),
    ('1.1.0-alpha.1', '1.1.0-alpha', true),
    ('1.0.9', '1.1.0', false),
  ]) {
    test('$latest compared with $current gives update=$newer', () async {
      final result = await _checkRelease(latest, current);
      expect(result.ok, isTrue);
      expect(result.hasUpdate, newer);
      expect(result.notes, 'Release notes');
      expect(result.apkUrl, 'https://example.com/app.apk');
    });
  }

  for (final invalid in ['', 'release-12', '1.1', '1.01.0', '1.1.0-01']) {
    test('invalid release version "$invalid" reports check failure', () async {
      final result = await _checkRelease(invalid, '1.1.0');
      expect(result.ok, isFalse);
      expect(result.hasUpdate, isFalse);
    });
  }

  testWidgets('a stalled response body times out and closes the connection', (
    tester,
  ) async {
    final body = StreamController<List<int>>();
    addTearDown(body.close);
    final client = _Client(body.stream);
    UpdateResult? result;
    HttpOverrides.runZoned(
      () => UpdateService.check('owner/repo', '1.1.0').then((r) => result = r),
      createHttpClient: (_) => client,
    );

    await tester.pump();
    await tester.pump(const Duration(seconds: 16));

    expect(result?.ok, isFalse);
    expect(client.forceClosed, isTrue);
  });
}

Future<UpdateResult> _checkRelease(String tag, String current) {
  final body = jsonEncode({
    'tag_name': tag,
    'body': 'Release notes',
    'html_url': 'https://example.com/release',
    'assets': [
      {
        'name': 'app.apk',
        'browser_download_url': 'https://example.com/app.apk',
      },
    ],
  });
  return HttpOverrides.runZoned(
    () => UpdateService.check('owner/repo', current),
    createHttpClient: (_) => _Client(Stream.value(utf8.encode(body))),
  );
}

// Replace only the external transport; response decoding, deadlines and version
// decisions are all exercised through the production check method.
class _Client extends Fake implements HttpClient {
  _Client(this.body);
  final Stream<List<int>> body;
  bool forceClosed = false;

  @override
  set connectionTimeout(Duration? value) {}

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _Request(body);

  @override
  void close({bool force = false}) => forceClosed = force;
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.body);
  final Stream<List<int>> body;

  @override
  final headers = _Headers();

  @override
  Future<HttpClientResponse> close() async => _Response(body);
}

class _Headers extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.body);
  final Stream<List<int>> body;

  @override
  int get statusCode => 200;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => body.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
