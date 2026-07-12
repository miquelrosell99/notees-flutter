import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api/api_client.dart';
import '../../core/secure/secure_storage.dart';
import '../../core/utils/client_id.dart';
import '../../data/local/app_database.dart';
import '../../data/models/server_profile.dart';
import '../../data/models/user.dart';
import '../../data/repositories/auth_repository.dart';
import '../../data/repositories/server_repository.dart';
import '../../data/repositories/workspace_repository.dart';
import '../../domain/services/sync_v2_service.dart';

/// Exposes the current server, authenticated user, and auth operations.
class AuthProvider extends ChangeNotifier {
  AuthProvider({
    required this.serverRepository,
    required this.secureStorage,
    required this.prefs,
  });

  final ServerRepository serverRepository;
  final SecureStorage secureStorage;
  final SharedPreferences prefs;

  ServerProfile? _activeServer;
  User? _user;
  Dio? _dio;
  SyncV2Service? _syncService;
  TwoFactorChallenge? _twoFactorChallenge;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  ServerProfile? get activeServer => _activeServer;
  User? get user => _user;
  bool get isAuthenticated => _user != null;
  bool get loading => _loading;
  bool get busy => _busy;
  String? get error => _error;
  Dio? get dio => _dio;
  SyncV2Service? get syncService => _syncService;

  /// Pending 2FA challenge after a successful password step, if any.
  TwoFactorChallenge? get twoFactorChallenge => _twoFactorChallenge;

  Future<void> initialize() async {
    _loading = true;
    notifyListeners();
    try {
      _activeServer = await serverRepository.getActiveServer();
      if (_activeServer != null) {
        _dio = createApiClient(
          baseUrl: _activeServer!.url,
          secureStorage: secureStorage,
          trustSelfSigned: _activeServer!.trustSelfSigned,
          cookieJar: await sharedCookieJar(),
        );
        _syncService = await _buildSyncService(_dio!);
        _user = await AuthRepository(dio: _dio!, secureStorage: secureStorage).checkSession();
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<SyncV2Service> _buildSyncService(Dio dio) async {
    final clientId = await getClientId(prefs);
    return SyncV2Service(
      database: AppDatabase(),
      dio: dio,
      clientId: clientId,
    );
  }

  Future<void> selectServer(ServerProfile server) async {
    await serverRepository.setActiveServerId(server.id);
    _activeServer = server;
    _dio = createApiClient(
      baseUrl: server.url,
      secureStorage: secureStorage,
      trustSelfSigned: server.trustSelfSigned,
      cookieJar: await sharedCookieJar(),
    );
    _syncService = await _buildSyncService(_dio!);
    _user = null;
    _twoFactorChallenge = null;
    notifyListeners();
  }

  Future<void> login(String email, String password, {bool rememberMe = false}) async {
    _error = null;
    _twoFactorChallenge = null;
    _busy = true;
    notifyListeners();
    try {
      if (_dio == null) throw const AuthException('No server configured');
      final repo = AuthRepository(dio: _dio!, secureStorage: secureStorage);
      final result = await repo.login(email: email, password: password, rememberMe: rememberMe);
      switch (result) {
        case LoginSuccess(:final user):
          _user = user;
          await _switchToDefaultWorkspace();
        case TwoFactorChallenge():
          _twoFactorChallenge = result;
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Completes a pending 2FA challenge with a TOTP or backup code.
  Future<void> verifyTwoFactor(String code) async {
    final challenge = _twoFactorChallenge;
    if (challenge == null) throw const AuthException('No two-factor challenge pending');
    _error = null;
    _busy = true;
    notifyListeners();
    try {
      if (_dio == null) throw const AuthException('No server configured');
      final repo = AuthRepository(dio: _dio!, secureStorage: secureStorage);
      _user = await repo.verifyTwoFactor(
        preauthToken: challenge.preauthToken,
        code: code,
      );
      _twoFactorChallenge = null;
      await _switchToDefaultWorkspace();
    } catch (e) {
      _error = e.toString();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Discards a pending 2FA challenge, returning to the password step.
  void cancelTwoFactor() {
    _twoFactorChallenge = null;
    _error = null;
    notifyListeners();
  }

  Future<void> register(String email, String password, {String? name, String? surnames}) async {
    _error = null;
    _busy = true;
    notifyListeners();
    try {
      if (_dio == null) throw const AuthException('No server configured');
      final repo = AuthRepository(dio: _dio!, secureStorage: secureStorage);
      _user = await repo.register(email: email, password: password, name: name, surnames: surnames);
      await _switchToDefaultWorkspace();
    } catch (e) {
      _error = e.toString();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    _busy = true;
    notifyListeners();
    try {
      if (_dio != null) {
        await AuthRepository(dio: _dio!, secureStorage: secureStorage).logout();
      }
    } finally {
      _busy = false;
      _user = null;
      _twoFactorChallenge = null;
      notifyListeners();
    }
  }

  /// Switches the active server and clears the current session so the user
  /// must sign in again.
  Future<void> switchActiveServer(ServerProfile server) async {
    await selectServer(server);
  }

  /// Updates the current user's profile and refreshes the cached user.
  Future<void> updateUserProfile({String? name, String? surnames}) async {
    if (_dio == null) throw const AuthException('No server configured');
    final repo = AuthRepository(dio: _dio!, secureStorage: secureStorage);
    _user = await repo.updateProfile(name: name, surnames: surnames);
    notifyListeners();
  }

  Future<void> _switchToDefaultWorkspace() async {
    if (_dio == null) return;
    final workspaceRepo = WorkspaceRepository(dio: _dio!);
    final workspaces = await workspaceRepo.listWorkspaces();
    if (workspaces.isNotEmpty) {
      await workspaceRepo.switchWorkspace(workspaces.first.uuid);
    }
  }
}
