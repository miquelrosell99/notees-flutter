import 'package:flutter/material.dart';

import '../../domain/models/relay/colors.dart';

/// Notees data-level color presets, matching the web app
/// (`apps/web/src/ui/variables.css` `--color-preset-*` values, 2026-10-03
/// refresh — brighter, perceptually even hues + light blue and gray).
///
/// The wire carries the preset TOKEN (`sky`) or a custom `#RRGGBB`
/// hex — never a resolved hex and never the retired
/// `var(--color-preset-*)` encoding (strict payload validators reject it).
/// Mobile previously stored resolved hexes for preset picks; the pickers
/// now write the token and keep the concrete hex here for rendering only.
/// The token set is imported from the protocol grammar ([colorPresetTokens])
/// so validation and rendering can never drift.
class ColorPresets {
  ColorPresets._();

  /// (token, hex, label) per preset, hue order then gray. The concrete hexes
  /// match the web's `--color-preset-*` values.
  static const List<(String token, String hex, String label)> entries = [
    ('red', '#e34d45', 'Red'),
    ('orange', '#ed822b', 'Orange'),
    ('yellow', '#f3b816', 'Yellow'),
    ('green', '#30a66f', 'Green'),
    ('teal', '#27a59c', 'Teal'),
    ('sky', '#20a9e9', 'Sky'),
    ('blue', '#4072e7', 'Blue'),
    ('purple', '#9662da', 'Purple'),
    ('pink', '#de4996', 'Pink'),
    ('gray', '#8c857d', 'Gray'),
  ];

  static const String defaultHex = '#f9f5e8';

  static final RegExp _cssVarPattern = RegExp(r'^var\(--color-preset-([a-z]+)\)$');

  /// Maps any stored color shape to its preset token: a token as-is, a
  /// preset hex (the mobile app's earlier resolved storage), or the retired
  /// `var(--color-preset-*)` encoding (pre-migration stored data). Returns
  /// null for custom hexes, unknown values, and unset.
  static String? tokenFor(String? stored) {
    if (stored == null) return null;
    final value = stored.trim();
    if (colorPresetTokens.contains(value)) return value;
    final varMatch = _cssVarPattern.firstMatch(value);
    final name = varMatch?.group(1);
    for (final (token, hex, label) in entries) {
      if (name != null && label.toLowerCase() == name) return token;
      if (hex == value) return token;
    }
    return null;
  }

  /// Resolves a stored color value to a [Color], or null when unset/unknown.
  ///
  /// Accepts every storage shape existing data may carry: the preset
  /// token (`sky`), a stored `#RRGGBB` hex (custom colors and the mobile
  /// app's earlier resolved preset hexes), and the retired web CSS variable
  /// references (`var(--color-preset-green)`), which the monorepo migration
  /// rewrites out of stored logs.
  static Color? tryResolve(String? stored) {
    if (stored == null || stored.trim().isEmpty) return null;
    final value = stored.trim();

    final varMatch = _cssVarPattern.firstMatch(value);
    if (varMatch != null) {
      final name = varMatch.group(1);
      for (final entry in entries) {
        if (entry.$3.toLowerCase() == name) return fromHex(entry.$2);
      }
      return null;
    }

    if (colorPresetTokens.contains(value)) {
      for (final entry in entries) {
        if (entry.$1 == value) return fromHex(entry.$2);
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
