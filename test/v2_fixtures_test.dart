import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';

/// Cross-implementation parity gate for the Notees protocol v2.
///
/// `test/fixtures/v2/` is a verbatim port of
/// `v2/packages/protocol/fixtures/` from the Notees monorepo — the same
/// canonical fixtures the TypeScript reference and the GTK client validate
/// against. Every envelope the reference produces must parse through the
/// Flutter wire models and re-serialize field-by-field, and every payload
/// must validate against the v2 op registry (`op-types.ts` port in
/// `OperationPayloads.validatePayload`). If a model and a fixture drift
/// (renamed field, changed default, changed casing), this test fails.
void main() {
  final fixturesDir = Directory('test/fixtures/v2');

  Map<String, dynamic> loadFixture(String name) =>
      jsonDecode(File('${fixturesDir.path}/$name').readAsStringSync())
          as Map<String, dynamic>;

  // Fixtures holding a single envelope document.
  const singleEnvelopeFixtures = [
    'envelope-minimal.json',
    'object-create.json',
  ];

  // Fixtures holding {"comment": ..., "envelopes": [...]}.
  const envelopeListFixtures = [
    'class-extends-cycle.json',
    'class-extends-m2m.json',
    'object-move.json',
    'property-set-lww.json',
    'typed-link-mark.json',
    'typed-link-mark-deleted.json',
  ];

  List<Map<String, dynamic>> envelopesOf(Map<String, dynamic> fixture) =>
      (fixture['envelopes'] as List<dynamic>).cast<Map<String, dynamic>>();

  void expectEnvelopeRoundTrips(Map<String, dynamic> raw, String fixtureName) {
    final envelope = OperationEnvelope.fromJson(raw);
    expect(
      envelope.toJson(),
      raw,
      reason: '$fixtureName drifted from the v2 wire models',
    );
    expect(
      () => OperationPayloads.validatePayload(envelope.opType, envelope.payload),
      returnsNormally,
      reason: '$fixtureName payload failed v2 registry validation '
          '(${envelope.opType})',
    );
    expect(
      OperationPayloads.isKnownOpType(envelope.opType),
      isTrue,
      reason: '$fixtureName carries an op type outside the v2 M1 registry',
    );
  }

  group('v2 fixture parity (monorepo canonical fixtures)', () {
    for (final name in singleEnvelopeFixtures) {
      test('$name parses and re-serializes exactly', () {
        expectEnvelopeRoundTrips(loadFixture(name), name);
      });
    }

    for (final name in envelopeListFixtures) {
      test('$name envelopes parse and re-serialize exactly', () {
        for (final raw in envelopesOf(loadFixture(name))) {
          expectEnvelopeRoundTrips(raw, name);
        }
      });
    }

    test('every fixture file on disk is covered by the gate', () {
      final onDisk = fixturesDir
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .toSet();
      final covered = {
        ...singleEnvelopeFixtures,
        ...envelopeListFixtures,
      };
      expect(onDisk.difference(covered), isEmpty,
          reason: 'fixture files without a gate mapping');
      expect(covered.difference(onDisk), isEmpty,
          reason: 'gate mappings without a fixture file');
    });

    test('all fixtures declare protocolVersion 2', () {
      for (final name in singleEnvelopeFixtures) {
        expect(loadFixture(name)['protocolVersion'], kRelayProtocolVersion,
            reason: name);
      }
      for (final name in envelopeListFixtures) {
        for (final raw in envelopesOf(loadFixture(name))) {
          expect(raw['protocolVersion'], kRelayProtocolVersion,
              reason: '$name ${raw['id']}');
        }
      }
    });

    test('envelope without protocolVersion is rejected', () {
      final raw = Map<String, dynamic>.from(loadFixture('envelope-minimal.json'))
        ..remove('protocolVersion');
      expect(() => OperationEnvelope.fromJson(raw), throwsFormatException);
    });

    test('envelope with a newer protocolVersion fails loud', () {
      final raw = Map<String, dynamic>.from(loadFixture('envelope-minimal.json'))
        ..['protocolVersion'] = kRelayProtocolVersion + 1;
      expect(() => OperationEnvelope.fromJson(raw), throwsFormatException);
    });

    test('snake_case envelope fields are rejected (camelCase-only wire)', () {
      final raw = loadFixture('envelope-minimal.json');
      final snake = <String, dynamic>{
        'id': raw['id'],
        'protocol_version': raw['protocolVersion'],
        'workspace_id': raw['workspaceId'],
        'actor_id': raw['actorId'],
        'device_id': raw['deviceId'],
        'hlc': raw['hlc'],
        'affected_node_ids': raw['affectedNodeIds'],
        'op_type': raw['opType'],
        'timestamp': raw['timestamp'],
        'payload': raw['payload'],
      };
      expect(() => OperationEnvelope.fromJson(snake), throwsFormatException);
    });

    test('missing deviceId or timestamp is rejected', () {
      final raw = loadFixture('envelope-minimal.json');
      final noDevice = Map<String, dynamic>.from(raw)..remove('deviceId');
      expect(() => OperationEnvelope.fromJson(noDevice), throwsFormatException);
      final noTimestamp = Map<String, dynamic>.from(raw)..remove('timestamp');
      expect(
          () => OperationEnvelope.fromJson(noTimestamp), throwsFormatException);
    });
  });
}
