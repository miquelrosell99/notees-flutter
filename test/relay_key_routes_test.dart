import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/repositories/relay_client.dart';

/// The E2EE workspace-key routes (`GET/PUT /workspaces/:id/key`,
/// routes-auth.ts) — the fake-Dio InterceptorsWrapper pattern from
/// sync_v2_pull_test.dart.
void main() {
  const workspaceId = '10000000-0000-4000-8000-000000000001';
  const wrappedKey = 'oKGio6SlpqeoqaqrEa5lc67bpNjQU9ACvDQTRW';

  /// Serves the key routes with [status]; every other request fails loud so
  /// a route regression surfaces instead of silently passing.
  Dio buildDio(int status) {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/workspaces/$workspaceId/key') {
            if (status == 404 || status == 403 || status == 409) {
              handler.reject(DioException(
                requestOptions: options,
                response: Response(
                  requestOptions: options,
                  statusCode: status,
                  data: <String, dynamic>{},
                ),
                type: DioExceptionType.badResponse,
              ));
              return;
            }
            if (options.method == 'GET') {
              handler.resolve(Response(
                requestOptions: options,
                data: const {'wrappedKey': wrappedKey},
                statusCode: 200,
              ));
              return;
            }
            // PUT: first-write-wins ack is a bare 204.
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 204,
            ));
            return;
          }
          handler.reject(DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            error: 'unexpected request: ${options.method} ${options.path}',
          ));
        },
      ),
    );
    return dio;
  }

  group('RelayClient workspace key routes', () {
    test('GET returns the wrapped key', () async {
      final client = RelayClient(dio: buildDio(200));
      expect(await client.fetchWorkspaceKey(workspaceId), wrappedKey);
    });

    test('GET 404 (no key stored / non-member) returns null', () async {
      final client = RelayClient(dio: buildDio(404));
      expect(await client.fetchWorkspaceKey(workspaceId), isNull);
    });

    test('GET 403 (API-key principal) propagates', () async {
      final client = RelayClient(dio: buildDio(403));
      expect(
        client.fetchWorkspaceKey(workspaceId),
        throwsA(isA<DioException>()),
      );
    });

    test('PUT with 204 completes', () async {
      final client = RelayClient(dio: buildDio(204));
      await client.storeWorkspaceKey(workspaceId, wrappedKey);
    });

    test('PUT 409 (first write wins) propagates for the adopt step', () async {
      final client = RelayClient(dio: buildDio(409));
      Object? error;
      try {
        await client.storeWorkspaceKey(workspaceId, wrappedKey);
      } catch (e) {
        error = e;
      }
      expect(error, isA<DioException>());
      expect((error! as DioException).response?.statusCode, 409);
    });
  });
}
