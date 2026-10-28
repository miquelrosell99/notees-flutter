import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/services/srs.dart';

/// The per-user cards scheduler preference — the `cardsAlgorithm` scalar.
///
/// The server-side per-user prefs store is the authority
/// (`GET`/`PUT /api/me/prefs`); `shared_preferences` carries the
/// device-local copy (the web `nodePrefs.ts` contract, simplified to one
/// scalar):
///
/// - a successful read validates the server value (`sm2`|`fsrs`), answers
///   it, and writes it through to the device copy;
/// - an invalid/absent server value answers the `fsrs` default (the web
///   `readDevicePrefScalar` contract);
/// - offline reads answer from the device copy, else the `fsrs` default;
/// - offline writes persist the device copy and are pushed to the server on
///   the next successful call.
class PrefsRepository {
  PrefsRepository({required this._dio, required this._prefs});

  final Dio _dio;
  final SharedPreferences _prefs;

  static const _deviceKey = 'notees.cardsAlgorithm';

  SrsAlgorithm get _deviceCopy =>
      parseSrsAlgorithm(_prefs.getString(_deviceKey)) ?? SrsAlgorithm.fsrs;

  /// The active scheduler — server-authoritative, device-local fallback.
  Future<SrsAlgorithm> getCardsAlgorithm() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/me/prefs');
      // The server answered — flush any offline write first (the
      // converge-on-next-successful-call contract).
      await _flushPending();
      final raw = response.data?['cardsAlgorithm'];
      final algorithm = parseSrsAlgorithm(raw);
      if (algorithm == null) {
        // Invalid/absent server value: the fsrs default stands (the web
        // readDevicePrefScalar contract); the device copy is untouched.
        return SrsAlgorithm.fsrs;
      }
      await _prefs.setString(_deviceKey, algorithm.wire);
      return algorithm;
    } catch (_) {
      return _deviceCopy;
    }
  }

  /// Persists [algorithm] — the device copy first (optimistic), then the
  /// server push; a failed push stays queued for the next successful call.
  Future<void> setCardsAlgorithm(SrsAlgorithm algorithm) async {
    await _prefs.setString(_deviceKey, algorithm.wire);
    try {
      await _dio.put<Map<String, dynamic>>(
        '/me/prefs',
        data: <String, dynamic>{'cardsAlgorithm': algorithm.wire},
      );
      _pending = null;
    } catch (_) {
      _pending = algorithm;
    }
  }

  SrsAlgorithm? _pending;

  Future<void> _flushPending() async {
    final pending = _pending;
    if (pending == null) return;
    try {
      await _dio.put<Map<String, dynamic>>(
        '/me/prefs',
        data: <String, dynamic>{'cardsAlgorithm': pending.wire},
      );
      _pending = null;
    } catch (_) {
      // Still offline — the next successful call retries.
    }
  }
}
