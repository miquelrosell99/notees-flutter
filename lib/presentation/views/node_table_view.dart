import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';

import '../../data/models/node.dart';
import '../../core/utils/node_icon.dart';
import '_view_helpers.dart';

/// Table view for a collection of nodes.
///
/// Shows the node name plus user-selectable property columns.
class NodeTableView extends StatefulWidget {
  const NodeTableView({
    super.key,
    required this.nodes,
    required this.onNodeTap,
    this.favoriteUuids,
    this.onFavoriteToggle,
  });

  final List<Node> nodes;
  final ValueChanged<Node> onNodeTap;
  final Set<String>? favoriteUuids;
  final ValueChanged<Node>? onFavoriteToggle;

  @override
  State<NodeTableView> createState() => _NodeTableViewState();
}

class _NodeTableViewState extends State<NodeTableView> {
  final Set<String> _selectedColumns = {};

  List<String> get _availableColumns => collectPropertyKeys(widget.nodes);

  @override
  void initState() {
    super.initState();
    _applyDefaults();
  }

  @override
  void didUpdateWidget(covariant NodeTableView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.nodes != oldWidget.nodes) {
      _applyDefaults();
    }
  }

  void _applyDefaults() {
    final available = _availableColumns;
    if (available.isEmpty) {
      _selectedColumns.clear();
      return;
    }
    // Keep existing selections that are still available; add first few defaults
    // when no valid selection exists.
    _selectedColumns.retainWhere(available.contains);
    if (_selectedColumns.isEmpty) {
      final defaults = available.take(3);
      _selectedColumns.addAll(defaults);
    }
  }

  Future<void> _openColumnSelector() async {
    final available = _availableColumns;
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No property columns available')),
      );
      return;
    }

    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => _ColumnSelector(
        available: available,
        selected: Set<String>.from(_selectedColumns),
      ),
    );

    if (result != null) {
      setState(() {
        _selectedColumns
          ..clear()
          ..addAll(result);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              Text(
                '${widget.nodes.length} items',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(MdiIcons.viewColumnOutline),
                tooltip: 'Select columns',
                onPressed: _openColumnSelector,
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: MediaQuery.of(context).size.width,
              ),
              child: DataTable(
                columns: [
                  const DataColumn(label: Text('Name')),
                  ..._selectedColumns.map(
                    (key) => DataColumn(
                      label: Text(propertyDisplayName(key)),
                    ),
                  ),
                ],
                rows: widget.nodes.map((node) {
                  final isFavorite = widget.favoriteUuids?.contains(node.uuid) ?? false;
                  return DataRow(
                    cells: [
                      DataCell(
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            NodeIcon(
                              iconField: node.icon,
                              fallbackIcon: iconForNode(node),
                              size: 18,
                              fallbackColor: colors.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Flexible(child: Text(node.displayName)),
                            if (widget.onFavoriteToggle != null) ...[
                              const SizedBox(width: 8),
                              IconButton(
                                icon: Icon(
                                  isFavorite ? MdiIcons.star : MdiIcons.starOutline,
                                  size: 18,
                                  color: isFavorite ? colors.primary : colors.onSurfaceVariant,
                                ),
                                tooltip: isFavorite ? 'Remove favorite' : 'Add favorite',
                                onPressed: () {
                                  HapticFeedback.lightImpact();
                                  widget.onFavoriteToggle!(node);
                                },
                              ),
                            ],
                          ],
                        ),
                        onTap: () => widget.onNodeTap(node),
                      ),
                      ..._selectedColumns.map(
                        (key) => DataCell(
                          Text(formatPropertyValue(node.properties[key])),
                          onTap: () => widget.onNodeTap(node),
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ColumnSelector extends StatefulWidget {
  const _ColumnSelector({
    required this.available,
    required this.selected,
  });

  final List<String> available;
  final Set<String> selected;

  @override
  State<_ColumnSelector> createState() => _ColumnSelectorState();
}

class _ColumnSelectorState extends State<_ColumnSelector> {
  late final Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.from(widget.selected);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Text(
                'Select columns',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.available.length,
                itemBuilder: (context, index) {
                  final key = widget.available[index];
                  final label = propertyDisplayName(key);
                  return CheckboxListTile(
                    title: Text(label),
                    value: _selected.contains(key),
                    onChanged: (value) {
                      setState(() {
                        if (value == true) {
                          _selected.add(key);
                        } else {
                          _selected.remove(key);
                        }
                      });
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(_selected),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
