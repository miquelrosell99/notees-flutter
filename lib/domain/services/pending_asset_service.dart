import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/crypto/crypto_custody.dart';
import '../../data/local/app_database.dart';
import '../../data/repositories/asset_repository.dart';
import '../../data/repositories/node_cache_repository.dart';
import '../../data/repositories/pending_asset_repository.dart';
import './local_asset_store.dart';
import './sync_v2_service.dart';

/// The result of a capture-time asset save: uploaded inline, or persisted
/// into the background queue.
enum AssetUploadOutcome { uploaded, queued }

/// The background-asset upload queue — a mobile-specific reliability layer
/// with NO web equivalent (the web client uploads inline, one attempt, no
/// queue: asset-transport.ts — a failed upload there drops the file).
///
/// Capture paths ([QuickCaptureService.uploadAsset]) enqueue on offline or
/// upload failure instead of dropping; the queue then drains on
/// connectivity restore / app start (foreground, via OfflineSync) and in the
/// 15-min WorkManager task (background), after flush so the attach target
/// exists server-side.
///
/// Drain state machine, per row (oldest first):
///  - target `node_uuid` not yet in the local projection → defer to the
///    next round (the creating flush/pull has not landed yet);
///  - upload+attach succeeds → row dropped, local file deleted;
///  - attach rejected 4xx (target node missing server-side) → retry count
///    bumps, eligible again next round (no backoff);
///  - upload fails 5xx/network → retry count bumps with exponential
///    backoff (`next_attempt_at`);
///  - after 6 attempts → `failed` (dead letter; Settings → Sync surfaces
///    retry-now / discard).
///
/// Sealing happens at DRAIN time with the session's workspace key —
/// foreground uses the custody cache's active key; the background isolate
/// restores custody from secure storage (the persisted master key) with a
/// defensive skip: any custody error logs and the round proceeds keyless
/// (plaintext uploads stay legal — mixed logs carry `iv NULL` assets).
/// NOTE: flutter_secure_storage inside a WorkManager isolate is UNVERIFIED
/// on device; the defensive path guarantees a custody glitch can never lose
/// a capture or crash the worker.
class PendingAssetService {
  PendingAssetService({
    required this.database,
    required this.dio,
    this.syncService,
    PendingAssetRepository? repository,
    Future<SecretKey?> Function()? backgroundKeyResolver,
    Duration Function(int retryCount)? backoff,
  })  : _repository = repository ?? PendingAssetRepository(database),
        _backoff = backoff ?? _defaultBackoff {
    _backgroundKeyResolver = backgroundKeyResolver ?? _restoreBackgroundKey;
  }

  final AppDatabase database;
  final Dio dio;
  final SyncV2Service? syncService;
  final PendingAssetRepository _repository;
  late final Future<SecretKey?> Function() _backgroundKeyResolver;
  final Duration Function(int retryCount) _backoff;

  /// Server caps (assets.ts), enforced at enqueue time so an over-cap
  /// capture fails loud at capture instead of dead-lettering.
  static const mediaCap = 50 * 1024 * 1024;
  static const docsCap = 100 * 1024 * 1024;

  static int capFor(String mime) =>
      mime.startsWith('image/') ||
              mime.startsWith('audio/') ||
              mime.startsWith('video/')
          ? mediaCap
          : docsCap;

  static Duration _defaultBackoff(int retryCount) {
    var minutes = 1 << (retryCount - 1).clamp(0, 10);
    if (minutes > const Duration(hours: 24).inMinutes) {
      minutes = const Duration(hours: 24).inMinutes;
    }
    return Duration(minutes: minutes);
  }

