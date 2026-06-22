import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import '../secure/secure_storage.dart';
import 'auth_interceptor.dart';

/// Creates a [Dio] instance configured for the active Notees server.
Dio createApiClient({
  required String baseUrl,
  required SecureStorage secureStorage,
  CookieJar? cookieJar,
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

  return dio;
}
