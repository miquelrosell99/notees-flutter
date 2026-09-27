import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/repositories/relay_ws_client.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';

/// Scripted in-process [WsConnection]: the test drives server → client
/// frames and inspects client → server sends, with no live socket.
class FakeWsConnection implements WsConnection {
  final _incoming = StreamController<dynamic>();
  final sent = <String>[];
  var _closed = false;

  @override
  Stream<dynamic> get messages => _incoming.stream;

  @override
  bool get isOpen => !_closed;

  @override
  void send(String data) {
    if (_closed) throw StateError('send on closed connection');
    sent.add(data);
  }

  @override
  void close(int code, String reason) {
    _closed = true;
    unawaited(_incoming.close());
  }

  /// Test driver: the server pushes a text frame.
  void serverSends(String frame) => _incoming.add(frame);

  /// Test driver: the server pushes a binary frame.
  void serverSendsBytes(List<int> bytes) => _incoming.add(bytes);

  /// Test driver: abnormal close (no close frame).
  void kill() {
    _closed = true;
    unawaited(_incoming.close());
  }
}

OperationEnvelope sampleEnvelope({String? id}) => OperationEnvelope(
      id: id ?? '0192a000-0000-7000-8000-0000000000f1',
      workspaceId: '0192a000-0000-7000-8000-000000000001',
      actorId: '0192a000-0000-7000-8000-000000000002',
      deviceId: 'test-device',
      hlc: const Hlc(physical: 1, logical: 0),
      affectedNodeIds: const ['0192a000-0000-7000-8000-000000000010'],
      opType: 'object.create',
      payload: const {
        'objectId': '0192a000-0000-7000-8000-000000000010',
        'nodeType': 'page',
        'classIds': <String>[],
      },
      timestamp: '2026-09-24T12:00:00.000Z',
    );

