import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/domain/models/relay/payload_crypto.dart';

/// The E2EE decrypt port's acceptance suite (lockstep with the GTK client's
/// `tests/test_crypto.py` and the monorepo's `packages/protocol/src/crypto.ts`):
/// the `envelope-encrypted.json` fixture vector opens with its public
/// `crypto.workspaceKey`, the plaintexts deep-equal the pinned expectations
/// AND validate against the strict op registry, and the negatives pin the
/// tag-first ct layout (a WebCrypto-style ct‖tag misread fails), the AAD
/// binding, and tamper detection.
void main() {
  const fixturesDir = 'test/fixtures/wire';

  Map<String, dynamic> loadFixture(String name) =>
      jsonDecode(File('$fixturesDir/$name').readAsStringSync())
          as Map<String, dynamic>;

  final fixture = loadFixture('envelope-encrypted.json');
  final key = importWorkspaceKey(fixture['crypto']['workspaceKey'] as String);

  List<OperationEnvelope> fixtureEnvelopes() =>
      (fixture['envelopes'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(OperationEnvelope.fromJson)
          .toList();

  /// The pinned expected plaintexts (verified against the monorepo's
  /// crypto.ts reference decrypt).
  const expectedCreate = <String, dynamic>{
    'objectId': '0192a000-0000-7000-8000-0000000000fc',
    'contentAst': [
      {'type': 'text', 'text': 'Encrypted fixture page'},
    ],
    'isEmbedded': false,
    'classIds': <String>[],
  };
  const expectedUpdate = <String, dynamic>{
    'objectId': '0192a000-0000-7000-8000-0000000000fc',
    'icon': 'book',
  };

  group('b64u helpers', () {
    test('round-trip with and without padding', () {
      expect(b64uDecode(b64uEncode([1, 2, 3, 4])), [1, 2, 3, 4]);
      // 32 bytes → 43 chars, no padding on encode; decode re-pads.
      final encoded = b64uEncode(List<int>.generate(32, (i) => i));
      expect(encoded.endsWith('='), isFalse);
      expect(b64uDecode(encoded), List<int>.generate(32, (i) => i));
    });

    test('rejects garbage', () {
      expect(() => b64uDecode('!!!'), throwsFormatException);
    });
  });

  group('importWorkspaceKey', () {
    test('accepts a 32-byte key', () {
      expect(importWorkspaceKey(b64uEncode(List<int>.filled(32, 0x5a))),
          isA<SecretKey>());
    });

    test('rejects a wrong-length key', () {
      expect(() => importWorkspaceKey(b64uEncode([1, 2, 3])),
          throwsFormatException);
    });
  });

  group('fixture vector (envelope-encrypted.json)', () {
    test('both envelopes open to the pinned plaintexts', () async {
      final envelopes = fixtureEnvelopes();
      expect(envelopes, hasLength(2));

      final openedCreate = await decryptEnvelope(key, envelopes[0]);
      expect(openedCreate.payload, expectedCreate);
      // Every other field is preserved.
      expect(openedCreate.id, envelopes[0].id);
      expect(openedCreate.opType, 'object.create');

      final openedUpdate = await decryptEnvelope(key, envelopes[1]);
      expect(openedUpdate.payload, expectedUpdate);
      expect(openedUpdate.opType, 'object.update');
    });

    test('the opened payloads pass the strict op registry', () async {
      final envelopes = fixtureEnvelopes();
      final openedCreate = await decryptEnvelope(key, envelopes[0]);
      final openedUpdate = await decryptEnvelope(key, envelopes[1]);
      expect(
        () => OperationPayloads.validatePayload(
            openedCreate.opType, openedCreate.payload),
        returnsNormally,
      );
      expect(
        () => OperationPayloads.validatePayload(
            openedUpdate.opType, openedUpdate.payload),
        returnsNormally,
      );
    });

    test('plaintext envelopes pass through unchanged', () async {
      final raw = loadFixture('envelope-minimal.json');
      final envelope = OperationEnvelope.fromJson(raw);
      final opened = await decryptEnvelope(key, envelope);
      expect(identical(opened, envelope), isTrue);
    });
  });

  group('negatives (the layout + binding contract)', () {
    test('wrong AAD fails authenticity', () async {
      final envelope = fixtureEnvelopes()[0];
      final slot = envelope.payload[r'$e'] as Map<String, dynamic>;
      expect(
        decryptPayload(key, 'wrong.aad', slot),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('a tampered ciphertext fails authenticity', () async {
      final envelope = fixtureEnvelopes()[0];
      final slot = Map<String, dynamic>.from(
          envelope.payload[r'$e'] as Map<String, dynamic>);
      final raw = b64uDecode(slot['ct'] as String);
      raw[20] ^= 0x01;
      slot['ct'] = b64uEncode(raw);
      expect(
        decryptPayload(key, envelopeAad(envelope), slot),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('a ct‖tag misread (WebCrypto layout) fails the tag-first fixture',
        () async {
      final envelope = fixtureEnvelopes()[0];
      final slot = envelope.payload[r'$e'] as Map<String, dynamic>;
      final raw = b64uDecode(slot['ct'] as String);
      // Re-pack as if the layout were ct‖tag — a port that assumes
      // WebCrypto's seal form feeds the same bytes through the wrong
      // split and must NOT open.
      final misread = <String, dynamic>{
        'iv': slot['iv'],
        'ct': b64uEncode([...raw.sublist(16), ...raw.sublist(0, 16)]),
      };
      expect(
        decryptPayload(key, envelopeAad(envelope), misread),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('malformed slots fail loud', () async {
      final envelope = fixtureEnvelopes()[0];
      expect(
        decryptPayload(key, envelopeAad(envelope), {'iv': 'x'}),
        throwsFormatException,
      );
      expect(
        decryptPayload(key, envelopeAad(envelope),
            {'iv': b64uEncode([1, 2, 3]), 'ct': b64uEncode(List<int>.filled(20, 0))}),
        throwsFormatException,
      );
    });
  });
}
