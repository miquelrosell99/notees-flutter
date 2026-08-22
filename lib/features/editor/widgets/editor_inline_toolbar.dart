import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';

/// Toolbar actions supported by the native editor.
enum EditorAction {
  bold,
  italic,
  underline,
  strikethrough,
  code,
  highlight,
  heading,
  heading1,
  heading2,
  heading3,
  bullet,
  link,
  classLink,
  tagLink,
  image,
  audio,
  task,
  property,
  table,
  template,
  date,
  slash,
  mention,
}

/// A keyboard-snapped toolbar for the native editor.
class EditorInlineToolbar extends StatelessWidget {
  const EditorInlineToolbar({
    super.key,
    required this.onAction,
  });

  final void Function(EditorAction action) onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Container(
      color: colors.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              // Inline formatting
              _ToolbarButton(
                icon: MdiIcons.formatBold,
                tooltip: 'Bold',
                onPressed: () => onAction(EditorAction.bold),
              ),
              _ToolbarButton(
                icon: MdiIcons.formatItalic,
                tooltip: 'Italic',
                onPressed: () => onAction(EditorAction.italic),
              ),
              _ToolbarButton(
                icon: MdiIcons.formatUnderline,
                tooltip: 'Underline',
                onPressed: () => onAction(EditorAction.underline),
              ),
              _ToolbarButton(
                icon: MdiIcons.formatStrikethrough,
                tooltip: 'Strikethrough',
                onPressed: () => onAction(EditorAction.strikethrough),
              ),
              _ToolbarButton(
                icon: MdiIcons.marker,
                tooltip: 'Highlight',
                onPressed: () => onAction(EditorAction.highlight),
              ),
              const VerticalDivider(width: 16),
              // Block types
              _ToolbarButton(
                icon: MdiIcons.formatHeader1,
                tooltip: 'Heading',
                onPressed: () => onAction(EditorAction.heading),
              ),
              _ToolbarButton(
                icon: MdiIcons.formatListBulleted,
                tooltip: 'Bullet list',
                onPressed: () => onAction(EditorAction.bullet),
              ),
              _ToolbarButton(
                icon: MdiIcons.checkboxMarkedOutline,
                tooltip: 'Task',
                onPressed: () => onAction(EditorAction.task),
              ),
              _ToolbarButton(
                icon: MdiIcons.calendar,
                tooltip: 'Insert date',
                onPressed: () => onAction(EditorAction.date),
              ),
              const VerticalDivider(width: 16),
              // Links and mentions
              _ToolbarButton(
                icon: MdiIcons.link,
                tooltip: 'Link to node',
                onPressed: () => onAction(EditorAction.link),
              ),
              _ToolbarButton(
                icon: MdiIcons.shapeOutline,
                tooltip: 'Link to class',
                onPressed: () => onAction(EditorAction.classLink),
              ),
              _ToolbarButton(
                icon: MdiIcons.at,
                tooltip: 'Mention',
                onPressed: () => onAction(EditorAction.mention),
              ),
              const VerticalDivider(width: 16),
              // Inserts
              _ToolbarButton(
                icon: MdiIcons.image,
                tooltip: 'Insert image',
                onPressed: () => onAction(EditorAction.image),
              ),
              _ToolbarButton(
                icon: MdiIcons.microphone,
                tooltip: 'Insert audio',
                onPressed: () => onAction(EditorAction.audio),
              ),
              _ToolbarButton(
                icon: MdiIcons.dotsHorizontal,
                tooltip: 'More commands',
                onPressed: () => onAction(EditorAction.slash),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon),
      tooltip: tooltip,
      onPressed: () {
        HapticFeedback.lightImpact();
        onPressed();
      },
    );
  }
}
