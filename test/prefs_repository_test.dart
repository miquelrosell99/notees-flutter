import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/repositories/prefs_repository.dart';
import 'package:notees/domain/services/srs.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The `cardsAlgorithm` prefs contract: server-authoritative over
/// `GET`/`PUT /api/me/prefs`, device-local copy via shared_preferences,
/// fsrs default when offline or the server value is invalid.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const deviceKey = 'notees.cardsAlgorithm';

  late SharedPreferences prefs;
  late List<RequestOptions> requests;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    requests = [];
  });

  /// A Dio whose handler decides per-request; records every request.
  Dio scriptedDio({
    required Object? Function(RequestOptions options) handle,
  }) {
    final dio = Dio(BaseOptions(baseUrl: 'https://notees.example.com/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          final result = handle(options);
          if (result is DioException) {
            handler.reject(result);
          } else {
            handler.resolve(Response(requestOptions: options, statusCode: 200, data: result));
          }
        },
      ),
    );
    return dio;
  }

  DioException offline(RequestOptions options) => DioException(
        requestOptions: options,
        error: 'no connectivity',
      );

  group('getCardsAlgorithm', () {
    test('mock-Dio round-trip: answers the server value and writes the device copy', () async {
      final repo = PrefsRepository(
        dio: scriptedDio(
          handle: (options) => <String, dynamic>{
            'favorites': <String>[],
            'recents': <String>[],
            'cardsAlgorithm': 'sm2',
            'updatedAt': '2026-10-28T10:00:00.000Z',
          },
        ),
        prefs: prefs,
      );

      expect(await repo.getCardsAlgorithm(), SrsAlgorithm.sm2);
      expect(requests.single.method, 'GET');
      expect(requests.single.path, '/me/prefs');
      expect(prefs.getString(deviceKey), 'sm2');
    });

    test('offline: answers the device copy', () async {
      await prefs.setString(deviceKey, 'sm2');
      final repo = PrefsRepository(dio: scriptedDio(handle: offline), prefs: prefs);

      expect(await repo.getCardsAlgorithm(), SrsAlgorithm.sm2);
    });

    test('offline with no device copy: answers the fsrs default', () async {
      final repo = PrefsRepository(dio: scriptedDio(handle: offline), prefs: prefs);

      expect(await repo.getCardsAlgorithm(), SrsAlgorithm.fsrs);
    });

    test('offline with a garbled device copy: answers the fsrs default', () async {
      await prefs.setString(deviceKey, 'garbage');
      final repo = PrefsRepository(dio: scriptedDio(handle: offline), prefs: prefs);

      expect(await repo.getCardsAlgorithm(), SrsAlgorithm.fsrs);
    });

    test('invalid server value falls back to fsrs (the device copy stands)', () async {
      await prefs.setString(deviceKey, 'sm2');
      final repo = PrefsRepository(
        dio: scriptedDio(
          handle: (options) => <String, dynamic>{'cardsAlgorithm': 'bogus'},
        ),
        prefs: prefs,
      );

      expect(await repo.getCardsAlgorithm(), SrsAlgorithm.fsrs);
      expect(prefs.getString(deviceKey), 'sm2');
    });

    test('absent server value falls back to fsrs', () async {
      final repo = PrefsRepository(
        dio: scriptedDio(handle: (options) => <String, dynamic>{}),
        prefs: prefs,
      );

      expect(await repo.getCardsAlgorithm(), SrsAlgorithm.fsrs);
    });
  });

  group('setCardsAlgorithm', () {
    test('mock-Dio round-trip: PUTs the scalar and persists the device copy', () async {
      final repo = PrefsRepository(
        dio: scriptedDio(
          handle: (options) => <String, dynamic>{'cardsAlgorithm': 'sm2'},
        ),
        prefs: prefs,
      );

      await repo.setCardsAlgorithm(SrsAlgorithm.sm2);

      final put = requests.single;
      expect(put.method, 'PUT');
      expect(put.path, '/me/prefs');
      expect(put.data, <String, dynamic>{'cardsAlgorithm': 'sm2'});
      expect(prefs.getString(deviceKey), 'sm2');
    });

    test('offline write persists the device copy and converges on the next successful call', () async {
      var online = false;
      final dio = Dio(BaseOptions(baseUrl: 'https://notees.example.com/api'));
      final putBodies = <String>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (!online) {
              handler.reject(DioException(requestOptions: options, error: 'no connectivity'));
              return;
            }
            if (options.method == 'PUT') {
              putBodies.add((options.data as Map<String, dynamic>)['cardsAlgorithm'] as String);
              handler.resolve(Response(requestOptions: options, statusCode: 200, data: const <String, dynamic>{}));
              return;
            }
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: const {'cardsAlgorithm': 'sm2'},
            ));
          },
        ),
      );
      final repo = PrefsRepository(dio: dio, prefs: prefs);

      await repo.setCardsAlgorithm(SrsAlgorithm.sm2); // offline — queued
      expect(prefs.getString(deviceKey), 'sm2');
      expect(putBodies, isEmpty);

      online = true;
      expect(await repo.getCardsAlgorithm(), SrsAlgorithm.sm2);
      expect(putBodies, ['sm2']); // the pending write flushed on the next successful call
    });

    test('a pending write answers OVER the stale GET and the device copy is '
        'not regressed to the pre-flush value', () async {
      // The GET's body still holds the PRE-FLUSH server value; the flush
      // lands before the answer is derived.
      var online = false;
      final dio = Dio(BaseOptions(baseUrl: 'https://notees.example.com/api'));
      final putBodies = <String>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (!online) {
              handler.reject(DioException(requestOptions: options, error: 'no connectivity'));
              return;
            }
            if (options.method == 'PUT') {
              putBodies.add((options.data as Map<String, dynamic>)['cardsAlgorithm'] as String);
              handler.resolve(Response(requestOptions: options, statusCode: 200, data: const <String, dynamic>{}));
              return;
            }
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: const {'cardsAlgorithm': 'fsrs'}, // stale — the flush hasn't landed
            ));
          },
        ),
      );
      final repo = PrefsRepository(dio: dio, prefs: prefs);

      await repo.setCardsAlgorithm(SrsAlgorithm.sm2); // offline — queued + device copy sm2
      online = true;

      // The pending write IS the server state once the PUT lands — it
      // answers, and the device copy is not overwritten by the pre-flush fsrs.
      expect(await repo.getCardsAlgorithm(), SrsAlgorithm.sm2);
      expect(putBodies, ['sm2']);
      expect(prefs.getString(deviceKey), 'sm2');
    });
  });
}
