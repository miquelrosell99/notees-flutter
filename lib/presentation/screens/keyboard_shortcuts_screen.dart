import 'package:flutter/material.dart';

import '../widgets/fleet_card.dart';
import '../widgets/section_title.dart';

/// Static reference list of keyboard shortcuts available in Notees.
class KeyboardShortcutsScreen extends StatelessWidget {
  const KeyboardShortcutsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Keyboard shortcuts')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: const [
          SectionTitle(icon: Icons.language_outlined, label: 'Global'),
          SizedBox(height: 8),
          _ShortcutGroup(shortcuts: [
            _Shortcut('Command palette', 'Ctrl + K'),
            _Shortcut('Quick add', 'Ctrl + N'),
            _Shortcut('Go to today', 'Ctrl + Shift + T'),
            _Shortcut('Toggle sidebar', 'Ctrl + \\'),
            _Shortcut('New page', 'Ctrl + N'),
            _Shortcut('Open settings', 'Ctrl + ,'),
            _Shortcut('Undo', 'Ctrl + Z'),
            _Shortcut('Redo', 'Ctrl + Y'),
          ]),
          SizedBox(height: 28),
          SectionTitle(icon: Icons.edit_note_outlined, label: 'Editor'),
          SizedBox(height: 8),
          _ShortcutGroup(shortcuts: [
            _Shortcut('Bold', 'Ctrl + B'),
            _Shortcut('Italic', 'Ctrl + I'),
            _Shortcut('Underline', 'Ctrl + U'),
            _Shortcut('Strikethrough', 'Ctrl + Shift + S'),
            _Shortcut('Inline code', 'Ctrl + E'),
            _Shortcut('Insert link', 'Ctrl + K'),
            _Shortcut('Find in page', 'Ctrl + F'),
            _Shortcut('Indent block', 'Tab'),
            _Shortcut('Outdent block', 'Shift + Tab'),
          ]),
          SizedBox(height: 28),
          SectionTitle(icon: Icons.select_all_outlined, label: 'Selection'),
          SizedBox(height: 8),
          _ShortcutGroup(shortcuts: [
            _Shortcut('Select all blocks', 'Ctrl + A'),
            _Shortcut('Copy', 'Ctrl + C'),
            _Shortcut('Cut', 'Ctrl + X'),
            _Shortcut('Paste', 'Ctrl + V'),
            _Shortcut('Delete selected', 'Delete'),
          ]),
          SizedBox(height: 28),
          SectionTitle(icon: Icons.keyboard_arrow_up_outlined, label: 'Navigation'),
          SizedBox(height: 8),
          _ShortcutGroup(shortcuts: [
            _Shortcut('Navigate up', '↑'),
            _Shortcut('Navigate down', '↓'),
            _Shortcut('Exit / cancel', 'Esc'),
          ]),
        ],
      ),
    );
  }
}

class _Shortcut {
  const _Shortcut(this.action, this.keys);
  final String action;
  final String keys;
}

class _ShortcutGroup extends StatelessWidget {
  const _ShortcutGroup({required this.shortcuts});

  final List<_Shortcut> shortcuts;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return FleetCard(
      child: Column(
        children: shortcuts.asMap().entries.map((entry) {
          final shortcut = entry.value;
          final isLast = entry.key == shortcuts.length - 1;
          return Column(
            children: [
              ListTile(
                title: Text(shortcut.action),
                trailing: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: colors.outline.withAlpha((0.2 * 255).round()),
                    ),
                  ),
                  child: Text(
                    shortcut.keys,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              if (!isLast) const Divider(height: 1),
            ],
          );
        }).toList(),
      ),
    );
  }
}
