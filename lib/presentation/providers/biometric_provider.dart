import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/secure/biometric_helper.dart';
import '../../core/secure/encryption_provider.dart';
import '../../core/secure/secure_storage.dart';

/// Persists and exposes the biometric app-lock preference.
///
/// When enabled, the local SQLite database is also encrypted at rest and the
/// encryption password is stored in secure storage. Unlocking with biometrics
/// retrieves the password and unlocks the database.
class BiometricProvider extends ChangeNotifier {
  BiometricProvider({
    required this.prefs,
    this.encryptionProvider,
    this.secureStorage,
    BiometricHelper? helper,
  }) : _helper = helper ?? BiometricHelper();

  final SharedPreferences prefs;
  EncryptionProvider? encryptionProvider;
  SecureStorage? secureStorage;
  final BiometricHelper _helper;

  static const _enabledKey = 'biometric_lock_enabled';

  bool? _available;
  bool _enabled = false;

  bool? get available => _available;
  bool get enabled => _enabled;

  Future<void> initialize() async {
    _enabled = prefs.getBool(_enabledKey) ?? false;
    try {
      _available = await _helper.isAvailable();
    } on Exception catch (_) {
      _available = false;
    }
    notifyListeners();
  }

  Future<bool> canAuthenticate() => _helper.isAvailable();

  /// Authenticates with biometrics and, if encryption is enabled, unlocks the
  /// database using the password stored in secure storage.
  Future<bool> authenticate({String reason = 'Unlock Notees'}) async {
    if (!enabled) return true;
    final available = await _helper.isAvailable();
    if (!available) return true;

    final ok = await _helper.authenticate(reason);
    if (!ok) return false;

    await _unlockEncryption();
    return true;
  }

  Future<void> setEnabled(bool value) async {
    HapticFeedback.lightImpact();
    if (value) {
      final ok = await _helper.authenticate('Enable biometric lock');
      if (!ok) return;
      await _enableEncryption();
    } else {
      await _disableEncryption();
    }
    _enabled = value;
    await prefs.setBool(_enabledKey, value);
    notifyListeners();
  }

  Future<void> _enableEncryption() async {
    final encryption = encryptionProvider;
    final storage = secureStorage;
    if (encryption == null || storage == null) return;

    if (encryption.isEnabled) {
      // Already encrypted; just try to ensure the database is unlocked.
      await _unlockEncryption();
      return;
    }

    final password = _generatePassword();
    await storage.writeEncryptionPassword(password);
    await encryption.enable(password);
  }

  Future<void> _disableEncryption() async {
    // Removing the password from secure storage means the app can no longer
    // auto-unlock the database with biometrics. The database stays encrypted;
    // the user can still unlock it manually from Settings or disable encryption
    // explicitly. This avoids data loss from recreating an unencrypted database.
    await secureStorage?.deleteEncryptionPassword();
  }

  Future<void> _unlockEncryption() async {
    final encryption = encryptionProvider;
    final storage = secureStorage;
    if (encryption == null ||
        storage == null ||
        !encryption.isEnabled ||
        encryption.isUnlocked) {
      return;
    }

    final password = await storage.readEncryptionPassword();
    if (password == null || password.isEmpty) return;

    try {
      await encryption.unlock(password);
    } on EncryptionException {
      // If the stored password does not unlock the database, the user will be
      // prompted to enter it via the encryption unlock flow.
    }
  }

  String _generatePassword() {
    final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    return base64UrlEncode(bytes);
  }
}
