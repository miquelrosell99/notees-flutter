import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/repositories/prefs_repository.dart';
import 'package:notees/domain/services/srs.dart';
import 'package:notees/features/cards/providers/cards_prefs_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The hub's algorithm toggle: optimistic — the value flips (and
/// listeners are notified) BEFORE the repository call resolves.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<PrefsRepository> repositoryWith({
    required Object? Function(RequestOptions options) handle,
  }) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://notees.example.com/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final result = handle(options);
          handler.resolve(Response(requestOptions: options, statusCode: 200, data: result));
        },
      ),
    );
    return PrefsRepository(dio: dio, prefs: await SharedPreferences.getInstance());
  }

  test('load answers the repository value and notifies', () async {
    final provider = CardsPrefsProvider(
      repository: await repositoryWith(
        handle: (options) => const {'cardsAlgorithm': 'sm2'},
      ),
    );
    var notified = 0;
    provider.addListener(() => notified++);

    expect(provider.loaded, isFalse);
    await provider.load();

    expect(provider.algorithm, SrsAlgorithm.sm2);
    expect(provider.loaded, isTrue);
    expect(notified, 1);
  });

  test('toggle is optimistic: the value flips before the PUT resolves', () async {
    final putGate = Completer<void>();
    final dio = Dio(BaseOptions(baseUrl: 'https://notees.example.com/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          await putGate.future; // the server is slow
          handler.resolve(Response(requestOptions: options, statusCode: 200, data: const {}));
        },
      ),
    );
    final provider = CardsPrefsProvider(
      repository: PrefsRepository(dio: dio, prefs: await SharedPreferences.getInstance()),
    );
    var notified = 0;
    provider.addListener(() => notified++);

    final pending = provider.toggle();
    expect(provider.algorithm, SrsAlgorithm.sm2); // already visible
    expect(notified, 1);

    putGate.complete();
    await pending;
  });

  test('toggle flips back and forth', () async {
    final provider = CardsPrefsProvider(
      repository: await repositoryWith(
        handle: (options) => const {'cardsAlgorithm': 'fsrs'},
      ),
    );
    await provider.load();
    expect(provider.algorithm, SrsAlgorithm.fsrs);

    await provider.toggle();
    expect(provider.algorithm, SrsAlgorithm.sm2);

    await provider.toggle();
    expect(provider.algorithm, SrsAlgorithm.fsrs);
  });
}
