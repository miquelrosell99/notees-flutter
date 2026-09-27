import 'package:flutter_test/flutter_test.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/relay_requests.dart';
import 'package:notees/domain/models/sync_v2.dart';

void main() {
  const uuidA = '0192a000-0000-7000-8000-000000000001';
  const uuidB = '0192a000-0000-7000-8000-000000000002';
  const uuidNode = '0192a000-0000-7000-8000-000000000010';

  Map<String, dynamic> envelopeJson({
    String id = '0192a000-0000-7000-8000-0000000000f1',
    int protocolVersion = kRelayProtocolVersion,
    String? deviceId = 'test-device',
    String? timestamp = '2026-09-24T12:00:00.000Z',
  }) =>
      {
        'id': id,
        'protocolVersion': protocolVersion,
        'workspaceId': uuidA,
        'actorId': uuidB,
        'deviceId': ?deviceId,
        'hlc': {'physical': 1000, 'logical': 2},
        'affectedNodeIds': [uuidNode],
        'opType': 'object.create',
        'timestamp': ?timestamp,
        'payload': {'objectId': uuidNode, 'nodeType': 'page'},
      };

  group('Hlc', () {
    test('orders by physical then logical', () {
      final a = Hlc(physical: 1, logical: 0);
      final b = Hlc(physical: 2, logical: 0);
      final c = Hlc(physical: 2, logical: 1);

      expect(a < b, isTrue);
      expect(b < c, isTrue);
      expect(a.compareTo(a), 0);
      expect(c > b, isTrue);
    });

    test('equality ignores compare helpers', () {
      const a = Hlc(physical: 5, logical: 1);
      const b = Hlc(physical: 5, logical: 1);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('OperationEnvelope', () {
    test('round-trips through JSON', () {
      final envelope = OperationEnvelope(
        id: uuidNode,
        workspaceId: uuidA,
        actorId: uuidB,
        deviceId: 'test-device',
        client: 'flutter',
        hlc: const Hlc(physical: 1000, logical: 2),
        affectedNodeIds: const [uuidNode],
        opType: 'object.create',
        payload: const {
          'objectId': uuidNode,
          'nodeType': 'page',
          'classIds': <String>[],
        },
        timestamp: '2026-09-24T12:00:00.000Z',
      );

      final json = envelope.toJson();
      final restored = OperationEnvelope.fromJson(json);

      expect(json['protocolVersion'], kRelayProtocolVersion);
      expect(restored.id, envelope.id);
      expect(restored.workspaceId, envelope.workspaceId);
      expect(restored.actorId, envelope.actorId);
      expect(restored.deviceId, envelope.deviceId);
      expect(restored.client, envelope.client);
      expect(restored.hlc, envelope.hlc);
      expect(restored.affectedNodeIds, envelope.affectedNodeIds);
      expect(restored.opType, envelope.opType);
      expect(restored.payload, envelope.payload);
      expect(restored.protocolVersion, kRelayProtocolVersion);
      expect(restored.timestamp, envelope.timestamp);
    });

    test('omits null client from JSON', () {
      final envelope = OperationEnvelope(
        id: uuidNode,
        workspaceId: uuidA,
        actorId: uuidB,
        deviceId: 'test-device',
        hlc: const Hlc(physical: 1, logical: 0),
        affectedNodeIds: const [uuidNode],
        opType: 'object.delete',
        payload: const {'objectId': uuidNode, 'permanent': true},
        timestamp: '2026-09-24T12:00:00.000Z',
      );

      final json = envelope.toJson();
      expect(json.containsKey('client'), isFalse);
      expect(json.containsKey('timestamp'), isTrue);
      expect(json.containsKey('deviceId'), isTrue);
    });

    test('throws when protocolVersion is missing', () {
      expect(
        () => OperationEnvelope.fromJson({
          'id': uuidNode,
          'workspaceId': uuidA,
          'actorId': uuidB,
          'deviceId': 'test-device',
          'hlc': {'physical': 1, 'logical': 0},
          'affectedNodeIds': <String>[],
          'opType': 'object.create',
          'timestamp': '2026-09-24T12:00:00.000Z',
          'payload': <String, dynamic>{},
        }),
        throwsFormatException,
      );
    });

    test('throws when protocolVersion is newer than supported', () {
      expect(
        () => OperationEnvelope.fromJson(
            envelopeJson(protocolVersion: kRelayProtocolVersion + 1)),
        throwsFormatException,
      );
    });

    test('throws when protocolVersion is not v2', () {
      expect(
        () => OperationEnvelope.fromJson(envelopeJson(protocolVersion: 1)),
        throwsFormatException,
      );
    });

    test('throws when deviceId or timestamp is missing', () {
      expect(
        () => OperationEnvelope.fromJson(envelopeJson(deviceId: null)),
        throwsFormatException,
      );
      expect(
        () => OperationEnvelope.fromJson(envelopeJson(timestamp: null)),
        throwsFormatException,
      );
    });

    test('throws on non-uuid id or workspaceId', () {
      expect(
        () => OperationEnvelope.fromJson({
          'id': 'env-1',
          'protocolVersion': kRelayProtocolVersion,
          'workspaceId': uuidA,
          'actorId': uuidB,
          'deviceId': 'test-device',
          'hlc': {'physical': 1, 'logical': 0},
          'affectedNodeIds': <String>[],
          'opType': 'object.create',
          'timestamp': '2026-09-24T12:00:00.000Z',
          'payload': <String, dynamic>{},
        }),
        throwsFormatException,
      );
    });
  });

  group('OperationIntent', () {
    test('round-trips task completion fields', () {
      final intent = OperationIntent(
        type: 'task_record_completion',
        clientId: 'client-1',
        seq: 1,
        nodeUuid: uuidNode,
        completionId: 'completion-1',
        completionStatus: 'done',
        completedAt: '2026-08-09T12:00:00.000Z',
        scheduledDate: '2026-08-09',
        deadlineDate: '2026-08-10',
      );

      final json = intent.toJson();
      final restored = OperationIntent.fromJson(json);

      expect(restored.type, intent.type);
      expect(restored.nodeUuid, intent.nodeUuid);
      expect(restored.completionId, intent.completionId);
      expect(restored.completionStatus, intent.completionStatus);
      expect(restored.completedAt, intent.completedAt);
      expect(restored.scheduledDate, intent.scheduledDate);
      expect(restored.deadlineDate, intent.deadlineDate);
    });
  });

  group('RelayBatchResponse', () {
    test('parses camelCase response', () {
      final response = RelayBatchResponse.fromJson({
        'savedCount': 3,
        'savedIds': ['a', 'b', 'c'],
      });

      expect(response.savedCount, 3);
      expect(response.savedIds, ['a', 'b', 'c']);
    });
  });

  group('CatchUpRequest', () {
    test('serializes workspaceId, afterSeq, and limit', () {
      const request = CatchUpRequest(
        workspaceId: 'ws-1',
        afterSeq: 42,
        limit: 500,
      );

      expect(request.toJson(), {
        'workspaceId': 'ws-1',
        'afterSeq': 42,
        'limit': 500,
      });
    });

    test('afterSeq defaults to 0', () {
      const request = CatchUpRequest(workspaceId: 'ws-1');

      expect(request.toJson()['afterSeq'], 0);
      expect(request.toJson().containsKey('hlc'), isFalse);
      expect(request.toJson().containsKey('afterId'), isFalse);
    });
  });

  group('CatchUpResponse', () {
    test('parses envelopes and pagination', () {
      final response = CatchUpResponse.fromJson({
        'envelopes': [envelopeJson()],
        'nextAfterSeq': 41,
        'hasMore': true,
        'restoreEpoch': 7,
        'totalRemaining': 120,
      });

      expect(response.envelopes, hasLength(1));
      expect(response.envelopes.first.opType, 'object.create');
      expect(response.nextAfterSeq, 41);
      expect(response.hasMore, isTrue);
      expect(response.restoreEpoch, 7);
      expect(response.totalRemaining, 120);
    });

    test('totalRemaining defaults to 0 when absent', () {
      final response = CatchUpResponse.fromJson({
        'envelopes': <Map<String, dynamic>>[],
        'nextAfterSeq': null,
        'hasMore': false,
        'restoreEpoch': 0,
      });

      expect(response.totalRemaining, 0);
      expect(response.nextAfterSeq, isNull);
    });

    test('final page still carries the cursor to adopt', () {
      final response = CatchUpResponse.fromJson({
        'envelopes': [envelopeJson(), envelopeJson()],
        'nextAfterSeq': 87,
        'hasMore': false,
        'restoreEpoch': 0,
        'totalRemaining': 2,
      });

      expect(response.hasMore, isFalse);
      expect(response.nextAfterSeq, 87);
    });
  });

  group('LatestSnapshotResponse', () {
    test('parses camelCase metadata', () {
      final response = LatestSnapshotResponse.fromJson({
        'snapshotId': 'snap-1',
        'hlc': {'physical': 100, 'logical': 0},
        'hasSnapshot': true,
        'restoreEpoch': 3,
        'upToSeq': 512,
      });

      expect(response.snapshotId, 'snap-1');
      expect(response.hlc.physical, 100);
      expect(response.hasSnapshot, isTrue);
      expect(response.upToSeq, 512);
      expect(response.restoreEpoch, 3);
    });

    test('upToSeq is nullable for pre-existing snapshots', () {
      final response = LatestSnapshotResponse.fromJson({
        'snapshotId': null,
        'hlc': {'physical': 100, 'logical': 0},
        'hasSnapshot': false,
        'restoreEpoch': 0,
        'upToSeq': null,
      });

      expect(response.upToSeq, isNull);
      expect(response.hasSnapshot, isFalse);
    });
  });
}
