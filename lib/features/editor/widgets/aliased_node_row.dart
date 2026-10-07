import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../core/utils/node_display_name.dart';
import '../../../core/utils/node_icon.dart';
import '../../../data/models/node.dart';

/// The alias-side pseudo-property row (SCHEMA.md "Node aliases"): ONE row
/// of properties-section chrome over the `aliasedNodeId` wire node field
/// itself, rendered at the top of the properties card when the carrier IS
/// an alias (the field set — document chrome only; the ADD direction lives
/// on the main page's title-row aliases sheet, this row never authors a
/// first alias onto an ordinary page).
///
/// The row names the main page: [onOpen] navigates to it, [onChange]
/// re-points the alias (the carrier's OWN field — the applier cycle-checks
/// the would-be chain), [onClear] clears the field present-null. A BROKEN
/// target (the stored id resolves no node) renders the raw id and keeps
/// Clear.
class AliasedNodeRow extends StatelessWidget {
  const AliasedNodeRow({
    super.key,
    required this.target,
    this.brokenTargetUuid,
    required this.onOpen,
    required this.onChange,
    required this.onClear,
  });

  /// The resolved main page, or null when [brokenTargetUuid] is set.
  final Node? target;
  final String? brokenTargetUuid;
  final VoidCallback onOpen;
  final VoidCallback onChange;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final target = this.target;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Aliased node',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            if (target != null)
              Expanded(
                child: TextButton.icon(
                  onPressed: onOpen,
                  icon: NodeIcon(
                    iconField: target.icon,
                    size: 18,
                    fallbackColor: colors.onSurfaceVariant,
                  ),
                  label: Text(
                    resolveNodeDisplayName(target),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    alignment: Alignment.centerLeft,
                  ),
                ),
              )
            else
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Broken reference: ${brokenTargetUuid ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.error,
                        ),
                  ),
                ),
              ),
            IconButton(
              icon: Icon(MdiIcons.pencilOutline, size: 18),
              tooltip: 'Change aliased node',
              color: colors.onSurfaceVariant,
              visualDensity: VisualDensity.compact,
              onPressed: onChange,
            ),
            IconButton(
              icon: Icon(MdiIcons.close, size: 18),
              tooltip: 'Clear alias',
              color: colors.onSurfaceVariant,
              visualDensity: VisualDensity.compact,
              onPressed: onClear,
            ),
          ],
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}
