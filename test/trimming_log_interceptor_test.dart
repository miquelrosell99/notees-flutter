import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/api/trimming_log_interceptor.dart';

/// The trimming log interceptor must never materialize a large response
/// body: the stock dio LogInterceptor stringifies the whole response, which
/// turned a ~160MB sealed snapshot download into a ~700MB string. These
/// tests pin the cap against a real local HTTP server.
void main() {
  late HttpServer server;
  late Dio dio;
  final logLines = <String>[];

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'))
      ..interceptors.add(
        TrimmingLogInterceptor(logPrint: logLines.add),
      );
  });

  tearDown(() async {
    await server.close(force: true);
    logLines.clear();
  });

  /// Serves [body] with the given content-type; records the request.
  void serve(List<int> body, {String? contentType}) {
    server.listen((request) async {
      request.response.statusCode = 200;
      if (contentType != null) {
        request.response.headers.contentType = ContentType.parse(contentType);
      }
      request.response.add(body);
      await request.response.close();
    });
  }

  test('a multi-MB binary body is logged by length only — every line stays '
      'under the cap and the body completes intact', () async {
    final body = List<int>.generate(4 * 1024 * 1024, (i) => i % 251);
    serve(body);

    final response = await dio.get<List<int>>(
      '/blob',
      options: Options(responseType: ResponseType.bytes),
    );

    expect(response.data, body);
    expect(logLines, isNotEmpty);
    for (final line in logLines) {
      expect(
        line.length,
        lessThanOrEqualTo(TrimmingLogInterceptor.maxBodyChars + 64),
        reason: 'log line exceeds the cap: ${line.substring(0, line.length > 80 ? 80 : line.length)}…',
      );
    }
    final totalChars = logLines.fold<int>(0, (sum, line) => sum + line.length);
    expect(totalChars, lessThan(4096));
    // The binary body was identified by length, never stringified.
    expect(
      logLines.any((line) => line.contains('${body.length} bytes (binary)')),
      isTrue,
    );
  });

  test('a JSON body over the cap is truncated with a dropped-char marker',
      () async {
    final huge = {'text': 'x' * (TrimmingLogInterceptor.maxBodyChars * 4)};
    serve(utf8.encode(jsonEncode(huge)),
        contentType: 'application/json');

    final response = await dio.get<Map<String, dynamic>>('/json');
    expect(response.data, huge);

    final bodyLine =
        logLines.firstWhere((line) => line.startsWith('  body: '));
    expect(
      bodyLine.length,
      lessThanOrEqualTo(TrimmingLogInterceptor.maxBodyChars + 40),
    );
    expect(bodyLine, contains('… (+'));
  });

  test('a small JSON body is logged verbatim', () async {
    serve(utf8.encode(jsonEncode({'ok': true})),
        contentType: 'application/json');

    await dio.get<Map<String, dynamic>>('/json');

    expect(logLines.any((line) => line.contains('{"ok":true}')), isTrue);
  });
}
