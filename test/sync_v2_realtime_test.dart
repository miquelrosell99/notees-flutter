import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/data/repositories/relay_ws_client.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Engine wiring for the realtime acceleration path (WIRE.md): ops frames
/// apply through the same path as catch-up, hello drives pull decisions, and
/// the snapshot-upload trigger PUTs a real derived-state database.
Future<void> waitFor(bool Function() condition, {String? reason}) async {
  final stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed > const Duration(seconds: 5)) {
      throw StateError('waitFor timed out${reason != null ? ': $reason' : ''}');
    }
    await Future.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> waitForAsync(Future<bool> Function() condition,
    {String? reason}) async {
  final stopwatch = Stopwatch()..start();
  while (!await condition()) {
    if (stopwatch.elapsed > const Duration(seconds: 5)) {
      throw StateError(
          'waitFor timed out${reason != null ? ': $reason' : ''}');
    }
    await Future.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  // buildV2SnapshotBytes writes a temp file via path_provider; serve a
  // real temp directory on the plugin channel.
  final tempDir = Directory.systemTemp.createTempSync('notees_b3_test');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => tempDir.path,
  );

  const workspaceId = '10000000-0000-4000-8000-000000000001';
  const node1 = '20000000-0000-4000-8000-000000000001';
  const user1 = '30000000-0000-4000-8000-000000000001';
  const device = '40000000-0000-4000-8000-000000000001';

  group('SyncV2Service realtime + snapshot upload', () {
    late AppDatabase database;
    late SyncV2Service service;
    late FakeWsConnection ws;
    late List<Map<String, dynamic>> catchUpCalls;
    late List<Map<String, dynamic>> httpCalls;
    var servedEpoch = 0;

    Map<String, dynamic> createEnvelopeJson(String id, String objectId) => {
          'id': id,
          'protocolVersion': 3,
          'workspaceId': workspaceId,
          'actorId': user1,
          'deviceId': device,
          'hlc': {'physical': 1, 'logical': 0},
          'affectedNodeIds': [objectId],
          'opType': 'object.create',
          'payload': {
            'objectId': objectId,
            'presentAsMain': true,
            'classIds': <String>[],
          },
          'timestamp': '2026-09-24T12:00:00.000Z',
        };

    Dio buildDio() {
      final dio = Dio(BaseOptions(baseUrl: 'https://notees.example.com/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            httpCalls.add({
              'method': options.method,
              'path': options.path,
              'query': options.queryParameters,
              if (options.data is List<int>)
                'body': Uint8List.fromList(options.data as List<int>),
            });
            if (options.path == '/relay/v2/snapshot') {
              handler.resolve(Response(
                requestOptions: options,
                data: {
                  'snapshotId': null,
                  'hlc': {'physical': 0, 'logical': 0},
                  'hasSnapshot': false,
                  'restoreEpoch': servedEpoch,
                  'upToSeq': null,
                },
                statusCode: 200,
              ));
              return;
            }
            if (options.path == '/relay/v2/catch-up') {
              catchUpCalls.add(Map<String, dynamic>.from(options.data as Map));
              handler.resolve(Response(
                requestOptions: options,
                data: {
                  'envelopes': <Map<String, dynamic>>[],
                  'nextAfterSeq': null,
                  'hasMore': false,
                  'restoreEpoch': servedEpoch,
                  'totalRemaining': 0,
                },
                statusCode: 200,
              ));
              return;
            }
            handler.resolve(Response(
              requestOptions: options,
              data: options.responseType == ResponseType.bytes
                  ? const <int>[]
                  : const {'savedCount': 1, 'savedIds': ['id']},
              statusCode: 200,
            ));
          },
        ),
      );
      return dio;
    }

    setUp(() async {
      final ffiDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb);
      await database.initializeSchema();
      final cache = NodeCacheRepository(database);
      await cache.upsertClass(uuid: 'class-1', name: 'Class');
      await cache.upsertPropertySchema(
        PropertySchemaRow(uuid: 'schema-1', workspaceId: workspaceId, name: 'P'),
      );
      catchUpCalls = [];
      httpCalls = [];
      NodeCacheRepository.snapshotDbOpener =
          (path) => databaseFactoryFfi.openDatabase(
                path,
                options: OpenDatabaseOptions(singleInstance: false),
              );
      ws = FakeWsConnection();
      service = SyncV2Service(
        database: database,
        dio: buildDio(),
        clientId: device,
      );
      service.wsConnectorOverride = (_) async => ws;
      await service.setWorkspaceId(workspaceId);
    });

    tearDown(() async {
      await service.stopRealtime();
      await database.close();
      AppDatabase.reset();
    });

    test('connects the WS URL with the token, ops frames apply to the cache',
        () async {
      String? connectedUrl;
      service.wsConnectorOverride = (url) async {
        connectedUrl = url;
        return ws;
      };
      service.startRealtime(apiKey: 'secret key');
      await pumpEventQueue();
      expect(
        connectedUrl,
        'wss://notees.example.com/api/relay/v2/ws/$workspaceId?token=secret+key',
      );

      // Fresh hello in sync with the local cursor: no pull, buffer drains.
      ws.serverSends(jsonEncode({
        'type': 'hello',
        'wsProtocolVersion': 2,
        'restoreEpoch': 0,
        'latestSeq': 0,
      }));
      await pumpEventQueue();
      expect(catchUpCalls, isEmpty);

      // A remote op lands over the socket and applies to the local cache.
      ws.serverSends(jsonEncode({
        'type': 'ops',
        'wsProtocolVersion': 2,
        'envelopes': [createEnvelopeJson('0192a000-0000-7000-8000-000000000001', node1)],
        'seqs': {'0192a000-0000-7000-8000-000000000001': 9},
      }));
      await waitForAsync(
        () async => (await service.cache.getByUuid(node1)) != null,
        reason: 'ops frame applied',
      );
      final node = await service.cache.getByUuid(node1);
      expect(node, isNotNull);
      expect(node!.isPage, isTrue);
      // The live frame did NOT advance the catch-up cursor: no watermark
      // row was written at all (an absent cursor reads as 0).
      final db = await database.database;
      final wm = await db.query('sync_watermark',
          where: 'workspace_id = ?', whereArgs: const [workspaceId]);
      expect(wm, isEmpty);
      // And it was recorded as applied from the server (echo dedupes).
      final ops = await db.query('relay_operations',
          where: 'id = ?',
          whereArgs: const ['0192a000-0000-7000-8000-000000000001']);
      expect(ops.single['is_local'], 0);
    });

    test('hello with latestSeq ahead of the cursor triggers a catch-up pull',
        () async {
      service.startRealtime(apiKey: 'k');
      await pumpEventQueue();

      ws.serverSends(jsonEncode({
        'type': 'hello',
        'wsProtocolVersion': 2,
        'restoreEpoch': 0,
        'latestSeq': 17,
      }));
      await waitFor(() => catchUpCalls.isNotEmpty, reason: 'catch-up pull');
      expect(catchUpCalls.single['afterSeq'], 0);
    });

    test('hello with a newer restoreEpoch wipes and resyncs from 0', () async {
      // Seed local state + a pending outbox op as a pre-wipe client.
      await service.enqueue(
        type: 'create',
        nodeUuid: node1,
        contentAst: const [
          {'type': 'text', 'text': 'pre-wipe'},
        ],
        isPage: true,
      );
      await service.flush();
      expect(await service.cache.getByUuid(node1), isNotNull);

      service.startRealtime(apiKey: 'k');
      await pumpEventQueue();
      servedEpoch = 9;
      ws.serverSends(jsonEncode({
        'type': 'hello',
        'wsProtocolVersion': 2,
        'restoreEpoch': 9,
        'latestSeq': 3,
      }));
      await waitForAsync(
        () async => (await service.cache.getByUuid(node1)) == null,
        reason: 'epoch wipe',
      );

      // The wipe cleared the node; the resync adopted the new epoch (wait
      // for the pull's watermark write so the test cannot outrun the
      // resync and race the teardown).
      expect(await service.cache.getByUuid(node1), isNull);
      final db = await database.database;
      await waitForAsync(() async {
        final rows = await db.query('sync_watermark',
            where: 'workspace_id = ?', whereArgs: const [workspaceId]);
        return rows.isNotEmpty && rows.single['restore_epoch'] == 9;
      }, reason: 'epoch adopted');
      final wm = await db.query('sync_watermark',
          where: 'workspace_id = ?', whereArgs: const [workspaceId]);
      expect(wm.single['restore_epoch'], 9);
      expect(wm.single['cursor_seq'], 0);
    });

    test('ack frames drain the outbox rows for the acknowledged envelope ids',
        () async {
      await service.enqueue(
        type: 'create',
        nodeUuid: node1,
        contentAst: const [
          {'type': 'text', 'text': 'hi'},
        ],
        isPage: true,
      );
      final db = await database.database;
      final outboxBefore = await db.query('relay_outbox');
      expect(outboxBefore, hasLength(1));
      final envelopeId = jsonDecode(
        outboxBefore.single['envelope_json'] as String,
      )['id'] as String;

      service.startRealtime(apiKey: 'k');
      await pumpEventQueue();
      ws.serverSends(jsonEncode({
        'type': 'hello',
        'wsProtocolVersion': 2,
        'restoreEpoch': 0,
        'latestSeq': 0,
      }));
      await pumpEventQueue();

      ws.serverSends(
          jsonEncode({'type': 'ack', 'savedIds': [envelopeId]}));
      await pumpEventQueue();
      expect(await db.query('relay_outbox'), isEmpty);
    });

    test('uploadSnapshot PUTs a real derived-state database', () async {
      await service.enqueue(
        type: 'create',
        nodeUuid: node1,
        contentAst: const [
          {'type': 'text', 'text': 'snapshot me'},
        ],
        isPage: true,
      );
      await service.flush();

      await service.uploadSnapshot();

      final put = httpCalls.firstWhere((c) => c['method'] == 'PUT');
      expect(put['path'], '/relay/v2/snapshot/data');
      expect(put['query']['workspaceId'], workspaceId);
      expect(put['query'].containsKey('physical'), isTrue);
      expect(put['query'].containsKey('logical'), isTrue);
      final body = put['body']! as Uint8List;
      expect(body, isNotEmpty);

      // The bytes are a SQLite database in the derived-state schema.
      final snapPath = p.join(tempDir.path, 'verify_snapshot.db');
      final snapFile = File(snapPath)
        ..writeAsBytesSync(body.toList(), flush: true);
      final snapDb = await databaseFactoryFfi.openDatabase(snapPath);
      try {
        final nodes = await snapDb.rawQuery(
            'SELECT id, is_class, present_as_main, name FROM node WHERE id = ?',
            [node1]);
        expect(nodes, hasLength(1));
        expect(nodes.single['is_class'], 0);
        expect(nodes.single['present_as_main'], 1);
        final order = await snapDb.rawQuery(
          'SELECT COUNT(*) AS c FROM node_child_order',
        );
        expect(order.single['c'], 0); // parentless page carries no order row
      } finally {
        await snapDb.close();
        snapFile.deleteSync();
      }
    });
  });
}

/// Scripted in-process [WsConnection] (same shape as the client unit tests).
class FakeWsConnection implements WsConnection {
  final _incoming = StreamController<dynamic>();
  var _closed = false;

  @override
  Stream<dynamic> get messages => _incoming.stream;

  @override
  bool get isOpen => !_closed;

  @override
  void send(String data) {
    if (_closed) throw StateError('send on closed connection');
  }

  @override
  void close(int code, String reason) {
    _closed = true;
    unawaited(_incoming.close());
  }

  void serverSends(String frame) => _incoming.add(frame);
}
