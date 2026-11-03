import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/key_derivators/api.dart' show ScryptParameters;
import 'package:pointycastle/key_derivators/scrypt.dart' show Scrypt;

import './operation_envelope.dart';

/// The scrypt parameters every client and the server agree on
/// (`SCRYPT_PARAMS` in crypto.ts, `KDF_N/R/P` in apps/server/src/auth.ts).
/// N=131072, r=8, p=1, dkLen=32.
const scryptN = 131072;
const scryptR = 8;
const scryptP = 1;
const scryptKeyLength = 32;

/// The account's password-wrapped master key record (server
/// `createKdfRecord`, KdfRecord in crypto.ts): scrypt parameters + salt, the
/// master key wrapped with the password-derived key (`iv ‖ tag ‖ ct` b64u),
/// and the verifier — HMAC-SHA256 over the DERIVED key with
/// "notees-key-check" — so a wrong password is detectable before the unwrap.
class KdfRecord {
  const KdfRecord({
    required this.algorithm,
    required this.n,
    required this.r,
    required this.p,
    required this.salt,
    required this.wrappedMasterKey,
    required this.keyVerifier,
  });

  final String algorithm;
  final int n;
  final int r;
  final int p;
  final String salt;
  final String wrappedMasterKey;
  final String keyVerifier;

  factory KdfRecord.fromJson(Map<String, dynamic> json) => KdfRecord(
        algorithm: json['algorithm'] as String? ?? 'scrypt',
        n: (json['N'] as num?)?.toInt() ?? scryptN,
        r: (json['r'] as num?)?.toInt() ?? scryptR,
        p: (json['p'] as num?)?.toInt() ?? scryptP,
        salt: json['salt'] as String,
        wrappedMasterKey: json['wrappedMasterKey'] as String,
        keyVerifier: json['keyVerifier'] as String,
      );

  Map<String, dynamic> toJson() => {
        'algorithm': algorithm,
        'N': n,
        'r': r,
        'p': p,
        'salt': salt,
        'wrappedMasterKey': wrappedMasterKey,
        'keyVerifier': keyVerifier,
      };
}

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

