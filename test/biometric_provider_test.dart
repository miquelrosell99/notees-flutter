import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/secure/biometric_helper.dart';
import 'package:notees/core/secure/encryption_provider.dart';
import 'package:notees/core/secure/secure_storage.dart';
import 'package:notees/presentation/providers/biometric_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeEncryptionProvider extends EncryptionProvider {
  _FakeEncryptionProvider({required super.prefs});

  bool _enabled = false;
  bool _unlocked = false;

  @override
  bool get isEnabled => _enabled;

  @override
  bool get isUnlocked => _unlocked;

  @override
  Future<void> enable(String password) async {
    _enabled = true;
    _unlocked = true;
    notifyListeners();
  }

  @override
  Future<void> unlock(String password) async {
    if (!_enabled) {
      throw const EncryptionException('Encryption is not configured');
    }
    _unlocked = true;
    notifyListeners();
  }

  @override
  Future<void> lock() async {
    _unlocked = false;
    notifyListeners();
  }

  @override
  Future<void> disable() async {
    _enabled = false;
    _unlocked = false;
    notifyListeners();
  }
}

class _FakeSecureStorage implements SecureStorage {
  final Map<String, String> _values = {};

  @override
  Future<void> clear() async => _values.clear();

  @override
  Future<void> deleteAccessToken() async {}

  @override
  Future<void> deleteApiKey(String serverId) async {}

  @override
  Future<void> deleteEncryptionPassword() async => _values.remove('encryption_password');

  @override
  Future<String?> readAccessToken() async => null;

  @override
  Future<String?> readApiKey(String serverId) async => null;

  @override
  Future<String?> readEncryptionPassword() async => _values['encryption_password'];

  @override
  Future<void> writeAccessToken(String token) async {}

  @override
  Future<void> writeApiKey(String serverId, String key) async {}

  @override
  Future<void> writeEncryptionPassword(String password) async =>
      _values['encryption_password'] = password;
}

class _AlwaysOkBiometricHelper extends BiometricHelper {
  _AlwaysOkBiometricHelper() : super();

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> authenticate(String reason) async => true;
}

class _UnavailableBiometricHelper extends BiometricHelper {
  _UnavailableBiometricHelper() : super();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<bool> authenticate(String reason) async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BiometricProvider', () {
    late SharedPreferences prefs;
    late _FakeEncryptionProvider encryption;
    late _FakeSecureStorage storage;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      encryption = _FakeEncryptionProvider(prefs: prefs);
      storage = _FakeSecureStorage();
    });

    test('enabling biometric lock enables encryption and stores password', () async {
      final provider = BiometricProvider(
        prefs: prefs,
        encryptionProvider: encryption,
        secureStorage: storage,
        helper: _AlwaysOkBiometricHelper(),
      );
      await provider.initialize();

      expect(encryption.isEnabled, isFalse);

      await provider.setEnabled(true);

      expect(provider.enabled, isTrue);
      expect(encryption.isEnabled, isTrue);
      expect(encryption.isUnlocked, isTrue);
      expect(await storage.readEncryptionPassword(), isNotNull);
      expect(await storage.readEncryptionPassword(), isNotEmpty);
    });

    test('disabling biometric lock removes stored password but keeps encryption', () async {
      final provider = BiometricProvider(
        prefs: prefs,
        encryptionProvider: encryption,
        secureStorage: storage,
        helper: _AlwaysOkBiometricHelper(),
      );
      await provider.initialize();
      await provider.setEnabled(true);

      await provider.setEnabled(false);

      expect(provider.enabled, isFalse);
      expect(encryption.isEnabled, isTrue);
      expect(await storage.readEncryptionPassword(), isNull);
    });

    test('authenticate unlocks encryption using stored password', () async {
      final provider = BiometricProvider(
        prefs: prefs,
        encryptionProvider: encryption,
        secureStorage: storage,
        helper: _AlwaysOkBiometricHelper(),
      );
      await provider.initialize();
      await provider.setEnabled(true);
      await encryption.lock();
      expect(encryption.isUnlocked, isFalse);

      final ok = await provider.authenticate();

      expect(ok, isTrue);
      expect(encryption.isUnlocked, isTrue);
    });

    test('authenticate returns true when biometrics are unavailable', () async {
      final provider = BiometricProvider(
        prefs: prefs,
        encryptionProvider: encryption,
        secureStorage: storage,
        helper: _UnavailableBiometricHelper(),
      );
      await provider.initialize();
      await provider.setEnabled(true);

      final ok = await provider.authenticate();

      expect(ok, isTrue);
    });
  });
}
