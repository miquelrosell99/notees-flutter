import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/routing/router.dart';
import '../../core/utils/view_mode_store.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_repository.dart';
import '../providers/auth_provider.dart';
import '../views/node_collection.dart';
import '../views/node_list_view.dart';
import '../views/node_view_mode.dart';
import '../widgets/fleet_card.dart';
import '../widgets/section_title.dart';
import '../widgets/view_mode_sheet.dart';

/// All pages view: root pages and recent pages.
class PagesScreen extends StatefulWidget {
  const PagesScreen({super.key});

  @override
  State<PagesScreen> createState() => _PagesScreenState();
}

class _PagesScreenState extends State<PagesScreen> {
  List<Node> _rootPages = [];
  List<Node> _recents = [];
  Set<String> _favoriteUuids = {};
  bool _loading = true;
  String? _error;
  NodeViewMode _viewMode = NodeViewMode.list;
  final _viewModeStore = ViewModeStore();

  @override
  void initState() {
    super.initState();
    _loadPages();
    _loadViewMode();
  }

  Future<void> _loadViewMode() async {
    final mode = await _viewModeStore.getMode('pages', NodeViewMode.list);
    if (mounted) setState(() => _viewMode = mode);
  }

  Future<void> _setViewMode(NodeViewMode mode) async {
    await _viewModeStore.setMode('pages', mode);
    if (mounted) setState(() => _viewMode = mode);
  }

  Future<void> _loadPages() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!);
      final results = await Future.wait([
        repo.fetchRootPages(),
        repo.fetchRecentPages(limit: 10),
        repo.fetchFavoriteUuids(),
      ]);
      setState(() {
        _rootPages = results[0] as List<Node>;
        _recents = results[1] as List<Node>;
        _favoriteUuids = (results[2] as List<String>).toSet();
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  void _openNode(Node node) {
    HapticFeedback.lightImpact();
    context.push('${Routes.editor}/${node.uuid}');
  }

  Future<void> _toggleFavorite(Node node) async {
    HapticFeedback.lightImpact();
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    final isFavorite = _favoriteUuids.contains(node.uuid);
    setState(() {
      if (isFavorite) {
        _favoriteUuids.remove(node.uuid);
      } else {
        _favoriteUuids.add(node.uuid);
      }
    });

    try {
      final repo = NodeRepository(dio: auth.dio!);
      if (isFavorite) {
        await repo.removeFavorite(node.uuid);
      } else {
        await repo.addFavorite(node.uuid);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (isFavorite) {
            _favoriteUuids.add(node.uuid);
          } else {
            _favoriteUuids.remove(node.uuid);
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update favorite: $e')),
        );
      }
    }
  }

  Future<void> _createPage(BuildContext context) async {
    HapticFeedback.lightImpact();
    final auth = context.read<AuthProvider>();
    final router = GoRouter.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('New page'),
          content: TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Page name'),
            onSubmitted: (value) => Navigator.of(ctx).pop(value.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );

    if (name == null || name.isEmpty) return;
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!);
      final page = await repo.createQuickNote(name: name);
      if (mounted) {
        router.push('${Routes.editor}/${page.uuid}');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pages'),
        actions: [
          IconButton(
            icon: Icon(_viewMode.icon),
            tooltip: 'Change view',
            onPressed: () async {
              final mode = await ViewModeSheet.show(context, _viewMode);
              if (mode != null) await _setViewMode(mode);
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadPages,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _buildContent(colors),
      ),
      floatingActionButton: FloatingActionButton.small(
        onPressed: () => _createPage(context),
        child: const Icon(Icons.add),
      ),
    );
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

    if (_viewMode != NodeViewMode.list) {
      final allPages = <String, Node>{
        for (final n in _rootPages) n.uuid: n,
        for (final n in _recents) n.uuid: n,
      }.values.toList();
      return NodeCollection(
        mode: _viewMode,
        nodes: allPages,
        onNodeTap: _openNode,
        emptyMessage: 'No pages',
        favoriteUuids: _favoriteUuids,
        onFavoriteToggle: _toggleFavorite,
      );
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SectionTitle(icon: Icons.widgets_outlined, label: 'Templates'),
        const SizedBox(height: 8),
        FleetCard(
          child: ListTile(
            leading: Icon(
              Icons.widgets_outlined,
              color: colors.onSurfaceVariant,
            ),
            title: const Text('Templates'),
            trailing: Icon(
              Icons.chevron_right,
              color: colors.onSurfaceVariant,
            ),
            onTap: () => context.push(Routes.templates),
          ),
        ),
        const SizedBox(height: 28),
        if (_rootPages.isNotEmpty) ...[
          const SectionTitle(icon: Icons.folder_outlined, label: 'Root pages'),
          const SizedBox(height: 8),
          FleetCard(
            child: NodeListView(
              nodes: _rootPages,
              onNodeTap: _openNode,
              shrinkWrap: true,
              favoriteUuids: _favoriteUuids,
              onFavoriteToggle: _toggleFavorite,
            ),
          ),
          const SizedBox(height: 28),
        ],
        const SectionTitle(icon: Icons.access_time, label: 'Recent'),
        const SizedBox(height: 8),
        FleetCard(
          child: _recents.isEmpty
              ? _buildEmptyTile('No recent pages')
              : NodeListView(
                  nodes: _recents,
                  onNodeTap: _openNode,
                  shrinkWrap: true,
                  favoriteUuids: _favoriteUuids,
                  onFavoriteToggle: _toggleFavorite,
                ),
        ),
      ],
    );
  }

  Widget _buildEmptyTile(String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(child: Text(message)),
    );
  }

}
