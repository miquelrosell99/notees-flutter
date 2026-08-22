import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import './app_colors.dart';

/// Available theme modes.
enum AppThemeMode { light, dark, system }

/// Available accent sources: monochrome white (default), optional sage,
/// cream functional accents, and dynamic color as the last resort.
enum AppAccent { white, functional, cream, dynamicColor }

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

  // Warm neutral palette mirrored from the web client (variables.css) so both
  // clients render the same surfaces, text, and outlines.
  final scaffoldBackground = isDark
      ? (pureBlack ? Colors.black : const Color(0xFF121211))
      : const Color(0xFFF5F3EF);
  final surfaceColor =
      isDark ? (pureBlack ? Colors.black : const Color(0xFF1A1A18)) : Colors.white;

  final colorScheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
    primary: accent ?? (isDark ? Colors.white : Colors.black),
    onPrimary: accent != null ? Colors.white : (isDark ? Colors.black : Colors.white),
    secondary: accent ?? (isDark ? Colors.grey.shade700 : Colors.grey.shade200),
    onSecondary: isDark ? Colors.white : Colors.black,
  ).copyWith(
    surface: surfaceColor,
    onSurface: isDark ? const Color(0xFFE8E6E1) : const Color(0xFF1A1A1A),
    onSurfaceVariant: isDark ? const Color(0xFFA8A29E) : const Color(0xFF5C5C5C),
    outline: isDark ? const Color(0xFF6B6962) : const Color(0xFFC4BFB6),
    outlineVariant: isDark ? const Color(0xFF2A2926) : const Color(0xFFE3DED6),
    error: isDark ? const Color(0xFFEF5550) : const Color(0xFFC0392B),
    inverseSurface: isDark ? const Color(0xFFE8E6E1) : const Color(0xFF1A1A1A),
    onInverseSurface: isDark ? const Color(0xFF121211) : const Color(0xFFF5F3EF),
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
      : colorScheme.copyWith(
          // fromSeed derives a blue-tinted primaryContainer even from an
          // achromatic seed; pin explicit warm neutrals for the white accent.
          primaryContainer: isDark ? const Color(0xFF262623) : const Color(0xFFEAE6DF),
          onPrimaryContainer: isDark ? Colors.white : Colors.black,
        );

  return ThemeData(
    useMaterial3: true,
    colorScheme: baseScheme,
    brightness: brightness,
    scaffoldBackgroundColor: scaffoldBackground,
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      backgroundColor: scaffoldBackground,
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
      surfaceTintColor: Colors.transparent,
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
    textTheme: _noteesTextTheme(baseScheme, isDark),
    fontFamily: 'Roboto',
  );
}

/// Builds the Notees text theme.
///
/// - Display / page titles use a system serif stack for editorial warmth.
/// - UI / body use the system sans-serif font (Roboto / Google Sans).
/// - Task and metadata roles use slightly tighter line heights.
TextTheme _noteesTextTheme(ColorScheme colors, bool isDark) {
  final serif = TextStyle(
    fontFamily: 'Georgia',
    fontFamilyFallback: const ['Noto Serif', 'Times New Roman', 'serif'],
    color: colors.onSurface,
    letterSpacing: -0.2,
  );
  final sans = TextStyle(
    fontFamily: 'Roboto',
    fontFamilyFallback: const ['Inter', 'sans-serif'],
    color: colors.onSurface,
    letterSpacing: -0.1,
  );

  return TextTheme(
    displayLarge: serif.copyWith(fontSize: 57, fontWeight: FontWeight.w400, height: 1.12),
    displayMedium: serif.copyWith(fontSize: 45, fontWeight: FontWeight.w400, height: 1.16),
    displaySmall: serif.copyWith(fontSize: 36, fontWeight: FontWeight.w400, height: 1.22),
    headlineLarge: serif.copyWith(fontSize: 32, fontWeight: FontWeight.w400, height: 1.25),
    headlineMedium: serif.copyWith(fontSize: 28, fontWeight: FontWeight.w400, height: 1.28),
    headlineSmall: sans.copyWith(fontSize: 24, fontWeight: FontWeight.w500, height: 1.33),
    titleLarge: sans.copyWith(fontSize: 22, fontWeight: FontWeight.w500, height: 1.27),
    titleMedium: sans.copyWith(fontSize: 16, fontWeight: FontWeight.w600, height: 1.5),
    titleSmall: sans.copyWith(fontSize: 14, fontWeight: FontWeight.w600, height: 1.43),
    bodyLarge: sans.copyWith(fontSize: 16, fontWeight: FontWeight.w400, height: 1.5),
    bodyMedium: sans.copyWith(fontSize: 14, fontWeight: FontWeight.w400, height: 1.43),
    bodySmall: sans.copyWith(fontSize: 12, fontWeight: FontWeight.w400, height: 1.33),
    labelLarge: sans.copyWith(fontSize: 14, fontWeight: FontWeight.w500, height: 1.43),
    labelMedium: sans.copyWith(fontSize: 12, fontWeight: FontWeight.w500, height: 1.33),
    labelSmall: sans.copyWith(fontSize: 11, fontWeight: FontWeight.w500, height: 1.27),
  ).apply(
    bodyColor: colors.onSurface,
    displayColor: colors.onSurface,
  );
}

Color _contrastFor(Color color) {
  final luminance = color.computeLuminance();
  return luminance > 0.5 ? Colors.black : Colors.white;
}

/// Returns explicit surface container values so dynamic or accent colors
/// cannot tint surfaces. Values mirror the web client's warm neutral scale
/// (`variables.css`); pure black keeps its own OLED scale.
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
      const Color(0xFF121211),
      const Color(0xFF121211),
      const Color(0xFF1A1A18),
      const Color(0xFF262623),
      const Color(0xFF3D3D39),
    );
  }
  return (
    const Color(0xFFFFFFFF),
    const Color(0xFFF5F3EF),
    const Color(0xFFFAF8F4),
    const Color(0xFFEAE6DF),
    const Color(0xFFDAD6CF),
  );
}

/// Resolves the effective accent color from the user's preference.
///
/// [dynamicColor] is the Material You dynamic color, if available.
Color? resolveAccent(AppAccent accent, Color? dynamicColor) {
  return switch (accent) {
    AppAccent.white => null,
    AppAccent.functional => noteesAccent,
    AppAccent.cream => noteesAccentCream,
    AppAccent.dynamicColor => dynamicColor ?? noteesAccent,
  };
}
