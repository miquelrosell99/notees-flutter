import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/payload_crypto.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:notees/features/settings/widgets/rebuild_local_tile.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The local-first derived rebuild (`rebuildLocalDerivedState`) — a
/// mobile-only capability (the web client has no local archive and no
/// manual rebuild). Covers convergence after corruption, offline operation,
/// the E2EE and keyless arms, watermark preservation, local-op inclusion,
/// the in-flight guard, and the confirm sheet.
/// Serves a snapshot-less relay; [catchUpPage] replays over catch-up.
/// Every request is recorded so the offline test can assert zero use.
class FakeRelay {
  FakeRelay({this.catchUpPage, this.blockCatchUp = false});

  Map<String, dynamic>? catchUpPage;
  final bool blockCatchUp;
  final requests = <String>[];
  final catchUpStarted = Completer<void>();
  var releaseCatchUp = Completer<void>();

  Dio buildDio() {
    final dio = Dio(BaseOptions(baseUrl: 'https://notees.example.com/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          requests.add('${options.method} ${options.path}');
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
          if (options.path == '/relay/v2/catch-up') {
            if (blockCatchUp) {
              if (!catchUpStarted.isCompleted) {
                catchUpStarted.complete();
              }
              await releaseCatchUp.future;
            }
            handler.resolve(Response(
              requestOptions: options,
              data: catchUpPage ??
                  const {
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
          handler.resolve(Response(
            requestOptions: options,
            data: const {'savedCount': 1, 'savedIds': ['id']},
            statusCode: 200,
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

  const workspaceId = '10000000-0000-4000-8000-000000000001';
  const node1 = '20000000-0000-4000-8000-000000000001';
  const node2 = '20000000-0000-4000-8000-000000000002';
  const user1 = '30000000-0000-4000-8000-000000000001';
  const device = '40000000-0000-4000-8000-000000000001';

  final workspaceKey = importWorkspaceKey(
    b64uEncode(List<int>.generate(32, (i) => 0x42)),
  );

  Map<String, dynamic> envelopeJson(
    String id,
    String objectId,
    String text, {
    int physical = 1,
  }) =>
      {
        'id': id,
        'protocolVersion': 3,
        'workspaceId': workspaceId,
        'actorId': user1,
        'deviceId': device,
        'hlc': {'physical': physical, 'logical': 0},
        'affectedNodeIds': [objectId],
        'opType': 'object.create',
        'payload': {
          'objectId': objectId,
          'contentAst': [
            {'type': 'text', 'text': text},
          ],
          'isEmbedded': false,
          'classIds': <String>[],
        },
        'timestamp': '2026-09-24T12:00:00.000Z',
      };

  Future<SyncV2Service> buildService(
    AppDatabase database,
    FakeRelay relay, {
    bool keyed = false,
  }) async {
    final service = SyncV2Service(
      database: database,
      dio: relay.buildDio(),
      clientId: device,
    );
    await service.setWorkspaceId(workspaceId);
    if (keyed) service.workspaceKey = workspaceKey;
    return service;
  }

  Future<AppDatabase> freshDatabase() async {
    final ffiDb = await databaseFactoryFfi.openDatabase(
      ':memory:',
      options: OpenDatabaseOptions(singleInstance: false),
    );
    final database = AppDatabase.fromDatabase(ffiDb);
    await database.initializeSchema();
    // Keep pull() from force-resetting the workspace on empty metadata.
    final cache = NodeCacheRepository(database);
    await cache.upsertClass(uuid: 'class-1', name: 'Class');
    await cache.upsertPropertySchema(
      PropertySchemaRow(uuid: 'schema-1', workspaceId: workspaceId, name: 'P'),
    );
    return database;
  }

  group('SyncV2Service.rebuildLocalDerivedState', () {
    late AppDatabase database;
    late SyncV2Service service;
    late FakeRelay relay;

    setUp(() async {
      database = await freshDatabase();
      relay = FakeRelay();
      service = await buildService(database, relay);
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
    });

    Future<void> seedLocalOp(String nodeUuid, String text) async {
      await service.enqueue(
        type: 'create',
        nodeUuid: nodeUuid,
        contentAst: [
          {'type': 'text', 'text': text},
        ],
        isPage: true,
      );
      await service.flush();
    }

    Future<List<Map<String, dynamic>>> derivedSnapshot() async {
      final db = await database.database;
      final nodes = await db.rawQuery(
        'SELECT uuid, title, is_page FROM node_cache ORDER BY uuid',
      );
      final props = await db.rawQuery(
        'SELECT node_uuid, property_schema_id, value, idx FROM property_value '
        'ORDER BY node_uuid, property_schema_id, idx',
      );
      return [...nodes, ...props];
    }

    Future<Map<String, Object?>> watermarkRow() async {
      final db = await database.database;
      final rows = await db.query(
        'sync_watermark',
        where: 'workspace_id = ?',
        whereArgs: const [workspaceId],
      );
      return rows.single;
    }

    test('rebuild converges after corrupting the derived state', () async {
      await seedLocalOp(node1, 'baseline page');
      await seedLocalOp(node2, 'second page');

      final baseline = await derivedSnapshot();
      expect(baseline, isNotEmpty);

      // Corrupt: wipe the node cache and scramble property rows.
      final db = await database.database;
      await db.delete('node_cache');
      await db.delete('property_value');
      expect(await service.cache.getByUuid(node1), isNull);

      final replayed = await service.rebuildLocalDerivedState();
      expect(replayed, 2);
      expect(await derivedSnapshot(), baseline);
      expect((await service.cache.getByUuid(node1))!.displayName,
          'baseline page');
    });

    test('rebuild performs zero network calls', () async {
      await seedLocalOp(node1, 'offline page');
      relay.requests.clear();

      final replayed = await service.rebuildLocalDerivedState();
      expect(replayed, 1);
      expect(relay.requests, isEmpty);
      expect((await service.cache.getByUuid(node1))!.displayName,
          'offline page');
    });

    test('local ops (is_local=1) are included in the replay', () async {
      await seedLocalOp(node1, 'local only');
      final db = await database.database;
      final local = await db.query(
        'relay_operations',
        where: 'workspace_id = ? AND is_local = 1',
        whereArgs: const [workspaceId],
      );
      expect(local, isNotEmpty);

      await service.rebuildLocalDerivedState();
      expect(await service.cache.getByUuid(node1), isNotNull);
    });

    test('watermarks are preserved across the rebuild', () async {
      // Seed a server op via pull so the cursor + received HLC advance.
      relay.catchUpPage = {
        'envelopes': [envelopeJson('0192a000-0000-7000-8000-000000000001',
            node1, 'server page')],
        'nextAfterSeq': 1,
        'hasMore': false,
        'restoreEpoch': 0,
        'totalRemaining': 0,
      };
      await service.pull();
      final before = await watermarkRow();

      final replayed = await service.rebuildLocalDerivedState();
      expect(replayed, 1);
      expect(await watermarkRow(), before);
    });

    test('E2EE arm: a keyed session replays sealed-wire content through '
        'custody', () async {
      // Keyed flush: the wire copy is sealed, the archive row is the
      // decrypted envelope — rebuild converges with the key held.
      service.workspaceKey = workspaceKey;
      await seedLocalOp(node1, 'sealed page');
      final db = await database.database;
      final row = (await db.query(
        'relay_operations',
        where: 'workspace_id = ?',
        whereArgs: const [workspaceId],
      )).single;
      final payload =
          jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      expect(payload.containsKey(r'$e'), isFalse);

      final replayed = await service.rebuildLocalDerivedState();
      expect(replayed, 1);
      expect(
          (await service.cache.getByUuid(node1))!.displayName, 'sealed page');
    });

    test('E2EE arm: an archive row carrying an encrypted-slot payload '
        'decrypts with the key held and skips keyless', () async {
      // A sealed server envelope recorded RAW (as a future recorder might):
      // the rebuild must route it through the same decrypt path as live
      // apply.
      final sealed = await encryptEnvelope(
        workspaceKey,
        OperationEnvelope.fromJson(envelopeJson(
          '0192a000-0000-7000-8000-000000000099',
          node2,
          'sealed archive page',
        )),
      );
      final db = await database.database;
      await db.insert('relay_operations', {
        'id': sealed.id,
        'workspace_id': workspaceId,
        'actor_id': user1,
        'hlc_physical': sealed.hlc.physical,
        'hlc_logical': sealed.hlc.logical,
        'affected_node_ids': jsonEncode(sealed.affectedNodeIds),
        'op_type': sealed.opType,
        'payload': jsonEncode(sealed.payload),
        'timestamp': sealed.timestamp,
        'is_local': 0,
      });

      // Keyless: the $e row is skipped (the locked semantic), not applied.
      final skipped = await service.rebuildLocalDerivedState();
      expect(skipped, 0);
      expect(await service.cache.getByUuid(node2), isNull);

      // Keyed: decrypts through custody and applies.
      service.workspaceKey = workspaceKey;
      final replayed = await service.rebuildLocalDerivedState();
      expect(replayed, 1);
      expect((await service.cache.getByUuid(node2))!.displayName,
          'sealed archive page');
    });

    test('rebuild refuses to run while a pull is in flight', () async {
      final blockingRelay = FakeRelay(blockCatchUp: true);
      final blockingService = await buildService(database, blockingRelay);

      final pullFuture = blockingService.pull();
      await blockingRelay.catchUpStarted.future;
      expect(
        blockingService.rebuildLocalDerivedState(),
        throwsA(isA<StateError>()),
      );

      blockingRelay.releaseCatchUp.complete();
      await pullFuture;
    });

    test('a mid-replay failure leaves the store cleared and reports loud',
        () async {
      await seedLocalOp(node1, 'doomed page');
      // Poison the archive with an envelope that kills the appliers.
      final db = await database.database;
      await db.insert('relay_operations', {
        'id': '0192a000-0000-7000-8000-0000000000ff',
        'workspace_id': workspaceId,
        'actor_id': user1,
        'hlc_physical': 999999,
        'hlc_logical': 0,
        'affected_node_ids': '["$node2"]',
        'op_type': 'class.create',
        'payload': '{not json',
        'timestamp': '2026-09-24T12:00:00.000Z',
        'is_local': 0,
      });

      await expectLater(
        service.rebuildLocalDerivedState(),
        throwsA(anything),
      );
      // The cleared store stays cleared; re-running after fixing the
      // archive converges (idempotent by construction).
      expect(await service.cache.getByUuid(node1), isNull);
      await db.delete(
        'relay_operations',
        where: 'id = ?',
        whereArgs: const ['0192a000-0000-7000-8000-0000000000ff'],
      );
      final replayed = await service.rebuildLocalDerivedState();
      expect(replayed, 1);
      expect(
          (await service.cache.getByUuid(node1))!.displayName, 'doomed page');
    });
  });

  group('RebuildConfirmSheet', () {
    testWidgets('Cancel pops false, Rebuild pops true',
        (WidgetTester tester) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                result = await showModalBottomSheet<bool>(
                  context: context,
                  builder: (_) => const RebuildConfirmSheet(),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Rebuild local data?'), findsOneWidget);
      expect(find.textContaining('keeps unsynced changes'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(result, isFalse);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Rebuild'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    });
  });
}
