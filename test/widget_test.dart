import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/features/auth/screens/splash_screen.dart';

void main() {
  testWidgets('Splash screen renders app name', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: SplashScreen()),
    );

    expect(find.text('Notees'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
