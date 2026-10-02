import 'package:flutter/material.dart';

import '../../data/models/node.dart';
import './color_presets.dart';
import './node_icon.dart';

/// Resolves the effective icon and color for a class by walking its
/// `extendsUuid` inheritance chain.
///
/// A class may define its own icon and color. If it does not, the resolver
/// follows the chain of parent classes until a value is found. This mirrors
/// the web app's class-extension semantics.
class ResolvedClassStyle {
  const ResolvedClassStyle({
    this.icon,
    this.iconField,
    this.color,
    this.sourceUuid,
  });

  final ParsedNodeIcon? icon;

  /// Raw icon string of the class that supplied [icon], ready to feed
  /// [NodeIcon]; null when the class chain has no icon.
  final String? iconField;

  final Color? color;
  final String? sourceUuid;
}

/// Builds a lookup map from class UUID to its resolved style.
Map<String, ResolvedClassStyle> resolveClassStyles(List<Node> classes) {
  final byUuid = {for (final c in classes) c.uuid: c};
  final cache = <String, ResolvedClassStyle>{};

  ResolvedClassStyle? resolve(String uuid, Set<String> visited) {
    if (cache.containsKey(uuid)) return cache[uuid];
    if (!visited.add(uuid)) return null;

    final cls = byUuid[uuid];
    if (cls == null) return null;

    ParsedNodeIcon? icon;
    String? iconField;
    Color? color;
    String? sourceUuid;

    final ownIcon = parseNodeIcon(cls.icon);
    final ownColor = ColorPresets.tryResolve(cls.color);
    if (ownIcon.iconData != null || ownIcon.emoji != null) {
      icon = ownIcon;
      iconField = cls.icon;
      sourceUuid = uuid;
    }
    if (ownColor != null) {
      color = ownColor;
      sourceUuid ??= uuid;
    }

    if (icon == null || color == null) {
      for (final parentUuid in cls.extendsUuid) {
        final parent = resolve(parentUuid, visited);
        if (parent == null) continue;
        if (icon == null && parent.icon != null) {
          icon = parent.icon;
          iconField = parent.iconField;
          sourceUuid ??= parent.sourceUuid;
        }
        if (color == null && parent.color != null) {
          color = parent.color;
          sourceUuid ??= parent.sourceUuid;
        }
        if (icon != null && color != null) break;
      }
    }

    final style = ResolvedClassStyle(
      icon: icon,
      iconField: iconField,
      color: color,
      sourceUuid: sourceUuid,
    );
    return cache[uuid] = style;
  }

  for (final c in classes) {
    resolve(c.uuid, <String>{});
  }
  return cache;
}

/// A node's effective icon/color pair: its own values, else the first
/// assigned class's (in class-assignment order). Mirrors the web client's
/// `effectiveNodeIcon` / `effectiveNodeColor`.
class ResolvedNodeStyle {
  const ResolvedNodeStyle({this.iconField, this.color});

  /// Raw icon string to feed [NodeIcon]; null when nothing resolves.
  final String? iconField;

  /// Effective color; null when neither the node nor its classes set one.
  final Color? color;
}

/// Resolves the effective style of [node]: its own icon and color first, else
/// the first assigned class (in [Node.classesUuid] order) whose resolved style
/// supplies the missing piece, following class inheritance via [classStyles].
ResolvedNodeStyle resolveNodeStyle(
  Node node,
  Map<String, ResolvedClassStyle> classStyles,
) {
  String? iconField;
  Color? color;

  // The node's own icon counts only when it parses to a glyph or emoji: a
  // JSON wrapper with neither is treated as absent.
  final ownIcon = parseNodeIcon(node.icon);
  if (ownIcon.iconData != null || ownIcon.emoji != null) {
    iconField = node.icon;
  }
  color = ColorPresets.tryResolve(node.color);

  for (final classUuid in node.classesUuid) {
    if (iconField != null && color != null) break;
    final style = classStyles[classUuid];
    if (style == null) continue;
    if (iconField == null && style.icon != null) {
      iconField = style.iconField;
    }
    if (color == null && style.color != null) {
      color = style.color;
    }
  }
  return ResolvedNodeStyle(iconField: iconField, color: color);
}

/// Renders a node's icon with its effective style: the node's own icon and
/// color, else the first assigned class's (mirrors the web client).
class EffectiveNodeIcon extends StatelessWidget {
  const EffectiveNodeIcon({
    super.key,
    required this.node,
    required this.classStyles,
    this.size = 20,
    this.fallbackIcon,
  });

  final Node node;
  final Map<String, ResolvedClassStyle> classStyles;
  final double size;
  final IconData? fallbackIcon;

  @override
  Widget build(BuildContext context) {
    final effective = resolveNodeStyle(node, classStyles);
    return NodeIcon(
      iconField: effective.iconField,
      size: size,
      fallbackIcon: fallbackIcon,
      fallbackColor: effective.color,
    );
  }
}
