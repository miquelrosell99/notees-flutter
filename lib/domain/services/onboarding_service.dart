import 'package:shared_preferences/shared_preferences.dart';

/// Tracks whether the user has completed the first-run onboarding flow.
class OnboardingService {
  OnboardingService({required this.prefs});

  final SharedPreferences prefs;

  static const _completedKey = 'onboarding_completed';
  static const _stepKey = 'onboarding_step';

  bool get isCompleted => prefs.getBool(_completedKey) ?? false;

  int get savedStep => prefs.getInt(_stepKey) ?? 0;

  Future<void> markStep(int step) async {
    await prefs.setInt(_stepKey, step);
  }

  Future<void> markCompleted() async {
    await prefs.setBool(_completedKey, true);
  }

  Future<void> reset() async {
    await prefs.remove(_completedKey);
    await prefs.remove(_stepKey);
  }
}
