import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// A [LogInterceptor] replacement that can never blow up on large bodies.
///
/// dio's stock `LogInterceptor(responseBody: true)` stringifies the whole
/// response (`response.toString().split('\n')`), which turns a ~160MB sealed
/// snapshot download into a ~700MB string before `logPrint` ever sees it.
/// This interceptor instead logs one line per request/response, caps any
/// String/JSON body at [_maxBodyChars], and for `List<int>` bodies logs ONLY
/// the byte length — a binary body is never stringified or materialized
/// beyond the cap.
class TrimmingLogInterceptor extends Interceptor {
  TrimmingLogInterceptor({void Function(String line)? logPrint})
      : _logPrint = logPrint ?? debugPrint;

  /// The maximum body characters written to the log per entry.
  static const int maxBodyChars = 1000;

  final void Function(String) _logPrint;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    _logPrint('→ ${options.method} ${options.uri}');
    final data = options.data;
    if (data is List<int>) {
      _logPrint('  body: ${data.length} bytes (binary)');
    } else if (data is String) {
      _logPrint('  body: ${_trim(data)}');
    } else if (data is Map || data is List) {
      _logPrint('  body: ${_trim(jsonEncode(data))}');
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _logPrint(
      '← ${response.statusCode} ${response.requestOptions.uri} '
      'content-length: '
      '${response.headers.value(Headers.contentLengthHeader) ?? '?'}',
    );
    final data = response.data;
    if (data is List<int>) {
      _logPrint('  body: ${data.length} bytes (binary)');
    } else if (data is String) {
      _logPrint('  body: ${_trim(data)}');
    } else if (data is Map || data is List) {
      _logPrint('  body: ${_trim(jsonEncode(data))}');
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _logPrint('✗ ${err.requestOptions.uri}: $err');
    handler.next(err);
  }

  String _trim(String body) {
    final normalized = body.replaceAll('\n', r'\n');
    if (normalized.length <= maxBodyChars) return normalized;
    final dropped = normalized.length - maxBodyChars;
    return '${normalized.substring(0, maxBodyChars)}… (+$dropped chars)';
  }
}
