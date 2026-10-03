import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/secure/secure_storage.dart';
import 'package:notees/data/models/server_profile.dart';
import 'package:notees/data/models/user.dart';
import 'package:notees/data/repositories/server_repository.dart';
import 'package:notees/data/repositories/workspace_repository.dart';
import 'package:notees/features/auth/providers/auth_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Startup workspace resolution: the router guard reads [AuthProvider
/// .hasValidWorkspace], which is decided here — a remembered workspace is
/// adopted only while the server still lists it, otherwise the session lands
/// on the management view.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Force the no-local-database target so the sync service stays null and the
  // resolution state machine can be tested without sqflite fakes
  // (AppDatabase.isSupported is android/iOS only).
  setUpAll(() => debugDefaultTargetPlatformOverride = TargetPlatform.linux);
  tearDownAll(() => debugDefaultTargetPlatformOverride = null);

  // initialize() opens the shared cookie jar via path_provider, which has no
  // implementation on the test host.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => '/tmp',
  );

  final sessionUser = User(
    id: 'user-1',
    uuid: 'user-1',
    email: 'owner@example.com',
    role: 'user',
    isActive: true,
  );

  Workspace workspace(String id, {String? name, String? role}) =>
      Workspace(uuid: id, name: name, role: role);

  late SharedPreferences prefs;
  late ServerRepository serverRepository;
  late ServerProfile server;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    serverRepository = ServerRepository(prefs: prefs);
    server = await serverRepository.addServer(
      url: 'https://notees.example.com',
      nickname: 'Test',
    );
  });

  String workspaceKeyFor(ServerProfile server) =>
      'active_workspace_${server.id}_user-1';

  /// Each entry of [workspaceReplies] is either the list to return or an
  /// Exception to throw, consumed in order across fetches.
  Future<_SeamedAuthProvider> buildAuth({
    bool withSession = true,
    List<Object> workspaceReplies = const [],
  }) async {
    return _SeamedAuthProvider(
      serverRepository: serverRepository,
      secureStorage: const SecureStorage(),
      prefs: prefs,
      session: withSession ? sessionUser : null,
      workspaceReplies: workspaceReplies,
    );
  }

  test('adopts the remembered workspace while the server still lists it',
      () async {
    final auth = await buildAuth(workspaceReplies: [
      [workspace('ws-1', name: 'Personal', role: 'owner')],
    ]);
    await prefs.setString(workspaceKeyFor(server), 'ws-1');

    await auth.initialize();

    expect(auth.isAuthenticated, isTrue);
    expect(auth.hasValidWorkspace, isTrue);
    expect(auth.activeWorkspaceId, 'ws-1');
    expect(auth.workspaces, hasLength(1));
    // The selection persists for the next boot.
    expect(prefs.getString(workspaceKeyFor(server)), 'ws-1');
  });

  test('no remembered workspace lands on the management view', () async {
    final auth = await buildAuth(workspaceReplies: [
      [workspace('ws-1', name: 'Personal', role: 'owner')],
    ]);

    await auth.initialize();

    expect(auth.workspaces, hasLength(1));
    expect(auth.activeWorkspaceId, isNull);
    expect(auth.hasValidWorkspace, isFalse);
  });

  test('a remembered workspace that left the account list is dropped',
      () async {
    final auth = await buildAuth(workspaceReplies: [
      [workspace('ws-1', name: 'Personal', role: 'owner')],
    ]);
    await prefs.setString(workspaceKeyFor(server), 'ws-stale');

    await auth.initialize();

    expect(auth.activeWorkspaceId, isNull);
    expect(auth.hasValidWorkspace, isFalse);
    expect(prefs.getString(workspaceKeyFor(server)), isNull);
  });

  test('an unreachable relay keeps the remembered selection (offline boot)',
      () async {
    final auth = await buildAuth(workspaceReplies: [
      Exception('socket error'),
    ]);
    await prefs.setString(workspaceKeyFor(server), 'ws-1');

    await auth.initialize();

    expect(auth.activeWorkspaceId, 'ws-1');
    expect(auth.hasValidWorkspace, isTrue);
  });

  test('unreachable relay without a remembered selection stays invalid',
      () async {
    final auth = await buildAuth(workspaceReplies: [
      Exception('socket error'),
    ]);

    await auth.initialize();

    expect(auth.hasValidWorkspace, isFalse);
  });

  test('no session means no workspace resolution', () async {
    final auth = await buildAuth(withSession: false);

    await auth.initialize();

    expect(auth.isAuthenticated, isFalse);
    expect(auth.hasValidWorkspace, isFalse);
    expect(auth.workspaceFetches, 0);
  });

  test('refreshWorkspaces drops the active workspace when it vanishes',
      () async {
    final auth = await buildAuth(workspaceReplies: [
      [
        workspace('ws-1', name: 'Personal', role: 'owner'),
        workspace('ws-2', name: 'Team', role: 'member'),
      ],
      [workspace('ws-2', name: 'Team', role: 'member')],
    ]);
    await prefs.setString(workspaceKeyFor(server), 'ws-1');
    await auth.initialize();
    expect(auth.hasValidWorkspace, isTrue);

    // Deleted (or membership revoked) server-side between boots.
    await auth.refreshWorkspaces();

    expect(auth.activeWorkspaceId, isNull);
    expect(auth.hasValidWorkspace, isFalse);
    expect(prefs.getString(workspaceKeyFor(server)), isNull);
    expect(auth.workspaces!.single.uuid, 'ws-2');
  });

  test('a failed refresh keeps the last list and reports the error', () async {
    final auth = await buildAuth(workspaceReplies: [
      [workspace('ws-1', name: 'Personal', role: 'owner')],
      Exception('boom'),
    ]);
    await prefs.setString(workspaceKeyFor(server), 'ws-1');
    await auth.initialize();

    await auth.refreshWorkspaces();

    expect(auth.workspaceListError, contains('boom'));
    expect(auth.workspaces, hasLength(1));
    expect(auth.hasValidWorkspace, isTrue);
  });

  test('switchWorkspace persists the selection per server+account', () async {
    final auth = await buildAuth(workspaceReplies: [
      [
        workspace('ws-1', name: 'Personal', role: 'owner'),
        workspace('ws-2', name: 'Team', role: 'member'),
      ],
    ]);
    await auth.initialize();
    expect(auth.hasValidWorkspace, isFalse);

    await auth.switchWorkspace('ws-2');

    expect(auth.activeWorkspaceId, 'ws-2');
    expect(prefs.getString(workspaceKeyFor(server)), 'ws-2');
    expect(auth.hasValidWorkspace, isTrue);
  });
}

class _SeamedAuthProvider extends AuthProvider {
  _SeamedAuthProvider({
    required super.serverRepository,
    required super.secureStorage,
    required super.prefs,
    required this.session,
    required List<Object> workspaceReplies,
  }) : _workspaceReplies = List<Object>.of(workspaceReplies);

  final User? session;
  final List<Object> _workspaceReplies;
  int workspaceFetches = 0;

  @override
  Future<User?> fetchSession() async => session;

  @override
  Future<List<Workspace>> fetchWorkspaces() async {
    workspaceFetches += 1;
    final next =
        _workspaceReplies.isEmpty ? const <Workspace>[] : _workspaceReplies.removeAt(0);
    if (next is Exception) throw next;
    return next as List<Workspace>;
  }
}
