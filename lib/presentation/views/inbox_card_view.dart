import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../core/utils/ast_stringifier.dart';
import '../../core/utils/color_presets.dart';
import '../../data/models/node.dart';
import '../widgets/fleet_card.dart';
import '../widgets/responsive_card_grid_delegate.dart';

/// Card grid view for Inbox blocks.
///
/// Each card represents a top-level Inbox block. The card title is the block
/// itself; the card body is the concatenated plain text of its child blocks.
/// Cards are tinted with the block's color and show class/task chips.
///
/// Swipe right to archive, swipe left to delete.
class InboxCardView extends StatelessWidget {
  const InboxCardView({
    super.key,
    required this.blocks,
    required this.onBlockTap,
    this.onBlockLongPress,
    this.onBlockArchive,
    this.onBlockDelete,
    this.onBlockArchiveUndo,
    this.onBlockDeleteUndo,
    this.classNames = const {},
  });

  final List<Node> blocks;
  final ValueChanged<Node> onBlockTap;
  final ValueChanged<Node>? onBlockLongPress;
  final ValueChanged<Node>? onBlockArchive;
  final ValueChanged<Node>? onBlockDelete;
  final ValueChanged<Node>? onBlockArchiveUndo;
  final ValueChanged<Node>? onBlockDeleteUndo;
  final Map<String, String> classNames;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: responsiveCardGridDelegate(context),
      itemCount: blocks.length,
      itemBuilder: (context, index) {
        final block = blocks[index];
        return _DismissibleInboxCard(
          block: block,
          classNames: classNames,
          onTap: () => onBlockTap(block),
          onLongPress: onBlockLongPress != null ? () => onBlockLongPress!(block) : null,
          onArchive: onBlockArchive != null ? () => onBlockArchive!(block) : null,
          onDelete: onBlockDelete != null ? () => onBlockDelete!(block) : null,
          onArchiveUndo: onBlockArchiveUndo != null ? () => onBlockArchiveUndo!(block) : null,
          onDeleteUndo: onBlockDeleteUndo != null ? () => onBlockDeleteUndo!(block) : null,
        );
      },
    );
  }
}

class _DismissibleInboxCard extends StatelessWidget {
  const _DismissibleInboxCard({
    required this.block,
    required this.classNames,
    required this.onTap,
    this.onLongPress,
    this.onArchive,
    this.onDelete,
    this.onArchiveUndo,
    this.onDeleteUndo,
  });

  final Node block;
  final Map<String, String> classNames;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onArchive;
  final VoidCallback? onDelete;
  final VoidCallback? onArchiveUndo;
  final VoidCallback? onDeleteUndo;

  @override
  Widget build(BuildContext context) {
    final canArchive = onArchive != null;
    final canDelete = onDelete != null;

    Widget card = _InboxCard(
      block: block,
      classNames: classNames,
      onTap: onTap,
      onLongPress: onLongPress,
    );

    if (!canArchive && !canDelete) return card;

    return Dismissible(
      key: ValueKey(block.uuid),
      direction: _direction,
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd && canArchive) {
          HapticFeedback.lightImpact();
          onArchive!();
          _showUndoSnackBar(
            context,
            message: 'Note archived',
            onUndo: onArchiveUndo,
          );
          return false; // We handle removal via parent refresh.
        }
        if (direction == DismissDirection.endToStart && canDelete) {
          final confirmed = await _confirmDelete(context);
          if (confirmed == true && context.mounted) {
            HapticFeedback.lightImpact();
            onDelete!();
            _showUndoSnackBar(
              context,
              message: 'Note deleted',
              onUndo: onDeleteUndo,
            );
          }
          return false;
        }
        return false;
      },
      background: _SwipeBackground(
        alignment: Alignment.centerLeft,
        icon: MdiIcons.archiveOutline,
        label: 'Archive',
        color: Theme.of(context).colorScheme.secondaryContainer,
        foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
      ),
      secondaryBackground: _SwipeBackground(
        alignment: Alignment.centerRight,
        icon: MdiIcons.deleteOutline,
        label: 'Delete',
        color: Theme.of(context).colorScheme.errorContainer,
        foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
      ),
      child: card,
    );
  }

  DismissDirection get _direction {
    if (onArchive != null && onDelete != null) return DismissDirection.horizontal;
    if (onArchive != null) return DismissDirection.startToEnd;
    if (onDelete != null) return DismissDirection.endToStart;
    return DismissDirection.none;
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete note?'),
            content: const Text('This note will be moved to trash.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _showUndoSnackBar(
    BuildContext context, {
    required String message,
    required VoidCallback? onUndo,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: onUndo != null
            ? SnackBarAction(
                label: 'Undo',
                onPressed: () {
                  HapticFeedback.lightImpact();
                  onUndo();
                },
              )
            : null,
      ),
    );
  }
}

class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({
    required this.alignment,
    required this.icon,
    required this.label,
    required this.color,
    required this.foregroundColor,
  });

  final Alignment alignment;
  final IconData icon;
  final String label;
  final Color color;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: foregroundColor),
          const SizedBox(height: 2),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: foregroundColor,
                  fontWeight: FontWeight.w500,
                ),
          ),
        ],
      ),
    );
  }
}

class _InboxCard extends StatelessWidget {
  const _InboxCard({
    required this.block,
    required this.classNames,
    required this.onTap,
    this.onLongPress,
  });

  final Node block;
  final Map<String, String> classNames;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final bgColor = ColorPresets.fromHex(block.color);
    final fgColor = ColorPresets.foregroundFor(bgColor);
    final mutedFg = fgColor.withAlpha((0.75 * 255).round());

    return FleetCard(
      onTap: onTap,
      child: InkWell(
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(20),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    block.isTask ? MdiIcons.checkCircleOutline : MdiIcons.inboxOutline,
                    color: mutedFg,
                    size: 22,
                  ),
                  const Spacer(),
                  if (block.isTask)
                    _Chip(
                      label: 'Task',
                      backgroundColor: fgColor.withAlpha((0.12 * 255).round()),
                      foregroundColor: fgColor,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                block.displayName,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: fgColor,
                    ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Text(
                  _childSummary(block),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: mutedFg,
                      ),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (block.classesUuid.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: _buildClassChips(fgColor),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClassChips(Color fgColor) {
    final names = block.classesUuid
        .map((uuid) => classNames[uuid])
        .whereType<String>()
        .where((name) => name.isNotEmpty)
        .take(3)
        .toList();
    if (names.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: names.map((label) {
        return _Chip(
          label: label,
          backgroundColor: fgColor.withAlpha((0.12 * 255).round()),
          foregroundColor: fgColor,
        );
      }).toList(),
    );
  }

  String _childSummary(Node block) {
    final buffer = StringBuffer();
    for (final child in block.children) {
      final text = astToPlainText(child.name).trim();
      if (text.isEmpty) continue;
      if (buffer.isNotEmpty) buffer.write(' · ');
      buffer.write(text);
    }
    return buffer.toString();
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final String label;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foregroundColor,
              fontWeight: FontWeight.w500,
            ),
      ),
    );
  }
}
