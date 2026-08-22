import 'package:flutter_test/flutter_test.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/relay_requests.dart';
import 'package:notees/domain/models/sync_v2.dart';

void main() {
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
      final a = Hlc(physical: 5, logical: 1);
      final b = Hlc(physical: 5, logical: 1);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('OperationEnvelope', () {
    test('round-trips through JSON', () {
      final envelope = OperationEnvelope(
        id: 'env-1',
        workspaceId: 'ws-1',
        actorId: 'actor-1',
        hlc: Hlc(physical: 1000, logical: 2),
        affectedNodeIds: const ['node-a', 'node-b'],
        opType: 'node.create',
        payload: const {
          'nodeId': 'node-a',
          'kind': 'page',
          'classIds': <String>[],
        },
        timestamp: '2026-08-09T12:00:00.000Z',
      );

      final json = envelope.toJson();
      final restored = OperationEnvelope.fromJson(json);

      expect(json['protocolVersion'], kRelayProtocolVersion);
      expect(restored.id, envelope.id);
      expect(restored.workspaceId, envelope.workspaceId);
      expect(restored.actorId, envelope.actorId);
      expect(restored.hlc, envelope.hlc);
      expect(restored.affectedNodeIds, envelope.affectedNodeIds);
      expect(restored.opType, envelope.opType);
      expect(restored.payload, envelope.payload);
      expect(restored.protocolVersion, kRelayProtocolVersion);
      expect(restored.timestamp, envelope.timestamp);
    });

    test('throws when protocolVersion is missing', () {
      expect(
        () => OperationEnvelope.fromJson({
          'id': 'env-1',
          'workspaceId': 'ws-1',
          'actorId': 'actor-1',
          'hlc': {'physical': 1, 'logical': 0},
          'affectedNodeIds': <String>[],
          'opType': 'node.create',
          'payload': <String, dynamic>{},
        }),
        throwsFormatException,
      );
    });

    test('throws when protocolVersion is newer than supported', () {
      expect(
        () => OperationEnvelope.fromJson({
          'id': 'env-1',
          'protocolVersion': kRelayProtocolVersion + 1,
          'workspaceId': 'ws-1',
          'actorId': 'actor-1',
          'hlc': {'physical': 1, 'logical': 0},
          'affectedNodeIds': <String>[],
          'opType': 'node.create',
          'payload': <String, dynamic>{},
        }),
        throwsFormatException,
      );
    });

    test('omits null timestamp from JSON', () {
      final envelope = OperationEnvelope(
        id: 'env-2',
        workspaceId: 'ws-1',
        actorId: 'actor-1',
        hlc: Hlc(physical: 1, logical: 0),
        affectedNodeIds: const ['node-a'],
        opType: 'node.delete',
        payload: const {'nodeId': 'node-a'},
      );

      final json = envelope.toJson();
      expect(json.containsKey('timestamp'), isFalse);
    });
  });

  group('OperationIntent', () {
    test('round-trips task completion fields', () {
      final intent = OperationIntent(
        type: 'task_record_completion',
        clientId: 'client-1',
        seq: 1,
        nodeUuid: 'node-a',
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
    test('parses snake_case response', () {
      final response = RelayBatchResponse.fromJson({
        'saved_count': 3,
        'saved_ids': ['a', 'b', 'c'],
      });

      expect(response.savedCount, 3);
      expect(response.savedIds, ['a', 'b', 'c']);
    });
  });

  group('CatchUpRequest', () {
    test('serializes workspace_id, after_seq, and limit', () {
      const request = CatchUpRequest(
        workspaceId: 'ws-1',
        afterSeq: 42,
        limit: 500,
      );

      expect(request.toJson(), {
        'workspace_id': 'ws-1',
        'after_seq': 42,
        'limit': 500,
      });
    });

    test('after_seq defaults to 0', () {
      const request = CatchUpRequest(workspaceId: 'ws-1');

      expect(request.toJson()['after_seq'], 0);
      expect(request.toJson().containsKey('hlc'), isFalse);
      expect(request.toJson().containsKey('after_id'), isFalse);
    });
  });

  group('CatchUpResponse', () {
    Map<String, dynamic> envelopeJson(String id) => {
          'id': id,
          'protocolVersion': kRelayProtocolVersion,
          'workspaceId': 'ws',
          'actorId': 'a',
          'hlc': {'physical': 10, 'logical': 0},
          'affectedNodeIds': ['n'],
          'opType': 'node.create',
          'payload': {'nodeId': 'n'},
          'timestamp': '2026-08-09T12:00:00.000Z',
        };

    test('parses envelopes and pagination', () {
      final response = CatchUpResponse.fromJson({
        'envelopes': [envelopeJson('e1')],
        'next_after_seq': 41,
        'has_more': true,
        'restore_epoch': 7,
      });

      expect(response.envelopes, hasLength(1));
      expect(response.envelopes.first.id, 'e1');
      expect(response.nextAfterSeq, 41);
      expect(response.hasMore, isTrue);
      expect(response.restoreEpoch, 7);
    });

    test('final page still carries the cursor to adopt', () {
      final response = CatchUpResponse.fromJson({
        'envelopes': [envelopeJson('e1'), envelopeJson('e2')],
        'next_after_seq': 87,
        'has_more': false,
        'restore_epoch': 0,
      });

      expect(response.hasMore, isFalse);
      expect(response.nextAfterSeq, 87);
    });

    test('empty page has a null cursor', () {
      final response = CatchUpResponse.fromJson({
        'envelopes': <Map<String, dynamic>>[],
        'next_after_seq': null,
        'has_more': false,
        'restore_epoch': 0,
      });

      expect(response.envelopes, isEmpty);
      expect(response.nextAfterSeq, isNull);
    });
  });

  group('LatestSnapshotResponse', () {
    test('parses up_to_seq when present', () {
      final response = LatestSnapshotResponse.fromJson({
        'snapshot_id': 'snap-1',
        'workspace_id': 'ws-1',
        'hlc': {'physical': 100, 'logical': 0},
        'data_base64': 'AAAA',
        'has_snapshot': true,
        'restore_epoch': 3,
        'up_to_seq': 512,
      });

      expect(response.upToSeq, 512);
      expect(response.restoreEpoch, 3);
    });

    test('up_to_seq is nullable for pre-existing snapshots', () {
      final response = LatestSnapshotResponse.fromJson({
        'snapshot_id': 'snap-1',
        'workspace_id': 'ws-1',
        'hlc': {'physical': 100, 'logical': 0},
        'data_base64': 'AAAA',
        'has_snapshot': true,
        'restore_epoch': 0,
        'up_to_seq': null,
      });

      expect(response.upToSeq, isNull);
    });
  });
}
