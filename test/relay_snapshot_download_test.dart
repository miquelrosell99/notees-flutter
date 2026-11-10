import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/repositories/relay_client.dart';

/// `downloadSnapshotData` — the memory-flat snapshot fetch: streams the
/// blob to a file, verifies the length, and throws [RelayException] on
/// non-2xx.
void main() {
  late HttpServer server;
  late Dio dio;
  late Directory tempDir;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}/api'));
    tempDir = await Directory.systemTemp.createTemp('notees_relay_test');
  });

  tearDown(() async {
    await server.close(force: true);
    await tempDir.delete(recursive: true);
  });

  void serveBytes(List<int> body, {int status = 200}) {
    server.listen((request) async {
      request.response.statusCode = status;
      request.response.add(body);
      await request.response.close();
    });
  }

  test('streams the blob to the destination file byte-for-byte', () async {
    final body =
        Uint8List.fromList(List<int>.generate(2 * 1024 * 1024 + 7, (i) => i % 256));
    serveBytes(body);

    final destination = '${tempDir.path}/snapshot.sealed';
    await RelayClient(dio: dio).downloadSnapshotData(
      workspaceId: 'ws-1',
      destinationPath: destination,
    );

    final written = await File(destination).readAsBytes();
    expect(written, body);
  });

  test('a non-2xx response throws RelayException and leaves no file',
      () async {
    serveBytes(<int>[1, 2, 3], status: 500);

    final destination = '${tempDir.path}/snapshot.sealed';
    expect(
      RelayClient(dio: dio).downloadSnapshotData(
        workspaceId: 'ws-1',
        destinationPath: destination,
      ),
      throwsA(isA<RelayException>()),
    );
    expect(await File(destination).exists(), isFalse);
  });

  test('a stream that errors mid-download fails and leaves no partial '
      'file', () async {
    final dioWithFailingStream = Dio(
      BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}/api'),
    )..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final controller = StreamController<Uint8List>();
            controller.add(Uint8List.fromList(List<int>.generate(100, (i) => i)));
            controller.addError(const HttpException('connection lost'));
            unawaited(controller.close());
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: controller.stream,
            ));
          },
        ),
      );

    final destination = '${tempDir.path}/snapshot.sealed';
    expect(
      RelayClient(dio: dioWithFailingStream).downloadSnapshotData(
        workspaceId: 'ws-1',
        destinationPath: destination,
      ),
      throwsA(anything),
    );
    expect(await File(destination).exists(), isFalse);
  });

  test('a short read against the declared content-length fails with '
      'RelayException and no partial file', () async {
    final dioWithShortBody = Dio(
      BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}/api'),
    )..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: ResponseBody(
                Stream.value(
                    Uint8List.fromList(List<int>.generate(100, (i) => i))),
                200,
                headers: {'content-length': ['1000']},
              ),
            ));
          },
        ),
      );

    final destination = '${tempDir.path}/snapshot.sealed';
    expect(
      RelayClient(dio: dioWithShortBody).downloadSnapshotData(
        workspaceId: 'ws-1',
        destinationPath: destination,
      ),
      throwsA(isA<RelayException>()),
    );
    expect(await File(destination).exists(), isFalse);
  });
}