  /// Persists [file] into the pending-assets directory and inserts the row.
  /// Throws [StateError] when the file exceeds the server cap (the caller
  /// keeps its fail-loud error path).
  Future<void> enqueue(
    File file, {
    String? nodeUuid,
    String? parentUuid,
  }) async {
    final mime = LocalAssetService.mimeTypeForPath(file.path);
    final size = await file.length();
    if (size > capFor(mime)) {
      throw StateError(
        'File is ${(size / 1048576).round()} MB — the server accepts at most '
        '${mime.startsWith('image/') || mime.startsWith('audio/') || mime.startsWith('video/') ? 50 : 100} MB '
        'for this type',
      );
    }
    final dir = Directory(p.join(
      (await getApplicationDocumentsDirectory()).path,
      'pending_assets',
    ));
    await dir.create(recursive: true);
    final id = const Uuid().v7();
    final destination = File(p.join(dir.path, '$id${p.extension(file.path)}'));
    await file.copy(destination.path);
    await _repository.insert(PendingAssetRow(
      id: id,
      localPath: destination.path,
      nodeUuid: nodeUuid,
      parentUuid: parentUuid,
      mime: mime,
      originalName: p.basename(file.path),
      sizeBytes: size,
      state: 'pending',
      retryCount: 0,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  /// Drains the queue oldest-first. [background] selects the custody source
  /// (see the class doc). Returns per-row errors (dead letters and deferred
  /// rows stay in the table for the next round / the Settings surface).
  Future<List<String>> drain({bool background = false}) async {
    final errors = <String>[];
    final rows = await _repository.listDue();
    if (rows.isEmpty) return errors;

    // One custody resolution per round (not per row).
    SecretKey? key;
    if (background) {
      try {
        key = await _backgroundKeyResolver();
      } catch (e) {
        // Defensive: a custody glitch (e.g. secure storage unavailable in
        // the isolate) must never crash the worker or lose the round —
        // plaintext uploads proceed (legal on the wire, iv NULL).
        debugPrint('PendingAssetService: background custody restore failed, '
            'draining keyless this round: $e');
        key = null;
      }
    } else {
      key = activeWorkspaceKey;
    }

    final cache = NodeCacheRepository(database);
    for (final row in rows) {
      try {
        final nodeUuid = row.nodeUuid ?? row.parentUuid;
        if (nodeUuid != null &&
            await cache.getByUuid(nodeUuid) == null) {
          // The creating flush/pull has not landed yet — retry next round.
          await _repository.recordFailure(
            row.id,
            error: 'attach target not synced yet',
            retryNowOrAtMillis: 0,
            retryNow: true,
            attempts: row.retryCount + 1,
            attemptedAtMillis: DateTime.now().millisecondsSinceEpoch,
          );
          continue;
        }
        await AssetRepository(dio: dio).uploadPath(
          row.localPath,
          existingNodeUuid: row.nodeUuid,
          parentUuid: row.nodeUuid == null ? row.parentUuid : null,
          mimeType: row.mime,
          originalName: row.originalName,
          sealKey: key,
        );
        await _repository.markDone(row.id);
        try {
          await File(row.localPath).delete();
        } catch (_) {
          // Best-effort cleanup of the queued copy.
        }
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        final isAttachRejection = status != null && status >= 400 && status < 500;
        errors.add('${row.originalName}: $e');
        await _recordAttempt(row, e.toString(), isAttachRejection);
      } catch (e) {
        errors.add('${row.originalName}: $e');
        await _recordAttempt(row, e.toString(), false);
      }
    }
    return errors;
  }

  Future<void> _recordAttempt(
    PendingAssetRow row,
    String error,
    bool retryNextRound,
  ) async {
    final attempts = row.retryCount + 1;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _repository.recordFailure(
      row.id,
      error: error,
      retryNowOrAtMillis:
          now + _backoff(attempts).inMilliseconds,
      retryNow: retryNextRound,
      attempts: attempts,
      attemptedAtMillis: now,
    );
  }

  /// Settings → Sync counts ("N uploads waiting / M failed").
  Future<({int pending, int failed})> counts() => _repository.counts();

  Future<List<PendingAssetRow>> failedItems() => _repository.listFailed();

  /// Dead-letter actions (Settings → Sync).
  Future<void> retryNow(String id) => _repository.requeue(id);

  Future<void> discard(String id) async {
    final row = await _repository.get(id);
    await _repository.discard(id);
    final path = row?.localPath;
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {
        // Best-effort cleanup.
      }
    }
  }

  /// Background custody: re-hydrate the persisted master key from secure
  /// storage, then fetch-or-ensure the workspace key. NOTE:
  /// flutter_secure_storage inside a WorkManager isolate is UNVERIFIED on
  /// device — every caller wraps this in a defensive catch.
  Future<SecretKey?> _restoreBackgroundKey() async {
    final sync = syncService;
    if (sync == null) return null;
    await restoreMasterKeyFromStorage();
    if (!hasMasterKey) return null;
    final workspaceId = await sync.getWorkspaceId();
    if (workspaceId == null) return null;
    return ensureWorkspaceKey(dio, workspaceId);
  }
}
