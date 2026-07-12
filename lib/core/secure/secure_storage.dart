import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Thin wrapper around [FlutterSecureStorage] for typed access to credentials.
class SecureStorage {
  const SecureStorage([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  static const _accessTokenKey = 'access_token';
  static const _apiKeyPrefix = 'api_key_';

  Future<void> writeAccessToken(String token) =>
      _storage.write(key: _accessTokenKey, value: token);

  Future<String?> readAccessToken() => _storage.read(key: _accessTokenKey);

  Future<void> deleteAccessToken() => _storage.delete(key: _accessTokenKey);

  Future<void> writeApiKey(String serverId, String key) =>
      _storage.write(key: '$_apiKeyPrefix$serverId', value: key);

  Future<String?> readApiKey(String serverId) =>
      _storage.read(key: '$_apiKeyPrefix$serverId');

  Future<void> deleteApiKey(String serverId) =>
      _storage.delete(key: '$_apiKeyPrefix$serverId');

  Future<void> clear() => _storage.deleteAll();
}
