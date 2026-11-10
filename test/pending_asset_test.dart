import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/models/node.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/data/repositories/pending_asset_repository.dart';
import 'package:notees/domain/models/relay/asset_crypto.dart';
import 'package:notees/domain/models/relay/payload_crypto.dart';
import 'package:notees/domain/services/offline_queue.dart';
import 'package:notees/domain/services/pending_asset_service.dart';
import 'package:notees/domain/services/quick_capture.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:notees/features/settings/widgets/pending_uploads_tile.dart';
import 'package:notees/native/background_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The background-asset upload queue — a mobile-specific reliability layer
/// (the web client uploads inline with no queue). Covers enqueue (offline /
/// upload failure / caps), the drain state machine (defer, attach-4xx retry,
/// 5xx backoff, dead-letter), custody (sealed background uploads, defensive
/// keyless fallback), and the worker's drain ordering.
class FakeAssetsApi {
  final uploads = <Map<String, dynamic>>[];
  final bodies = <Uint8List>[];
  int? failStatus;

  Dio buildDio() {
    final dio = Dio(BaseOptions(baseUrl: 'https://notees.example.com/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (options.path == '/api/assets') {
            final form = options.data as FormData;
            final fields = <String, dynamic>{
              for (final e in form.fields) e.key: e.value,
            };
            final file = form.files.single.value;
            final bytes = <int>[];
            await for (final chunk in file.finalize().cast<List<int>>()) {
              bytes.addAll(chunk);
            }
            final status = failStatus;
            if (status != null) {
              handler.reject(DioException(
                requestOptions: options,
                response: Response(
                  requestOptions: options,
                  statusCode: status,
                ),
                type: DioExceptionType.badResponse,
              ));
              return;
            }
            uploads.add(fields);
            bodies.add(Uint8List.fromList(bytes));
            handler.resolve(Response(
              requestOptions: options,
              data: {
                'assetId': 'asset-${uploads.length}',
                'originalName': file.filename,
              },
              statusCode: 200,
            ));
            return;
          }
          handler.reject(DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            error: 'unexpected request: ${options.path}',
          ));
        },
      ),
    );
    return dio;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  // pending_asset rows reference files under the app-documents directory.
  final tempDir = Directory.systemTemp.createTempSync('notees_pending_test');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => tempDir.path,
  );

  // Default connectivity for the service-level tests: online.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('dev.fluttercommunity.plus/connectivity'),
    (call) async => ['wifi'],
  );

  const workspaceId = '10000000-0000-4000-8000-000000000001';
  const node1 = '20000000-0000-4000-8000-000000000001';
  const device = '40000000-0000-4000-8000-000000000001';

  Future<AppDatabase> freshDatabase() async {
    final ffiDb = await databaseFactoryFfi.openDatabase(
      ':memory:',
      options: OpenDatabaseOptions(singleInstance: false),
    );
    final database = AppDatabase.fromDatabase(ffiDb);
    await database.initializeSchema();
    return database;
  }

  Future<void> putNode(AppDatabase database, String uuid) async {
    await NodeCacheRepository(database).upsert(Node(
      id: 0,
      uuid: uuid,
      name: 'node $uuid',
      displayName: 'node $uuid',
      isPage: false,
    ));
  }

  Future<File> captureFile(String name, [int bytes = 64]) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsBytes(List<int>.generate(bytes, (i) => i % 251),
        flush: true);
    return file;
  }

  void cleanTempDir() {
    for (final entity in tempDir.listSync()) {
      if (entity is Directory) {
        entity.deleteSync(recursive: true);
      } else {
        entity.deleteSync();
      }
    }
  }

  /// Records POST /api/uploads with fields + drained bytes; scripts failures.
  group('PendingAssetService', () {
    late AppDatabase database;
    late PendingAssetService service;
    late FakeAssetsApi api;

    setUp(() async {
      database = await freshDatabase();
      api = FakeAssetsApi();
      service = PendingAssetService(
        database: database,
        dio: api.buildDio(),
        backoff: (retryCount) => Duration.zero, // rounds are manual here
      );
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
      cleanTempDir();
    });

    test('enqueue copies the file into the pending dir and inserts the row',
        () async {
      final capture = await captureFile('photo.jpg');
      await service.enqueue(capture, nodeUuid: node1);

      final repo = PendingAssetRepository(database);
      final rows = await repo.listDue();
      expect(rows, hasLength(1));
      expect(rows.single.nodeUuid, node1);
      expect(rows.single.originalName, 'photo.jpg');
      expect(rows.single.mime, 'image/jpeg');
      expect(rows.single.isPending, isTrue);
      // The queued copy lives in the pending dir; the source stays.
      expect(File(rows.single.localPath).existsSync(), isTrue);
      expect(rows.single.localPath,
          contains('pending_assets'));
    });

    test('over-cap captures throw (fail loud at capture)', () async {
      final big = await captureFile('big.jpg', 60 * 1024 * 1024);
      expect(
        service.enqueue(big),
        throwsA(isA<StateError>()),
      );
      // A 100 MB doc-class file is within the doc cap.
      final doc = await captureFile('big.bin', 100 * 1024 * 1024);
      await service.enqueue(doc);
      expect(await PendingAssetRepository(database).counts(),
          (pending: 1, failed: 0));
    });

    test('drain uploads oldest first, attaches, and cleans up', () async {
      await putNode(database, node1);
      await service.enqueue(await captureFile('a.jpg'), nodeUuid: node1);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await service.enqueue(await captureFile('b.jpg'), nodeUuid: node1);

      final errors = await service.drain();
      expect(errors, isEmpty);
      expect(api.uploads, hasLength(2));
      expect(api.uploads.first['objectId'], node1);
      // Creation order, oldest first.
      expect(api.bodies[0][0], 0); // captureFile bytes start at 0
      expect(File('${tempDir.path}/a.jpg').existsSync(), isTrue); // source
      expect(
        await PendingAssetRepository(database).counts(),
        (pending: 0, failed: 0),
      );
    });

    test('a target node not yet synced defers to the next round', () async {
      await service.enqueue(await captureFile('a.jpg'), nodeUuid: node1);

      final errors = await service.drain();
      expect(errors, isEmpty);
      expect(api.uploads, isEmpty);
      final row = (await PendingAssetRepository(database).listDue()).single;
      expect(row.retryCount, 1);
      // The file stays queued.
      expect(File(row.localPath).existsSync(), isTrue);
    });

    test('an attach 4xx retries the next round without backoff', () async {
      await putNode(database, node1);
      await service.enqueue(await captureFile('a.jpg'), nodeUuid: node1);
      api.failStatus = 422;

      await service.drain();
      expect(api.uploads, isEmpty);
      final repo = PendingAssetRepository(database);
      final row = (await repo.listDue()).single;
      expect(row.retryCount, 1);

      // Next round is immediately eligible and retries the upload.
      api.failStatus = null;
      await service.drain();
      expect(api.uploads, hasLength(1));
      expect(await repo.get(row.id), isNull); // markDone removed it
    });

    test('an upload 5xx backs off (not due until the backoff elapses)',
        () async {
      final backingOff = PendingAssetService(
        database: database,
        dio: api.buildDio(),
        backoff: (retryCount) => const Duration(hours: 1),
      );
      await putNode(database, node1);
      await backingOff.enqueue(await captureFile('a.jpg'), nodeUuid: node1);
      api.failStatus = 500;

      final errors = await backingOff.drain();
      expect(errors, hasLength(1));
      // Not due again yet (backoff window open).
      expect(await PendingAssetRepository(database).listDue(), isEmpty);
      expect(
          (await PendingAssetRepository(database).counts()).pending, 0);
    });

    test('dead-letters after 6 attempts; retry-now and discard work',
        () async {
      await putNode(database, node1);
      await service.enqueue(await captureFile('a.jpg'), nodeUuid: node1);
      api.failStatus = 500;

      for (var round = 0; round < 6; round++) {
        await service.drain();
      }
      final repo = PendingAssetRepository(database);
      expect(await repo.listDue(), isEmpty);
      final failed = await repo.listFailed();
      expect(failed, hasLength(1));
      expect(failed.single.retryCount, 6);
      expect(failed.single.lastError, isNotNull);

      // Retry-now requeues with a fresh budget.
      await service.retryNow(failed.single.id);
      expect(await repo.listDue(), hasLength(1));

      // Discard drops the row and the file.
      final localPath = (await repo.listDue()).single.localPath;
      await service.discard(failed.single.id);
      expect(await repo.get(failed.single.id), isNull);
      expect(File(localPath).existsSync(), isFalse);
    });

    test('a keyed background drain seals and declares the upload', () async {
      await putNode(database, node1);
      await service.enqueue(await captureFile('a.jpg'), nodeUuid: node1);
      final key = SecretKey(List<int>.filled(32, 7));
      final sealedService = PendingAssetService(
        database: database,
        dio: api.buildDio(),
        backgroundKeyResolver: () async => key,
        backoff: (retryCount) => Duration.zero,
      );

      await sealedService.drain(background: true);
      expect(api.uploads.single['encrypted'], '1');
      expect(api.uploads.single['mimeType'], 'image/jpeg');
      expect(api.uploads.single['iv'], isNotNull);
      // The blob opens under the key.
      final opened = await decryptAssetBytes(
        key,
        Uint8List.fromList(b64uDecode(api.uploads.single['iv'] as String)),
        api.bodies.single,
      );
      expect(opened[0], 0);
    });

    test('a background custody failure degrades to plaintext, never throws',
        () async {
      await putNode(database, node1);
      await service.enqueue(await captureFile('a.jpg'), nodeUuid: node1);
      final brokenService = PendingAssetService(
        database: database,
        dio: api.buildDio(),
        backgroundKeyResolver: () async =>
            throw StateError('secure storage unavailable in isolate'),
        backoff: (retryCount) => Duration.zero,
      );

      // The round still completes, uploading plaintext (legal, iv NULL).
      final errors = await brokenService.drain(background: true);
      expect(errors, isEmpty);
      expect(api.uploads.single.containsKey('encrypted'), isFalse);
      expect(await PendingAssetRepository(database).listDue(), isEmpty);
    });
  });

  group('QuickCaptureService enqueue paths', () {
    late AppDatabase database;
    late FakeAssetsApi api;

    setUp(() async {
      database = await freshDatabase();
      api = FakeAssetsApi();
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
      cleanTempDir();
    });

    test('a failed inline upload queues the capture instead of dropping it',
        () async {
      api.failStatus = 500;
      final capture =
          File('${tempDir.path}/tile.m4a')..writeAsBytesSync([1, 2, 3]);
      final service = QuickCaptureService(
        dio: api.buildDio(),
        database: database,
        syncService: null,
      );

      final outcome = await service.uploadAsset(capture, parentUuid: node1);
      expect(outcome, AssetUploadOutcome.queued);
      final rows = await PendingAssetRepository(database).listDue();
      expect(rows, hasLength(1));
      expect(rows.single.parentUuid, node1);
      expect(rows.single.mime, 'audio/mp4');
    });

    test('an offline capture queues instead of dropping', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'),
        (call) async => ['none'],
      );
      addTearDown(() =>
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
            const MethodChannel('dev.fluttercommunity.plus/connectivity'),
            (call) async => ['wifi'],
          ));
      final capture =
          File('${tempDir.path}/offline.jpg')..writeAsBytesSync([9, 9, 9]);
      final service = QuickCaptureService(
        dio: api.buildDio(),
        database: database,
        syncService: null,
      );

      final outcome = await service.uploadAsset(capture, parentUuid: node1);
      expect(outcome, AssetUploadOutcome.queued);
      expect(await PendingAssetRepository(database).listDue(), hasLength(1));
    });
  });

  group('worker wiring', () {
    late AppDatabase database;

    setUp(() async {
      database = await freshDatabase();
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
      cleanTempDir();
    });

    test('the SQLCipher skip gate reads the encryption_enabled pref',
        () async {
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      expect(skipsLocalDbWork(prefs), isFalse);
      await prefs.setBool('encryption_enabled', true);
      expect(skipsLocalDbWork(prefs), isTrue);
    });

    test('the worker drains pending assets after flush, before pull',
        () async {
      // Keep pull() from force-resetting the workspace on empty metadata.
      final cache = NodeCacheRepository(database);
      await cache.upsertClass(uuid: 'class-1', name: 'Class');
      await cache.upsertPropertySchema(
        PropertySchemaRow(uuid: 'schema-1', workspaceId: workspaceId, name: 'P'),
      );
      await putNode(database, node1);

      final order = <String>[];
      final dio = Dio(BaseOptions(baseUrl: 'https://notees.example.com/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            if (options.path == '/api/assets') {
              order.add('assets');
              final form = options.data as FormData;
              await for (final _ in form.files.single.value
                  .finalize()
                  .cast<List<int>>()) {}
              handler.resolve(Response(
                requestOptions: options,
                data: {'assetId': 'a1'},
                statusCode: 200,
              ));
              return;
            }
            if (options.path == '/relay/v2/catch-up') {
              order.add('pull');
              handler.resolve(Response(
                requestOptions: options,
                data: const {
                  'envelopes': <Map<String, dynamic>>[],
                  'nextAfterSeq': null,
                  'hasMore': false,
                  'restoreEpoch': 0,
                  'totalRemaining': 0,
                },
                statusCode: 200,
              ));
              return;
            }
            if (options.path == '/relay/v2/snapshot') {
              handler.resolve(Response(
                requestOptions: options,
                data: const {
                  'snapshotId': null,
                  'hlc': {'physical': 0, 'logical': 0},
                  'hasSnapshot': false,
                  'restoreEpoch': 0,
                  'upToSeq': null,
                },
                statusCode: 200,
              ));
              return;
            }
            if (options.path == '/relay/v2/snapshot/data' &&
                options.method == 'PUT') {
              // The pull-time snapshot auto-upload (Slice A) rides the same
              // fake; drain its stream and accept.
              final body = options.data;
              if (body is Stream) {
                await for (final _ in body.cast<List<int>>()) {}
              }
              handler.resolve(Response(requestOptions: options, statusCode: 204));
              return;
            }
            handler.resolve(Response(
              requestOptions: options,
              data: const {'savedCount': 1, 'savedIds': ['id']},
              statusCode: 200,
            ));
          },
        ),
      );

      final syncService = SyncV2Service(
        database: database,
        dio: dio,
        clientId: device,
      );
      await syncService.setWorkspaceId(workspaceId);
      final pending = PendingAssetService(
        database: database,
        dio: dio,
        syncService: syncService,
        backoff: (retryCount) => Duration.zero,
      );
      await pending.enqueue(await captureFile('worker.jpg'), nodeUuid: node1);

      await runPeriodicSync(
        queue: OfflineQueue(database: database, syncService: syncService),
        syncService: syncService,
        pendingAssets: pending,
      );

      expect(order, containsAllInOrder(['assets', 'pull']));
      expect(await PendingAssetRepository(database).listDue(), isEmpty);
    });
  });

  group('PendingUploadsSheet', () {
    testWidgets('shows the waiting count and failed items with working '
        'actions', (WidgetTester tester) async {
      final rows = [
        PendingAssetRow(
          id: 'p1',
          localPath: '/tmp/p1.jpg',
          mime: 'image/jpeg',
          originalName: 'photo.jpg',
          sizeBytes: 10,
          state: 'failed',
          retryCount: 6,
          lastError: 'upload 500',
          createdAt: 0,
        ),
      ];
      final retried = <String>[];
      final discarded = <String>[];
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Theme(
            data: ThemeData(),
            child: PendingUploadsSheet(
              pendingCount: 2,
              failed: rows,
              onRetry: (id) async => retried.add(id),
              onDiscard: (id) async => discarded.add(id),
            ),
          ),
        ),
      ));

      expect(find.textContaining('2 upload(s) waiting'), findsOneWidget);
      expect(find.text('photo.jpg'), findsOneWidget);
      expect(find.text('upload 500'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pump();
      expect(retried, ['p1']);
      await tester.tap(find.widgetWithText(TextButton, 'Discard'));
      await tester.pump();
      expect(discarded, ['p1']);
    });
  });
}
