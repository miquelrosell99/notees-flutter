import 'package:material_ui/material_ui.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/color_presets.dart';
import '../../../domain/graph/graph_color_group.dart';
import '../../../domain/services/graph_service.dart';

/// The graph's color-groups sheet: the group list (the list order IS the
/// first-match-wins priority) and the add/edit form — a label, a preset
/// color, and the query as DSL text through the local query surface (the
/// same grammar the search box accepts). Saving rides GraphService: the
/// group persists device-locally and the canvas behind repaints on the
/// service's notification — live recolor on save.
class ColorGroupsSheet extends StatefulWidget {
  const ColorGroupsSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const ColorGroupsSheet(),
    );
  }

  @override
  State<ColorGroupsSheet> createState() => _ColorGroupsSheetState();
}

class _ColorGroupsSheetState extends State<ColorGroupsSheet> {
  /// Null = the list view; otherwise the id being edited ('' = a new
  /// group).
  String? _editingId;
  final _labelController = TextEditingController();
  final _dslController = TextEditingController();
  String _color = ColorPresets.entries.first.$1;
  String? _formError;

  @override
  void dispose() {
    _labelController.dispose();
    _dslController.dispose();
    super.dispose();
  }

  void _startEdit(GraphColorGroup? group) {
    _labelController.text = group?.label ?? '';
    _dslController.clear();
    _color = ColorPresets.tokenFor(group?.color) ?? _color;
    setState(() {
      _editingId = group?.id ?? '';
      _formError = null;
    });
  }

  Future<void> _save(GraphService service) async {
    final dsl = _dslController.text.trim();
    if (dsl.isEmpty) {
      setState(() => _formError = 'Enter a query (e.g. name: My page)');
      return;
    }
    try {
      await service.saveGroup(
        id: _editingId!.isEmpty ? null : _editingId,
        label: _labelController.text,
        color: _color,
        dslText: dsl,
      );
    } catch (error) {
      if (mounted) setState(() => _formError = error.toString());
      return;
    }
    if (mounted) setState(() => _editingId = null);
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<GraphService>();
    return FractionallySizedBox(
      heightFactor: 0.85,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: _editingId == null ? _buildList(service) : _buildForm(service),
        ),
      ),
    );
  }

  Widget _buildList(GraphService service) {
    final theme = Theme.of(context);
    final groups = service.groups;
    return Column(
      key: const ValueKey('list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(
            'Color groups',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            'Nodes matching a group render in its color. The first matching '
            'group wins — the list order is the priority.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: groups.isEmpty
              ? const _NoGroups()
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: groups.length,
                  itemBuilder: (context, index) {
                    final group = groups[index];
                    final dot = ColorPresets.tryResolve(group.color) ??
                        theme.colorScheme.surfaceContainerHighest;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          radius: 10,
                          backgroundColor: dot,
                        ),
                        title: Text(group.label),
                        subtitle: Text(
                          group.error ??
                              (group.ast == null
                                  ? 'Painted nowhere'
                                  : '${group.ast!.children.length} '
                                      'condition${group.ast!.children.length == 1 ? '' : 's'}'),
                          style: group.error != null
                              ? TextStyle(
                                  color: theme.colorScheme.error)
                              : null,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(MdiIcons.pencilOutline),
                              onPressed: () => _startEdit(group),
                            ),
                            IconButton(
                              icon: Icon(MdiIcons.deleteOutline),
                              onPressed: () =>
                                  service.removeGroup(group.id),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: FilledButton.icon(
            onPressed: () => _startEdit(null),
            icon: Icon(MdiIcons.plus),
            label: const Text('Add color group'),
          ),
        ),
      ],
    );
  }

  Widget _buildForm(GraphService service) {
    final theme = Theme.of(context);
    return ListView(
      key: const ValueKey('form'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: [
        Text(
          _editingId!.isEmpty ? 'Add color group' : 'Edit color group',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _labelController,
          decoration: const InputDecoration(
            labelText: 'Label',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Color',
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (token, hex, label) in ColorPresets.entries)
              _ColorDot(
                token: token,
                hex: hex,
                label: label,
                selected: _color == token,
                onTap: () => setState(() => _color = token),
              ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _dslController,
          decoration: const InputDecoration(
            labelText: 'Query',
            hintText: 'e.g. class: Meeting or name: Alpha',
            border: OutlineInputBorder(),
            helperText: 'The same query language the search box accepts.',
          ),
        ),
        if (_formError != null) ...[
          const SizedBox(height: 8),
          Text(
            _formError!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            TextButton(
              onPressed: () => setState(() => _editingId = null),
              child: const Text('Cancel'),
            ),
            const Spacer(),
            FilledButton(
              onPressed: () => _save(service),
              child: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }
}

class _NoGroups extends StatelessWidget {
  const _NoGroups();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            MdiIcons.paletteOutline,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant
                .withAlpha((0.35 * 255).round()),
          ),
          const SizedBox(height: 12),
          Text(
            'No color groups yet',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Paint the nodes a query selects — by class, name, or tags.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.token,
    required this.hex,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String token;
  final String hex;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = ColorPresets.fromHex(hex);
    return Semantics(
      label: label,
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outlineVariant,
              width: selected ? 3 : 1,
            ),
          ),
          child: selected
              ? Icon(
                  Icons.check,
                  size: 16,
                  color: ColorPresets.foregroundFor(color),
                )
              : null,
        ),
      ),
    );
  }
}
