import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  group('custody (KDF record + key wrap, plan-04 port)', () {
    const password = 'golden horse battery';
    final salt = List<int>.generate(16, (i) => i + 1);
    final fixedIv = List<int>.generate(12, (i) => 0xa0 + i);
    final masterBytes = List<int>.generate(32, (i) => 0x50 + i);

    /// Builds the KDF record EXACTLY as the server's createKdfRecord does
    /// (apps/server/src/auth.ts), with fixed bytes where the server draws
    /// random — the plan-01 TS golden vector ported with exact-string
    /// equality (the expected strings were produced independently with
    /// node:crypto).
    Future<KdfRecord> buildServerStyleRecord() async {
      final derived = deriveScryptKeyBytes(password, salt);
      final box = await AesGcm.with256bits().encrypt(
        masterBytes,
        secretKey: SecretKey(derived),
        nonce: fixedIv,
      );
      return KdfRecord(
        algorithm: 'scrypt',
        n: scryptN,
        r: scryptR,
        p: scryptP,
        salt: b64uEncode(salt),
        wrappedMasterKey: b64uEncode(
          [...fixedIv, ...box.mac.bytes, ...box.cipherText],
        ),
        keyVerifier: b64uEncode(await keyVerifierBytes(derived)),
      );
    }

    test('golden vector: exact wrapped record + verifier strings', () async {
      final record = await buildServerStyleRecord();
      expect(record.salt, 'AQIDBAUGBwgJCgsMDQ4PEA');
      expect(
        record.wrappedMasterKey,
        'oKGio6SlpqeoqaqrEa5lc67bpNjQU9ACvDQTRW-HY5NU6Vl8Axj2OTztsZafrlTyzXIVbR3uyA7jS5IN',
      );
      expect(record.keyVerifier, '12aPlhN1yihN2nOKLlxUSperu4hEr-qg2LS54MbGTtk');
    });

    test('golden vector: unwrap opens the server-built record and the '
        'master key opens a server-sealed blob', () async {
      final record = await buildServerStyleRecord();
      final masterKey = await unwrapMasterKey(password, record);

      // A blob the server sealed with the master key (node:crypto:
      // AES-256-GCM over "hello notees" with a fixed iv).
      final blobIv = List<int>.generate(12, (i) => 0xc0 + i);
      final blobBox = await AesGcm.with256bits().encrypt(
        utf8.encode('hello notees'),
        secretKey: SecretKey(masterBytes),
        nonce: blobIv,
      );
      final opened = await AesGcm.with256bits().decrypt(
        blobBox,
        secretKey: masterKey,
      );
      expect(utf8.decode(opened), 'hello notees');

      // Wrong password fails at the verifier, before any unwrap.
      expect(
        unwrapMasterKey('wrong password', record),
        throwsA(isA<StateError>()),
      );
      try {
        await unwrapMasterKey('wrong password', record);
        fail('expected a verifier mismatch');
      } on StateError catch (e) {
        expect(e.message, contains('verifier'));
      }
    });

    test('createKdfRecord/unwrapMasterKey round-trip', () async {
      final masterKey = generateMasterKey();
      final record = await createKdfRecord(masterKey, password);
      expect(record.algorithm, 'scrypt');
      expect(record.n, scryptN);
      expect(record.r, scryptR);
      expect(record.p, scryptP);
      final unwrapped = await unwrapMasterKey(password, record);
      expect(await unwrapped.extractBytes(), await masterKey.extractBytes());
      expect(unwrapMasterKey('nope', record), throwsStateError);
    });

    test('workspace key wrap/unwrap round-trip; wrong master fails', () async {
      final master = generateMasterKey();
      final otherMaster = generateMasterKey();
      final workspaceKey = generateWorkspaceKey();
      final wrapped = await wrapWorkspaceKey(master, workspaceKey);
      final opened = await unwrapWorkspaceKey(master, wrapped);
      expect(await opened.extractBytes(), await workspaceKey.extractBytes());
      expect(
        unwrapWorkspaceKey(otherMaster, wrapped),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('encryptPayload/decryptPayload round-trip with AAD binding', () async {
      final workspaceKey = importWorkspaceKey(
        b64uEncode(List<int>.generate(32, (i) => 0x30 + i)),
      );
      const aad = '0192a000-0000-7000-8000-0000000000fc.10000000-0000-4000-8000-000000000001';
      const payload = <String, dynamic>{'objectId': 'x', 'isEmbedded': false};
      final slot = await encryptPayload(workspaceKey, aad, payload);
      expect(slot.keys, [r'$e']);
      final opened = await decryptPayload(
        workspaceKey,
        aad,
        slot[r'$e'] as Map<String, dynamic>,
      );
      expect(opened, payload);
      expect(
        decryptPayload(
          workspaceKey,
          'wrong.aad',
          slot[r'$e'] as Map<String, dynamic>,
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('encryptEnvelope/decryptEnvelope round-trip; other fields preserved',
        () async {
      final envelopes = fixtureEnvelopes();
      final plaintext = envelopes[0];
      final workspaceKey = importWorkspaceKey(
        fixture['crypto']['workspaceKey'] as String,
      );
      final sealed = await encryptEnvelope(workspaceKey, plaintext);
      expect(sealed.payload.keys, [r'$e']);
      expect(sealed.id, plaintext.id);
      expect(sealed.hlc, plaintext.hlc);
      expect(sealed.opType, plaintext.opType);
      expect(sealed.affectedNodeIds, plaintext.affectedNodeIds);
      final opened = await decryptEnvelope(workspaceKey, sealed);
      expect(opened.payload, plaintext.payload);
    });

    test('encryptBytes/decryptBytes round-trip; wrong key + tamper fail',
        () async {
      final workspaceKey = generateWorkspaceKey();
      final other = SecretKey(List<int>.filled(32, 9));
      final bytes = Uint8List.fromList([1, 2, 3, 250, 251, 252]);
      final sealed = await encryptBytes(workspaceKey, bytes);
      expect(sealed.length, 12 + 16 + bytes.length);
      expect(await decryptBytes(workspaceKey, sealed), bytes);
      expect(
        decryptBytes(other, sealed),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      final tampered = Uint8List.fromList(sealed);
      tampered[tampered.length - 1] ^= 0xff;
      expect(
        decryptBytes(workspaceKey, tampered),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('decryptBytesToFile round-trips through files; wrong key fails',
        () async {
      final workspaceKey = generateWorkspaceKey();
      final other = SecretKey(List<int>.filled(32, 9));
      final bytes = Uint8List.fromList(
          List<int>.generate(300 * 1024 + 11, (i) => i % 256));
      final sealed = await encryptBytes(workspaceKey, bytes);

      final tempDir = await Directory.systemTemp.createTemp('notees_crypto');
      addTearDown(() => tempDir.delete(recursive: true));
      final sealedPath = '${tempDir.path}/blob.sealed';
      final plainPath = '${tempDir.path}/blob.db';
      final wrongPath = '${tempDir.path}/blob.wrong';
      await File(sealedPath).writeAsBytes(sealed, flush: true);

      await decryptBytesToFile(workspaceKey, sealedPath, plainPath);
      expect(await File(plainPath).readAsBytes(), bytes);

      expect(
        decryptBytesToFile(other, sealedPath, wrongPath),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      expect(await File(wrongPath).exists(), isFalse);
    });

    test('export/import round-trips a workspace key', () async {
      final workspaceKey = generateWorkspaceKey();
      final raw = await exportWorkspaceKey(workspaceKey);
      expect(raw.length, 32);
      final reimported = importWorkspaceKey(b64uEncode(raw));
      expect(await exportWorkspaceKey(reimported), raw);
    });
  });
}
