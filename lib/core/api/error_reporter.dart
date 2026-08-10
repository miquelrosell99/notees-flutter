import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Global navigator key used to show error dialogs from interceptors.
final GlobalKey<NavigatorState> apiErrorNavigatorKey = GlobalKey<NavigatorState>();

/// Logs outgoing requests and records failed responses to a file so they can
/// be inspected without `adb logcat`. Also shows a concise dialog for 4xx/5xx
/// responses to make server-side errors visible during manual testing.
class ApiErrorReporter extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    debugPrint('[API] ${options.method} ${options.uri}');
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final response = err.response;
    final status = response?.statusCode;
    final method = err.requestOptions.method;
    final uri = err.requestOptions.uri.toString();
    final data = response?.data;
    final detail = data is Map<String, dynamic>
        ? (data['detail'] ?? data['message'] ?? data.toString())
        : data?.toString();

    final message = '[$method $status] $uri\n${detail ?? err.message}';
    debugPrint('[API ERROR] $message');

    await _appendLog(message);

    // 404s are often expected (removed endpoints, optional features). Log them
    // but do not show a disruptive dialog; callers should handle them gracefully.
    if (status != null && status >= 400 && status != 404) {
      _showDialog(method, status, uri, detail);
    }

    handler.next(err);
  }

  Future<void> _appendLog(String message) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/api_errors.log');
      final timestamp = DateTime.now().toIso8601String();
      await file.writeAsString('$timestamp $message\n\n', mode: FileMode.append);
    } catch (_) {
      // Logging must never crash the app.
    }
  }

  void _showDialog(String method, int status, String uri, Object? detail) {
    final context = apiErrorNavigatorKey.currentContext;
    if (context == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (apiErrorNavigatorKey.currentContext == null) return;
      showDialog(
        context: apiErrorNavigatorKey.currentContext!,
        builder: (_) => AlertDialog(
          title: Text('Server error ($status)'),
          content: SingleChildScrollView(
            child: SelectableText(
              '$method $uri\n\n${detail ?? 'No detail'}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(apiErrorNavigatorKey.currentContext!).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    });
  }
}
