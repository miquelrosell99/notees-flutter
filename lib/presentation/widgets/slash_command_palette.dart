import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'editor_inline_toolbar.dart';

/// Bottom-sheet palette of slash commands for the native editor.
class SlashCommandPalette extends StatelessWidget {
  const SlashCommandPalette({super.key});

  static Future<EditorAction?> show(BuildContext context) {
    return showModalBottomSheet<EditorAction>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.4,
        maxChildSize: 0.8,
        expand: false,
        builder: (context, scrollController) => const SlashCommandPalette(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final commands = <({IconData icon, String label, EditorAction action})>[
      (icon: Icons.looks_one, label: 'Heading 1', action: EditorAction.heading1),
      (icon: Icons.looks_two, label: 'Heading 2', action: EditorAction.heading2),
      (icon: Icons.looks_3, label: 'Heading 3', action: EditorAction.heading3),
      (icon: Icons.format_bold, label: 'Bold', action: EditorAction.bold),
      (icon: Icons.format_italic, label: 'Italic', action: EditorAction.italic),
      (icon: Icons.check_circle_outline, label: 'Task', action: EditorAction.task),
      (icon: Icons.code, label: 'Code', action: EditorAction.code),
      (icon: Icons.image, label: 'Image', action: EditorAction.image),
      (icon: Icons.link, label: 'Link', action: EditorAction.link),
      (icon: Icons.tag, label: 'Tag', action: EditorAction.tagLink),
      (icon: Icons.category_outlined, label: 'Class', action: EditorAction.classLink),
      (icon: Icons.tune, label: 'Property', action: EditorAction.property),
      (icon: Icons.table_chart, label: 'Table', action: EditorAction.table),
      (icon: Icons.description_outlined, label: 'Template', action: EditorAction.template),
    ];

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Commands',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: commands.length,
              itemBuilder: (context, index) {
                final command = commands[index];
                return ListTile(
                  leading: Icon(command.icon, color: colors.onSurfaceVariant),
                  title: Text(command.label),
                  onTap: () {
                    HapticFeedback.lightImpact();
                    Navigator.of(context).pop(command.action);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
