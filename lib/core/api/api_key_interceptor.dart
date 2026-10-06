import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../secure/secure_storage.dart';

/// Attaches the single-user API key (`X-API-Key`) to every
/// relay (and, forward-compatibly, object) request for the active server.
///
/// The key is fetched per request from secure storage (`readApiKey` keyed by
/// the server profile id). When no key is stored the request is sent without
/// the header and the server's 401 surfaces to the caller, which is the wire
/// contract; storage/plugin errors degrade the same way rather than blocking
/// the sync loop.
class RelayApiKeyInterceptor extends Interceptor {
  RelayApiKeyInterceptor({
    required this.secureStorage,
    required this.serverId,
  });

  final SecureStorage secureStorage;
  final String? serverId;

  static bool _usesApiKey(String path) =>
      path.startsWith('/relay/') || path.startsWith('/objects');

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final serverId = this.serverId;
    if (serverId != null &&
        serverId.isNotEmpty &&
        _usesApiKey(options.path)) {
      try {
        final key = await secureStorage.readApiKey(serverId);
        if (key != null && key.isNotEmpty) {
          options.headers['X-API-Key'] = key;
        }
      } on MissingPluginException {
        // Test hosts and platforms without secure storage: unauthenticated.
      } on PlatformException {
        // Key unreadable (e.g. locked keystore): let the 401 surface.
      }
    }
    handler.next(options);
  }
}
