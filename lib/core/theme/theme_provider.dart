import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_colors.dart';
import 'theme_builder.dart';

/// Persists and exposes the user's appearance choices.
class ThemeProvider extends ChangeNotifier {
  ThemeProvider(this._prefs);

  final SharedPreferences _prefs;

  AppThemeMode get themeMode {
    final raw = _prefs.getString(_themeModeKey);
    return AppThemeMode.values.byName(raw ?? AppThemeMode.system.name);
  }

  /// Fleet theming: monochrome white is the default accent; sage, orange,
  /// and dynamic color are opt-in alternatives.
  AppAccent get accent {
    final raw = _prefs.getString(_accentKey);
    return AppAccent.values.firstWhere(
      (a) => a.name == raw,
      orElse: () => AppAccent.white,
    );
  }

  bool get pureBlack => _prefs.getBool(_pureBlackKey) ?? false;

  Future<void> setThemeMode(AppThemeMode value) async {
    await _prefs.setString(_themeModeKey, value.name);
    HapticFeedback.lightImpact();
    notifyListeners();
  }

  Future<void> setAccent(AppAccent value) async {
    await _prefs.setString(_accentKey, value.name);
    HapticFeedback.lightImpact();
    notifyListeners();
  }

  Future<void> setPureBlack(bool value) async {
    await _prefs.setBool(_pureBlackKey, value);
    HapticFeedback.lightImpact();
    notifyListeners();
  }

  /// Builds the light or dark theme for the given [brightness], taking into
  /// account the current accent preference and the optional Material You
  /// [dynamicColor].
  ThemeData themeFor(Brightness brightness, Color? dynamicColor) {
    final effectiveAccent = accent == AppAccent.dynamicColor
        ? (dynamicColor ?? noteesAccent)
        : resolveAccent(accent, dynamicColor);
    return buildNoteesTheme(
      brightness: brightness,
      accent: effectiveAccent,
      pureBlack: pureBlack,
    );
  }

  static const _themeModeKey = 'theme_mode';
  static const _accentKey = 'accent';
  static const _pureBlackKey = 'pure_black';
}

/// Root widget that watches system brightness and dynamic color and rebuilds
/// the MaterialApp theme accordingly.
class NoteesDynamicTheme extends StatelessWidget {
  const NoteesDynamicTheme({
    super.key,
    required this.provider,
    required this.builder,
  });

  final ThemeProvider provider;
  final Widget Function(BuildContext context, ThemeData light, ThemeData dark) builder;

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        final brightness = MediaQuery.platformBrightnessOf(context);
        final mode = provider.themeMode;
        final isDark = mode == AppThemeMode.dark ||
            (mode == AppThemeMode.system && brightness == Brightness.dark);

        final accent = provider.accent == AppAccent.dynamicColor
            ? (isDark ? darkDynamic?.primary : lightDynamic?.primary)
            : resolveAccent(provider.accent, null);

        final lightTheme = provider.themeFor(Brightness.light, accent);
        final darkTheme = provider.themeFor(Brightness.dark, accent);

        return AnimatedBuilder(
          animation: provider,
          builder: (context, _) => builder(context, lightTheme, darkTheme),
        );
      },
    );
  }
}
