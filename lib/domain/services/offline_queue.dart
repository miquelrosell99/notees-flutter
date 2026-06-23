import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';

import '../../data/local/app_database.dart';
import '../models/editor_block_snapshot.dart';
import 'editor_save_service.dart';

/// Stores API mutations while offline and replays them when connectivity
/// returns. Supports quick-note creation and editor page saves.
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

  /// Serializes a full page save and stores it in the offline queue.
  ///
  /// Older pending editor saves for the same [pageId] are removed so the queue
  /// only replays the most recent state for that page.
  Future<void> enqueueEditorSave(
    int pageId,
    String title,
    List<EditorBlockSnapshot> roots,
    List<int> deletedIds,
  ) async {
    final pending = await database.pending();
    for (final item in pending) {
      if (item['method'] != 'editor_save') continue;
      final existingPayload = jsonDecode(item['payload'] as String) as Map<String, dynamic>;
      if ((existingPayload['page_id'] as num?)?.toInt() == pageId) {
        await database.remove((item['id'] as num).toInt());
      }
    }

    await database.enqueue(
      'editor_save',
      jsonEncode({
        'page_id': pageId,
        'title': title,
        'roots': roots.map((r) => r.toJson()).toList(),
        'deleted_ids': deletedIds,
      }),
    );
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
          case 'editor_save':
            final pageId = (payload['page_id'] as num).toInt();
            final title = payload['title'] as String;
            final roots = ((payload['roots'] as List<dynamic>?) ?? [])
                .map((e) => EditorBlockSnapshot.fromJson(e as Map<String, dynamic>))
                .toList();
            final deletedIds = ((payload['deleted_ids'] as List<dynamic>?) ?? [])
                .map((e) => (e as num).toInt())
                .toList();
            final service = EditorSaveService(dio: dio);
            await service.savePage(
              pageId: pageId,
              title: title,
              roots: roots,
              deletedIds: deletedIds,
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
