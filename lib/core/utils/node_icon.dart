import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/icon_map.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import 'color_presets.dart';

/// A parsed node icon: either an MDI glyph or a raw emoji, plus an optional
/// embedded color (data color, independent of the theme accent).
class ParsedNodeIcon {
  const ParsedNodeIcon({this.iconData, this.emoji, this.color});

  final IconData? iconData;
  final String? emoji;
  final Color? color;
}

/// Parses the server `icon` field, which the web app stores as either
/// - a JSON object: `{"icon": "mdiCalendarToday", "color": "var(--color-preset-green)"}`
/// - a bare emoji: `📅`
/// - a bare MDI name: `mdiCalendarToday`
ParsedNodeIcon parseNodeIcon(String? iconField) {
  if (iconField == null || iconField.trim().isEmpty) {
    return const ParsedNodeIcon();
  }
  final value = iconField.trim();

  if (value.startsWith('{')) {
    try {
      final json = jsonDecode(value) as Map<String, dynamic>;
      return ParsedNodeIcon(
        iconData: _mdiFromName(json['icon'] as String?),
        color: ColorPresets.tryResolve(json['color'] as String?),
      );
    } catch (_) {
      return const ParsedNodeIcon();
    }
  }

  final mdi = _mdiFromName(value);
  if (mdi != null) return ParsedNodeIcon(iconData: mdi);

  // Anything else is treated as a literal emoji/symbol.
  return ParsedNodeIcon(emoji: value);
}

/// Resolves an MDI name (`mdiCalendarToday` or `calendarToday`) to its glyph.
IconData? _mdiFromName(String? name) {
  if (name == null || name.isEmpty) return null;
  var key = name.trim();
  if (key.startsWith('mdi')) key = key.substring(3);
  if (key.isEmpty) return null;
  key = key[0].toLowerCase() + key.substring(1);
  return iconMap[key];
}

/// Renders a node's icon (emoji or MDI glyph) with its embedded data color.
class NodeIcon extends StatelessWidget {
  const NodeIcon({
    super.key,
    required this.iconField,
    this.size = 20,
    this.fallbackIcon,
    this.fallbackColor,
  });

  final String? iconField;
  final double size;

  /// Used when the node has no icon of its own.
  final IconData? fallbackIcon;
  final Color? fallbackColor;

  @override
  Widget build(BuildContext context) {
    final parsed = parseNodeIcon(iconField);
    final colors = Theme.of(context).colorScheme;

    if (parsed.emoji != null) {
      return Text(parsed.emoji!, style: TextStyle(fontSize: size * 0.9, height: 1.1));
    }

    return Icon(
      parsed.iconData ?? fallbackIcon ?? MdiIcons.fileDocumentOutline,
      size: size,
      color: parsed.color ?? fallbackColor ?? colors.onSurfaceVariant,
    );
  }
}
