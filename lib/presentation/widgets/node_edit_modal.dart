import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/icon_map.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../core/utils/color_presets.dart';
import 'bottom_sheet_drag_handle.dart';

/// Result returned from [NodeEditModal.show].
class NodeEditResult {
  const NodeEditResult({
    required this.name,
    this.icon,
    this.color,
  });

  final String name;
  final String? icon;
  final String? color;
}

/// Reusable bottom-sheet modal for editing a node's name, icon, and color.
///
/// Used for renaming pages and editing class definitions. Pass
/// [allowIconColor] = false to hide the icon/color sections (e.g. for page
/// title renames where only the name should change).
class NodeEditModal extends StatefulWidget {
  const NodeEditModal({
    super.key,
    this.title = 'Edit',
    this.initialName = '',
    this.initialIcon,
    this.initialColor,
    this.allowIconColor = true,
    this.confirmLabel = 'Save',
  });

  final String title;
  final String initialName;
  final String? initialIcon;
  final String? initialColor;
  final bool allowIconColor;
  final String confirmLabel;

  static Future<NodeEditResult?> show(
    BuildContext context, {
    String title = 'Edit',
    String initialName = '',
    String? initialIcon,
    String? initialColor,
    bool allowIconColor = true,
    String confirmLabel = 'Save',
  }) {
    return showModalBottomSheet<NodeEditResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: NodeEditModal(
          title: title,
          initialName: initialName,
          initialIcon: initialIcon,
          initialColor: initialColor,
          allowIconColor: allowIconColor,
          confirmLabel: confirmLabel,
        ),
      ),
    );
  }

  @override
  State<NodeEditModal> createState() => _NodeEditModalState();
}

class _NodeEditModalState extends State<NodeEditModal> {
  late final TextEditingController _nameController;
  String? _selectedIcon;
  String? _selectedColor;
  final TextEditingController _iconSearchController = TextEditingController();
  final FocusNode _nameFocus = FocusNode();

  List<MapEntry<String, IconData>> _filteredIcons = [];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
    _selectedIcon = widget.initialIcon;
    _selectedColor = widget.initialColor;
    _filteredIcons = iconMap.entries.take(60).toList();
    _iconSearchController.addListener(_filterIcons);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _nameFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _iconSearchController.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _filterIcons() {
    final query = _iconSearchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      setState(() => _filteredIcons = iconMap.entries.take(60).toList());
      return;
    }
    setState(() {
      _filteredIcons = iconMap.entries
          .where((e) => e.key.toLowerCase().contains(query))
          .take(120)
          .toList();
    });
  }

  NodeEditResult? _buildResult() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return null;
    return NodeEditResult(
      name: name,
      icon: _selectedIcon,
      color: _selectedColor,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const BottomSheetDragHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Text(
              widget.title,
              style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _nameController,
              focusNode: _nameFocus,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Name',
                filled: true,
                fillColor: colors.surfaceContainerHighest.withAlpha((0.4 * 255).round()),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => Navigator.of(context).pop(_buildResult()),
            ),
          ),
          if (widget.allowIconColor) ...[
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Color',
                style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  _ColorOption(
                    color: null,
                    isSelected: _selectedColor == null,
                    onTap: () => setState(() => _selectedColor = null),
                  ),
                  ...ColorPresets.entries.map((entry) {
                    final (hex, _) = entry;
                    return _ColorOption(
                      color: ColorPresets.fromHex(hex),
                      isSelected: _selectedColor == hex,
                      onTap: () => setState(() => _selectedColor = hex),
                    );
                  }),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Icon',
                style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _iconSearchController,
                decoration: InputDecoration(
                  hintText: 'Search icons',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: colors.surfaceContainerHighest.withAlpha((0.4 * 255).round()),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 220,
              child: GridView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 6,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                ),
                itemCount: _filteredIcons.length,
                itemBuilder: (ctx, index) {
                  final entry = _filteredIcons[index];
                  final name = 'mdi${entry.key[0].toUpperCase()}${entry.key.substring(1)}';
                  final isSelected = _selectedIcon == name;
                  return InkWell(
                    onTap: () => setState(() => _selectedIcon = name),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      decoration: BoxDecoration(
                        color: isSelected
                            ? colors.primaryContainer
                            : colors.surfaceContainerHighest.withAlpha((0.4 * 255).round()),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: Icon(entry.value, size: 22),
                    ),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(_buildResult()),
                    child: Text(widget.confirmLabel),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorOption extends StatelessWidget {
  const _ColorOption({required this.isSelected, required this.onTap, this.color});

  final Color? color;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color ?? colors.surfaceContainerHighest,
            shape: BoxShape.circle,
            border: Border.all(
              color: isSelected ? colors.primary : colors.outline.withAlpha((0.2 * 255).round()),
              width: isSelected ? 3 : 1,
            ),
          ),
          child: color == null
              ? Icon(MdiIcons.close, size: 16, color: colors.onSurfaceVariant)
              : isSelected
                  ? Icon(MdiIcons.check, size: 16, color: ColorPresets.foregroundFor(color!))
                  : null,
        ),
      ),
    );
  }
}
