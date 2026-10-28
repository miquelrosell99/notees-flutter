import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:notees/core/routing/router.dart';
import 'package:notees/core/secure/secure_storage.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/models/node.dart';
import 'package:notees/data/models/server_profile.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/data/repositories/server_repository.dart';
import 'package:notees/data/repositories/workspace_repository.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:notees/features/auth/providers/auth_provider.dart';
import 'package:notees/features/home/screens/main_shell_screen.dart';
import 'package:notees/features/settings/providers/settings_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The command-palette navigation contract: picking a node from the global
/// palette (Ctrl/Cmd+K) pushes the editor route with the node's wire uuid —
/// not the local int row id (`Node.id`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pageUuid = '30000000-0000-4000-8000-0000000000f1';

  // The wire uuid and the local row id must disagree, or the regression
  // (pushing the row id) could pass by accident.
  const localRowId = 42;
  final paletteNode = Node(
    id: localRowId,
    uuid: pageUuid,
    name: 'Palette Page',
    displayName: 'Palette Page',
  );

  late SharedPreferences prefs;
  late FakePaletteSyncService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    service = FakePaletteSyncService(recentPages: [paletteNode]);
  });

  tearDown(() async {
    AppDatabase.reset();
  });

  testWidgets('picking a node from the palette pushes the editor with the '
      'wire uuid (not the local row id)', (tester) async {
    final auth = FakeAuth(
      serverRepository: ServerRepository(prefs: prefs),
      secureStorage: const SecureStorage(),
      prefs: prefs,
      syncService: service,
    );

    final pushedUuids = <String>[];
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const MainShellScreen(initialIndex: 4),
        ),
        GoRoute(
          path: '${Routes.editor}/:nodeUuid',
          builder: (context, state) {
            pushedUuids.add(state.pathParameters['nodeUuid']!);
            return const Scaffold(body: Text('editor stub'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child: ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(prefs),
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );
    await tester.pump();

    // Ctrl+K opens the palette; the scripted cache serves the recent page.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The static entries fill the viewport, so filter to the recent page by
    // typing its title into the palette field; picking the entry pops the
    // sheet and the shell pushes the editor route.
    await tester.enterText(find.byType(TextField), 'Palette');
    await tester.pump();
    expect(find.text('Palette Page'), findsOneWidget);
    await tester.tap(find.text('Palette Page'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(pushedUuids, hasLength(1));
    expect(
      pushedUuids.single,
      matches(RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      )),
    );
    expect(pushedUuids.single, pageUuid);
    expect(pushedUuids.single, isNot('$localRowId'));
    // The push navigated: shell + editor matches. (currentConfiguration.uri
    // reports the base path in this go_router version, so the match list is
    // the reliable signal.)
    expect(router.routerDelegate.currentConfiguration.matches.length, 2);
  });
}

/// An in-memory [NodeCacheRepository] stand-in: serves the scripted recent
/// pages (the only surface the palette reads) without a database.
class FakePaletteCache extends NodeCacheRepository {
  FakePaletteCache(this.recentPages) : super(AppDatabase.inMemory());

  final List<Node> recentPages;

  @override
  Future<List<Node>> getRecentPages({int limit = 10}) async => recentPages;

  @override
  Future<List<Node>> getFavorites(
    String workspaceId, {
    int limit = 50,
    String? actorId,
  }) async =>
      const [];
}

/// A [SyncV2Service] whose [cache] is the fake — the production seam the
/// shell's palette path self-provisions from.
class FakePaletteSyncService extends SyncV2Service {
  FakePaletteSyncService({required List<Node> recentPages})
      : fakeCache = FakePaletteCache(recentPages),
        super(
          database: AppDatabase.inMemory(),
          dio: Dio(BaseOptions(baseUrl: 'https://notees.example.com/api')),
          clientId: '40000000-0000-4000-8000-000000000001',
        );

  final FakePaletteCache fakeCache;

  @override
  NodeCacheRepository get cache => fakeCache;

  @override
  Future<String?> getWorkspaceId() async => '10000000-0000-4000-8000-000000000001';
}

/// A scripted [AuthProvider] for widget tests: authenticated against a fake
/// server whose Dio rejects every request (the palette path only reads the
/// local cache). The sync service getter is overridden with the fake layer
/// because the base field is private.
class FakeAuth extends AuthProvider {
  FakeAuth({
    required super.serverRepository,
    required super.secureStorage,
    required super.prefs,
    required SyncV2Service syncService,
  })  : fakeSyncService = syncService,
        fakeDio = rejectingDio();

  final SyncV2Service fakeSyncService;
  final Dio fakeDio;

  @override
  SyncV2Service? get syncService => fakeSyncService;

  @override
  bool get loading => false;

  @override
  bool get isAuthenticated => true;

  @override
  bool get isLocalMode => false;

  @override
  ServerProfile? get activeServer =>
      ServerProfile(id: 'server-1', url: 'https://notees.example.com', nickname: 'Test');

  @override
  Dio? get dio => fakeDio;

  @override
  bool get onboardingCompleted => true;

  @override
  String? get activeWorkspaceId => 'ws-owner';

  @override
  List<Workspace>? get workspaces => [Workspace(uuid: 'ws-owner', name: 'Personal', role: 'owner')];

  @override
  bool get hasValidWorkspace => true;
}

Dio rejectingDio() {
  final dio = Dio(BaseOptions(baseUrl: 'https://notees.example.com/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.reject(
        DioException(requestOptions: options, error: 'unscripted ${options.path}'),
      ),
    ),
  );
  return dio;
}
