import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import './payload_crypto.dart' show randomBytes;

/// CAS asset-byte sealing (`encryptAssetBytes`/`decryptAssetBytes` in the
/// monorepo's crypto module, plan 05) — AES-256-GCM via
/// package:cryptography, no KDF (the workspace key arrives unwrapped from
/// crypto custody).
///
/// Blob layout contract — shared byte-for-byte with the TypeScript reference
/// (WebCrypto) and the GTK port; cross-client asset sharing depends on it:
///  - stored bytes = tag(16) ‖ ct — the GCM authentication tag FIRST, the
///    ciphertext after (package:cryptography's SecretBox splits it as
///    `mac = blob.sublist(0, 16)`, `cipherText = blob.sublist(16)`);
///  - the IV is EXTERNAL: server-side asset metadata (the `iv` column, b64u
///    on the wire), never part of the blob and never op-log state — the wire
///    and the fixture corpus are untouched;
///  - the IV is a fresh random 12-byte GCM nonce per asset.
///
/// Plaintext assets carry `iv NULL` and behave exactly as before; keyless
/// sessions upload and download plaintext (the mixed log stays legal).

/// Seals [bytes] for the CAS store: fresh random 12-byte IV, blob = tag‖ct.
Future<({Uint8List iv, Uint8List blob})> encryptAssetBytes(
  SecretKey workspaceKey,
  Uint8List bytes,
) async {
  final iv = randomBytes(12);
  final box = await AesGcm.with256bits().encrypt(
    bytes,
    secretKey: workspaceKey,
    nonce: iv,
  );
  return (
    iv: Uint8List.fromList(iv),
    blob: Uint8List.fromList([...box.mac.bytes, ...box.cipherText]),
  );
}

/// Inverse of [encryptAssetBytes]: opens a tag-first [blob] with the
/// external [iv]. Throws [FormatException] on a malformed blob or IV and
/// lets [SecretBoxAuthenticationError] propagate on a wrong key or
/// tampering — callers surface their honest error state, never corrupted
/// bytes.
Future<Uint8List> decryptAssetBytes(
  SecretKey workspaceKey,
  Uint8List iv,
  Uint8List blob,
) async {
  if (iv.length != 12) {
    throw FormatException('asset IV must be 12 bytes, got ${iv.length}');
  }
  if (blob.length < 16) {
    throw const FormatException('sealed asset blob must carry a 16-byte tag');
  }
  final box = SecretBox(
    blob.sublist(16),
    nonce: iv,
    mac: Mac(blob.sublist(0, 16)),
  );
  final plain = await AesGcm.with256bits().decrypt(
    box,
    secretKey: workspaceKey,
  );
  return Uint8List.fromList(plain);
}
