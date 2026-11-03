@Timeout(Duration(minutes: 2))
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/domain/models/relay/asset_crypto.dart';
import 'package:notees/domain/models/relay/payload_crypto.dart';

/// Asset-byte sealing (plan 05): the tag-first blob + external-IV layout
/// every port shares (TS WebCrypto reference, GTK cryptography, Flutter
/// package:cryptography). Round-trip, layout, and fail-closed tamper cases.
void main() {
  group('encryptAssetBytes/decryptAssetBytes', () {
    test('round-trips empty and non-empty bytes', () async {
      final key = generateWorkspaceKey();
      final cases = <Uint8List>[
        Uint8List(0),
        Uint8List.fromList([1, 2, 3, 250, 251, 252]),
        Uint8List.fromList(List<int>.generate(4096, (i) => i % 256)),
      ];
      for (final bytes in cases) {
        final sealed = await encryptAssetBytes(key, bytes);
        expect(sealed.iv.length, 12);
        expect(sealed.blob.length, 16 + bytes.length);
        expect(await decryptAssetBytes(key, sealed.iv, sealed.blob), bytes);
      }
    });

    test('blob is tag-first: opens via a manually split SecretBox', () async {
      // Proves the tag‖ct layout against package:cryptography directly —
      // the byte contract the TS/GTK ports must match (tag = first 16
      // bytes, ciphertext = the rest, IV external).
      final key = generateWorkspaceKey();
      final bytes = Uint8List.fromList(
        List<int>.generate(64, (i) => i * 3 % 256),
      );
      final sealed = await encryptAssetBytes(key, bytes);
      final box = SecretBox(
        sealed.blob.sublist(16),
        nonce: sealed.iv,
        mac: Mac(sealed.blob.sublist(0, 16)),
      );
      final opened = await AesGcm.with256bits().decrypt(
        box,
        secretKey: key,
      );
      expect(Uint8List.fromList(opened), bytes);
    });

    test('fresh IV per seal (same plaintext, two uploads)', () async {
      final key = generateWorkspaceKey();
      final bytes = Uint8List.fromList([9, 9, 9]);
      final a = await encryptAssetBytes(key, bytes);
      final b = await encryptAssetBytes(key, bytes);
      expect(a.iv, isNot(b.iv));
      expect(a.blob, isNot(b.blob));
    });

    test('wrong key, tampered tag, tampered ciphertext all fail closed',
        () async {
      final key = generateWorkspaceKey();
      final other = SecretKey(List<int>.filled(32, 9));
      final bytes = Uint8List.fromList([1, 2, 3, 250, 251, 252]);
      final sealed = await encryptAssetBytes(key, bytes);

      expect(
        decryptAssetBytes(other, sealed.iv, sealed.blob),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );

      final tamperedTag = Uint8List.fromList(sealed.blob);
      tamperedTag[0] ^= 0xff;
      expect(
        decryptAssetBytes(key, sealed.iv, tamperedTag),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );

      final tamperedCt = Uint8List.fromList(sealed.blob);
      tamperedCt[tamperedCt.length - 1] ^= 0xff;
      expect(
        decryptAssetBytes(key, sealed.iv, tamperedCt),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('malformed IV and blob are rejected with FormatException', () async {
      final key = generateWorkspaceKey();
      final sealed = await encryptAssetBytes(key, Uint8List.fromList([1]));

      expect(
        decryptAssetBytes(key, Uint8List(11), sealed.blob),
        throwsA(isFormatException),
      );
      expect(
        decryptAssetBytes(key, sealed.iv, Uint8List(15)),
        throwsA(isFormatException),
      );
    });
  });
}
