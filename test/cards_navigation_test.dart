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
import 'package:notees/features/cards/screens/cards_screen.dart';
import 'package:notees/features/cards/screens/review_session_screen.dart';
import 'package:notees/features/home/screens/main_shell_screen.dart';
import 'package:notees/features/settings/providers/settings_provider.dart';
import 'package:notees/features/tasks/screens/tasks_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The memorization-cards navigation tests: the third shell destination
/// and the /cards + /cards/review deep-link routes with the state.extra
/// session hand-off.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  FakeAuth fakeAuth() => FakeAuth(
        serverRepository: ServerRepository(prefs: prefs),
        secureStorage: const SecureStorage(),
        prefs: prefs,
      );

  Widget appWithShell({int initialIndex = 2}) {
    final auth = fakeAuth();
    return ChangeNotifierProvider<AuthProvider>.value(
      value: auth,
      child: ChangeNotifierProvider<SettingsProvider>(
        create: (_) => SettingsProvider(prefs),
        child: MaterialApp(home: MainShellScreen(initialIndex: initialIndex)),
      ),
    );
  }

  group('main shell navigation', () {
    testWidgets('Cards is the third destination; tapping switches tabs',
        (tester) async {
      await tester.pumpWidget(appWithShell(initialIndex: 2));
      await tester.pump();

      // Five destinations + the Search action, in order.
      final labels = tester
          .widgetList<Text>(find.byWidgetPredicate(
              (widget) => widget is Text && widget.data != null))
          .map((text) => text.data!)
          .toList();
      final navLabels = [
        'Home',
        'Tasks',
        'Cards',
        'Journal',
        'Library',
        'Search',
      ].where(labels.contains).toList();
      expect(navLabels, ['Home', 'Tasks', 'Cards', 'Journal', 'Library', 'Search']);

      // The Cards tab is active (the hub placeholder builds).
      expect(find.byType(CardsScreen), findsOneWidget);
      expect(find.text('Cards'), findsWidgets);

      // Switch to Tasks and back.
      await tester.tap(find.text('Tasks'));
      await tester.pump();
      expect(find.byType(TasksScreen), findsOneWidget);

      await tester.tap(find.text('Cards'));
      await tester.pump();
      expect(find.byType(CardsScreen), findsOneWidget);
    });

    testWidgets('the rail path renders the same five destinations',
        (tester) async {
      // Default test surface (800x600 logical) drives the NavigationRail branch.
      await tester.pumpWidget(appWithShell(initialIndex: 2));
      await tester.pump();

      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.destinations.length, 6); // five + Search
      expect(find.byType(NavigationBar), findsNothing);
    });

    testWidgets('the bar path renders the same five destinations',
        (tester) async {
      // A narrow surface (400x600 logical) drives the NavigationBar branch.
      tester.view.physicalSize = const Size(1200.0, 1800.0);
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(appWithShell(initialIndex: 2));
      await tester.pump();

      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.destinations.length, 6); // five + Search
      expect(find.byType(NavigationRail), findsNothing);
    });
  });

  group('deep-link routes', () {
    Future<GoRouter> pumpRouter(
      WidgetTester tester, {
      required FakeAuth auth,
      required String location,
    }) async {
      final router = createRouter(authProvider: auth);
      await tester.pumpWidget(
        ChangeNotifierProvider<AuthProvider>.value(
          value: auth,
          child: ChangeNotifierProvider<SettingsProvider>(
            create: (_) => SettingsProvider(prefs),
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      router.go(location);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      return router;
    }

    testWidgets('/cards lands on the shell with the Cards tab active',
        (tester) async {
      final auth = fakeAuth();
      await pumpRouter(tester, auth: auth, location: Routes.cards);

      expect(find.byType(CardsScreen), findsOneWidget);
    });

    testWidgets('/cards/review without a hand-off falls back (member resolve fails loud-safe)',
        (tester) async {
      final auth = fakeAuth();
      await pumpRouter(tester, auth: auth, location: Routes.cardsReview);

      // No usable cache in the test: the fallback resolve lands on the
      // honest error state rather than crashing the route.
      expect(find.byType(ReviewSessionScreen), findsOneWidget);
      expect(find.text('Could not start the review session'), findsOneWidget);
    });

    testWidgets('a pushed /cards/review with a hand-off extra skips the fallback',
        (tester) async {
      final auth = fakeAuth();
      final router = await pumpRouter(tester, auth: auth, location: Routes.cards);
      expect(find.byType(CardsScreen), findsOneWidget);

      router.push(Routes.cardsReview, extra: <String, dynamic>{
        'cardIds': <String>['card-a', 'card-b'],
        'label': 'All cards',
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(ReviewSessionScreen), findsOneWidget);
      expect(find.text('2 cards'), findsOneWidget);
    });

    testWidgets('a corrupt hand-off extra falls back like a deep link',
        (tester) async {
      final auth = fakeAuth();
      final router = await pumpRouter(tester, auth: auth, location: Routes.cards);

      router.push(Routes.cardsReview, extra: 'not-a-handoff');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(ReviewSessionScreen), findsOneWidget);
      expect(find.text('Could not start the review session'), findsOneWidget);
    });
  });

  group('CardsSessionHandOff.fromExtra', () {
    test('parses the hand-off map', () {
      final handOff = CardsSessionHandOff.fromExtra(<String, dynamic>{
        'cardIds': <String>['a', 'b'],
        'label': 'All cards',
      });
      expect(handOff?.cardIds, ['a', 'b']);
      expect(handOff?.label, 'All cards');
    });

    test('rejects a missing/corrupt extra', () {
      expect(CardsSessionHandOff.fromExtra(null), isNull);
      expect(CardsSessionHandOff.fromExtra('garbage'), isNull);
      expect(CardsSessionHandOff.fromExtra(<String, dynamic>{}), isNull);
      expect(
        CardsSessionHandOff.fromExtra(<String, dynamic>{'cardIds': <String>[], 'label': 'x'}),
        isNull,
      );
      expect(
        CardsSessionHandOff.fromExtra(<String, dynamic>{'cardIds': <String>['a']}),
        isNull,
      );
      expect(
        CardsSessionHandOff.fromExtra(<String, dynamic>{
          'cardIds': 'not-a-list',
          'label': 'x',
        }),
        isNull,
      );
    });
  });
}

/// A scripted [AuthProvider] for widget tests: authenticated against a
/// fake server whose Dio rejects every request (screens must land on their
/// honest error/empty states).
class FakeAuth extends AuthProvider {
  FakeAuth({required super.serverRepository, required super.secureStorage, required super.prefs})
      : fakeDio = rejectingDio();

  final Dio fakeDio;

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
