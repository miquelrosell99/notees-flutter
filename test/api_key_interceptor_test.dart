import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/api/api_client.dart';
import 'package:notees/core/secure/secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter_secure_storage talks to a platform method channel; serve the
  // keyring from a map so the interceptor's read path can be exercised.
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  var keyring = <String, String>{};

  setUp(() {
    keyring = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'read':
          final args = call.arguments as Map<dynamic, dynamic>;
          return keyring[args['key'] as String];
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// Builds a client wired like production and captures the headers of the
  /// next request without touching the network.
  Future<Map<String, dynamic>> captureHeaders({
    required String path,
    String? serverId,
  }) async {
    final dio = createApiClient(
      baseUrl: 'https://notees.example.com',
      secureStorage: const SecureStorage(),
      serverId: serverId,
    );
    final captured = <String, dynamic>{};
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          captured.addAll(options.headers);
          handler.resolve(Response(
            requestOptions: options,
            data: const <String, dynamic>{},
            statusCode: 200,
          ));
        },
      ),
    );
    await dio.get<Map<String, dynamic>>(path);
    return captured;
  }

  group('RelayApiKeyInterceptor (X-API-Key auth)', () {
    test('attaches the stored per-server key to relay requests', () async {
      keyring['api_key_server-1'] = 'secret-key';

      final headers = await captureHeaders(
        path: '/relay/v2/catch-up',
        serverId: 'server-1',
      );

      expect(headers['X-API-Key'], 'secret-key');
    });

    test('sends relay requests without the header when no key is stored '
        '(the server 401 surfaces)', () async {
      final headers = await captureHeaders(
        path: '/relay/v2/batch',
        serverId: 'server-1',
      );

      expect(headers.containsKey('X-API-Key'), isFalse);
    });

    test('sends without the header when no server id is wired (local mode)',
        () async {
      keyring['api_key_server-1'] = 'secret-key';

      final headers = await captureHeaders(path: '/relay/v2/snapshot');

      expect(headers.containsKey('X-API-Key'), isFalse);
    });

    test('does not attach the key to non-relay routes (JWT-authed)', () async {
      keyring['api_key_server-1'] = 'secret-key';

      final headers = await captureHeaders(
        path: '/auth/me',
        serverId: 'server-1',
      );

      expect(headers.containsKey('X-API-Key'), isFalse);
    });

    test('covers the future object surface too', () async {
      keyring['api_key_server-1'] = 'secret-key';

      final headers = await captureHeaders(
        path: '/objects/0192a000-0000-7000-8000-000000000010',
        serverId: 'server-1',
      );

      expect(headers['X-API-Key'], 'secret-key');
    });
  });
}
