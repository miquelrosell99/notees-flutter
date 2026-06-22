import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/server_profile.dart';

/// Stores and manages the user's Notees server profiles.
class ServerRepository {
  ServerRepository({
    SharedPreferences? prefs,
    FlutterSecureStorage? secureStorage,
  })  : _prefs = prefs ?? SharedPreferences.getInstance() as SharedPreferences,
        _secureStorage = secureStorage ?? const FlutterSecureStorage();

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secureStorage;

  static const _serversKey = 'servers';
  static const _activeServerIdKey = 'active_server_id';

  Future<List<ServerProfile>> getServers() async {
    final raw = _prefs.getStringList(_serversKey) ?? [];
    return raw.map((r) => ServerProfile.fromRaw(r)).toList();
  }

  Future<ServerProfile?> getActiveServer() async {
    final servers = await getServers();
    final activeId = _prefs.getString(_activeServerIdKey);
    if (activeId == null) return servers.firstOrNull;
    return servers.where((s) => s.id == activeId).firstOrNull ?? servers.firstOrNull;
  }

  Future<String?> getActiveServerId() async => _prefs.getString(_activeServerIdKey);

  Future<void> setActiveServerId(String? id) async {
    if (id == null) {
      await _prefs.remove(_activeServerIdKey);
    } else {
      await _prefs.setString(_activeServerIdKey, id);
    }
  }

  Future<ServerProfile> addServer({
    required String url,
    required String nickname,
    String? apiKey,
  }) async {
    final normalized = _normalizeUrl(url);
    final profile = ServerProfile(
      id: _generateId(),
      url: normalized,
      nickname: nickname.isEmpty ? normalized : nickname,
      apiKey: apiKey,
    );
    final servers = await getServers();
    servers.add(profile);
    await _saveServers(servers);
    await setActiveServerId(profile.id);
    return profile;
  }

  Future<void> updateServer(ServerProfile profile) async {
    final servers = await getServers();
    final index = servers.indexWhere((s) => s.id == profile.id);
    if (index >= 0) {
      servers[index] = profile;
      await _saveServers(servers);
    }
  }

  Future<void> removeServer(String id) async {
    final servers = await getServers();
    servers.removeWhere((s) => s.id == id);
    await _saveServers(servers);
    final activeId = await getActiveServerId();
    if (activeId == id) {
      await setActiveServerId(servers.firstOrNull?.id);
    }
  }

  Future<void> clear() async {
    await _prefs.remove(_serversKey);
    await _prefs.remove(_activeServerIdKey);
    await _secureStorage.deleteAll();
  }

  Future<void> _saveServers(List<ServerProfile> servers) async {
    await _prefs.setStringList(_serversKey, servers.map((s) => s.toRaw()).toList());
  }

  /// Verifies that the server is reachable. Returns an error message or null.
  Future<String?> pingServer(String url) async {
    final normalized = _normalizeUrl(url);
    final healthUri = Uri.parse('$normalized/api/health');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(healthUri);
      final response = await request.close().timeout(const Duration(seconds: 8));
      if (response.statusCode >= 400) {
        return 'Server returned ${response.statusCode}';
      }
      await response.drain<void>();
      return null;
    } on Exception catch (e) {
      return 'Could not reach server: $e';
    } finally {
      client.close();
    }
  }

  String _normalizeUrl(String url) {
    var trimmed = url.trim();
    if (trimmed.endsWith('/')) trimmed = trimmed.substring(0, trimmed.length - 1);
    return trimmed;
  }

  String _generateId() {
    final now = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final rand = Random.secure().nextInt(0xFFFFFF).toRadixString(36);
    return '$now$rand';
  }
}
