import 'package:flutter/material.dart';

/// Notees data-level color presets, matching the web app.
///
/// The web app stores these as CSS variable references (e.g.
/// `var(--color-preset-red)`); mobile stores the resolved hex values directly.
class ColorPresets {
  ColorPresets._();

  static const List<(String hex, String label)> entries = [
    ('#c55a55', 'Red'),
    ('#c98557', 'Orange'),
    ('#b8a23a', 'Yellow'),
    ('#4f8f6a', 'Green'),
    ('#4a8a83', 'Teal'),
    ('#5a79c9', 'Blue'),
    ('#8a6cc9', 'Purple'),
    ('#c06a9a', 'Pink'),
  ];

  static const String defaultHex = '#f9f5e8';

  static final RegExp _cssVarPattern = RegExp(r'^var\(--color-preset-([a-z]+)\)$');

  /// Resolves a stored color value to a [Color], or null when unset/unknown.
  ///
  /// Accepts both storage formats: the web app's CSS variable references
  /// (`var(--color-preset-green)`) and freeform hex strings (`#RRGGBB`).
  static Color? tryResolve(String? stored) {
    if (stored == null || stored.trim().isEmpty) return null;
    final value = stored.trim();

    final varMatch = _cssVarPattern.firstMatch(value);
    if (varMatch != null) {
      final name = varMatch.group(1);
      for (final (hex, label) in entries) {
        if (label.toLowerCase() == name) return fromHex(hex);
      }
      return null;
    }

    if (value.startsWith('#')) {
      final hex = value.substring(1);
      if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
      if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    }
    return null;
  }

  /// Parses a hex color string (#RRGGBB) into a Flutter [Color].
  static Color fromHex(String? hex) {
    if (hex == null || hex.isEmpty) return const Color(0xFFF9F5E8);
    var value = hex.trim();
    if (value.startsWith('#')) value = value.substring(1);
    if (value.length == 6) {
      return Color(int.parse('FF$value', radix: 16));
    }
    if (value.length == 8) {
      return Color(int.parse(value, radix: 16));
    }
    return const Color(0xFFF9F5E8);
  }

  /// Returns a text color that contrasts with the given background [color].
  static Color foregroundFor(Color color) {
    final luminance = color.computeLuminance();
    return luminance > 0.5 ? Colors.black87 : Colors.white;
  }
}
