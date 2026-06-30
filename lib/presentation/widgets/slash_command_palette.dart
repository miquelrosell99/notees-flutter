import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
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
      (icon: MdiIcons.formatHeader1, label: 'Heading 1', action: EditorAction.heading1),
      (icon: MdiIcons.formatHeader2, label: 'Heading 2', action: EditorAction.heading2),
      (icon: MdiIcons.formatHeader3, label: 'Heading 3', action: EditorAction.heading3),
      (icon: MdiIcons.formatBold, label: 'Bold', action: EditorAction.bold),
      (icon: MdiIcons.formatItalic, label: 'Italic', action: EditorAction.italic),
      (icon: MdiIcons.checkCircleOutline, label: 'Task', action: EditorAction.task),
      (icon: MdiIcons.codeBraces, label: 'Code', action: EditorAction.code),
      (icon: MdiIcons.image, label: 'Image', action: EditorAction.image),
      (icon: MdiIcons.link, label: 'Link', action: EditorAction.link),
      (icon: MdiIcons.tag, label: 'Tag', action: EditorAction.tagLink),
      (icon: MdiIcons.shapeOutline, label: 'Class', action: EditorAction.classLink),
      (icon: MdiIcons.tune, label: 'Property', action: EditorAction.property),
      (icon: MdiIcons.table, label: 'Table', action: EditorAction.table),
      (icon: MdiIcons.fileDocumentOutline, label: 'Template', action: EditorAction.template),
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
                  icon: Icon(MdiIcons.close),
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
