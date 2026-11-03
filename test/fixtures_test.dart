import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/domain/models/relay/payload_crypto.dart';

/// Cross-implementation parity gate for the Notees protocol v2.
///
/// `test/fixtures/wire/` is a verbatim port of
/// `packages/protocol/fixtures/` from the Notees monorepo — the same
/// canonical fixtures the TypeScript reference and the GTK client validate
/// against. Every envelope the reference produces must parse through the
/// Flutter wire models and re-serialize field-by-field, and every payload
/// must validate against the op registry (`op-types.ts` port in
/// `OperationPayloads.validatePayload`). If a model and a fixture drift
/// (renamed field, changed default, changed casing), this test fails.
void main() {
  final fixturesDir = Directory('test/fixtures/wire');

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
    'card-review.json',
    'class-convert.json',
    'class-extends-cycle.json',
    'class-extends-m2m.json',
    'class-extends-system-lock.json',
    'class-link-assertion.json',
    'class-link.json',
    'class-parentless-role.json',
    'class-display-template.json',
    'class-property-active.json',
    'class-property-defaults.json',
    'class-property-pinned.json',
    'class-unassign.json',
    'code-block.json',
    'embed-ref-view.json',
    'envelope-encrypted.json',
    'external-ref.json',
    'hr.json',
    'heading-content.json',
    'is-embedded-date-chain.json',
    'is-embedded-parent-page.json',
    'link-embedded.json',
    'mention-custom-label.json',
    'object-color.json',
    'object-delete-class-routing.json',
    'object-delete-date-chain.json',
    'object-is-embedded.json',
    'object-list-style.json',
    'object-move-before.json',
    'object-move.json',
    'object-restore.json',
    'object-update-active.json',
    'trash-empty.json',
    'object-wire-fields.json',
    'property-asset-type.json',
    'property-assign.json',
    'property-date-qualifier.json',
    'property-datetime.json',
    'property-schema-delete.json',
    'property-schema-scope.json',
    'property-schema-update-fields.json',
    'property-set-lww.json',
    'property-validation-rules.json',
    'property-value-elements.json',
    'query-ast-v2.json',
    'tag-membership.json',
    'typed-link-mark.json',
    'typed-link-mark-deleted.json',
    'workspace-feature-set.json',
  ];

  List<Map<String, dynamic>> envelopesOf(Map<String, dynamic> fixture) =>
      (fixture['envelopes'] as List<dynamic>).cast<Map<String, dynamic>>();

  /// The public test key behind `envelope-encrypted.json`'s `crypto` block
  /// (b64u 32 bytes). Raw `$e` payloads are SHAPE-validated only
  /// (`OperationEnvelope.fromJson`); the strict op registry runs on the
  /// OPENED plaintext.
  late final SecretKey _fixtureWorkspaceKey = importWorkspaceKey(
    loadFixture('envelope-encrypted.json')['crypto']['workspaceKey'] as String,
  );

  Future<void> expectEnvelopeRoundTrips(
    Map<String, dynamic> raw,
    String fixtureName,
  ) async {
    final envelope = OperationEnvelope.fromJson(raw);
    expect(
      envelope.toJson(),
      raw,
      reason: '$fixtureName drifted from the wire models',
    );
    if (envelope.payload.containsKey(r'$e')) {
      // The E2EE slot: the app runtime rejects `$e` at apply time
      // (sibling custody is pending), so the strict registry must NOT
      // schema-validate the raw slot — but the decrypted plaintext MUST
      // validate, lockstep with the GTK gate.
      expect(
        () => OperationPayloads.validatePayload(
            envelope.opType, envelope.payload),
        throwsFormatException,
        reason: '$fixtureName raw \$e payload must not be schema-validated',
      );
      final opened = await decryptEnvelope(_fixtureWorkspaceKey, envelope);
      expect(
        () =>
            OperationPayloads.validatePayload(opened.opType, opened.payload),
        returnsNormally,
        reason: '$fixtureName opened payload failed registry validation '
            '(${envelope.opType})',
      );
    } else {
      expect(
        () =>
            OperationPayloads.validatePayload(envelope.opType, envelope.payload),
        returnsNormally,
        reason: '$fixtureName payload failed registry validation '
            '(${envelope.opType})',
      );
    }
    expect(
      OperationPayloads.isKnownOpType(envelope.opType),
      isTrue,
      reason: '$fixtureName carries an op type outside the op registry',
    );
  }

  group('fixture parity (monorepo canonical fixtures)', () {
    for (final name in singleEnvelopeFixtures) {
      test('$name parses and re-serializes exactly', () async {
        await expectEnvelopeRoundTrips(loadFixture(name), name);
      });
    }

    for (final name in envelopeListFixtures) {
      test('$name envelopes parse and re-serialize exactly', () async {
        for (final raw in envelopesOf(loadFixture(name))) {
          await expectEnvelopeRoundTrips(raw, name);
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

    test('all fixtures declare protocolVersion 3 (Revision 11 envelope)', () {
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
