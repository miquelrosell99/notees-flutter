import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/secure/biometric_helper.dart';

/// Persists and exposes the biometric app-lock preference.
class BiometricProvider extends ChangeNotifier {
  BiometricProvider({
    required this.prefs,
    BiometricHelper? helper,
  }) : _helper = helper ?? BiometricHelper();

  final SharedPreferences prefs;
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

  Future<bool> authenticate({String reason = 'Unlock Notees'}) async {
    if (!enabled) return true;
    final available = await _helper.isAvailable();
    if (!available) return true;
    return _helper.authenticate(reason);
  }

  Future<void> setEnabled(bool value) async {
    HapticFeedback.lightImpact();
    if (value) {
      final ok = await _helper.authenticate('Enable biometric lock');
      if (!ok) return;
    }
    _enabled = value;
    await prefs.setBool(_enabledKey, value);
    notifyListeners();
  }
}
