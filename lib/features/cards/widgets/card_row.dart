import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../data/models/node.dart';
import '../../../shared/widgets/fleet_card.dart';
import '../../editor/widgets/ast_rich_text.dart';

/// One card row in the hub list: the title (one line of the node content),
/// the due-day caption, and the per-row play action starting a single-card
/// review session. The row tap opens the node in the editor.
class CardRow extends StatelessWidget {
  const CardRow({
    super.key,
    required this.node,
    this.due,
    required this.onOpen,
    required this.onReview,
  });

  final Node node;

  /// The effective cardDue day (YYYY-MM-DD); null = fresh.
  final String? due;

  /// Opens the node in the editor.
  final VoidCallback onOpen;

  /// Starts a single-card review session over this row's node.
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: FleetCard(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AstRichText(
                      source: node.name,
                      maxLines: 1,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      due ?? 'New',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(MdiIcons.playCircleOutline, color: colors.primary),
                tooltip: 'Review this card',
                onPressed: onReview,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
