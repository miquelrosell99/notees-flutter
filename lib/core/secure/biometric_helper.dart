import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// Wraps local_auth to provide a simple biometric prompt for the app lock.
class BiometricHelper {
  BiometricHelper([LocalAuthentication? localAuth]) : _localAuth = localAuth ?? LocalAuthentication();

  final LocalAuthentication _localAuth;

  Future<bool> isAvailable() async {
    final available = await _localAuth.canCheckBiometrics;
    final deviceSupported = await _localAuth.isDeviceSupported();
    return available && deviceSupported;
  }

  Future<List<BiometricType>> getAvailableTypes() async {
    try {
      return await _localAuth.getAvailableBiometrics();
    } on PlatformException {
      return [];
    }
  }

  Future<bool> authenticate(String reason) async {
    try {
      return await _localAuth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
          useErrorDialogs: true,
        ),
      );
    } on PlatformException {
      return false;
    }
  }
}
