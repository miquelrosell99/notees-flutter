import 'package:flutter/material.dart';

/// Toolbar actions supported by the native editor.
enum EditorAction {
  bold,
  italic,
  underline,
  strikethrough,
  code,
  highlight,
  heading1,
  heading2,
  heading3,
  link,
  classLink,
  tagLink,
  image,
  audio,
  task,
  property,
  table,
  template,
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
              _ToolbarButton(
                icon: Icons.format_bold,
                tooltip: 'Bold',
                onPressed: () => onAction(EditorAction.bold),
              ),
              _ToolbarButton(
                icon: Icons.format_italic,
                tooltip: 'Italic',
                onPressed: () => onAction(EditorAction.italic),
              ),
              _ToolbarButton(
                icon: Icons.format_underlined,
                tooltip: 'Underline',
                onPressed: () => onAction(EditorAction.underline),
              ),
              _ToolbarButton(
                icon: Icons.format_strikethrough,
                tooltip: 'Strikethrough',
                onPressed: () => onAction(EditorAction.strikethrough),
              ),
              _ToolbarButton(
                icon: Icons.code,
                tooltip: 'Code',
                onPressed: () => onAction(EditorAction.code),
              ),
              _ToolbarButton(
                icon: Icons.highlight,
                tooltip: 'Highlight',
                onPressed: () => onAction(EditorAction.highlight),
              ),
              _ToolbarButton(
                icon: Icons.looks_one,
                tooltip: 'Heading 1',
                onPressed: () => onAction(EditorAction.heading1),
              ),
              _ToolbarButton(
                icon: Icons.looks_two,
                tooltip: 'Heading 2',
                onPressed: () => onAction(EditorAction.heading2),
              ),
              _ToolbarButton(
                icon: Icons.looks_3,
                tooltip: 'Heading 3',
                onPressed: () => onAction(EditorAction.heading3),
              ),
              const VerticalDivider(width: 16),
              _ToolbarButton(
                icon: Icons.link,
                tooltip: 'Link to node',
                onPressed: () => onAction(EditorAction.link),
              ),
              _ToolbarButton(
                icon: Icons.category_outlined,
                tooltip: 'Link to class',
                onPressed: () => onAction(EditorAction.classLink),
              ),
              _ToolbarButton(
                icon: Icons.tag,
                tooltip: 'Link to tag',
                onPressed: () => onAction(EditorAction.tagLink),
              ),
              const VerticalDivider(width: 16),
              _ToolbarButton(
                icon: Icons.image,
                tooltip: 'Insert image',
                onPressed: () => onAction(EditorAction.image),
              ),
              _ToolbarButton(
                icon: Icons.mic,
                tooltip: 'Insert audio',
                onPressed: () => onAction(EditorAction.audio),
              ),
              const VerticalDivider(width: 16),
              _ToolbarButton(
                icon: Icons.format_list_bulleted,
                tooltip: 'Slash command',
                onPressed: () => onAction(EditorAction.slash),
              ),
              _ToolbarButton(
                icon: Icons.alternate_email,
                tooltip: 'Mention',
                onPressed: () => onAction(EditorAction.mention),
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
      onPressed: onPressed,
    );
  }
}
