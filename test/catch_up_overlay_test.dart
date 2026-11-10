import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:notees/features/home/providers/sync_status_provider.dart';
import 'package:notees/shared/widgets/catch_up_overlay.dart';
import 'package:provider/provider.dart';

Widget _wrap(SyncStatusProvider status, Widget child) {
  return MediaQuery(
    data: const MediaQueryData(),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Theme(
        data: ThemeData(),
        child: ChangeNotifierProvider<SyncStatusProvider>.value(
          value: status,
          child: child,
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

  testWidgets('the overlay blocks interaction with the app shell',
      (WidgetTester tester) async {
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
}
