import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';

import '../../data/local/app_database.dart';

/// Stores API mutations while offline and replays them when connectivity
/// returns. Currently supports quick-note creation.
class OfflineQueue {
  OfflineQueue({
    required this.database,
    required this.dio,
  });

  final AppDatabase database;
  final Dio dio;

  Future<void> enqueueQuickNote(String name) async {
    await database.enqueue('quick_note', jsonEncode({'name': name}));
  }

  Future<List<String>> process() async {
    final errors = <String>[];
    final pending = await database.pending();
    for (final item in pending) {
      final method = item['method'] as String;
      final payload = jsonDecode(item['payload'] as String) as Map<String, dynamic>;
      try {
        switch (method) {
          case 'quick_note':
            final name = payload['name'] as String;
            await dio.post<Map<String, dynamic>>(
              '/nodes/page',
              queryParameters: {'name': name},
            );
        }
        await database.remove((item['id'] as num).toInt());
      } on DioException catch (e) {
        errors.add('$method: ${e.message}');
      }
    }
    return errors;
  }

  static Future<bool> get isOnline async {
    final results = await Connectivity().checkConnectivity();
    return results.isNotEmpty && !results.contains(ConnectivityResult.none);
  }
}
