import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/system.dart';
import '../../core/utils/ast_builder.dart';
import '../../data/local/app_database.dart';
import '../../data/repositories/asset_repository.dart';
import '../../data/repositories/node_repository.dart';
import '../../features/settings/providers/settings_provider.dart';
import './local_asset_store.dart';
import './sync_v2_service.dart';

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

  Future<void> save(
    String name, {
    bool isTask = false,
    String? color,
    String? parentUuid,
  }) async {
    final online = await _isOnline();
    final targetParent = parentUuid ?? SystemPageUuids.inbox;

    if (syncService != null) {
      // Always use the v2 outbox so the note can be created offline and synced
      // when connectivity returns. The parent defaults to the workspace Inbox
      // but can be overridden (e.g. today's daily journal).
      final nodeUuid = const Uuid().v7();
      await syncService!.enqueue(
        type: 'create',
        nodeUuid: nodeUuid,
        contentAst: AstBuilder.parseInline(name),
        parentUuid: targetParent,
        isPage: false,
        isTask: isTask,
        properties: color != null ? {'color': color} : null,
      );
      if (online) {
        await syncService!.flush();
      }
      return;
    }

    if (online) {
      await NodeRepository(dio: dio, syncService: syncService).createInboxBlock(
        name: name,
        isTask: isTask,
        color: color,
        parentUuid: targetParent,
      );
    } else {
      if (!AppDatabase.isSupported) {
        throw StateError('Offline capture is not available on this platform');
      }
      await _database.enqueueQuickNote(name);
    }
  }

  /// Uploads [file] as an asset block under [parentUuid], or converts
  /// [existingNodeUuid] into an asset when given.
  ///
  /// In local (serverless) mode the bytes go to the on-device
  /// [LocalAssetStore] and the canonical asset ops are emitted locally, so a
  /// later server attach replays them.
  Future<void> uploadAsset(
    File file, {
    String? parentUuid,
    String? existingNodeUuid,
    String? content,
  }) async {
    final sync = syncService;
    if (sync != null && sync.serverless) {
      await LocalAssetService(sync).upload(
        file,
        parentUuid: parentUuid,
        existingNodeUuid: existingNodeUuid,
        content: content,
      );
      return;
    }
    await AssetRepository(dio: dio).uploadFile(
      file,
      parentUuid: parentUuid,
      existingNodeUuid: existingNodeUuid,
      content: content,
    );
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

/// Resolves a [QuickCaptureDestination] to the UUID that should be used as the
/// parent for newly captured blocks.
Future<String> resolveQuickCaptureParentUuid({
  required NodeRepository repository,
  required QuickCaptureDestination destination,
}) async {
  return switch (destination) {
    QuickCaptureDestination.inbox => SystemPageUuids.inbox,
    QuickCaptureDestination.today =>
        (await repository.getOrCreateDailyJournal(DateTime.now())).uuid,
  };
}
