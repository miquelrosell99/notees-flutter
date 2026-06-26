import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/local/app_database.dart';

String _bytesToHex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

Uint8List _generateSalt({int length = 16}) {
  final random = Random.secure();
  return Uint8List.fromList(List<int>.generate(length, (_) => random.nextInt(256)));
}

/// Manages opt-in SQLCipher encryption for the local database.
///
/// The user's password is never stored. A random salt is persisted in
/// [SharedPreferences] and a 256-bit key is derived with PBKDF2-HMAC-SHA256.
/// The derived key is kept in memory only while the database is unlocked.
class EncryptionProvider extends ChangeNotifier {
  EncryptionProvider({required this.prefs});

  final SharedPreferences prefs;

  static const _enabledKey = 'encryption_enabled';
  static const _saltKey = 'encryption_salt';
  static const _verifyKey = 'encryption_verify';
  static const _iterations = 100000;

  bool _isUnlocked = false;
  String? _derivedKeyHex;

  bool get isEnabled => prefs.getBool(_enabledKey) ?? false;

  bool get isUnlocked => _isUnlocked && _derivedKeyHex != null;

  String? get databasePassword {
    final key = _derivedKeyHex;
    if (key == null) return null;
    return "x'$key'";
  }

  /// Enables encryption with a new password. This deletes and recreates the
  /// local database with the SQLCipher password.
  Future<void> enable(String password) async {
    if (password.length < 8) {
      throw const EncryptionException('Password must be at least 8 characters');
    }

    final salt = _generateSalt();
    final key = await _deriveKey(password, salt);
    final verify = await _computeVerify(key);

    await prefs.setString(_saltKey, base64Encode(salt));
    await prefs.setString(_verifyKey, base64Encode(verify));
    await prefs.setBool(_enabledKey, true);

    _derivedKeyHex = _bytesToHex(key);
    _isUnlocked = true;
    AppDatabase.encryptionPassword = databasePassword;
    await AppDatabase().recreate();
    notifyListeners();
  }

  /// Unlocks the database with the user's password.
  Future<void> unlock(String password) async {
    final saltBase64 = prefs.getString(_saltKey);
    final verifyBase64 = prefs.getString(_verifyKey);
    if (saltBase64 == null || verifyBase64 == null) {
      throw const EncryptionException('Encryption is not configured');
    }

    final salt = base64Decode(saltBase64);
    final key = await _deriveKey(password, salt);
    final verify = await _computeVerify(key);
    final expected = base64Decode(verifyBase64);

    if (!_constantTimeEquals(verify, expected)) {
      throw const EncryptionException('Incorrect password');
    }

    _derivedKeyHex = _bytesToHex(key);
    _isUnlocked = true;
    AppDatabase.encryptionPassword = databasePassword;
    notifyListeners();
  }

  /// Locks the database. The user must enter the password again to unlock.
  Future<void> lock() async {
    _derivedKeyHex = null;
    _isUnlocked = false;
    AppDatabase.encryptionPassword = null;
    await AppDatabase().close();
    notifyListeners();
  }

  /// Disables encryption. This deletes and recreates the local database
  /// without a password.
  Future<void> disable() async {
    await prefs.remove(_enabledKey);
    await prefs.remove(_saltKey);
    await prefs.remove(_verifyKey);
    _derivedKeyHex = null;
    _isUnlocked = false;
    AppDatabase.encryptionPassword = null;
    await AppDatabase().recreate();
    notifyListeners();
  }

  /// Must be called at app startup if encryption is enabled but no password
  /// has been entered yet. It sets the locked state and closes any open
  /// unencrypted database connection.
  Future<void> initialize() async {
    if (isEnabled) {
      _isUnlocked = false;
      _derivedKeyHex = null;
      AppDatabase.encryptionPassword = null;
      await AppDatabase().close();
      notifyListeners();
    }
  }

  Future<Uint8List> _deriveKey(String password, Uint8List salt) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _iterations,
      bits: 256,
    );
    final secretKey = await pbkdf2.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );
    final bytes = await secretKey.extractBytes();
    return Uint8List.fromList(bytes);
  }

  Future<Uint8List> _computeVerify(Uint8List key) async {
    final hmac = Hmac.sha256();
    final mac = await hmac.calculateMac(
      utf8.encode('notees-mobile-encryption-verify'),
      secretKey: SecretKey(key),
    );
    return Uint8List.fromList(mac.bytes);
  }

  bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }
}

class EncryptionException implements Exception {
  const EncryptionException(this.message);

  final String message;

  @override
  String toString() => 'EncryptionException: $message';
}
