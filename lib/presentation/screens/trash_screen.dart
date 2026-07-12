import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/routing/router.dart';
import '../../core/utils/node_icon.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_repository.dart';
import '../providers/auth_provider.dart';
import '../widgets/fleet_card.dart';

/// Trashed nodes: restore or permanently delete.
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  List<Node> _nodes = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadTrash();
  }

  Future<void> _loadTrash() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      final nodes = await repo.fetchTrash(pageSize: 100);
      if (mounted) {
        setState(() {
          _nodes = nodes;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _restoreNode(Node node) async {
    HapticFeedback.lightImpact();
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      await repo.restoreNode(node.uuid);
      if (mounted) await _loadTrash();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not restore: $e')),
        );
      }
    }
  }

  Future<void> _deleteNode(Node node) async {
    HapticFeedback.lightImpact();
    final auth = context.read<AuthProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Permanently delete?'),
        content: Text('"${node.displayName}" will be gone forever.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (auth.dio == null) return;

    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      await repo.permanentlyDeleteNode(node.uuid);
      if (mounted) await _loadTrash();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete: $e')),
        );
      }
    }
  }

  void _openNode(Node node) {
    HapticFeedback.lightImpact();
    context.push('${Routes.editor}/${node.id}');
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trash'),
        actions: [
          if (_nodes.isNotEmpty)
            IconButton(
              icon: Icon(MdiIcons.deleteForeverOutline),
              tooltip: 'Empty trash',
              onPressed: _emptyTrash,
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadTrash,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _buildContent(colors),
      ),
    );
  }

  Future<void> _emptyTrash() async {
    HapticFeedback.lightImpact();
    final auth = context.read<AuthProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Empty trash?'),
        content: const Text('All trashed items will be permanently deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('Empty'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (auth.dio == null) return;

    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      await repo.emptyTrash();
      if (mounted) await _loadTrash();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not empty trash: $e')),
        );
      }
    }
  }

  Widget _buildContent(ColorScheme colors) {
    if (_error != null) {
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(_error!, style: TextStyle(color: colors.error)),
          ),
        ],
      );
    }

    if (_nodes.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 120),
          Center(child: Text('Trash is empty')),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        FleetCard(
          child: Column(
            children: _nodes.asMap().entries.map((entry) {
              final node = entry.value;
              final isLast = entry.key == _nodes.length - 1;
              return Column(
                children: [
                  ListTile(
                    leading: NodeIcon(
                      iconField: node.icon,
                      fallbackIcon: _iconForNode(node),
                      fallbackColor: colors.onSurfaceVariant,
                    ),
                    title: Text(node.displayName),
                    subtitle: node.writeDate != null ? Text(node.writeDate!) : null,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(MdiIcons.restore, color: colors.primary),
                          tooltip: 'Restore',
                          onPressed: () => _restoreNode(node),
                        ),
                        IconButton(
                          icon: Icon(MdiIcons.deleteForever, color: colors.error),
                          tooltip: 'Delete permanently',
                          onPressed: () => _deleteNode(node),
                        ),
                      ],
                    ),
                    onTap: () => _openNode(node),
                  ),
                  if (!isLast) const Divider(height: 1),
                ],
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  IconData _iconForNode(Node node) {
    if (node.isJournal) return MdiIcons.calendarOutline;
    if (node.isTask) return MdiIcons.checkCircleOutline;
    return node.icon?.isNotEmpty == true ? MdiIcons.fileDocumentOutline : MdiIcons.fileDocumentOutline;
  }
}
