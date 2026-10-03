import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:notees/core/routing/router.dart';
import 'package:notees/core/secure/secure_storage.dart';
import 'package:notees/data/models/server_profile.dart';
import 'package:notees/data/repositories/server_repository.dart';
import 'package:notees/data/repositories/workspace_repository.dart';
import 'package:notees/features/auth/providers/auth_provider.dart';
import 'package:notees/features/auth/screens/workspace_management_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The fullscreen workspace management view: honest loading / error / empty
/// states, rows with roles + an active mark, tap-to-switch (→ main shell),
/// create (→ enters the new workspace), and owner-only rename.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shellMarker = 'SHELL-REACHED';

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  /// A scripted Dio for the create/rename endpoints the screen drives through
  /// [AuthProvider.dio]. [onRename] mirrors the server applying the PATCH so
  /// the view's refresh shows the new name.
  Dio fakeApi({void Function(String name)? onRename}) {
    final dio = Dio(BaseOptions(baseUrl: 'https://notees.example.com/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'POST' && options.path == '/workspaces') {
            final body = options.data as Map<String, dynamic>?;
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 201,
              data: {
                'id': 'ws-new',
                'name': body?['name'],
                'role': 'owner',
              },
            ));
            return;
          }
          if (options.method == 'PATCH' &&
              options.path == '/workspaces/ws-owner') {
            final body = options.data as Map<String, dynamic>?;
            onRename?.call(body?['name'] as String? ?? '');
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: {'id': 'ws-owner', 'name': body?['name']},
            ));
            return;
          }
          handler.reject(DioException(
            requestOptions: options,
            error: 'unscripted ${options.path}',
          ));
        },
      ),
    );
    return dio;
  }

  GoRouter routerFor(_ScreenAuthProvider auth) => GoRouter(
        initialLocation: Routes.workspaces,
        routes: [
          GoRoute(
            path: Routes.workspaces,
            builder: (context, state) => const WorkspaceManagementScreen(),
          ),
          GoRoute(
            path: Routes.dashboard,
            builder: (context, state) =>
                const Scaffold(body: Text(shellMarker)),
          ),
        ],
      );

  Future<_ScreenAuthProvider> pumpScreen(
    WidgetTester tester, {
    List<Workspace>? workspaces,
    String? error,
    String? activeId,
    bool valid = false,
  }) async {
    late _ScreenAuthProvider auth;
    auth = _ScreenAuthProvider(
      serverRepository: ServerRepository(prefs: prefs),
      secureStorage: const SecureStorage(),
      prefs: prefs,
    )
      ..fakeWorkspaces = workspaces
      ..fakeError = error
      ..fakeActiveId = activeId
      ..valid = valid
      ..fakeDio = fakeApi(
        onRename: (name) {
          auth.fakeWorkspaces = [
            Workspace(uuid: 'ws-owner', name: name, role: 'owner'),
            Workspace(uuid: 'ws-member', name: 'Team', role: 'member'),
          ];
          auth.notifyListeners();
        },
      );
    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child: MaterialApp.router(routerConfig: routerFor(auth)),
      ),
    );
    await tester.pump();
    return auth;
  }

  Workspace ownerWs() => Workspace(uuid: 'ws-owner', name: 'Personal', role: 'owner');
  Workspace memberWs() => Workspace(uuid: 'ws-member', name: 'Team', role: 'member');

  testWidgets('shows a loading spinner before the first fetch lands',
      (tester) async {
    await pumpScreen(tester, workspaces: null);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Personal'), findsNothing);
  });

  testWidgets('lists workspaces with roles and marks the active one',
      (tester) async {
    final auth = await pumpScreen(
      tester,
      workspaces: [ownerWs(), memberWs()],
      activeId: 'ws-owner',
      valid: true,
    );

    expect(auth.refreshCount, 1); // fetched on entry
    expect(find.text('Personal'), findsOneWidget);
    expect(find.text('Team'), findsOneWidget);
    expect(find.text('Owner · Active'), findsOneWidget);
    expect(find.text('Member'), findsOneWidget);
    // Escape hatch only exists with a valid workspace.
    expect(find.byTooltip('Close'), findsOneWidget);
  });

  testWidgets('has no close button at startup without a valid workspace',
      (tester) async {
    await pumpScreen(
      tester,
      workspaces: [ownerWs()],
      valid: false,
    );

    expect(find.byTooltip('Close'), findsNothing);
  });

  testWidgets('error state offers an honest retry', (tester) async {
    final auth = await pumpScreen(tester, workspaces: null, error: 'boom');

    expect(find.text('Could not load workspaces'), findsOneWidget);
    expect(find.text('boom'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(auth.refreshCount, 2);
  });

  testWidgets('empty state invites creating the first workspace',
      (tester) async {
    await pumpScreen(tester, workspaces: []);

    expect(find.text('Create your first workspace'), findsOneWidget);
    expect(find.text('New workspace'), findsOneWidget);
  });

  testWidgets('tapping a workspace switches to it and enters the shell',
      (tester) async {
    final auth = await pumpScreen(
      tester,
      workspaces: [ownerWs(), memberWs()],
      activeId: 'ws-owner',
      valid: true,
    );

    await tester.tap(find.text('Team'));
    await tester.pumpAndSettle();

    expect(auth.switched, ['ws-member']);
    expect(find.text(shellMarker), findsOneWidget);
  });

  testWidgets('tapping the active workspace closes without switching',
      (tester) async {
    final auth = await pumpScreen(
      tester,
      workspaces: [ownerWs()],
      activeId: 'ws-owner',
      valid: true,
    );

    await tester.tap(find.text('Personal'));
    await tester.pumpAndSettle();

    expect(auth.switched, isEmpty);
    expect(find.text(shellMarker), findsOneWidget);
  });

  testWidgets('creating a workspace enters it (web parity)', (tester) async {
    final auth = await pumpScreen(tester, workspaces: []);

    await tester.tap(find.text('New workspace'));
    await tester.pumpAndSettle();
    expect(find.text('New workspace'), findsNWidgets(2)); // row + sheet title

    await tester.enterText(find.byType(TextField), 'Research');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(auth.switched, ['ws-new']);
    expect(find.text(shellMarker), findsOneWidget);
  });

  testWidgets('rename is owner-only and refreshes the list', (tester) async {
    final auth = await pumpScreen(
      tester,
      workspaces: [ownerWs(), memberWs()],
      activeId: 'ws-owner',
      valid: true,
    );

    // Non-owner rows have no rename affordance; owner rows do.
    expect(find.byTooltip('Rename Team'), findsNothing);
    expect(find.byTooltip('Rename Personal'), findsOneWidget);

    await tester.tap(find.byTooltip('Rename Personal'));
    await tester.pumpAndSettle();
    expect(find.text('Rename workspace'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Vault');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    expect(auth.refreshCount, 2);
    expect(find.text('Personal'), findsNothing);
    expect(find.text('Vault'), findsOneWidget);
  });
}

class _ScreenAuthProvider extends AuthProvider {
  _ScreenAuthProvider({
    required super.serverRepository,
    required super.secureStorage,
    required super.prefs,
  });

  List<Workspace>? fakeWorkspaces;
  String? fakeError;
  String? fakeActiveId;
  bool valid = false;
  Dio? fakeDio;
  int refreshCount = 0;
  List<String> switched = [];

  @override
  bool get loading => false;

  @override
  bool get isAuthenticated => true;

  @override
  bool get isLocalMode => false;

  @override
  ServerProfile? get activeServer => ServerProfile(
      id: 'server-1',
      url: 'https://notees.example.com',
      nickname: 'Test');

  @override
  Dio? get dio => fakeDio;

  @override
  bool get onboardingCompleted => true;

  @override
  String? get activeWorkspaceId => fakeActiveId;

  @override
  List<Workspace>? get workspaces => fakeWorkspaces;

  @override
  String? get workspaceListError => fakeError;

  @override
  bool get hasValidWorkspace => valid;

  @override
  Future<void> refreshWorkspaces() async {
    refreshCount += 1;
  }

  @override
  Future<void> switchWorkspace(String workspaceId) async {
    fakeActiveId = workspaceId;
    switched.add(workspaceId);
    notifyListeners();
  }
}
