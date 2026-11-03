import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import './operation_envelope.dart';

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
/// Test support + future runtime custody (plan 04): the app runtime still
/// REJECTS `$e` payloads at apply time — only the fixture gates and replay
/// harnesses decrypt.
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
