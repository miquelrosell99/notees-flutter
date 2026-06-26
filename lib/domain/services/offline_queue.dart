import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../../core/utils/ast_builder.dart';
import '../../data/local/app_database.dart';
import '../models/editor_block_snapshot.dart';
import 'editor_save_service.dart';
import 'sync_v2_service.dart';

/// Stores API mutations while offline and replays them when connectivity
/// returns. Supports quick-note creation and editor page saves.
///
/// When a [SyncV2Service] is available, legacy queued items are translated into
/// v2 sync operations so they participate in the same outbox and conflict
/// resolution path.
class OfflineQueue {
  OfflineQueue({
    required this.database,
    required this.dio,
    this.syncService,
  });

  final AppDatabase database;
  final Dio dio;
  final SyncV2Service? syncService;

  Future<void> enqueueQuickNote(String name) async {
    await database.enqueue('quick_note', jsonEncode({'name': name}));
  }

  /// Serializes a full page save and stores it in the offline queue.
  ///
  /// Older pending editor saves for the same [pageId] are removed so the queue
  /// only replays the most recent state for that page.
  Future<void> enqueueEditorSave(
    String pageUuid,
    String title,
    List<EditorBlockSnapshot> roots,
    List<String> deletedUuids,
  ) async {
    final pending = await database.pending();
    for (final item in pending) {
      if (item['method'] != 'editor_save') continue;
      final existingPayload = jsonDecode(item['payload'] as String) as Map<String, dynamic>;
      if ((existingPayload['page_uuid'] as String?) == pageUuid) {
        await database.remove((item['id'] as num).toInt());
      }
    }

    await database.enqueue(
      'editor_save',
      jsonEncode({
        'page_uuid': pageUuid,
        'title': title,
        'roots': roots.map((r) => r.toJson()).toList(),
        'deleted_uuids': deletedUuids,
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
            if (syncService != null) {
              final nodeUuid = const Uuid().v7();
              await syncService!.enqueue(
                type: 'create',
                nodeUuid: nodeUuid,
                contentAst: AstBuilder.parseInline(name),
                isPage: true,
              );
              await syncService!.flush();
            } else {
              await dio.post<Map<String, dynamic>>(
                '/nodes/page',
                queryParameters: {'name': name},
              );
            }
          case 'editor_save':
            final pageUuid = payload['page_uuid'] as String;
            final title = payload['title'] as String;
            final roots = ((payload['roots'] as List<dynamic>?) ?? [])
                .map((e) => EditorBlockSnapshot.fromJson(e as Map<String, dynamic>))
                .toList();
            final deletedUuids = ((payload['deleted_uuids'] as List<dynamic>?) ?? [])
                .map((e) => e as String)
                .toList();
            final service = EditorSaveService(dio: dio, syncService: syncService);
            await service.savePage(
              pageUuid: pageUuid,
              title: title,
              roots: roots,
              deletedUuids: deletedUuids,
            );
        }
        await database.remove((item['id'] as num).toInt());
      } on DioException catch (e) {
        errors.add('$method: ${e.message}');
      } catch (e) {
        errors.add('$method: $e');
      }
    }
    return errors;
  }

  static Future<bool> get isOnline async {
    final results = await Connectivity().checkConnectivity();
    return results.isNotEmpty && !results.contains(ConnectivityResult.none);
  }
}
