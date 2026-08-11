import 'package:flutter/material.dart';

import '../../data/models/node.dart';
import 'color_presets.dart';
import 'node_icon.dart';

/// Resolves the effective icon and color for a class by walking its
/// `extendsUuid` inheritance chain.
///
/// A class may define its own icon and color. If it does not, the resolver
/// follows the chain of parent classes until a value is found. This mirrors
/// the web app's class-extension semantics.
class ResolvedClassStyle {
  const ResolvedClassStyle({this.icon, this.color, this.sourceUuid});

  final ParsedNodeIcon? icon;
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
    Color? color;
    String? sourceUuid;

    final ownIcon = parseNodeIcon(cls.icon);
    final ownColor = ColorPresets.tryResolve(cls.color);
    if (ownIcon.iconData != null || ownIcon.emoji != null) {
      icon = ownIcon;
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
