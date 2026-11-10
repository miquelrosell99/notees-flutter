import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:notees/core/secure/secure_storage.dart';
import 'package:notees/data/repositories/server_repository.dart';
import 'package:notees/features/auth/providers/auth_provider.dart';
import 'package:notees/features/home/providers/sync_status_provider.dart';
import 'package:notees/shared/widgets/catch_up_overlay.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAuthProvider extends AuthProvider {
  _FakeAuthProvider({
    required super.serverRepository,
    required super.secureStorage,
    required super.prefs,
  });

  var retryCount = 0;

  @override
  void retryWorkspacePull() => retryCount++;
}

Future<_FakeAuthProvider> _buildFakeAuth() async {
  SharedPreferences.setMockInitialValues(const {});
  final prefs = await SharedPreferences.getInstance();
  return _FakeAuthProvider(
    serverRepository: ServerRepository(prefs: prefs),
    secureStorage: const SecureStorage(),
    prefs: prefs,
  );
}

Widget _wrap(
  SyncStatusProvider status,
  Widget child, {
  AuthProvider? auth,
}) {
  return MediaQuery(
    data: const MediaQueryData(),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Theme(
        data: ThemeData(),
        child: ChangeNotifierProvider<SyncStatusProvider>.value(
          value: status,
          child: auth == null
              ? child
              : ChangeNotifierProvider<AuthProvider>.value(
                  value: auth,
                  child: child,
                ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('hidden: the child shows and no overlay renders',
      (WidgetTester tester) async {
    final status = SyncStatusProvider();
    addTearDown(status.dispose);

    await tester.pumpWidget(_wrap(
      status,
      const CatchUpOverlay(child: Text('app shell')),
    ));

    expect(find.text('app shell'), findsOneWidget);
    expect(find.text('Notees'), findsNothing);
    expect(find.textContaining('Catching up'), findsNothing);
  });

  testWidgets('shown without a fraction: plain label + indeterminate '
      'spinner', (WidgetTester tester) async {
    final status = SyncStatusProvider();
    addTearDown(status.dispose);
    status.beginCatchUp();

    await tester.pumpWidget(_wrap(
      status,
      const CatchUpOverlay(child: Text('app shell')),
    ));

    expect(find.text('app shell'), findsOneWidget); // beneath the overlay
    expect(find.text('Catching up…'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CircularProgressIndicator && widget.value == null,
      ),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('shown with a fraction: floored percent + determinate bar',
      (WidgetTester tester) async {
    final status = SyncStatusProvider();
    addTearDown(status.dispose);
    status.beginCatchUp();
    status.updateProgress(40, 100);

    await tester.pumpWidget(_wrap(
      status,
      const CatchUpOverlay(child: SizedBox.expand()),
    ));

    expect(find.text('Catching up… 40%'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, 0.4);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('the overlay blocks interaction with the app shell while '
      'catching up', (WidgetTester tester) async {
    final status = SyncStatusProvider();
    addTearDown(status.dispose);
    status.beginCatchUp();
    var taps = 0;

    await tester.pumpWidget(_wrap(
      status,
      CatchUpOverlay(
        child: Center(
          child: ElevatedButton(
            onPressed: () => taps++,
            child: const Text('tap me'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('tap me'), warnIfMissed: false);
    await tester.pump();
    expect(taps, 0);
  });

  testWidgets('ending the catch-up removes the overlay and restores the '
      'shell', (WidgetTester tester) async {
    final status = SyncStatusProvider();
    addTearDown(status.dispose);
    status.beginCatchUp();

    await tester.pumpWidget(_wrap(
      status,
      const CatchUpOverlay(child: Text('app shell')),
    ));
    expect(find.text('Catching up…'), findsOneWidget);

    status.endCatchUp();
    await tester.pump();

    expect(find.text('Catching up…'), findsNothing);
    expect(find.text('app shell'), findsOneWidget);
  });

  group('error mode', () {
    testWidgets('a failed pull shows the error with Retry and Dismiss',
        (WidgetTester tester) async {
      final status = SyncStatusProvider();
      addTearDown(status.dispose);
      status.beginCatchUp();
      status.failCatchUp('connection refused');
      final auth = await _buildFakeAuth();
      addTearDown(auth.dispose);

      await tester.pumpWidget(_wrap(
        status,
        const CatchUpOverlay(child: Text('app shell')),
        auth: auth,
      ));

      expect(find.text('Sync failed'), findsOneWidget);
      expect(find.text('connection refused'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Dismiss'), findsOneWidget);
      // No progress UI in error mode.
      expect(find.textContaining('Catching up'), findsNothing);
    });

    testWidgets('Retry re-runs the workspace pull', (WidgetTester tester) async {
      final status = SyncStatusProvider();
      addTearDown(status.dispose);
      status.beginCatchUp();
      status.failCatchUp('connection refused');
      final auth = await _buildFakeAuth();
      addTearDown(auth.dispose);
      expect(auth.retryCount, 0);

      await tester.pumpWidget(_wrap(
        status,
        const CatchUpOverlay(child: Text('app shell')),
        auth: auth,
      ));

      await tester.tap(find.widgetWithText(OutlinedButton, 'Retry'));
      await tester.pump();
      expect(auth.retryCount, 1);
    });

    testWidgets('Dismiss hides the overlay and clears the error',
        (WidgetTester tester) async {
      final status = SyncStatusProvider();
      addTearDown(status.dispose);
      status.beginCatchUp();
      status.failCatchUp('connection refused');
      final auth = await _buildFakeAuth();
      addTearDown(auth.dispose);

      await tester.pumpWidget(_wrap(
        status,
        const CatchUpOverlay(child: Text('app shell')),
        auth: auth,
      ));

      await tester.tap(find.widgetWithText(TextButton, 'Dismiss'));
      await tester.pump();

      expect(status.showCatchUpOverlay, isFalse);
      expect(status.isPullFailed, isFalse);
      expect(find.text('Sync failed'), findsNothing);
      expect(find.text('app shell'), findsOneWidget);
    });
  });
}
