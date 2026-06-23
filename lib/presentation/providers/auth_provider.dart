import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/secure/secure_storage.dart';
import '../../data/models/server_profile.dart';
import '../../data/models/user.dart';
import '../../data/repositories/auth_repository.dart';
import '../../data/repositories/server_repository.dart';
import '../../data/repositories/workspace_repository.dart';

/// Exposes the current server, authenticated user, and auth operations.
class AuthProvider extends ChangeNotifier {
  AuthProvider({
    required this.serverRepository,
    required this.secureStorage,
  });

  final ServerRepository serverRepository;
  final SecureStorage secureStorage;

  ServerProfile? _activeServer;
  User? _user;
  Dio? _dio;
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
        );
        _user = await AuthRepository(dio: _dio!, secureStorage: secureStorage).checkSession();
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> selectServer(ServerProfile server) async {
    await serverRepository.setActiveServerId(server.id);
    _activeServer = server;
    _dio = createApiClient(
      baseUrl: server.url,
      secureStorage: secureStorage,
      trustSelfSigned: server.trustSelfSigned,
    );
    _user = null;
    notifyListeners();
  }

  Future<void> login(String email, String password, {bool rememberMe = false}) async {
    _error = null;
    _busy = true;
    notifyListeners();
    try {
      if (_dio == null) throw const AuthException('No server configured');
      final repo = AuthRepository(dio: _dio!, secureStorage: secureStorage);
      _user = await repo.login(email: email, password: password, rememberMe: rememberMe);
      await _switchToDefaultWorkspace();
    } catch (e) {
      _error = e.toString();
    } finally {
      _busy = false;
      notifyListeners();
    }
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