void main() {
  const fastDelays = [
    Duration(milliseconds: 5),
    Duration(milliseconds: 5),
  ];

  group('RelayWsClient', () {
    test('dispatches hello/ops/ack/error frames', () async {
      final conn = FakeWsConnection();
      HelloInfoCapture? hello;
      OpsCapture? ops;
      List<String>? ack;
      final errors = <Object>[];
      final client = RelayWsClient(
        url: 'ws://example/ws',
        connector: (_) async => conn,
        reconnectDelays: fastDelays,
        onHello: (h) => hello = HelloInfoCapture(h.latestSeq, h.restoreEpoch),
        onOps: (envelopes, seqs) => ops = OpsCapture(envelopes, seqs),
        onAck: (ids) => ack = ids,
        onError: errors.add,
      );
      client.start();
      await pumpEventQueue();

      conn.serverSends(jsonEncode({
        'type': 'hello',
        'wsProtocolVersion': 2,
        'restoreEpoch': 7,
        'latestSeq': 42,
      }));
      await pumpEventQueue();
      expect(hello, isNotNull);
      expect(hello!.latestSeq, 42);
      expect(hello!.restoreEpoch, 7);
      expect(client.latestSeq, 42);
      expect(client.restoreEpoch, 7);

      conn.serverSends(jsonEncode({
        'type': 'ops',
        'wsProtocolVersion': 2,
        'envelopes': [sampleEnvelope().toJson()],
        'seqs': {'0192a000-0000-7000-8000-0000000000f1': 42},
      }));
      await pumpEventQueue();
      expect(ops, isNotNull);
      expect(ops!.envelopes.single['opType'], 'object.create');
      expect(ops!.seqs['0192a000-0000-7000-8000-0000000000f1'], 42);

      conn.serverSends(jsonEncode({
        'type': 'ack',
        'savedIds': ['a', 'b'],
      }));
      await pumpEventQueue();
      expect(ack, ['a', 'b']);

      conn.serverSends(jsonEncode({'type': 'error', 'message': 'boom'}));
      await pumpEventQueue();
      expect(errors, hasLength(1));

      await client.stop();
    });

    test('unknown frame types are ignored', () async {
      final conn = FakeWsConnection();
      final errors = <Object>[];
      final hellos = <WsHelloInfo>[];
      final client = RelayWsClient(
        url: 'ws://example/ws',
        connector: (_) async => conn,
        reconnectDelays: fastDelays,
        onHello: hellos.add,
        onError: errors.add,
      );
      client.start();
      await pumpEventQueue();

      conn.serverSends(jsonEncode({'type': 'hologram', 'x': 1}));
      await pumpEventQueue();
      expect(hellos, isEmpty);
      expect(errors, isEmpty);

      // The connection still works afterwards.
      conn.serverSends(jsonEncode({
        'type': 'hello',
        'wsProtocolVersion': 2,
        'restoreEpoch': 0,
        'latestSeq': 1,
      }));
      await pumpEventQueue();
      expect(hellos, hasLength(1));
      await client.stop();
    });

    test('malformed frames answer onError and keep the connection', () async {
      final conn = FakeWsConnection();
      final errors = <Object>[];
      final hellos = <WsHelloInfo>[];
      final client = RelayWsClient(
        url: 'ws://example/ws',
        connector: (_) async => conn,
        reconnectDelays: fastDelays,
        onHello: hellos.add,
        onError: errors.add,
      );
      client.start();
      await pumpEventQueue();

      conn.serverSends('this is not json');
      await pumpEventQueue();
      expect(errors, hasLength(1));
      expect(errors.single, isA<RealtimeProtocolError>());

      conn.serverSendsBytes(utf8.encode('{"type":"hello","wsProtocolVersion":2,"latestSeq":3,"restoreEpoch":0}'));
      await pumpEventQueue();
      expect(hellos, hasLength(1));
      await client.stop();
    });

    test('a newer framing version fails loud: error, close, NO reconnect',
        () async {
      final conn = FakeWsConnection();
      final errors = <Object>[];
      var connectCount = 0;
      final client = RelayWsClient(
        url: 'ws://example/ws',
        connector: (_) async {
          connectCount++;
          return conn;
        },
        reconnectDelays: fastDelays,
        onError: errors.add,
      );
      client.start();
      await pumpEventQueue();

      conn.serverSends(jsonEncode({
        'type': 'hello',
        'wsProtocolVersion': kWsProtocolVersion + 1,
        'restoreEpoch': 0,
        'latestSeq': 0,
      }));
      await pumpEventQueue();
      await Future.delayed(const Duration(milliseconds: 30));
      await pumpEventQueue();

      expect(client.failed, isTrue);
      expect(errors.single, isA<ProtocolVersionError>());
      expect(connectCount, 1); // never reconnects
      await client.stop();
    });

    test('abnormal close reconnects and delivers frames on the new socket',
        () async {
      final connections = [FakeWsConnection(), FakeWsConnection()];
      var connectCount = 0;
      final hellos = <WsHelloInfo>[];
      final ops = <OpsCapture>[];
      final client = RelayWsClient(
        url: 'ws://example/ws',
        connector: (_) async => connections[connectCount++],
        reconnectDelays: fastDelays,
        onHello: hellos.add,
        onOps: (envelopes, seqs) => ops.add(OpsCapture(envelopes, seqs)),
      );
      client.start();
      await pumpEventQueue();

      connections[0].serverSends(jsonEncode({
        'type': 'hello',
        'wsProtocolVersion': 2,
        'restoreEpoch': 0,
        'latestSeq': 1,
      }));
      await pumpEventQueue();
      expect(hellos, hasLength(1));

      connections[0].kill();
      await Future.delayed(const Duration(milliseconds: 50));
      await pumpEventQueue();
      expect(connectCount, 2);

      connections[1].serverSends(jsonEncode({
        'type': 'hello',
        'wsProtocolVersion': 2,
        'restoreEpoch': 0,
        'latestSeq': 2,
      }));
      await pumpEventQueue();
      expect(hellos, hasLength(2));

      connections[1].serverSends(jsonEncode({
        'type': 'ops',
        'wsProtocolVersion': 2,
        'envelopes': [sampleEnvelope(id: '0192a000-0000-7000-8000-0000000000f2').toJson()],
        'seqs': const {},
      }));
      await pumpEventQueue();
      expect(ops, hasLength(1));
      await client.stop();
    });

    test('stop closes cleanly (code 1000) and never reconnects', () async {
      final conn = FakeWsConnection();
      var connectCount = 0;
      final client = RelayWsClient(
        url: 'ws://example/ws',
        connector: (_) async {
          connectCount++;
          return conn;
        },
        reconnectDelays: fastDelays,
      );
      client.start();
      await pumpEventQueue();
      expect(connectCount, 1);

      await client.stop();
      await Future.delayed(const Duration(milliseconds: 30));
      await pumpEventQueue();
      expect(connectCount, 1);
      expect(conn.isOpen, isFalse);
    });

    test('sendBatch writes a batch frame; false when no socket', () async {
      final conn = FakeWsConnection();
      final client = RelayWsClient(
        url: 'ws://example/ws',
        connector: (_) async => conn,
        reconnectDelays: fastDelays,
      );
      expect(client.sendBatch([sampleEnvelope()]), isFalse);

      client.start();
      await pumpEventQueue();
      expect(client.sendBatch([sampleEnvelope()]), isTrue);
      final frame = jsonDecode(conn.sent.single) as Map<String, dynamic>;
      expect(frame['type'], 'batch');
      expect((frame['envelopes'] as List).single, sampleEnvelope().toJson());
      await client.stop();
    });
  });

  group('buildRelayWsUrl', () {
    test('maps the REST base to the relay WS URL', () {
      expect(
        buildRelayWsUrl(
          'https://notees.example.com/api',
          '0192a000-0000-7000-8000-000000000001',
          'secret key',
        ),
        'wss://notees.example.com/api/relay/v2/ws/'
            '0192a000-0000-7000-8000-000000000001?token=secret+key',
      );
      expect(
        buildRelayWsUrl(
          'http://192.168.1.10:8080/api/',
          'ws-id',
          'k',
        ),
        'ws://192.168.1.10:8080/api/relay/v2/ws/ws-id?token=k',
      );
    });
  });
}

class HelloInfoCapture {
  HelloInfoCapture(this.latestSeq, this.restoreEpoch);
  final int latestSeq;
  final int restoreEpoch;
}

class OpsCapture {
  OpsCapture(this.envelopes, this.seqs);
  final List<Map<String, dynamic>> envelopes;
  final Map<String, int> seqs;
}
