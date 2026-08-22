import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api/api_client.dart';
import '../../core/secure/secure_storage.dart';
import '../../core/utils/client_id.dart';
import '../../core/utils/uuid7.dart';
import '../../data/local/app_database.dart';
import '../../data/models/server_profile.dart';
import '../../data/models/user.dart';
import '../../data/repositories/auth_repository.dart';
import '../../data/repositories/server_repository.dart';
import '../../data/repositories/workspace_repository.dart';
import '../../domain/services/local_workspace_seed.dart';
import '../../domain/services/onboarding_service.dart';
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
  bool _onboardingCompleted = false;

  ServerProfile? get activeServer => _activeServer;
  User? get user => _user;
  bool get isAuthenticated => _user != null;
  bool get loading => _loading;
  bool get busy => _busy;
  String? get error => _error;
  Dio? get dio => _dio;
  SyncV2Service? get syncService => _syncService;
  bool get onboardingCompleted => _onboardingCompleted;

  /// Offline (serverless) mode: the current session is the synthetic local
  /// profile, with no server configured and no auth.
  bool get isLocalMode => _user?.isLocal ?? false;

  // Server-dependent capabilities, mirroring the web client's
  // `useCapabilities` gating. All are disabled in local mode; the UI hides
  // the corresponding entry points rather than letting them fail.
  bool get canManageServers => !isLocalMode;
  bool get canManageWorkspaces => !isLocalMode;
  bool get canManageAccount => !isLocalMode;
  bool get canShare => !isLocalMode;
  bool get canUploadAssets => !isLocalMode;

  // Local profile persistence. The local workspace uuid is stored alongside
  // so the session survives a local database reset.
  static const _localProfileUuidKey = 'local_profile_uuid';
  static const _localWorkspaceUuidKey = 'local_workspace_uuid';
  static const _localDisplayName = 'Local user';

  OnboardingService get onboardingService => OnboardingService(prefs: prefs);

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
        if (_user == null) {
          // Server configured but not signed in. If the user originally chose
          // local mode and a login is still pending (e.g. they added a server
          // but never completed sign-in), fall back to the local session so
          // local data stays reachable until a successful login adopts it.
          await _restoreLocalSessionIfPresent();
        }
        _applyActorId();
      } else {
        await _restoreLocalSessionIfPresent();
      }
      _onboardingCompleted = onboardingService.isCompleted;
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Restores the persisted local profile, if any. No-op otherwise.
  Future<void> _restoreLocalSessionIfPresent() async {
    final localUuid = prefs.getString(_localProfileUuidKey);
    if (localUuid == null) return;
    await _startLocalSession(localUuid);
  }

  /// Creates the local profile: a synthetic user with no server and no auth,
  /// plus the seeded local workspace. Mirrors the web client's
  /// `loginLocally()` + `ensureLocalWorkspace()`.
  Future<void> loginLocally() async {
    _error = null;
    _busy = true;
    notifyListeners();
    try {
      final uuid = Uuid7.generate();
      await prefs.setString(_localProfileUuidKey, uuid);
      await _startLocalSession(uuid);
    } catch (e) {
      _error = e.toString();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Starts (or restores) an offline session for the local profile [uuid].
  Future<void> _startLocalSession(String uuid) async {
    _user = User(
      id: uuid,
      uuid: uuid,
      email: 'local@local', // Sentinel, never sent anywhere.
      name: _localDisplayName,
      role: 'user',
      isActive: true,
      isLocal: true,
    );
    // A placeholder client: every core read path is local-cache first, but
    // screens gate on `dio == null` before doing any work, so a non-null
    // client that never issues requests keeps them functional.
    _dio ??= Dio();
    _syncService = await _buildServerlessSyncService();
    _applyActorId();

    final sync = _syncService;
    if (sync == null) {
      // Platforms without the local SQLite store (non-Android/iOS) get a
      // session without persistence; nothing to seed.
      debugPrint('AuthProvider: local mode without local database support; '
          'data will not persist');
      return;
    }
    var workspaceId = prefs.getString(_localWorkspaceUuidKey);
    if (workspaceId == null) {
      workspaceId = Uuid7.generate();
      await prefs.setString(_localWorkspaceUuidKey, workspaceId);
    }
    await sync.setWorkspaceId(workspaceId);
    await LocalWorkspaceSeed(sync).ensureLocalWorkspace(
      displayName: _localDisplayName,
    );
  }

  Future<SyncV2Service?> _buildServerlessSyncService() async {
    if (!AppDatabase.isSupported) return null;
    final clientId = await getClientId(prefs);
    return SyncV2Service(
      database: AppDatabase(),
      dio: Dio(),
      clientId: clientId,
      serverless: true,
    );
  }

  /// Propagate the authenticated user's uuid to the sync service so
  /// envelopes carry the user as actor (not the per-install device id).
  void _applyActorId() {
    _syncService?.actorId = _user?.uuid;
  }

  Future<SyncV2Service?> _buildSyncService(Dio dio) async {
    // The local SQLite queue (sqflite_sqlcipher) only has Android/iOS
    // implementations; elsewhere repositories talk to the API directly
    // when there is no sync service.
    if (!AppDatabase.isSupported) return null;
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
    _applyActorId();
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
          _applyActorId();
          await _switchToDefaultWorkspace();
          await _adoptLocalWorkspaceIfPending();
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
      _applyActorId();
      await _switchToDefaultWorkspace();
      await _adoptLocalWorkspaceIfPending();
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
      _applyActorId();
      await _switchToDefaultWorkspace();
      await _adoptLocalWorkspaceIfPending();
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
      _applyActorId();
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
    _applyActorId();
    notifyListeners();
  }

  Future<void> _switchToDefaultWorkspace() async {
    if (_dio == null) return;
    final workspaceRepo = WorkspaceRepository(dio: _dio!);
    final workspaces = await workspaceRepo.listWorkspaces();
    if (workspaces.isNotEmpty) {
      final workspaceId = workspaces.first.uuid;
      await workspaceRepo.switchWorkspace(workspaceId);
      await _syncService?.setWorkspaceId(workspaceId);
    }
  }

  /// Connect-later adoption (v1): after the first successful server login
  /// from a local profile, remap the local workspace id (and actor) of the
  /// accumulated outbox/operation state onto the server workspace, clear the
  /// local profile, then flush the outbox so local edits reach the server.
  ///
  /// This is not a full op-log replay like the web client's `adoption.ts`:
  /// the server workspace keeps its own seed (the class.create applier is an
  /// upsert on class id, so our duplicate seed ops are harmless), and only
  /// the pending outbox is pushed.
  Future<void> _adoptLocalWorkspaceIfPending() async {
    final localWorkspaceId = prefs.getString(_localWorkspaceUuidKey);
    if (localWorkspaceId == null) return;
    final sync = _syncService;
    final serverWorkspaceId = await sync?.getWorkspaceId();
    if (sync != null &&
        serverWorkspaceId != null &&
        serverWorkspaceId != localWorkspaceId) {
      await sync.remapWorkspace(
        localWorkspaceId,
        serverWorkspaceId,
        actorId: _user?.uuid,
      );
    }
    await prefs.remove(_localProfileUuidKey);
    await prefs.remove(_localWorkspaceUuidKey);
    try {
      await sync?.flush();
      await sync?.pull();
    } on Exception catch (e) {
      // Login itself succeeded; the outbox stays pending and the next
      // connectivity-driven flush retries.
      debugPrint('AuthProvider: post-adoption sync failed: $e');
    }
  }

  /// Reloads the onboarding completion flag from preferences and notifies
  /// listeners. Call this after the onboarding flow finishes so the router
  /// redirect re-evaluates.
  Future<void> refreshOnboarding() async {
    _onboardingCompleted = onboardingService.isCompleted;
    notifyListeners();
  }
}
