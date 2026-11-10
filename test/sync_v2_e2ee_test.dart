import 'dart:convert';
import 'dart:io';

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

  /// What the stored snapshot row declares (the single-PUT/commit `sealed`
  /// flag, served back in `GET /snapshot` meta).
  bool snapshotSealed = false;
  int? snapshotUpToSeq;

  /// Staged multipart parts: index → bytes, in arrival order.
  final parts = <int, Uint8List>{};
  String? lastUploadId;
  Map<String, dynamic>? lastCommit;
  int? lastPartCount;
  List<int>? lastPartSizes;
  var snapshotDataGets = 0;
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

  /// The file-based snapshot pipeline's temp files (the pull must always
  /// clean them up, success or failure).
  List<FileSystemEntity> snapshotTempFiles() => tempDir
      .listSync()
      .where((entity) => entity.path.contains('notees_snapshot_'))
      .toList();

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
                'sealed': relay.snapshotSealed,
              },
              statusCode: 200,
            ));
            return;
          }
          if (options.path == '/relay/v2/snapshot/data' &&
              options.method == 'GET') {
            relay.snapshotDataGets++;
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
            relay.snapshotSealed =
                options.queryParameters['sealed'] == '1';
            handler.resolve(Response(requestOptions: options, statusCode: 204));
            return;
          }
          if (options.path == '/relay/v2/snapshot/data/part' &&
              options.method == 'PUT') {
            final index = options.queryParameters['index'] as int;
            relay.lastUploadId =
                options.queryParameters['upload'] as String;
            expect(
              relay.parts.containsKey(index),
              isFalse,
              reason: 'duplicate part index $index',
            );
            relay.parts[index] =
                Uint8List.fromList(options.data as List<int>);
            handler.resolve(Response(
              requestOptions: options,
              data: {
                'upload': relay.lastUploadId,
                'index': index,
              },
              statusCode: 201,
            ));
            return;
          }
          if (options.path == '/relay/v2/snapshot/data/commit' &&
              options.method == 'POST') {
            relay.lastCommit = Map<String, dynamic>.from(
                options.queryParameters);
            final partCount = options.queryParameters['parts'] as int;
            relay.lastPartCount = partCount;
            relay.lastPartSizes =
                relay.parts.values.map((p) => p.length).toList();
            final assembled = <int>[];
            for (var i = 0; i < partCount; i++) {
              assembled.addAll(relay.parts[i]!.toList());
            }
            relay.snapshotBlob = Uint8List.fromList(assembled);
            relay.snapshotSealed =
                options.queryParameters['sealed'] == '1';
            relay.parts.clear();
            handler.resolve(Response(
              requestOptions: options,
              data: {'snapshotId': 'snap-committed'},
              statusCode: 201,
            ));
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

      // The upload declared sealed=1 (the snapshot row serves it back).
      expect(relay.snapshotSealed, isTrue);
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
      // The file-based pipeline left nothing behind.
      expect(snapshotTempFiles(), isEmpty);
    });

    test('snapshot restore with a wrong key fails loud (real corruption)',
        () async {
      relay.snapshotBlob = await encryptBytes(
        importWorkspaceKey(b64uEncode(List<int>.filled(32, 0x11))),
        Uint8List.fromList(latin1.encode('not a database at all')),
      );
      relay.snapshotSealed = true;
      relay.snapshotUpToSeq = 1;

      final service = await buildService(database, relay);
      service.workspaceKey = workspaceKey;
      await expectLater(
        service.pull(),
        throwsA(isA<SyncV2Exception>()),
      );
      // A failed restore still cleans its temp files.
      expect(snapshotTempFiles(), isEmpty);
    });

    test('locked: a sealed snapshot blob is skipped with a counted warning; '
        'catch-up covers the content and sync stays green', () async {
      // A keyed device produced the sealed snapshot (uploads are
      // keyed-only); the log below it carries a plaintext and a sealed op.
      relay.snapshotBlob = await encryptBytes(
        workspaceKey,
        Uint8List.fromList(latin1.encode('sealed snapshot bytes')),
      );
      relay.snapshotSealed = true;
      // The snapshot claims to cover seq 5 — a restore would shortcut the
      // cursor there; the skip must NOT adopt that shortcut.
      relay.snapshotUpToSeq = 5;
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

      // The sealed snapshot did NOT restore; catch-up covered the log:
      // plaintext applied, the sealed envelope skipped — both counted.
      expect((await service.cache.getByUuid(node1))!.displayName, 'plain page');
      expect(await service.cache.getByUuid(node2), isNull);
      expect(service.lockedSkipCount, 2);
      // The cursor advanced only over the replayed log, not the snapshot's
      // upToSeq shortcut.
      expect(await cursorSeq(database), 2);
      expect(snapshotTempFiles(), isEmpty);
    });

    test('locked: a plaintext snapshot still restores (the magic probe '
        'passes through)', () async {
      // A locked device uploads a PLAINTEXT snapshot (legacy/keyless
      // workspace); a locked restore must keep restoring it — only blobs
      // lacking the SQLite magic are treated as sealed.
      final serviceA = await buildService(database, relay);
      await serviceA.enqueue(
        type: 'create',
        nodeUuid: node1,
        contentAst: const [
          {'type': 'text', 'text': 'legacy snapshot page'},
        ],
        isPage: true,
      );
      await serviceA.flush();
      relay.snapshotUpToSeq = 1;
      await serviceA.uploadSnapshot();
      // The blob is a real plaintext SQLite image.
      expect(relay.snapshotBlob, isNotNull);
      expect(latin1.decode(relay.snapshotBlob!.toList(), allowInvalid: true)
          .contains('legacy snapshot page'), isTrue);
      await database.close();
      AppDatabase.reset();

      final databaseB = await freshDatabase();
      addTearDown(() async {
        await databaseB.close();
        AppDatabase.reset();
      });
      final serviceB = await buildService(databaseB, relay);
      expect(serviceB.hasWorkspaceKey, isFalse);
      await serviceB.pull();

      expect((await serviceB.cache.getByUuid(node1))!.displayName,
          'legacy snapshot page');
      expect(await cursorSeq(databaseB), 1);
      expect(serviceB.lockedSkipCount, 0);
      expect(snapshotTempFiles(), isEmpty);
    });

    test('keyed: a PLAINTEXT server snapshot is skipped (the empty-store '
        'trap); the log replays instead and the blob is not re-downloaded',
        () async {
      // A keyless device uploaded a plaintext snapshot (legacy workspace);
      // the server now serves it to a KEYED client (e.g. after the workspace
      // was keyed on another device). Restoring the content-empty image and
      // jumping the cursor to upToSeq would blank the workspace — the skip
      // replays the log from the durable cursor instead.
      final serviceA = await buildService(database, relay);
      await serviceA.enqueue(
        type: 'create',
        nodeUuid: node1,
        contentAst: const [
          {'type': 'text', 'text': 'replayed page'},
        ],
        isPage: true,
      );
      await serviceA.flush();
      relay.snapshotUpToSeq = 1;
      await serviceA.uploadSnapshot();
      // Keyless upload ⇒ plaintext row, sealed flag absent.
      expect(relay.snapshotSealed, isFalse);
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

      // The snapshot was skipped (counted), the log replay covered the
      // content, and the cursor advanced over the REPLAY (seq 1), not the
      // snapshot's upToSeq shortcut.
      expect(serviceB.lockedSkipCount, 1);
      expect((await serviceB.cache.getByUuid(node1))!.displayName,
          'replayed page');
      expect(await cursorSeq(databaseB), 1);

      // The watermark marked the snapshot seen: a second pull does not
      // re-download the blob.
      final getsAfterFirst = relay.snapshotDataGets;
      await serviceB.pull();
      expect(relay.snapshotDataGets, getsAfterFirst);
      expect(snapshotTempFiles(), isEmpty);
    });

    test('locked: a sealed snapshot is not re-downloaded after the skip '
        '(the HLC watermark advances)', () async {
      relay.snapshotBlob = await encryptBytes(
        workspaceKey,
        Uint8List.fromList(latin1.encode('sealed snapshot bytes')),
      );
      relay.snapshotSealed = true;
      relay.snapshotUpToSeq = 3;
      relay.envelopes.add({
        ...envelopeJson(
          '0192a000-0000-7000-8000-000000000001',
          createPayload(node1, 'plain page'),
        ),
        'seq': 1,
      });
      relay.nextSeq = 1;

      final service = await buildService(database, relay);
      await service.pull();
      expect(service.lockedSkipCount, 1);
      expect(await cursorSeq(database), 1);

      final getsAfterFirst = relay.snapshotDataGets;
      await service.pull();
      expect(relay.snapshotDataGets, getsAfterFirst);
      expect(snapshotTempFiles(), isEmpty);
    });

    test('upload below the chunk threshold rides a single PUT declaring '
        'sealed=1 (keyed) or no flag (keyless)', () async {
      // Keyed small upload: single PUT (no parts), sealed declared.
      final serviceA = await buildService(database, relay);
      serviceA.workspaceKey = workspaceKey;
      await serviceA.enqueue(
        type: 'create',
        nodeUuid: node1,
        contentAst: const [
          {'type': 'text', 'text': 'small snapshot'},
        ],
        isPage: true,
      );
      await serviceA.flush();
      await serviceA.uploadSnapshot();
      expect(relay.parts, isEmpty);
      expect(relay.lastCommit, isNull);
      expect(relay.snapshotSealed, isTrue);
      expect(relay.snapshotBlob, isNotNull);
      await database.close();
      AppDatabase.reset();

      // Keyless small upload: single PUT, no sealed flag.
      final databaseB = await freshDatabase();
      addTearDown(() async {
        await databaseB.close();
        AppDatabase.reset();
      });
      final serviceB = await buildService(databaseB, relay);
      await serviceB.enqueue(
        type: 'create',
        nodeUuid: node2,
        contentAst: const [
          {'type': 'text', 'text': 'plain small snapshot'},
        ],
        isPage: true,
      );
      await serviceB.flush();
      await serviceB.uploadSnapshot();
      expect(relay.parts, isEmpty);
      expect(relay.lastCommit, isNull);
      expect(relay.snapshotSealed, isFalse);
    });

    test('upload past the chunk threshold rides part+commit (sealed '
        'declared on the commit)', () async {
      // Tiny thresholds stand in for the 48 MiB/64 MiB wire constants so
      // the multipart flow is exercisable with a small snapshot.
      final service = SyncV2Service(
        database: database,
        dio: buildDio(relay),
        clientId: device,
        snapshotChunkThreshold: 64,
        snapshotPartSize: 32,
      );
      await service.setWorkspaceId(workspaceId);
      service.workspaceKey = workspaceKey;
      await service.enqueue(
        type: 'create',
        nodeUuid: node1,
        contentAst: const [
          {'type': 'text', 'text': 'chunked snapshot page'},
        ],
        isPage: true,
      );
      await service.flush();
      await service.uploadSnapshot();

      // No single-PUT: the blob arrived through staged parts + commit.
      expect(relay.lastCommit, isNotNull);
      expect(relay.lastUploadId, isNotNull);
      expect(relay.lastCommit!['sealed'], '1');
      expect(relay.lastCommit!['upload'], relay.lastUploadId);
      expect(relay.lastPartCount, relay.lastPartSizes!.length);
      for (final size in relay.lastPartSizes!) {
        expect(size, lessThanOrEqualTo(32));
      }
      // The committed blob reassembles the parts and opens under the key.
      expect(relay.snapshotSealed, isTrue);
      final opened = await decryptBytes(workspaceKey, relay.snapshotBlob!);
      expect(latin1.decode(opened.toList(), allowInvalid: true)
          .contains('chunked snapshot page'), isTrue);
      // The staging area was cleared by the commit.
      expect(relay.parts, isEmpty);
    });
  });
}
