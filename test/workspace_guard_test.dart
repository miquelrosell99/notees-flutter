import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:notees/core/routing/router.dart';
import 'package:notees/core/secure/secure_storage.dart';
import 'package:notees/data/models/server_profile.dart';
import 'package:notees/data/repositories/server_repository.dart';
import 'package:notees/data/repositories/workspace_repository.dart';
import 'package:notees/features/auth/providers/auth_provider.dart';
import 'package:notees/features/auth/screens/login_screen.dart';
import 'package:notees/features/auth/screens/server_setup_screen.dart';
import 'package:notees/features/auth/screens/workspace_management_screen.dart';
import 'package:notees/features/home/screens/main_shell_screen.dart';
import 'package:notees/features/settings/providers/settings_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The startup routing guard: unauthenticated sessions follow the existing
/// auth flow; authenticated server sessions without a valid active workspace
/// land on the fullscreen workspace management view instead of the main
/// shell; valid sessions reach the shell (and may visit the manager).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  (_GuardAuthProvider, GoRouter) buildHarness() {
    final auth = _GuardAuthProvider(
      serverRepository: ServerRepository(prefs: prefs),
      secureStorage: const SecureStorage(),
      prefs: prefs,
    );
    final router = createRouter(authProvider: auth);
    return (auth, router);
  }

  Future<void> pumpHarness(
    WidgetTester tester,
    _GuardAuthProvider auth,
    GoRouter router,
  ) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider(create: (_) => SettingsProvider(prefs)),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    // Fixed pumps, not pumpAndSettle: the shell's loading skeletons shimmer
    // forever when there is no sync service, and settling never completes.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('no server configured lands on server setup', (tester) async {
    final (auth, router) = buildHarness();
    auth.serverConfigured = false;

    await pumpHarness(tester, auth, router);

    expect(find.byType(ServerSetupScreen), findsOneWidget);
  });

  testWidgets('server without a session lands on login', (tester) async {
    final (auth, router) = buildHarness();
    auth.serverConfigured = true;
    auth.signedIn = false;

    await pumpHarness(tester, auth, router);

    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('authenticated without a valid workspace lands on the manager',
      (tester) async {
    final (auth, router) = buildHarness();
    auth.serverConfigured = true;
    auth.signedIn = true;
    auth.workspaceValid = false;

    await pumpHarness(tester, auth, router);

    expect(find.byType(WorkspaceManagementScreen), findsOneWidget);
    expect(find.byType(MainShellScreen), findsNothing);
    // No escape hatch into the shell without a workspace.
    expect(find.byTooltip('Close'), findsNothing);
  });

  testWidgets('the shell is unreachable while no workspace is valid',
      (tester) async {
    final (auth, router) = buildHarness();
    auth.serverConfigured = true;
    auth.signedIn = true;
    auth.workspaceValid = false;

    await pumpHarness(tester, auth, router);
    router.go(Routes.dashboard);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(WorkspaceManagementScreen), findsOneWidget);
  });

  testWidgets('a valid workspace reaches the main shell', (tester) async {
    final (auth, router) = buildHarness();
    auth.serverConfigured = true;
    auth.signedIn = true;
    auth.workspaceValid = true;

    await pumpHarness(tester, auth, router);

    expect(find.byType(MainShellScreen), findsOneWidget);
  });

  testWidgets('the manager stays reachable with a valid workspace',
      (tester) async {
    final (auth, router) = buildHarness();
    auth.serverConfigured = true;
    auth.signedIn = true;
    auth.workspaceValid = true;

    await pumpHarness(tester, auth, router);
    router.go(Routes.workspaces);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(WorkspaceManagementScreen), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
  });
}

class _GuardAuthProvider extends AuthProvider {
  _GuardAuthProvider({
    required super.serverRepository,
    required super.secureStorage,
    required super.prefs,
  });

  bool serverConfigured = false;
  bool signedIn = false;
  bool workspaceValid = false;

  @override
  bool get loading => false;

  @override
  ServerProfile? get activeServer => serverConfigured
      ? ServerProfile(
          id: 'server-1',
          url: 'https://notees.example.com',
          nickname: 'Test',
        )
      : null;

  @override
  bool get isAuthenticated => signedIn;

  @override
  bool get isLocalMode => false;

  @override
  bool get onboardingCompleted => true;

  @override
  bool get hasValidWorkspace => workspaceValid;

  @override
  List<Workspace>? get workspaces => const [];

  @override
  Future<void> refreshWorkspaces() async {}
}
