import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';

import '../../data/models/node.dart';
import '../../data/repositories/node_repository.dart';

/// Actions that can be triggered from the global command palette.
enum CommandPaletteAction {
  dashboard,
  journal,
  tasks,
  pages,
  journalToday,
  search,
  settings,
}

/// Base class for items returned from the command palette.
sealed class CommandPaletteItem {
  const CommandPaletteItem();
}

/// A static navigation command.
final class StaticCommand extends CommandPaletteItem {
  const StaticCommand(this.action);

  final CommandPaletteAction action;
}

/// A command that opens a specific node.
final class NodeCommand extends CommandPaletteItem {
  const NodeCommand(this.node);

  final Node node;
}

/// A globally accessible command palette (Ctrl/Cmd+K style).
///
/// Offers quick navigation to top-level screens plus recent pages and
/// favorites fetched from [NodeRepository].
class CommandPalette extends StatefulWidget {
  const CommandPalette({super.key, required this.repo});

  final NodeRepository repo;

  static Future<CommandPaletteItem?> show(
    BuildContext context,
    NodeRepository repo,
  ) {
    return showModalBottomSheet<CommandPaletteItem>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.65,
        child: CommandPalette(repo: repo),
      ),
    );
  }

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandEntry {
  const _CommandEntry({
    required this.icon,
    required this.label,
    required this.item,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final CommandPaletteItem item;
}

class _CommandPaletteState extends State<CommandPalette> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  List<Node> _recents = [];
  List<Node> _favorites = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadItems() async {
    try {
      final results = await Future.wait([
        widget.repo.fetchRecentPages(limit: 10),
        widget.repo.fetchFavorites(limit: 20),
      ]);
      if (mounted) {
        setState(() {
          _recents = results[0];
          _favorites = results[1];
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  List<_CommandEntry> _buildEntries() {
    final entries = <_CommandEntry>[
      _CommandEntry(
        icon: MdiIcons.viewDashboardOutline,
        label: 'Go to dashboard',
        item: StaticCommand(CommandPaletteAction.dashboard),
      ),
      _CommandEntry(
        icon: MdiIcons.calendarOutline,
        label: 'Go to journals',
        item: StaticCommand(CommandPaletteAction.journal),
      ),
      _CommandEntry(
        icon: MdiIcons.checkCircleOutline,
        label: 'Go to tasks',
        item: StaticCommand(CommandPaletteAction.tasks),
      ),
      _CommandEntry(
        icon: MdiIcons.fileDocumentOutline,
        label: 'Go to pages',
        item: StaticCommand(CommandPaletteAction.pages),
      ),
      _CommandEntry(
        icon: MdiIcons.calendarEditOutline,
        label: "Go to journal today",
        item: StaticCommand(CommandPaletteAction.journalToday),
      ),
      _CommandEntry(
        icon: MdiIcons.magnify,
        label: 'Go to search',
        item: StaticCommand(CommandPaletteAction.search),
      ),
      _CommandEntry(
        icon: MdiIcons.cogOutline,
        label: 'Go to settings',
        item: StaticCommand(CommandPaletteAction.settings),
      ),
      ..._recents.map(
        (node) => _CommandEntry(
          icon: MdiIcons.clockOutline,
          label: node.displayName,
          subtitle: 'Recent page',
          item: NodeCommand(node),
        ),
      ),
      ..._favorites.map(
        (node) => _CommandEntry(
          icon: MdiIcons.star,
          label: node.displayName,
          subtitle: 'Favorite',
          item: NodeCommand(node),
        ),
      ),
    ];
    return entries;
  }

  List<_CommandEntry> _filteredEntries() {
    final query = _controller.text.trim().toLowerCase();
    final entries = _buildEntries();
    if (query.isEmpty) return entries;
    return entries.where((entry) {
      final labelMatch = entry.label.toLowerCase().contains(query);
      final subtitleMatch =
          entry.subtitle?.toLowerCase().contains(query) ?? false;
      return labelMatch || subtitleMatch;
    }).toList();
  }

  void _select(_CommandEntry entry) {
    HapticFeedback.lightImpact();
    Navigator.of(context).pop(entry.item);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final filtered = _filteredEntries();

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
                    'Command palette',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                IconButton(
                  icon: Icon(MdiIcons.close),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: true,
              textAlignVertical: TextAlignVertical.center,
              decoration: InputDecoration(
                hintText: 'Type a command or page name...',
                prefixIcon: Icon(MdiIcons.magnify),
                filled: true,
                fillColor: colors.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                _error!,
                style: TextStyle(color: colors.error),
              ),
            ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            )
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final entry = filtered[index];
                  return ListTile(
                    leading: Icon(entry.icon, color: colors.onSurfaceVariant),
                    title: Text(entry.label),
                    subtitle: entry.subtitle != null
                        ? Text(
                            entry.subtitle!,
                            style: TextStyle(color: colors.onSurfaceVariant),
                          )
                        : null,
                    onTap: () => _select(entry),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
