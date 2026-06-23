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
      ]);
      setState(() {
        _rootPages = results[0];
        _recents = results[1];
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
    context.push('${Routes.editor}/${node.id}');
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
      final allPages = <Node>{
        for (final n in _rootPages) n.id: n,
        for (final n in _recents) n.id: n,
      }.values.toList();
      return NodeCollection(
        mode: _viewMode,
        nodes: allPages,
        onNodeTap: _openNode,
        emptyMessage: 'No pages',
      );
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (_rootPages.isNotEmpty) ...[
          const SectionTitle(icon: Icons.folder_outlined, label: 'Root pages'),
          const SizedBox(height: 8),
          FleetCard(
            child: NodeListView(
              nodes: _rootPages,
              onNodeTap: _openNode,
              shrinkWrap: true,
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

  void _createPage(BuildContext context) {
    HapticFeedback.lightImpact();
    // TODO: open a native quick-create page dialog.
  }
}
