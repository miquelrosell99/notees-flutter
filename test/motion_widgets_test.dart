import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/shared/widgets/motion.dart';
import 'package:notees/shared/widgets/skeletons.dart';

/// Minimal harness without a Navigator, so route-transition overlays
/// (IgnorePointer/AnimatedOpacity layers) never interfere with hit tests
/// or widget finders.
Widget _wrap(Widget child, {bool disableAnimations = false}) {
  return MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Theme(
        data: ThemeData(),
        child: Center(child: child),
      ),
    ),
  );
}

void main() {
  testWidgets('PressScale scales down while pressed and back on release',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(const PressScale(child: SizedBox(width: 100, height: 100))),
    );

    final scaleFinder = find.descendant(
      of: find.byType(PressScale),
      matching: find.byType(ScaleTransition),
    );
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
      _wrap(
        PressScale(
          onTap: () => taps++,
          child: const SizedBox(width: 100, height: 100),
        ),
      ),
    );

    await tester.tap(find.byType(PressScale));
    expect(taps, 1);
    await tester.pumpAndSettle();
  });

  testWidgets('PressScale renders without scale when animations are disabled',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        const PressScale(child: SizedBox(width: 100, height: 100)),
        disableAnimations: true,
      ),
    );

    expect(
      find.descendant(
        of: find.byType(PressScale),
        matching: find.byType(ScaleTransition),
      ),
      findsNothing,
    );
    expect(find.byType(PressScale), findsOneWidget);
  });

  testWidgets('ShimmerBox pulses by default', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(const ShimmerBox(width: 40, height: 40)),
    );
    expect(
      find.descendant(
        of: find.byType(ShimmerBox),
        matching: find.byType(FadeTransition),
      ),
      findsOneWidget,
    );
    // Do not pumpAndSettle: the shimmer repeats forever.
    await tester.pump(const Duration(milliseconds: 700));
  });

  testWidgets('ShimmerBox is a static box when animations are disabled',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        const ShimmerBox(width: 40, height: 40),
        disableAnimations: true,
      ),
    );

    expect(
      find.descendant(
        of: find.byType(ShimmerBox),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(ShimmerBox),
        matching: find.byType(Container),
      ),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
  });

  testWidgets('FadeSlideIn renders the child directly when animations are '
      'disabled', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(const FadeSlideIn(child: Text('hello')), disableAnimations: true),
    );

    expect(find.text('hello'), findsOneWidget);
    expect(find.byType(Opacity), findsNothing);
  });

  testWidgets('TaskListSkeleton renders shimmer rows',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(const TaskListSkeleton()),
    );

    expect(find.byType(ShimmerBox), findsWidgets);
    // Advance past a shimmer cycle to catch layout errors mid-animation.
    await tester.pump(const Duration(milliseconds: 1500));
  });
}
