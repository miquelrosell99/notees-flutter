import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/shared/widgets/motion.dart';
import 'package:notees/shared/widgets/skeletons.dart';

void main() {
  // The MaterialApp route transition contributes its own ScaleTransition /
  // FadeTransition widgets; always scope finders to the widget under test.
  Finder insidePressScale(Type type) => find.descendant(
        of: find.byType(PressScale),
        matching: find.byType(type),
      );

  Finder insideShimmerBox(Type type) => find.descendant(
        of: find.byType(ShimmerBox),
        matching: find.byType(type),
      );

  testWidgets('PressScale scales down while pressed and back on release',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: PressScale(child: SizedBox(width: 100, height: 100)),
          ),
        ),
      ),
    );
    // Let the route entrance finish so the page is no longer IgnorePointer'd.
    await tester.pumpAndSettle();

    final scaleFinder = insidePressScale(ScaleTransition);
    expect(scaleFinder, findsOneWidget);
    expect(tester.widget<ScaleTransition>(scaleFinder).scale.value, 1.0);

    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(PressScale)));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.widget<ScaleTransition>(scaleFinder).scale.value,
        lessThan(1.0));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.widget<ScaleTransition>(scaleFinder).scale.value, 1.0);
  });

  testWidgets('PressScale forwards taps when onTap is provided',
      (WidgetTester tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PressScale(
              onTap: () => taps++,
              child: const SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PressScale));
    expect(taps, 1);
    await tester.pumpAndSettle();
  });

  testWidgets('PressScale renders without scale when animations are disabled',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: Scaffold(
            body: PressScale(child: SizedBox(width: 100, height: 100)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(insidePressScale(ScaleTransition), findsNothing);
    expect(find.byType(PressScale), findsOneWidget);
  });

  testWidgets('ShimmerBox pulses by default', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ShimmerBox(width: 40, height: 40)),
      ),
    );
    expect(insideShimmerBox(FadeTransition), findsOneWidget);
    // Do not pumpAndSettle: the shimmer repeats forever.
    await tester.pump(const Duration(milliseconds: 700));
  });

  testWidgets('ShimmerBox is a static box when animations are disabled',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: Scaffold(body: ShimmerBox(width: 40, height: 40)),
        ),
      ),
    );

    expect(insideShimmerBox(FadeTransition), findsNothing);
    expect(
      insideShimmerBox(Container),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
  });

  testWidgets('FadeSlideIn renders the child directly when animations are '
      'disabled', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: MaterialApp(home: FadeSlideIn(child: Text('hello'))),
      ),
    );

    expect(find.text('hello'), findsOneWidget);
    expect(find.byType(Opacity), findsNothing);
  });

  testWidgets('TaskListSkeleton renders shimmer rows',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: TaskListSkeleton())),
    );

    expect(find.byType(ShimmerBox), findsWidgets);
    // Advance past a shimmer cycle to catch layout errors mid-animation.
    await tester.pump(const Duration(milliseconds: 1500));
  });
}
