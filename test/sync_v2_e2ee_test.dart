import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/payload_crypto.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The E2EE sync boundary (spec §2, plan-04): decrypt-before-apply at the
/// single remote-apply chokepoint, encrypt-a-copy at push (outbox row +
/// local echo stay plaintext), snapshot seal/decrypt at the engine
/// boundary, and the locked semantic (no key ⇒ `$e` skipped with a counted
/// warning, cursor advances, sync stays green). Fake-Dio harness mirroring
/// sync_v2_pull_test.dart.
/// In-memory stand-in for the relay: holds the op log (ascending seqs),
/// pushed batches, and an optional snapshot blob.
class FakeRelay {
  final envelopes = <Map<String, dynamic>>[]; // each carries its seq
  final pushedBatches = <List<Map<String, dynamic>>>[];
  Uint8List? snapshotBlob;
  int? snapshotUpToSeq;
  var nextSeq = 0;

  void ingestBatch(List<Map<String, dynamic>> batch) {
    pushedBatches.add(batch);
    for (final envelope in batch) {
      nextSeq++;
      envelopes.add({...envelope, 'seq': nextSeq});
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  // buildV2SnapshotBytes writes a temp file via path_provider; serve a
  // real temp directory on the plugin channel (pattern from
  // sync_v2_realtime_test.dart).
  final tempDir = Directory.systemTemp.createTempSync('notees_e2ee_test');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => tempDir.path,
  );

  const workspaceId = '10000000-0000-4000-8000-000000000001';
  const node1 = '20000000-0000-4000-8000-000000000001';
  const node2 = '20000000-0000-4000-8000-000000000002';
  const user1 = '30000000-0000-4000-8000-000000000001';
  const device = '40000000-0000-4000-8000-000000000001';

  /// One shared workspace key; the server-held sealed envelopes below are
  /// produced with it (a second device holding the same key).
  final workspaceKey = importWorkspaceKey(
    b64uEncode(List<int>.generate(32, (i) => 0x42)),
  );

  Dio buildDio(FakeRelay relay) {
    final dio = Dio(BaseOptions(baseUrl: 'https://notees.example.com/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/relay/v2/snapshot') {
            handler.resolve(Response(
              requestOptions: options,
              data: {
                'snapshotId': relay.snapshotBlob != null ? 'snap-1' : null,
                'hlc': {
                  'physical': relay.snapshotBlob != null ? 99 : 0,
                  'logical': 0,
                },
                'hasSnapshot': relay.snapshotBlob != null,
                'restoreEpoch': 0,
                'upToSeq': relay.snapshotUpToSeq,
              },
              statusCode: 200,
            ));
            return;
          }
          if (options.path == '/relay/v2/snapshot/data' &&
              options.method == 'GET') {
            final blob = relay.snapshotBlob;
            if (blob == null) {
              handler.reject(DioException(
                requestOptions: options,
                response: Response(
                  requestOptions: options,
                  statusCode: 404,
                ),
                type: DioExceptionType.badResponse,
              ));
              return;
            }
            handler.resolve(Response(
              requestOptions: options,
              data: blob.toList(),
              statusCode: 200,
            ));
            return;
          }
          if (options.path == '/relay/v2/snapshot/data' &&
              options.method == 'PUT') {
            relay.snapshotBlob =
                Uint8List.fromList(options.data as List<int>);
            handler.resolve(Response(requestOptions: options, statusCode: 204));
            return;
          }
          if (options.path == '/relay/v2/catch-up') {
            final afterSeq =
                (options.data as Map<String, dynamic>)['afterSeq'] as int? ??
                    0;
            final page = relay.envelopes
                .where((e) => (e['seq'] as int) > afterSeq)
                .toList();
            handler.resolve(Response(
              requestOptions: options,
              data: {
                'envelopes': page,
                'nextAfterSeq':
                    page.isEmpty ? null : page.last['seq'],
                'hasMore': false,
                'restoreEpoch': 0,
                'totalRemaining': 0,
              },
              statusCode: 200,
            ));
            return;
          }
          if (options.path == '/relay/v2/batch') {
            final body = options.data as Map<String, dynamic>;
            final batch = (body['envelopes'] as List<dynamic>)
                .cast<Map<String, dynamic>>();
            relay.ingestBatch(batch);
            handler.resolve(Response(
              requestOptions: options,
              data: {
                'savedCount': batch.length,
                'savedIds': batch.map((e) => e['id']).toList(),
              },
              statusCode: 200,
            ));
            return;
          }
          handler.reject(DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            error: 'unexpected request: ${options.method} ${options.path}',
          ));
        },
      ),
    );
    return dio;
  }

  Map<String, dynamic> createPayload(String objectId, String text) => {
        'objectId': objectId,
        'contentAst': [
          {'type': 'text', 'text': text},
        ],
        'isEmbedded': false,
        'classIds': <String>[],
      };

  Map<String, dynamic> envelopeJson(
    String id,
    Map<String, dynamic> payload, {
    int physical = 1,
  }) =>
      {
        'id': id,
        'protocolVersion': 3,
        'workspaceId': workspaceId,
        'actorId': user1,
        'deviceId': device,
        'hlc': {'physical': physical, 'logical': 0},
        'affectedNodeIds': [payload['objectId']],
        'opType': 'object.create',
        'payload': payload,
        'timestamp': '2026-09-24T12:00:00.000Z',
      };

  /// Seals an envelope server-side (a keyed device produced it) and returns
  /// its wire JSON.
  Future<Map<String, dynamic>> sealedEnvelopeJson(
    String id,
    Map<String, dynamic> payload,
  ) async {
    final envelope = OperationEnvelope.fromJson(envelopeJson(id, payload));
    return (await encryptEnvelope(workspaceKey, envelope)).toJson();
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

  Future<SyncV2Service> buildService(
    AppDatabase database,
    FakeRelay relay,
  ) async {
    final service = SyncV2Service(
      database: database,
      dio: buildDio(relay),
      clientId: device,
    );
    await service.setWorkspaceId(workspaceId);
    return service;
  }

  Future<int> cursorSeq(AppDatabase database) async {
    final db = await database.database;
    final rows = await db.query(
      'sync_watermark',
      columns: ['cursor_seq'],
      where: 'workspace_id = ?',
      whereArgs: const [workspaceId],
    );
    if (rows.isEmpty) return 0;
    return rows.first['cursor_seq'] as int? ?? 0;
  }

  setUpAll(() {
    NodeCacheRepository.snapshotDbOpener =
        (path) => databaseFactoryFfi.openDatabase(
              path,
              options: OpenDatabaseOptions(singleInstance: false),
            );
  });

  group('SyncV2Service E2EE boundary', () {
    late AppDatabase database;
    late FakeRelay relay;

    setUp(() async {
      database = await freshDatabase();
      relay = FakeRelay();
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
    });

    test('flush encrypts a copy on the wire; outbox row + local echo stay '
        'plaintext', () async {
      final service = await buildService(database, relay);
      service.workspaceKey = workspaceKey;

      await service.enqueue(
        type: 'create',
        nodeUuid: node1,
        contentAst: const [
          {'type': 'text', 'text': 'secret page'},
        ],
        isPage: true,
      );
      await service.flush();

      // The wire batch carried the sealed envelope…
      expect(relay.pushedBatches, hasLength(1));
      final wirePayload =
          relay.pushedBatches.single.single['payload'] as Map<String, dynamic>;
      expect(wirePayload.keys, [r'$e']);
      final opened = await decryptPayload(
        workspaceKey,
        envelopeAad(OperationEnvelope.fromJson(
            relay.pushedBatches.single.single)),
        wirePayload[r'$e'] as Map<String, dynamic>,
      );
      expect(opened['objectId'], node1);

      // …the local echo stayed plaintext (applied to the cache)…
      expect((await service.cache.getByUuid(node1))!.displayName,
          'secret page');

      // …and the recorded operation is plaintext too.
      final db = await database.database;
      final rows = await db.query(
        'relay_operations',
        where: 'op_type = ?',
        whereArgs: const ['object.create'],
      );
      expect(rows, hasLength(1));
      final recorded = jsonDecode(rows.single['payload'] as String)
          as Map<String, dynamic>;
      expect(recorded['objectId'], node1);
      expect(recorded.containsKey(r'$e'), isFalse);
      // The outbox row is consumed; nothing sealed lingers locally.
      expect(await db.query('relay_outbox'), isEmpty);
    });

    test('flush with no key pushes plaintext (locked stays green)', () async {
      final service = await buildService(database, relay);
      expect(service.hasWorkspaceKey, isFalse);

      await service.enqueue(
        type: 'create',
        nodeUuid: node1,
        contentAst: const [
          {'type': 'text', 'text': 'plain page'},
        ],
        isPage: true,
      );
      final errors = await service.flush();

      expect(errors, isEmpty);
      final wirePayload =
          relay.pushedBatches.single.single['payload'] as Map<String, dynamic>;
      expect(wirePayload.containsKey(r'$e'), isFalse);
    });

    test('pull decrypts sealed envelopes before apply', () async {
      relay.envelopes.add({
        ...await sealedEnvelopeJson(
          '0192a000-0000-7000-8000-000000000002',
          createPayload(node2, 'sealed page'),
        ),
        'seq': 1,
      });
      relay.nextSeq = 1;

      final service = await buildService(database, relay);
      service.workspaceKey = workspaceKey;
      await service.pull();

      expect((await service.cache.getByUuid(node2))!.displayName,
          'sealed page');
      expect(await cursorSeq(database), 1);
      expect(service.lockedSkipCount, 0);
    });

    test('locked mixed batch: plaintext applies, \$e skipped with a counted '
        'warning, cursor advances, sync green', () async {
      relay.envelopes
        ..add({
          ...envelopeJson(
            '0192a000-0000-7000-8000-000000000001',
            createPayload(node1, 'plain page'),
          ),
          'seq': 1,
        })
        ..add({
          ...await sealedEnvelopeJson(
            '0192a000-0000-7000-8000-000000000002',
            createPayload(node2, 'sealed page'),
          ),
          'seq': 2,
        });
      relay.nextSeq = 2;

      final service = await buildService(database, relay);
      expect(service.hasWorkspaceKey, isFalse);
      await service.pull();

      // Plaintext applied; the encrypted envelope skipped (never recorded)…
      expect((await service.cache.getByUuid(node1))!.displayName, 'plain page');
      expect(await service.cache.getByUuid(node2), isNull);
      expect(service.lockedSkipCount, 1);
      final db = await database.database;
      expect(await db.query('relay_operations'), hasLength(1));

      // …and the cursor advanced over BOTH envelopes: no re-fetch loop.
      expect(await cursorSeq(database), 2);
    });

    test('two-device convergence: A pushes sealed, B pulls and decrypts',
        () async {
      // Device A: keyed flush onto the shared relay.
      final serviceA = await buildService(database, relay);
      serviceA.workspaceKey = workspaceKey;
      await serviceA.enqueue(
        type: 'create',
        nodeUuid: node1,
        contentAst: const [
          {'type': 'text', 'text': 'shared page'},
        ],
        isPage: true,
      );
      await serviceA.flush();
      await database.close();
      AppDatabase.reset();

      // Device B: fresh derived state, same key, pulls the sealed log.
      final databaseB = await freshDatabase();
      addTearDown(() async {
        await databaseB.close();
        AppDatabase.reset();
      });
      final serviceB = await buildService(databaseB, relay);
      serviceB.workspaceKey = workspaceKey;
      await serviceB.pull();

      expect(
          (await serviceB.cache.getByUuid(node1))!.displayName, 'shared page');
      expect(await cursorSeq(databaseB), 1);
    });

    test('snapshot upload seals a copy; restore decrypts it at the boundary',
        () async {
      // Device A: keyed flush + sealed snapshot upload.
      final serviceA = await buildService(database, relay);
      serviceA.workspaceKey = workspaceKey;
      await serviceA.enqueue(
        type: 'create',
        nodeUuid: node1,
        contentAst: const [
          {'type': 'text', 'text': 'snapshot me'},
        ],
        isPage: true,
      );
      await serviceA.flush();
      relay.snapshotUpToSeq = 1;
      await serviceA.uploadSnapshot();

      // The stored blob is sealed — it does not even parse as a database…
      final blob = relay.snapshotBlob!;
      expect(blob, isNotNull);
      final text = latin1.decode(blob.toList(), allowInvalid: true);
      expect(text.contains('snapshot me'), isFalse);
      // …and opens under the workspace key.
      final opened = await decryptBytes(workspaceKey, blob);
      expect(latin1.decode(opened.toList(), allowInvalid: true)
          .contains('snapshot me'), isTrue);

      // Device B (fresh) restores through the sealed snapshot.
      await database.close();
      AppDatabase.reset();
      final databaseB = await freshDatabase();
      addTearDown(() async {
        await databaseB.close();
        AppDatabase.reset();
      });
      final serviceB = await buildService(databaseB, relay);
      serviceB.workspaceKey = workspaceKey;
      await serviceB.pull();

      expect((await serviceB.cache.getByUuid(node1))!.displayName,
          'snapshot me');
      expect(await cursorSeq(databaseB), 1);
    });

    test('snapshot restore with a wrong key fails loud (real corruption)',
        () async {
      relay.snapshotBlob = await encryptBytes(
        importWorkspaceKey(b64uEncode(List<int>.filled(32, 0x11))),
        Uint8List.fromList(latin1.encode('not a database at all')),
      );
      relay.snapshotUpToSeq = 1;

      final service = await buildService(database, relay);
      service.workspaceKey = workspaceKey;
      await expectLater(
        service.pull(),
        throwsA(isA<SyncV2Exception>()),
      );
    });
  });
}
