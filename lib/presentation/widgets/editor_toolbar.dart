import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A keyboard-snapped toolbar that drives the web-based Lexical editor through
/// the `window.noteesMobileEditor` JS bridge.
///
/// The toolbar reads `MediaQuery.viewInsets.bottom` so it sits flush above the
/// on-screen keyboard and disappears when the keyboard is hidden.
class EditorToolbar extends StatelessWidget {
  const EditorToolbar({
    super.key,
    required this.onCommand,
    this.onInsertLink,
    this.visible = true,
  });

  final ValueChanged<String> onCommand;
  final VoidCallback? onInsertLink;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: keyboardHeight > 0 ? keyboardHeight : bottomPadding),
      child: AnimatedOpacity(
        opacity: visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: visible ? 56.0 : 0.0,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            border: Border(
              top: BorderSide(
                color: theme.colorScheme.outline.withAlpha((0.15 * 255).round()),
              ),
            ),
          ),
          child: visible
              ? SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ToolbarButton(
                          icon: Icons.format_bold,
                          label: 'Bold',
                          onPressed: () => _send('applyFormat("bold")'),
                        ),
                        _ToolbarButton(
                          icon: Icons.format_italic,
                          label: 'Italic',
                          onPressed: () => _send('applyFormat("italic")'),
                        ),
                        _ToolbarButton(
                          icon: Icons.format_underline,
                          label: 'Underline',
                          onPressed: () => _send('applyFormat("underline")'),
                        ),
                        _ToolbarButton(
                          icon: Icons.format_strikethrough,
                          label: 'Strikethrough',
                          onPressed: () => _send('applyFormat("strikethrough")'),
                        ),
                        _ToolbarButton(
                          icon: Icons.code,
                          label: 'Inline code',
                          onPressed: () => _send('applyFormat("code")'),
                        ),
                        _ToolbarButton(
                          icon: Icons.insert_link,
                          label: 'Link',
                          onPressed: onInsertLink ?? () => _send('insertLink()'),
                        ),
                        _ToolbarButton(
                          icon: Icons.calendar_today,
                          label: 'Today',
                          onPressed: () => _send('insertDate()'),
                        ),
                      ],
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }

  void _send(String command) {
    HapticFeedback.lightImpact();
    onCommand(command);
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return IconButton(
      icon: Icon(icon),
      tooltip: label,
      color: theme.colorScheme.onSurface,
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: onPressed,
    );
  }
}
