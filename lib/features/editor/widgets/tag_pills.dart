import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../core/utils/color_presets.dart';
import '../../../core/utils/node_display_name.dart';
import '../../../core/utils/node_icon.dart';
import '../../../data/models/node.dart';

/// Whether a block's dedicated tags row renders. Web BlockRow parity
/// (`nt-block-tags`): the row shows only when the block carries at least
/// one tag — an untagged block renders no row at all.
bool shouldShowTagRow(List<String> tagIds) => tagIds.isNotEmpty;

/// Tags render alphabetically everywhere (web TagsRow parity): order by
/// display name, dropping ids that have no resolved node in
/// [nodesByUuid] (a tag deleted elsewhere disappears from the row).
List<Node> sortedTagNodes(
  Iterable<String> tagIds,
  Map<String, Node> nodesByUuid,
) {
  final tags = <Node>[
    for (final id in tagIds)
      if (nodesByUuid[id] != null) nodesByUuid[id]!,
  ];
  tags.sort(
    (a, b) => resolveNodeDisplayName(a).toLowerCase().compareTo(
          resolveNodeDisplayName(b).toLowerCase(),
        ),
  );
  return tags;
}

/// The pill chrome color (web `effectiveNodeColor` parity): the tag's own
/// color, else its classes' color, else [fallback].
Color effectiveTagColor(
  Node tag,
  Map<String, Color> colorsByUuid,
  Color fallback,
) {
  final own = ColorPresets.tryResolve(tag.color);
  if (own != null) return own;
  for (final classUuid in tag.classesUuid) {
    final classColor = colorsByUuid[classUuid];
    if (classColor != null) return classColor;
  }
  return fallback;
}

/// Tag pills: the "Tags:" metadata row for pages and blocks. Pills mirror
/// the class chips (tinted surface + border in the tag's effective color),
/// render alphabetically by display name (web TagsRow parity — the sorting
/// lives here, not at the call sites), and carry a trailing × that
/// unassigns (web TagsRow `pill__right-button`). An optional trailing chip
/// opens the assign picker; a tap on a pill opens the tag's page.
class TagPills extends StatelessWidget {
  const TagPills({
    super.key,
    required this.tagIds,
    required this.nodesByUuid,
    required this.colorsByUuid,
    required this.fallbackColor,
    this.onOpen,
    this.onRemove,
    this.onAdd,
    this.compact = false,
  });

  final Iterable<String> tagIds;
  final Map<String, Node> nodesByUuid;
  final Map<String, Color> colorsByUuid;
  final Color fallbackColor;
  final ValueChanged<Node>? onOpen;
  final ValueChanged<Node>? onRemove;
  final VoidCallback? onAdd;

  /// Block rows render tighter pills that indent under the block content.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tags = sortedTagNodes(tagIds, nodesByUuid);

    return Wrap(
      spacing: compact ? 6 : 8,
      runSpacing: compact ? 6 : 8,
      children: [
        for (final tag in tags)
          _TagPill(
            tag: tag,
            color: effectiveTagColor(tag, colorsByUuid, fallbackColor),
            compact: compact,
            onOpen: onOpen,
            onRemove: onRemove,
          ),
        if (onAdd != null)
          ActionChip(
            avatar: Icon(
              MdiIcons.tagPlus,
              size: compact ? 14 : 16,
              color: colors.onSurfaceVariant,
            ),
            label: Text(
              tags.isEmpty ? 'Add tag' : '',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
            ),
            backgroundColor: colors.onSurfaceVariant.withAlpha(
              (0.08 * 255).round(),
            ),
            side: BorderSide(
              color: colors.onSurfaceVariant.withAlpha((0.25 * 255).round()),
            ),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            onPressed: onAdd,
          ),
      ],
    );
  }
}

class _TagPill extends StatelessWidget {
  const _TagPill({
    required this.tag,
    required this.color,
    required this.compact,
    this.onOpen,
    this.onRemove,
  });

  final Node tag;
  final Color color;
  final bool compact;
  final ValueChanged<Node>? onOpen;
  final ValueChanged<Node>? onRemove;

  @override
  Widget build(BuildContext context) {
    final name = resolveNodeDisplayName(tag);
    return GestureDetector(
      onTap: onOpen == null ? null : () => onOpen!(tag),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 10,
          vertical: compact ? 2 : 4,
        ),
        decoration: BoxDecoration(
          color: color.withAlpha((0.10 * 255).round()),
          borderRadius: BorderRadius.circular(compact ? 12 : 16),
          border: Border.all(color: color.withAlpha((0.30 * 255).round())),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            NodeIcon(
              iconField: tag.icon,
              size: compact ? 13 : 15,
              fallbackIcon: MdiIcons.tagOutline,
              fallbackColor: color,
            ),
            const SizedBox(width: 4),
            Text(
              name,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: color,
                    fontSize: compact ? 11 : null,
                  ),
            ),
            if (onRemove != null) ...[
              const SizedBox(width: 2),
              InkWell(
                onTap: () => onRemove!(tag),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    MdiIcons.close,
                    size: compact ? 12 : 14,
                    color: color,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