/// Constant-time equality for byte strings (the verifier check —
/// `constantTimeEqual` in crypto.ts).
bool _constantTimeEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Derives the 32-byte password wrap key via scrypt (pointycastle —
/// package:cryptography has no scrypt). Pure Dart; N=131072 needs ~128MiB
/// of scratch, so this is the expensive step of login (the same cost the
/// web/GTK clients pay).
Uint8List deriveScryptKeyBytes(String password, List<int> salt) {
  final derivator = Scrypt()
    ..init(
      ScryptParameters(
        scryptN,
        scryptR,
        scryptP,
        scryptKeyLength,
        Uint8List.fromList(salt),
      ),
    );
  final passwordBytes = Uint8List.fromList(utf8.encode(password));
  final out = Uint8List(scryptKeyLength);
  derivator.deriveKey(passwordBytes, 0, out, 0);
  return out;
}

/// `keyVerifierOf` in crypto.ts: HMAC-SHA256(derivedKey, "notees-key-check").
Future<List<int>> keyVerifierBytes(List<int> derivedKeyBytes) async {
  final mac = await Hmac.sha256().calculateMac(
    utf8.encode('notees-key-check'),
    secretKey: SecretKey(derivedKeyBytes),
  );
  return mac.bytes;
}

/// A fresh random 256-bit master key (`generateMasterKey` in crypto.ts).
SecretKey generateMasterKey() => SecretKey(_randomBytes(32));

/// Wraps [masterKey] with the password-derived key into a [KdfRecord]
/// (`createKdfRecord` in crypto.ts).
Future<KdfRecord> createKdfRecord(SecretKey masterKey, String password) async {
  final salt = _randomBytes(16);
  final wrapKeyBytes = deriveScryptKeyBytes(password, salt);
  final iv = _randomBytes(12);
  final box = await AesGcm.with256bits().encrypt(
    await masterKey.extractBytes(),
    secretKey: SecretKey(wrapKeyBytes),
    nonce: iv,
  );
  return KdfRecord(
    algorithm: 'scrypt',
    n: scryptN,
    r: scryptR,
    p: scryptP,
    salt: b64uEncode(salt),
    // iv ‖ tag ‖ ct — the server record's layout, tag BEFORE ct (the
    // payload slot's ct field is the opposite order, documented below).
    wrappedMasterKey: b64uEncode(
      Uint8List.fromList([...iv, ...box.mac.bytes, ...box.cipherText]),
    ),
    keyVerifier: b64uEncode(await keyVerifierBytes(wrapKeyBytes)),
  );
}

/// Opens a [KdfRecord] with [password] (`unwrapMasterKey` in crypto.ts).
/// Fail-fast: the verifier is over the derived key, so a wrong password is
/// rejected before the wrapped key is touched.
Future<SecretKey> unwrapMasterKey(String password, KdfRecord record) async {
  final salt = b64uDecode(record.salt);
  final wrapKeyBytes = deriveScryptKeyBytes(password, salt);
  final expected = b64uDecode(record.keyVerifier);
  final actual = await keyVerifierBytes(wrapKeyBytes);
  if (!_constantTimeEqual(actual, expected)) {
    throw StateError('master-key verifier mismatch (wrong password)');
  }
  final raw = b64uDecode(record.wrappedMasterKey);
  if (raw.length < 12 + 16 + 1) {
    throw const FormatException('wrapped master key is too short');
  }
  final box = SecretBox(
    raw.sublist(28), // ct
    nonce: Uint8List.fromList(raw.sublist(0, 12)),
    mac: Mac(raw.sublist(12, 28)),
  );
  final masterBytes = await AesGcm.with256bits().decrypt(
    box,
    secretKey: SecretKey(wrapKeyBytes),
  );
  return SecretKey(masterBytes);
}

/// A fresh random 256-bit workspace key (`generateWorkspaceKey` in crypto.ts).
SecretKey generateWorkspaceKey() => SecretKey(_randomBytes(32));

/// Wraps [workspaceKey] with the account [masterKey]: b64u of
/// `iv ‖ tag ‖ ct` (`wrapWorkspaceKey` in crypto.ts — the same layout as the
/// KDF record, opposite order from the payload slot's ct field).
Future<String> wrapWorkspaceKey(
  SecretKey masterKey,
  SecretKey workspaceKey,
) async {
  final iv = _randomBytes(12);
  final box = await AesGcm.with256bits().encrypt(
    await workspaceKey.extractBytes(),
    secretKey: masterKey,
    nonce: iv,
  );
  return b64uEncode(
    Uint8List.fromList([...iv, ...box.mac.bytes, ...box.cipherText]),
  );
}

/// Inverse of [wrapWorkspaceKey] (`unwrapWorkspaceKey` in crypto.ts).
Future<SecretKey> unwrapWorkspaceKey(
  SecretKey masterKey,
  String wrapped,
) async {
  final raw = b64uDecode(wrapped);
  if (raw.length < 12 + 16 + 1) {
    throw const FormatException('wrapped workspace key is too short');
  }
  final box = SecretBox(
    raw.sublist(28),
    nonce: Uint8List.fromList(raw.sublist(0, 12)),
    mac: Mac(raw.sublist(12, 28)),
  );
  final bytes = await AesGcm.with256bits().decrypt(box, secretKey: masterKey);
  return SecretKey(bytes);
}

/// Seals one payload as the `{"$e": {iv, ct}}` slot (`encryptPayload` in
/// crypto.ts): iv = b64u(12-byte nonce), ct = b64u(tag(16) ‖ ct) — TAG FIRST,
/// the opposite order from the wrapped keys above.
Future<Map<String, dynamic>> encryptPayload(
  SecretKey workspaceKey,
  String aad,
  Map<String, dynamic> payload,
) async {
  final iv = _randomBytes(12);
  final box = await AesGcm.with256bits().encrypt(
    utf8.encode(jsonEncode(payload)),
    secretKey: workspaceKey,
    aad: utf8.encode(aad),
    nonce: iv,
  );
  return {
    r'$e': {
      'iv': b64uEncode(iv),
      'ct': b64uEncode(
        Uint8List.fromList([...box.mac.bytes, ...box.cipherText]),
      ),
    },
  };
}

/// Seals an envelope's payload; every other field (id, HLC, …) is preserved
/// (`encryptEnvelope` in crypto.ts).
Future<OperationEnvelope> encryptEnvelope(
  SecretKey workspaceKey,
  OperationEnvelope envelope,
) async {
  final slot = await encryptPayload(
    workspaceKey,
    envelopeAad(envelope),
    envelope.payload,
  );
  return envelope.copyWith(payload: slot);
}

/// Seals a snapshot blob: raw bytes `iv ‖ tag ‖ ct` (`encryptBytes` in
/// crypto.ts).
Future<Uint8List> encryptBytes(SecretKey workspaceKey, Uint8List bytes) async {
  final iv = _randomBytes(12);
  final box = await AesGcm.with256bits().encrypt(
    bytes,
    secretKey: workspaceKey,
    nonce: iv,
  );
  return Uint8List.fromList([...iv, ...box.mac.bytes, ...box.cipherText]);
}

/// Inverse of [encryptBytes] (`decryptBytes` in crypto.ts). Lets
/// [SecretBoxAuthenticationError] propagate on a wrong key or tampering.
Future<Uint8List> decryptBytes(
  SecretKey workspaceKey,
  Uint8List bytes,
) async {
  if (bytes.length < 12 + 16 + 1) {
    throw const FormatException('sealed blob is too short');
  }
  final box = SecretBox(
    bytes.sublist(28),
    nonce: Uint8List.fromList(bytes.sublist(0, 12)),
    mac: Mac(bytes.sublist(12, 28)),
  );
  final plain = await AesGcm.with256bits().decrypt(
    box,
    secretKey: workspaceKey,
  );
  return Uint8List.fromList(plain);
}

/// The raw 32-byte key behind a [SecretKey] (`exportWorkspaceKey` in
/// crypto.ts).
Future<Uint8List> exportWorkspaceKey(SecretKey workspaceKey) async {
  final raw = await workspaceKey.extractBytes();
  if (raw.length != 32) {
    throw FormatException(
      'workspace key must be 32 raw bytes, got ${raw.length}',
    );
  }
  return Uint8List.fromList(raw);
}

/// E2EE payload decryption (the `{"$e": {iv, ct}}` slot) — a Dart port of
/// `packages/protocol/src/crypto.ts` (WebCrypto reference) for the GTK/
/// Flutter lockstep corpus. AES-256-GCM via `package:cryptography`;
/// base64url via `dart:convert` with manual padding (the wire form is
/// UNPADDED b64u; decode re-pads).
///
/// The fixture/envelope contract (SCHEMA.md E2EE, `envelope-encrypted.json`):
///  - `crypto.workspaceKey` = b64u of the raw 32-byte AES key;
///  - AAD = `${envelope.id}.${envelope.workspaceId}` (binds the ciphertext
///    to its envelope — a moved ciphertext fails to open);
///  - slot `iv` = b64u of the 12-byte GCM nonce;
///  - slot `ct` = b64u of `tag(16) ‖ ct` — TAG FIRST (unlike the wrapped
///    keys' `iv ‖ tag ‖ ct`); package:cryptography's SecretBox wants the
///    split form, so `mac = raw.sublist(0, 16)`, `cipherText =
///    raw.sublist(16)`;
///  - plaintext = UTF-8 JSON of the payload object.
///
/// Runtime custody (sync boundary): SyncV2Service decrypts `$e` envelopes
/// before apply and encrypts a copy at push when a workspace key is
/// installed; with no key (locked) it skips them with a counted warning —
/// the locked semantic shared with the web/GTK clients. Keys are memory-only
/// (never persisted).
/// Unpadded on the wire (crypto.ts `b64uEncode` strips `=+$/`).
String b64uEncode(List<int> bytes) {
  final encoded = base64UrlEncode(bytes);
  final pad = encoded.indexOf('=');
  return pad == -1 ? encoded : encoded.substring(0, pad);
}

/// Unpadded-on-the-wire b64u; decode re-pads to a multiple of 4.
List<int> b64uDecode(String text) {
  final padded = text + '=' * ((4 - text.length % 4) % 4);
  try {
    return base64Url.decode(padded);
  } on FormatException {
    throw FormatException('invalid base64url: $text');
  }
}

/// GCM AAD binds a ciphertext to its envelope (`envelopeAad` in crypto.ts).
String envelopeAad(OperationEnvelope envelope) =>
    '${envelope.id}.${envelope.workspaceId}';

/// The raw 32-byte workspace key behind a fixture's `crypto.workspaceKey`.
SecretKey importWorkspaceKey(String b64uKey) {
  final raw = b64uDecode(b64uKey);
  if (raw.length != 32) {
    throw FormatException(
      'workspace key must be 32 raw bytes (b64u), got ${raw.length}',
    );
  }
  return SecretKey(raw);
}

/// Opens one `{"$e": {iv, ct}}` slot: splits the tag-first ct layout into
/// SecretBox form and decrypts with the envelope-bound AAD. Throws
/// [FormatException] on malformed slots and lets
/// [SecretBoxAuthenticationError] propagate on a wrong key/AAD/tampered
/// ciphertext (GCM authenticity).
Future<Map<String, dynamic>> decryptPayload(
  SecretKey workspaceKey,
  String aad,
  Map<String, dynamic> slot,
) async {
  final ivText = slot['iv'];
  final ctText = slot['ct'];
  if (ivText is! String || ctText is! String) {
    throw FormatException('encrypted slot must carry string iv/ct');
  }
  final iv = b64uDecode(ivText);
  if (iv.length != 12) {
    throw FormatException('GCM nonce must be 12 bytes, got ${iv.length}');
  }
  final raw = b64uDecode(ctText);
  if (raw.length < 16) {
    throw FormatException('ct must carry a 16-byte tag prefix');
  }
  // Tag-first wire layout → SecretBox(cipherText, nonce, mac).
  final cipherText = raw.sublist(16);
  final mac = Mac(raw.sublist(0, 16));
  final box = SecretBox(cipherText, nonce: iv, mac: mac);
  final algorithm = AesGcm.with256bits();
  final plain = await algorithm.decrypt(
    box,
    secretKey: workspaceKey,
    aad: utf8.encode(aad),
  );
  final decoded = jsonDecode(utf8.decode(plain));
  if (decoded is! Map<String, dynamic>) {
    throw FormatException('decrypted payload is not a JSON object');
  }
  return decoded;
}

/// Opens an envelope's payload; plaintext envelopes pass through unchanged
/// (`decryptEnvelope` in crypto.ts). Every other field (id, HLC, …) is
/// preserved.
Future<OperationEnvelope> decryptEnvelope(
  SecretKey workspaceKey,
  OperationEnvelope envelope,
) async {
  if (!envelope.payload.containsKey(r'$e')) return envelope;
  final payload = await decryptPayload(
    workspaceKey,
    envelopeAad(envelope),
    envelope.payload[r'$e'] as Map<String, dynamic>,
  );
  return envelope.copyWith(payload: payload);
}
