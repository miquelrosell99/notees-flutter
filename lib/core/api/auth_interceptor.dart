import 'package:dio/dio.dart';

import '../secure/secure_storage.dart';

/// Attaches the access token to every request and retries once on 401 by
/// refreshing via the refresh-token cookie.
class AuthInterceptor extends Interceptor {
  AuthInterceptor({
    required this.secureStorage,
    required this.dio,
  });

  final SecureStorage secureStorage;
  final Dio dio;

  bool _isRefreshing = false;
  final _pendingRequests = <ErrorInterceptorHandler>[];

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await secureStorage.readAccessToken();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final response = err.response;
    if (response?.statusCode != 401 || err.requestOptions.path == '/auth/refresh') {
      handler.next(err);
      return;
    }

    if (_isRefreshing) {
      _pendingRequests.add(handler);
      return;
    }

    _isRefreshing = true;

    try {
      final refreshed = await _refreshToken();
      if (refreshed) {
        final token = await secureStorage.readAccessToken();
        final opts = err.requestOptions;
        opts.headers['Authorization'] = 'Bearer $token';
        final cloned = await dio.fetch(opts);
        handler.resolve(cloned);
      } else {
        handler.next(err);
      }
    } on DioException catch (e) {
      handler.next(e);
    } finally {
      _isRefreshing = false;
      for (final pending in _pendingRequests) {
        final token = await secureStorage.readAccessToken();
        final opts = err.requestOptions;
        opts.headers['Authorization'] = 'Bearer $token';
        try {
          final cloned = await dio.fetch(opts);
          pending.resolve(cloned);
        } on DioException catch (e) {
          pending.next(e);
        }
      }
      _pendingRequests.clear();
    }
  }

  Future<bool> _refreshToken() async {
    try {
      // The refresh endpoint uses the refresh_token cookie, so we must not
      // send the Authorization header here.
      final response = await dio.post<Map<String, dynamic>>(
        '/auth/refresh',
        options: Options(headers: {'Authorization': null}),
      );
      final data = response.data;
      if (data == null) return false;
      final token = data['access_token'] as String?;
      if (token == null) return false;
      await secureStorage.writeAccessToken(token);
      return true;
    } on DioException {
      return false;
    }
  }
}
