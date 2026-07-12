import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../secure/secure_storage.dart';
import 'auth_interceptor.dart';

CookieJar? _sharedCookieJar;

/// Returns the shared persistent cookie jar used by all API clients.
///
/// The Notees server issues the refresh token as an HTTPOnly cookie scoped to
/// `/api/auth/refresh` and rotates it on every refresh. Without a persistent
/// jar the app can never refresh an expired access token, so every client
/// (foreground and background sync) must share this one.
Future<CookieJar> sharedCookieJar() async {
  final existing = _sharedCookieJar;
  if (existing != null) return existing;
  final dir = await getApplicationSupportDirectory();
  return _sharedCookieJar = PersistCookieJar(
    storage: FileStorage(p.join(dir.path, 'cookies')),
  );
}

/// Creates a [Dio] instance configured for the active Notees server.
Dio createApiClient({
  required String baseUrl,
  required SecureStorage secureStorage,
  CookieJar? cookieJar,
  bool trustSelfSigned = false,
}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: baseUrl.endsWith('/') ? '${baseUrl}api' : '$baseUrl/api',
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {'Accept': 'application/json'},
    ),
  );

  dio.interceptors.add(AuthInterceptor(secureStorage: secureStorage, dio: dio));

  if (cookieJar != null) {
    dio.interceptors.add(CookieManager(cookieJar));
  }

  dio.interceptors.add(LogInterceptor(requestBody: true, responseBody: true));

  if (trustSelfSigned) {
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.badCertificateCallback =
            (X509Certificate cert, String host, int port) => true;
        return client;
      },
    );
  }

  return dio;
}
