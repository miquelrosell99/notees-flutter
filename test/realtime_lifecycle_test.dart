import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/data/repositories/relay_ws_client.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Lifecycle races for the realtime wiring: start→stop→start, stop while
/// the workspace lookup is in flight, double start, workspace switch
/// (stop-old/start-new URL), and the error surface.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  Future<void> waitFor(bool Function() condition, {String? reason}) async {
    final stopwatch = Stopwatch()..start();
    while (!condition()) {
      if (stopwatch.elapsed > const Duration(seconds: 5)) {
        throw StateError('waitFor timed out${reason != null ? ': $reason' : ''}');
      }
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  const workspaceId = '10000000-0000-4000-8000-000000000001';
  const workspace2 = '50000000-0000-4000-8000-000000000001';
  const node1 = '20000000-0000-4000-8000-000000000001';
  const device = '40000000-0000-4000-8000-000000000001';

  group('realtime lifecycle', () {
    late AppDatabase database;
    late SyncV2Service service;
    late List<FakeWsConnection> connections;
    late List<String> connectionUrls;

    Dio buildDio() {
      final dio = Dio(BaseOptions(baseUrl: 'https://notees.example.com/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
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
      connections = [];
      connectionUrls = [];
      service = SyncV2Service(
        database: database,
        dio: buildDio(),
        clientId: device,
      );
      service.wsConnectorOverride = (url) async {
        connectionUrls.add(url);
        final conn = FakeWsConnection();
        connections.add(conn);
        return conn;
      };
      await service.setWorkspaceId(workspaceId);
    });

    tearDown(() async {
      await service.stopRealtime();
      await database.close();
      AppDatabase.reset();
    });

    void sendHello(FakeWsConnection conn) => conn.serverSends(jsonEncode({
          'type': 'hello',
          'wsProtocolVersion': 2,
          'restoreEpoch': 0,
          'latestSeq': 0,
        }));

    test('start → stop → start establishes a fresh connection', () async {
      service.startRealtime(apiKey: 'k');
      await waitFor(() => connections.length == 1, reason: 'first connect');
      sendHello(connections[0]);
      await pumpEventQueue();

      await service.stopRealtime();
      expect(connections[0].isOpen, isFalse);

      service.startRealtime(apiKey: 'k');
      await waitFor(() => connections.length == 2, reason: 'second connect');
      expect(connectionUrls, hasLength(2));
      sendHello(connections[1]);
      await pumpEventQueue();

      // The new connection carries live traffic.
      connections[1].serverSends(jsonEncode({
        'type': 'ops',
        'wsProtocolVersion': 2,
        'envelopes': [
          {
            'id': '0192a000-0000-7000-8000-000000000001',
            'protocolVersion': 2,
            'workspaceId': workspaceId,
            'actorId': '30000000-0000-4000-8000-000000000001',
            'deviceId': device,
            'hlc': {'physical': 1, 'logical': 0},
            'affectedNodeIds': [node1],
            'opType': 'object.create',
            'payload': {
              'objectId': node1,
              'nodeType': 'page',
              'classIds': <String>[],
            },
            'timestamp': '2026-09-24T12:00:00.000Z',
          },
        ],
        'seqs': const {},
      }));
      await waitForAsyncNode(service, node1);
    });

    test('stop during the workspace lookup: no connection is established',
        () async {
      service.startRealtime(apiKey: 'k');
      // Stop synchronously, before getWorkspaceId() resolves.
      await service.stopRealtime();
      await pumpEventQueue();
      await Future.delayed(const Duration(milliseconds: 50));
      await pumpEventQueue();
      expect(connections, isEmpty);
    });

    test('double start while running is a no-op', () async {
      service.startRealtime(apiKey: 'k');
      service.startRealtime(apiKey: 'k');
      await waitFor(() => connections.length == 1, reason: 'single connect');
      await Future.delayed(const Duration(milliseconds: 50));
      await pumpEventQueue();
      expect(connections, hasLength(1));
    });

    test('workspace switch resubscribes with the new workspace URL',
        () async {
      service.startRealtime(apiKey: 'k');
      await waitFor(() => connections.length == 1, reason: 'first connect');
      expect(connectionUrls.single, contains('/ws/$workspaceId?'));

      await service.stopRealtime();
      await service.setWorkspaceId(workspace2);
      service.startRealtime(apiKey: 'k');
      await waitFor(() => connections.length == 2, reason: 'reconnect');
      expect(connectionUrls[1], contains('/ws/$workspace2?'));
      expect(connectionUrls[1], isNot(contains(workspaceId)));
    });

    test('stop without start is a safe no-op', () async {
      await service.stopRealtime();
      expect(connections, isEmpty);
    });

    test('WS errors surface via onRealtimeError; reconnect keeps working',
        () async {
      final errors = <String>[];
      service.onRealtimeError = errors.add;
      service.startRealtime(apiKey: 'k');
      await waitFor(() => connections.length == 1, reason: 'connect');
      sendHello(connections[0]);
      await pumpEventQueue();

      connections[0].serverSends(
          jsonEncode({'type': 'error', 'message': 'relay hiccup'}));
      await waitFor(() => errors.isNotEmpty, reason: 'error surfaced');
      expect(service.lastRealtimeError, contains('relay hiccup'));

      // The connection is still usable (no fail-loud for relay errors).
      connections[0].kill();
      await waitFor(() => connections.length == 2,
          reason: 'auto-reconnect after kill');
    });
  });
}

Future<void> waitForAsyncNode(SyncV2Service service, String uuid) async {
  final stopwatch = Stopwatch()..start();
  while ((await service.cache.getByUuid(uuid)) == null) {
    if (stopwatch.elapsed > const Duration(seconds: 5)) {
      throw StateError('waitFor timed out: node $uuid');
    }
    await Future.delayed(const Duration(milliseconds: 10));
  }
}

/// Scripted in-process [WsConnection].
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

  void kill() {
    _closed = true;
    unawaited(_incoming.close());
  }
}
