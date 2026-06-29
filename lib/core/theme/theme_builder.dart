import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';

/// Available theme modes.
enum AppThemeMode { light, dark, system }

/// Available accent sources.
enum AppAccent { white, functional, dynamicColor }

/// Builds the fleet RosellRamos [ThemeData] for Notees.
///
/// - Surfaces stay flat (elevation 0).
/// - The functional accent is sage green.
/// - Dynamic color replaces the accent when requested and available.
ThemeData buildNoteesTheme({
  required Brightness brightness,
  Color? accent,
  bool pureBlack = false,
}) {
  final isDark = brightness == Brightness.dark;

  // Monochrome base seed color. We derive the scheme from a neutral seed and
  // then override the primary color with the chosen accent.
  final seedColor = accent ?? (isDark ? Colors.grey.shade900 : Colors.white);

  final surfaceContainers = _surfaceContainers(isDark, pureBlack);

  final colorScheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
    primary: accent ?? (isDark ? Colors.white : Colors.black),
    onPrimary: accent != null ? Colors.white : (isDark ? Colors.black : Colors.white),
    secondary: accent ?? (isDark ? Colors.grey.shade700 : Colors.grey.shade200),
    onSecondary: isDark ? Colors.white : Colors.black,
    surface: pureBlack && isDark ? Colors.black : null,
  ).copyWith(
    surfaceContainerLowest: surfaceContainers.$1,
    surfaceContainerLow: surfaceContainers.$2,
    surfaceContainer: surfaceContainers.$3,
    surfaceContainerHigh: surfaceContainers.$4,
    surfaceContainerHighest: surfaceContainers.$5,
  );

  final baseScheme = accent != null
      ? colorScheme.copyWith(
          primary: accent,
          onPrimary: _contrastFor(accent),
          primaryContainer: accent.withAlpha((0.15 * 255).round()),
          onPrimaryContainer: accent,
        )
      : colorScheme;

  return ThemeData(
    useMaterial3: true,
    colorScheme: baseScheme,
    brightness: brightness,
    scaffoldBackgroundColor: baseScheme.surface,
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      backgroundColor: baseScheme.surface,
      foregroundColor: baseScheme.onSurface,
      centerTitle: true,
      systemOverlayStyle: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      elevation: 0,
      backgroundColor: baseScheme.surface,
      selectedItemColor: baseScheme.primary,
      unselectedItemColor: baseScheme.onSurfaceVariant,
      type: BottomNavigationBarType.fixed,
    ),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      backgroundColor: baseScheme.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: baseScheme.primaryContainer,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        return TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? baseScheme.onSurface
              : baseScheme.onSurfaceVariant,
        );
      }),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: baseScheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: baseScheme.outline.withAlpha((0.1 * 255).round()),
        ),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        backgroundColor: baseScheme.primary,
        foregroundColor: baseScheme.onPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        side: BorderSide(color: baseScheme.outline.withAlpha((0.2 * 255).round())),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: baseScheme.surfaceContainerHighest,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: baseScheme.outline.withAlpha((0.2 * 255).round()),
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: baseScheme.outline.withAlpha((0.2 * 255).round()),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: baseScheme.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: baseScheme.error),
      ),
      contentPadding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
    ),
    chipTheme: ChipThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      side: BorderSide(color: baseScheme.outline.withAlpha((0.2 * 255).round())),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      elevation: 0,
      backgroundColor: baseScheme.surfaceContainerHighest,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    dialogTheme: DialogThemeData(
      elevation: 0,
      backgroundColor: baseScheme.surfaceContainerHighest,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    snackBarTheme: SnackBarThemeData(
      elevation: 0,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      backgroundColor: baseScheme.inverseSurface,
      contentTextStyle: TextStyle(color: baseScheme.onInverseSurface),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 0,
      backgroundColor: baseScheme.primary,
      foregroundColor: baseScheme.onPrimary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    dividerTheme: DividerThemeData(
      color: baseScheme.outline.withAlpha((0.1 * 255).round()),
      space: 1,
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ),
    switchTheme: SwitchThemeData(
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return Colors.transparent;
        return baseScheme.outline.withAlpha((0.3 * 255).round());
      }),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    fontFamily: 'Roboto',
  );
}

Color _contrastFor(Color color) {
  final luminance = color.computeLuminance();
  return luminance > 0.5 ? Colors.black : Colors.white;
}

/// Returns explicit grayscale surface container values so dynamic or accent
/// colors cannot tint surfaces. Values are chosen from the Attire fleet scale.
(Color, Color, Color, Color, Color) _surfaceContainers(bool isDark, bool pureBlack) {
  if (isDark) {
    if (pureBlack) {
      return (
        const Color(0xFF000000),
        const Color(0xFF111111),
        const Color(0xFF1A1A1A),
        const Color(0xFF222222),
        const Color(0xFF2A2A2A),
      );
    }
    return (
      const Color(0xFF0F0F0F),
      const Color(0xFF1A1A1A),
      const Color(0xFF1F1F1F),
      const Color(0xFF252525),
      const Color(0xFF2A2A2A),
    );
  }
  return (
    const Color(0xFFFFFFFF),
    const Color(0xFFF7F7F7),
    const Color(0xFFF2F2F2),
    const Color(0xFFECECEC),
    const Color(0xFFE6E6E6),
  );
}

/// Resolves the effective accent color from the user's preference.
///
/// [dynamicColor] is the Material You dynamic color, if available.
Color? resolveAccent(AppAccent accent, Color? dynamicColor) {
  return switch (accent) {
    AppAccent.white => null,
    AppAccent.functional => noteesAccent,
    AppAccent.dynamicColor => dynamicColor ?? noteesAccent,
  };
}
