import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../../core/utils/ast_builder.dart';
import '../../data/local/app_database.dart';
import '../../data/repositories/node_repository.dart';
import 'sync_v2_service.dart';

/// Saves a quick note, falling back to the offline queue when there is no
/// connectivity.
class QuickCaptureService {
  QuickCaptureService({
    required this.dio,
    AppDatabase? database,
    this.syncService,
  }) : _database = database ?? AppDatabase();

  final Dio dio;
  final AppDatabase _database;
  final SyncV2Service? syncService;

  Future<void> save(String name, {bool isTask = false}) async {
    final online = await _isOnline();

    if (syncService != null) {
      // Always use the v2 outbox so the note can be created offline and synced
      // when connectivity returns.
      final nodeUuid = const Uuid().v7();
      await syncService!.enqueue(
        type: 'create',
        nodeUuid: nodeUuid,
        contentAst: AstBuilder.parseInline(name),
        isPage: true,
        isTask: isTask,
      );
      if (online) {
        await syncService!.flush();
      }
      return;
    }

    if (online) {
      await NodeRepository(dio: dio, syncService: syncService).createQuickNote(name: name);
    } else {
      await _database.enqueueQuickNote(name);
    }
  }

  Future<int> pendingCount() async {
    final pending = await _database.pending();
    return pending.length;
  }

  static Future<bool> _isOnline() async {
    final results = await Connectivity().checkConnectivity();
    return results.isNotEmpty && !results.contains(ConnectivityResult.none);
  }
}
