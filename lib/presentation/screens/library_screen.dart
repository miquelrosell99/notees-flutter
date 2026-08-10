import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/routing/router.dart';
import '../../core/utils/view_mode_store.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_repository.dart';
import '../../domain/models/search_filters.dart';
import '../../domain/services/sync_v2_service.dart';
import '../providers/auth_provider.dart';
import '../views/node_collection.dart';
import '../views/node_list_view.dart';
import '../views/node_view_mode.dart';
import '../widgets/empty_state.dart';
import '../widgets/fleet_card.dart';
import '../widgets/section_title.dart';
import '../widgets/view_mode_sheet.dart';

/// Unified Library tab: browse pages, journals, and tags with recent pins.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<Node> _rootPages = [];
  List<Node> _recents = [];
  List<Node> _recentJournals = [];
  List<Node> _tags = [];
  List<Node> _alphabeticalNodes = [];
  Set<String> _favoriteUuids = {};
  Map<String, Node> _classIndex = {};
  bool _loading = true;
  String? _error;
  NodeViewMode _viewMode = NodeViewMode.list;
  final _viewModeStore = ViewModeStore();

  @override
  void initState() {
    super.initState();
    _loadLibrary();
    _loadViewMode();
  }

  Future<void> _loadViewMode() async {
    final mode = await _viewModeStore.getMode('library', NodeViewMode.list);
    if (mounted) setState(() => _viewMode = mode);
  }

  Future<void> _setViewMode(NodeViewMode mode) async {
    await _viewModeStore.setMode('library', mode);
    if (mounted) setState(() => _viewMode = mode);
  }

  Future<void> _loadLibrary() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      final results = await Future.wait([
        repo.fetchRootPages(),
        repo.fetchRecentPages(limit: 10),
        repo.fetchFavoriteUuids(),
        repo.fetchClasses(),
        repo.searchWithFilters(
          const SearchFilters(
            nodeType: NodeType.journal,
            sortBy: SortBy.writeDate,
            order: SortOrder.desc,
            limit: 10,
          ),
        ),
        repo.searchWithFilters(
          const SearchFilters(
            nodeType: NodeType.page,
            sortBy: SortBy.name,
            order: SortOrder.asc,
            limit: 200,
          ),
        ),
        repo.searchWithFilters(
          const SearchFilters(
            nodeType: NodeType.journal,
            sortBy: SortBy.name,
            order: SortOrder.asc,
            limit: 200,
          ),
        ),
      ]);
      if (mounted) {
        setState(() {
          _rootPages = results[0] as List<Node>;
          _recents = results[1] as List<Node>;
          _favoriteUuids = (results[2] as List<String>).toSet();
          final classes = results[3] as List<Node>;
          _classIndex = {for (final c in classes) c.uuid: c};
          _recentJournals = results[4] as List<Node>;
          _tags = classes.where((c) => _looksLikeTag(c)).toList();
          final pages = results[5] as List<Node>;
          final journals = results[6] as List<Node>;
          _alphabeticalNodes = [...pages, ...journals]
            ..sort(
              (a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
            );
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _looksLikeTag(Node node) {
    // Classes that are used as tags often have a simple naming convention or
    // specific UUIDs; without explicit metadata we surface all classes as tags.
    return node.displayName.isNotEmpty;
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
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
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

  Future<void> _archiveNode(Node node) async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      await repo.archiveNode(node.uuid);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${node.displayName} archived')),
        );
        await _loadLibrary();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not archive: $e')),
        );
      }
    }
  }

  void _showNodeActions(Node node) {
    final isFavorite = _favoriteUuids.contains(node.uuid);
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(isFavorite ? MdiIcons.star : MdiIcons.starOutline),
              title: Text(isFavorite ? 'Unpin' : 'Pin'),
              onTap: () {
                Navigator.of(context).pop();
                _toggleFavorite(node);
              },
            ),
            ListTile(
              leading: Icon(MdiIcons.archiveOutline),
              title: const Text('Archive'),
              onTap: () {
                Navigator.of(context).pop();
                _archiveNode(node);
              },
            ),
            ListTile(
              leading: Icon(
                node.isJournal ? MdiIcons.fileDocumentEditOutline : MdiIcons.eyeOutline,
              ),
              title: Text(node.isJournal ? 'Open journal' : 'Open in Focus Mode'),
              onTap: () {
                Navigator.of(context).pop();
                _openNode(node);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showTagNodes(Node tag) async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => _TagNodesSheet(
        tag: tag,
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

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
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

  void _openSearch() {
    HapticFeedback.lightImpact();
    context.push(Routes.search);
  }

  void _openJournals() {
    HapticFeedback.lightImpact();
    context.push(Routes.journals);
  }

  void _openPages() {
    HapticFeedback.lightImpact();
    context.push(Routes.pages);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            icon: Icon(MdiIcons.magnify),
            tooltip: 'Search',
            onPressed: _openSearch,
          ),
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
        onRefresh: _loadLibrary,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _buildContent(colors),
      ),
      floatingActionButton: FloatingActionButton.small(
        onPressed: () => _createPage(context),
        tooltip: 'New page',
        child: Icon(MdiIcons.plus),
      ),
    );
  }

  Widget _buildContent(ColorScheme colors) {
    if (_error != null) {
      return ListView(
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

    if (_viewMode != NodeViewMode.list) {
      final allNodes = <String, Node>{
        for (final n in _rootPages) n.uuid: n,
        for (final n in _recents) n.uuid: n,
        for (final n in _recentJournals) n.uuid: n,
      }.values.toList();
      return NodeCollection(
        mode: _viewMode,
        nodes: allNodes,
        onNodeTap: _openNode,
        emptyMessage: 'Library is empty',
        favoriteUuids: _favoriteUuids,
        onFavoriteToggle: _toggleFavorite,
        classIndex: _classIndex,
      );
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _buildRecentPins(colors),
        const SizedBox(height: 28),
        SectionTitle(icon: MdiIcons.folderOutline, label: 'Pages'),
        const SizedBox(height: 8),
        FleetCard(
          child: Column(
            children: [
              ListTile(
                leading: Icon(MdiIcons.fileDocumentOutline, color: colors.onSurfaceVariant),
                title: const Text('All pages'),
                trailing: Icon(MdiIcons.chevronRight, color: colors.onSurfaceVariant),
                onTap: _openPages,
              ),
              const Divider(height: 1),
              _rootPages.isEmpty
                  ? _buildEmptyTile('No root pages')
                  : NodeListView(
                      nodes: _rootPages.take(5).toList(),
                      onNodeTap: _openNode,
                      onNodeLongPress: _showNodeActions,
                      shrinkWrap: true,
                      favoriteUuids: _favoriteUuids,
                      onFavoriteToggle: _toggleFavorite,
                    ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        SectionTitle(icon: MdiIcons.calendarOutline, label: 'Journals'),
        const SizedBox(height: 8),
        FleetCard(
          child: Column(
            children: [
              ListTile(
                leading: Icon(MdiIcons.calendarMonthOutline, color: colors.onSurfaceVariant),
                title: const Text('All journals'),
                trailing: Icon(MdiIcons.chevronRight, color: colors.onSurfaceVariant),
                onTap: _openJournals,
              ),
              const Divider(height: 1),
              _recentJournals.isEmpty
                  ? _buildEmptyTile('No recent journals')
                  : NodeListView(
                      nodes: _recentJournals.take(5).toList(),
                      onNodeTap: _openNode,
                      onNodeLongPress: _showNodeActions,
                      shrinkWrap: true,
                    ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        SectionTitle(icon: MdiIcons.tagOutline, label: 'Tags'),
        const SizedBox(height: 8),
        FleetCard(
          child: _tags.isEmpty
              ? _buildEmptyTile('No tags yet')
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _tags.map((tag) {
                      return ActionChip(
                        avatar: Icon(MdiIcons.tagOutline, size: 16),
                        label: Text(tag.displayName),
                        onPressed: () => _showTagNodes(tag),
                      );
                    }).toList(),
                  ),
                ),
        ),
        const SizedBox(height: 28),
        SectionTitle(icon: MdiIcons.formatListBulleted, label: 'Alphabetical'),
        const SizedBox(height: 8),
        _buildAlphabeticalIndex(colors),
      ],
    );
  }

  Map<String, List<Node>> _groupAlphabetically() {
    final groups = <String, List<Node>>{};
    for (final node in _alphabeticalNodes) {
      final first = node.displayName.isEmpty ? '#' : node.displayName[0].toUpperCase();
      final letter = RegExp(r'[A-Z]').hasMatch(first) ? first : '#';
      groups.putIfAbsent(letter, () => []).add(node);
    }
    final sortedKeys = groups.keys.toList()..sort();
    return {for (final k in sortedKeys) k: groups[k]!};
  }

  Widget _buildAlphabeticalIndex(ColorScheme colors) {
    final groups = _groupAlphabetically();
    if (groups.isEmpty) {
      return FleetCard(child: _buildEmptyTile('No pages or journals'));
    }

    return FleetCard(
      child: Column(
        children: groups.entries.map((entry) {
          return ExpansionTile(
            title: Text('${entry.key} (${entry.value.length})'),
            children: entry.value.map((node) {
              return ListTile(
                leading: Icon(
                  node.isJournal ? MdiIcons.calendarOutline : MdiIcons.fileDocumentOutline,
                  color: colors.onSurfaceVariant,
                ),
                title: Text(node.displayName),
                trailing: Icon(MdiIcons.chevronRight, color: colors.onSurfaceVariant),
                onTap: () => _openNode(node),
                onLongPress: () => _showNodeActions(node),
              );
            }).toList(),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildRecentPins(ColorScheme colors) {
    final pins = _recents.where((n) => _favoriteUuids.contains(n.uuid)).toList();
    final displayPins = pins.isEmpty ? _recents.take(3).toList() : pins.take(4).toList();

    if (displayPins.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(
          icon: pins.isEmpty ? MdiIcons.clockOutline : MdiIcons.star,
          label: pins.isEmpty ? 'Recent' : 'Pinned',
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 140,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: displayPins.length,
            separatorBuilder: (context, index) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final node = displayPins[index];
              return SizedBox(
                width: 180,
                child: _PinCard(
                  node: node,
                  onTap: _openNode,
                  onLongPress: _showNodeActions,
                  isFavorite: _favoriteUuids.contains(node.uuid),
                  onFavoriteToggle: _toggleFavorite,
                ),
              );
            },
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

class _PinCard extends StatelessWidget {
  const _PinCard({
    required this.node,
    required this.onTap,
    required this.onLongPress,
    required this.isFavorite,
    required this.onFavoriteToggle,
  });

  final Node node;
  final ValueChanged<Node> onTap;
  final ValueChanged<Node> onLongPress;
  final bool isFavorite;
  final ValueChanged<Node> onFavoriteToggle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FleetCard(
      onTap: () => onTap(node),
      onLongPress: () => onLongPress(node),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  node.isJournal ? MdiIcons.calendarOutline : MdiIcons.fileDocumentOutline,
                  size: 20,
                  color: colors.onSurfaceVariant,
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(
                    isFavorite ? MdiIcons.star : MdiIcons.starOutline,
                    size: 20,
                    color: isFavorite ? colors.primary : colors.onSurfaceVariant,
                  ),
                  tooltip: isFavorite ? 'Remove favorite' : 'Add favorite',
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    onFavoriteToggle(node);
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Text(
                node.displayName,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TagNodesSheet extends StatefulWidget {
  const _TagNodesSheet({
    required this.tag,
    required this.dio,
    this.syncService,
    required this.favoriteUuids,
  });

  final Node tag;
  final Dio dio;
  final SyncV2Service? syncService;
  final Set<String> favoriteUuids;

  @override
  State<_TagNodesSheet> createState() => _TagNodesSheetState();
}

class _TagNodesSheetState extends State<_TagNodesSheet> {
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
          classUuids: [widget.tag.uuid],
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
                    Icon(MdiIcons.tagOutline, color: colors.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.tag.displayName,
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
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Text(_error!, style: TextStyle(color: colors.error)),
                            ),
                          )
                        : _nodes.isEmpty
                            ? const Center(child: Text('No pages or journals with this tag'))
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
                                    title: Text(node.displayName),
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
