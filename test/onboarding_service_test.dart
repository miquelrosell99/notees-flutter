import 'package:flutter_test/flutter_test.dart';
import 'package:notees/domain/services/onboarding_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('OnboardingService', () {
    late SharedPreferences prefs;
    late OnboardingService service;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      service = OnboardingService(prefs: prefs);
    });

    test('isCompleted returns false by default', () {
      expect(service.isCompleted, isFalse);
    });

    test('markCompleted persists completion', () async {
      await service.markCompleted();
      expect(service.isCompleted, isTrue);
    });

    test('markStep persists step index', () async {
      await service.markStep(2);
      expect(service.savedStep, 2);
    });

    test('reset clears completion and step', () async {
      await service.markCompleted();
      await service.markStep(3);
      await service.reset();
      expect(service.isCompleted, isFalse);
      expect(service.savedStep, 0);
    });
  });
}
