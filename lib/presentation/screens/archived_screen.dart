import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/routing/router.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_repository.dart';
import '../providers/auth_provider.dart';
import '../widgets/empty_state.dart';

/// Screen showing archived nodes. Users can unarchive items or open them.
class ArchivedScreen extends StatefulWidget {
  const ArchivedScreen({super.key});

  @override
  State<ArchivedScreen> createState() => _ArchivedScreenState();
}

class _ArchivedScreenState extends State<ArchivedScreen> {
  List<Node> _archived = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadArchived();
  }

  Future<void> _loadArchived() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) {
      setState(() => _loading = false);
      return;
    }

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      final nodes = await repo.fetchArchived();
      if (mounted) {
        setState(() {
          _archived = nodes;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _unarchive(Node node) async {
    HapticFeedback.lightImpact();
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      await repo.unarchiveNode(node.uuid);
      if (mounted) await _loadArchived();
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not unarchive: $e')),
        );
      }
    }
  }

  void _openNode(Node node) {
    HapticFeedback.lightImpact();
    context.push('${Routes.editor}/${node.uuid}');
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Archived'),
      ),
      body: RefreshIndicator(
        onRefresh: _loadArchived,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _buildBody(colors),
      ),
    );
  }

  Widget _buildBody(ColorScheme colors) {
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

    if (_archived.isEmpty) {
      return ListView(
        children: [
          EmptyState(
            icon: MdiIcons.archiveOutline,
            title: 'Nothing archived',
            subtitle: 'Archived notes will appear here.',
          ),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _archived.length,
      itemBuilder: (context, index) {
        final node = _archived[index];
        return Dismissible(
          key: ValueKey(node.uuid),
          direction: DismissDirection.endToStart,
          confirmDismiss: (_) async {
            _unarchive(node);
            return false;
          },
          background: Container(
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(MdiIcons.archiveArrowUpOutline, color: colors.onPrimaryContainer),
                const SizedBox(height: 2),
                Text(
                  'Unarchive',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colors.onPrimaryContainer,
                        fontWeight: FontWeight.w500,
                      ),
                ),
              ],
            ),
          ),
          child: Card(
            margin: EdgeInsets.zero,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(
                color: colors.outline.withAlpha((0.1 * 255).round()),
              ),
            ),
            child: ListTile(
              leading: Icon(
                node.isTask ? MdiIcons.checkCircleOutline : MdiIcons.fileDocumentOutline,
                color: colors.onSurfaceVariant,
              ),
              title: Text(node.displayName),
              subtitle: Text(
                node.isPage ? 'Page' : 'Block',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              trailing: IconButton(
                icon: Icon(MdiIcons.archiveArrowUpOutline),
                tooltip: 'Unarchive',
                onPressed: () => _unarchive(node),
              ),
              onTap: () => _openNode(node),
            ),
          ),
        );
      },
    );
  }
}
