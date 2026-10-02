import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/routing/router.dart';
import '../../../core/utils/node_display_name.dart';
import '../../../data/models/node.dart';
import '../../../data/repositories/node_repository.dart';
import '../../../domain/models/search_filters.dart';
import '../../../domain/services/sync_v2_service.dart';
import '../../auth/providers/auth_provider.dart';
import '../../settings/providers/settings_provider.dart';
import '../../../shared/views/node_list_view.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/fleet_card.dart';
import '../../../shared/widgets/motion.dart';
import '../../../shared/widgets/node_actions.dart';
import '../../../shared/widgets/skeletons.dart';

/// The Library tab: the browse-everything hub. Organization lives here
/// (pages, classes, journals, archive, trash); personal glanceables
/// (Today, Favorites, Recent, Inbox) live on the Home tab.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<Node> _rootPages = [];
  List<Node> _classes = [];
  Set<String> _favoriteUuids = {};
  bool _loading = true;
  String? _error;
  late final NodeActions _actions;

  @override
  void initState() {
    super.initState();
    _actions = NodeActions(
      isFavorite: (node) => _favoriteUuids.contains(node.uuid),
      onFavoriteChanged: _onFavoriteChanged,
      onReload: _loadLibrary,
    );
    _loadLibrary();
  }

  Future<void> _loadLibrary() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      final results = await Future.wait([
        repo.fetchRootPages(),
        repo.fetchFavoriteUuids(),
        repo.fetchClasses(),
      ]);
      if (mounted) {
        setState(() {
          _rootPages = results[0] as List<Node>;
          _favoriteUuids = (results[1] as List<String>).toSet();
          _classes = results[2] as List<Node>;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // Row actions are shared with the Home tab; the library keeps thin wrappers
  // so the existing call sites (sections, "All pages", sheets) stay untouched.
  Future<void> _openNode(Node node) => _actions.open(context, node);

  Future<void> _toggleFavorite(Node node) => _actions.toggleFavorite(context, node);

  Future<void> _archiveNode(Node node) => _actions.archive(context, node);

  void _showNodeActions(Node node) => _actions.showActions(context, node);

  void _onFavoriteChanged(Node node, bool favorite) {
    setState(() {
      if (favorite) {
        _favoriteUuids.add(node.uuid);
      } else {
        _favoriteUuids.remove(node.uuid);
      }
    });
  }

  Future<void> _showClassNodes(Node cls) async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => _ClassNodesSheet(
        cls: cls,
        dio: auth.dio!,
        syncService: auth.syncService,
        favoriteUuids: _favoriteUuids,
      ),
    );
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
    if (!mounted) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      final page = await repo.createQuickNote(name: name);
      if (mounted) {
        await router.push('${Routes.editor}/${page.uuid}');
        // Reload so the new page (and any renames made in the editor) show
        // up with their titles.
        if (mounted) await _loadLibrary();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openAllPages() {
    HapticFeedback.lightImpact();
    final dateFormat = context.read<SettingsProvider>().dateFormat;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _NodeListScreen(
          title: 'Pages',
          nodes: _rootPages,
          onNodeTap: _openNode,
          onNodeLongPress: _showNodeActions,
          favoriteUuids: _favoriteUuids,
          onFavoriteToggle: _toggleFavorite,
          onArchive: _archiveNode,
          dateFormat: dateFormat,
        ),
      ),
    );
  }

  void _openAllClasses() {
    HapticFeedback.lightImpact();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _NodeListScreen(
          title: 'Classes',
          nodes: _classes,
          onNodeTap: _showClassNodes,
        ),
      ),
    );
  }

  void _openJournals() {
    HapticFeedback.lightImpact();
    context.push(Routes.journals);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // No AppBar; SafeArea keeps the header clear of the status-bar inset
      // (mirrors the Home tab).
      body: SafeArea(
        maintainBottomViewPadding: true,
        child: RefreshIndicator(
          onRefresh: _loadLibrary,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _loading
                ? const CardListSkeleton(key: ValueKey('library-loading'))
                : _buildContent(),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.small(
        onPressed: () => _createPage(context),
        tooltip: 'New page',
        child: Icon(MdiIcons.plus),
      ),
    );
  }

  Widget _menuTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, color: colors.onSurfaceVariant),
      title: Text(label),
      trailing: Icon(MdiIcons.chevronRight, color: colors.onSurfaceVariant),
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
    );
  }

  Widget _buildContent() {
    if (_error != null) {
      return ListView(
        key: const ValueKey('library-error'),
        padding: const EdgeInsets.all(20),
        children: [
          EmptyState(
            icon: MdiIcons.alertCircleOutline,
            title: 'Could not load library',
            subtitle: _error,
          ),
          const SizedBox(height: 16),
          Center(
            child: FilledButton.tonalIcon(
              onPressed: _loadLibrary,
              icon: Icon(MdiIcons.refresh),
              label: const Text('Retry'),
            ),
          ),
        ],
      );
    }

    return ListView(
      key: const ValueKey('library-content'),
      padding: const EdgeInsets.all(20),
      children: [
        Text('Library', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        staggered(
          0,
          FleetCard(
            child: Column(
              children: [
                _menuTile(
                  icon: MdiIcons.bookOpenPageVariant,
                  label: 'All pages',
                  onTap: _openAllPages,
                ),
                const Divider(height: 1),
                _menuTile(
                  icon: MdiIcons.shapeOutline,
                  label: 'All classes',
                  onTap: _openAllClasses,
                ),
                const Divider(height: 1),
                _menuTile(
                  icon: MdiIcons.calendarOutline,
                  label: 'All journals',
                  onTap: _openJournals,
                ),
                const Divider(height: 1),
                _menuTile(
                  icon: MdiIcons.archiveOutline,
                  label: 'Archive',
                  onTap: () => context.push(Routes.archived),
                ),
                const Divider(height: 1),
                _menuTile(
                  icon: MdiIcons.deleteOutline,
                  label: 'Trash',
                  onTap: () => context.push(Routes.trash),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
class _ClassNodesSheet extends StatefulWidget {
  const _ClassNodesSheet({
    required this.cls,
    required this.dio,
    this.syncService,
    required this.favoriteUuids,
  });

  final Node cls;
  final Dio dio;
  final SyncV2Service? syncService;
  final Set<String> favoriteUuids;

  @override
  State<_ClassNodesSheet> createState() => _ClassNodesSheetState();
}

class _ClassNodesSheetState extends State<_ClassNodesSheet> {
  List<Node> _nodes = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final repo = NodeRepository(dio: widget.dio, syncService: widget.syncService);
      final results = await repo.searchWithFilters(
        SearchFilters(
          classUuids: [widget.cls.uuid],
          sortBy: SortBy.name,
          order: SortOrder.asc,
          limit: 100,
        ),
      );
      if (mounted) {
        setState(() {
          _nodes = results;
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

  void _open(Node node) {
    HapticFeedback.lightImpact();
    Navigator.of(context).pop();
    context.push('${Routes.editor}/${node.uuid}');
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    Icon(MdiIcons.shapeOutline, color: colors.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.cls.displayName,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Text(
                      '${_nodes.length}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _loading
                    ? const ListTileSkeletonList(itemCount: 4)
                    : _error != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Text(_error!, style: TextStyle(color: colors.error)),
                            ),
                          )
                        : _nodes.isEmpty
                            ? const Center(child: Text('No pages or journals with this class'))
                            : ListView.builder(
                                controller: scrollController,
                                itemCount: _nodes.length,
                                itemBuilder: (context, index) {
                                  final node = _nodes[index];
                                  final isFavorite = widget.favoriteUuids.contains(node.uuid);
                                  return ListTile(
                                    leading: Icon(
                                      node.isJournal ? MdiIcons.calendarOutline : MdiIcons.fileDocumentOutline,
                                      color: colors.onSurfaceVariant,
                                    ),
                                    title: Text(
                                      resolveNodeDisplayName(
                                        node,
                                        dateFormat: context.read<SettingsProvider>().dateFormat,
                                      ),
                                    ),
                                    trailing: Icon(
                                      isFavorite ? MdiIcons.star : MdiIcons.starOutline,
                                      color: isFavorite ? colors.primary : colors.onSurfaceVariant,
                                      size: 20,
                                    ),
                                    onTap: () => _open(node),
                                  );
                                },
                              ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Full-screen node list used by the Library "All pages" / "All classes"
/// tiles. Receives its nodes from the caller, so opening it needs no extra
/// fetch and the rows behave exactly like the library section lists.
class _NodeListScreen extends StatelessWidget {
  const _NodeListScreen({
    required this.title,
    required this.nodes,
    required this.onNodeTap,
    this.onNodeLongPress,
    this.favoriteUuids,
    this.onFavoriteToggle,
    this.onArchive,
    this.dateFormat,
  });

  final String title;
  final List<Node> nodes;
  final ValueChanged<Node> onNodeTap;
  final ValueChanged<Node>? onNodeLongPress;
  final Set<String>? favoriteUuids;
  final ValueChanged<Node>? onFavoriteToggle;
  final ValueChanged<Node>? onArchive;
  final String? dateFormat;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: nodes.isEmpty
          ? const Center(child: Text('Nothing here yet'))
          : NodeListView(
              nodes: nodes,
              onNodeTap: onNodeTap,
              onNodeLongPress: onNodeLongPress,
              favoriteUuids: favoriteUuids,
              onFavoriteToggle: onFavoriteToggle,
              onArchive: onArchive,
              dateFormat: dateFormat,
            ),
    );
  }
}
