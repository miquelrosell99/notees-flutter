import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/constants/system.dart';
import '../../core/routing/router.dart';
import '../../core/utils/view_mode_store.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_repository.dart';
import '../../data/repositories/node_view_repository.dart';
import '../../domain/models/search_filters.dart';
import '../providers/auth_provider.dart';
import '../views/node_collection.dart';
import '../views/node_view_mode.dart';
import '../widgets/filter_bottom_sheet.dart';
import '../widgets/filter_chip_bar.dart';
import '../widgets/fleet_card.dart';
import '../widgets/section_title.dart';
import '../widgets/view_mode_sheet.dart';

/// Live search across nodes with advanced filters.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  SearchFilters _filters = const SearchFilters();
  List<Node> _results = [];
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;
  int _currentPage = 1;
  bool _hasMore = false;
  NodeViewMode _viewMode = NodeViewMode.list;
  final _viewModeStore = ViewModeStore();
  Timer? _debounceTimer;

  // Saved searches / query collections
  List<NodeView> _savedViews = [];
  bool _loadingSavedViews = true;
  NodeView? _activeSavedView;

  // Recents and favorites shown when the search box is empty (like the web
  // command palette).
  List<Node> _recents = [];
  List<Node> _favorites = [];
  Set<String> _favoriteUuids = {};
  bool _loadingSuggestions = true;

  @override
  void initState() {
    super.initState();
    _loadViewMode();
    _loadSavedSearches();
    _loadSuggestions();
  }

  Future<void> _loadViewMode() async {
    final mode = await _viewModeStore.getMode('search', NodeViewMode.list);
    if (mounted) setState(() => _viewMode = mode);
  }

  Future<void> _setViewMode(NodeViewMode mode) async {
    await _viewModeStore.setMode('search', mode);
    if (mounted) setState(() => _viewMode = mode);
  }

  Future<void> _loadSavedSearches() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) {
      if (mounted) setState(() => _loadingSavedViews = false);
      return;
    }

    final nodeRepo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
    final viewRepo = NodeViewRepository(dio: auth.dio!);

    try {
      final classes = await nodeRepo.fetchClasses();
      Node? queryClass;
      for (final c in classes) {
        if (c.uuid == SystemClassUuids.query) {
          queryClass = c;
          break;
        }
      }

      if (queryClass == null) {
        if (mounted) setState(() => _loadingSavedViews = false);
        return;
      }

      final pages = await nodeRepo.searchWithFilters(
        SearchFilters(
          nodeType: NodeType.page,
          classUuids: [queryClass.uuid],
          limit: 50,
        ),
      );

      final views = <NodeView>[];
      await Future.wait(
        pages.map((page) async {
          try {
            final pageViews = await viewRepo.fetchViews(page.uuid);
            views.addAll(
              pageViews.where(
                (v) => v.viewType == 'list' || v.viewType == 'table',
              ),
            );
          } catch (_) {
            // Ignore per-page failures so one broken query page doesn't
            // hide saved searches from other pages.
          }
        }),
      );

      if (mounted) {
        setState(() {
          _savedViews = views;
          _loadingSavedViews = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingSavedViews = false);
    }
  }

  Future<void> _loadSuggestions() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) {
      if (mounted) setState(() => _loadingSuggestions = false);
      return;
    }

    final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
    try {
      final results = await Future.wait([
        repo.fetchRecentPages(limit: 10),
        repo.fetchFavorites(limit: 50),
        repo.fetchFavoriteUuids(),
      ]);
      if (mounted) {
        setState(() {
          _recents = results[0] as List<Node>;
          _favorites = results[1] as List<Node>;
          _favoriteUuids = (results[2] as List<String>).toSet();
          _loadingSuggestions = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingSuggestions = false);
    }
  }

  Future<void> _toggleFavorite(Node node) async {
    HapticFeedback.lightImpact();
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    final isFavorite = _favoriteUuids.contains(node.uuid);
    setState(() {
      if (isFavorite) {
        _favoriteUuids.remove(node.uuid);
        _favorites.removeWhere((n) => n.uuid == node.uuid);
      } else {
        _favoriteUuids.add(node.uuid);
        _favorites.add(node);
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
            _favorites.add(node);
          } else {
            _favoriteUuids.remove(node.uuid);
            _favorites.removeWhere((n) => n.uuid == node.uuid);
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update favorite: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onQueryChanged(String query) {
    if (_activeSavedView != null) {
      setState(() => _activeSavedView = null);
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), _search);
  }

  Future<void> _search({bool append = false}) async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    final page = append ? _currentPage + 1 : 1;
    final searchFilters = _filters.copyWith(
      query: _controller.text.trim(),
      page: page,
    );

    setState(() {
      if (append) {
        _loadingMore = true;
      } else {
        _loading = true;
      }
    });
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      final results = await repo.searchWithFilters(searchFilters);
      if (mounted) {
        setState(() {
          if (append) {
            _results.addAll(results);
            _currentPage = page;
          } else {
            _results = results;
            _currentPage = 1;
          }
          _hasMore = results.length >= searchFilters.limit;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  void _loadMore() => _search(append: true);

  void _onFiltersChanged(SearchFilters filters) {
    if (_activeSavedView != null) {
      setState(() => _activeSavedView = null);
    }
    setState(() => _filters = filters);
    _search();
  }

  Future<void> _runSavedSearch(NodeView view) async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    final repo = NodeViewRepository(dio: auth.dio!);
    setState(() {
      _loading = true;
      _activeSavedView = view;
      _error = null;
    });

    try {
      final nodes = await repo.executeView(view.uuid);
      if (mounted) {
        setState(() {
          _results = nodes;
          _viewMode = view.viewType == 'table'
              ? NodeViewMode.table
              : NodeViewMode.list;
          _hasMore = false;
          _loading = false;
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

  void _clearSavedSearch() {
    setState(() => _activeSavedView = null);
    _search();
  }

  void _openNode(Node node) {
    HapticFeedback.lightImpact();
    context.push('${Routes.editor}/${node.uuid}');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          focusNode: _focusNode,
          autofocus: true,
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            hintText: 'Search notes, tasks, pages...',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (context, value, child) {
                if (value.text.isEmpty) return const SizedBox.shrink();
                return IconButton(
                  icon: const Icon(Icons.clear),
                  tooltip: 'Clear search',
                  onPressed: () {
                    _controller.clear();
                    _onQueryChanged('');
                  },
                );
              },
            ),
            filled: true,
            fillColor: colors.surfaceContainerHighest,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(28),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
          ),
          onChanged: _onQueryChanged,
        ),
        actions: [
          IconButton(
            icon: Icon(_viewMode.icon),
            tooltip: 'Change view',
            onPressed: () async {
              final mode = await ViewModeSheet.show(context, _viewMode);
              if (mode != null) await _setViewMode(mode);
            },
          ),
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Filter',
            onPressed: () async {
              final updated = await FilterBottomSheet.show(context, _filters);
              if (updated != null) {
                _onFiltersChanged(updated);
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          FilterChipBar(
            filters: _filters,
            onChanged: _onFiltersChanged,
          ),
          if (_activeSavedView != null)
            ListTile(
              leading: Icon(Icons.saved_search, color: colors.primary),
              title: Text(_activeSavedView!.name),
              subtitle: const Text('Saved search'),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Clear saved search',
                onPressed: _clearSavedSearch,
              ),
            ),
          if (_controller.text.trim().isEmpty &&
              _filters.isEmpty &&
              _savedViews.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    'Saved searches',
                    style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  if (_loadingSavedViews)
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                ],
              ),
            ),
          if (_controller.text.trim().isEmpty &&
              _filters.isEmpty &&
              _savedViews.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: _savedViews.map((view) {
                  return ActionChip(
                    avatar: Icon(
                      view.viewType == 'table'
                          ? Icons.table_rows
                          : Icons.list,
                      size: 18,
                    ),
                    label: Text(view.name),
                    onPressed: () => _runSavedSearch(view),
                  );
                }).toList(),
              ),
            ),
          Expanded(child: _buildBody(colors)),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme colors) {
    if (_loading && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(_error!, style: TextStyle(color: colors.error)),
        ),
      );
    }

    if (_controller.text.trim().isEmpty && _filters.isEmpty && _activeSavedView == null) {
      return _buildSuggestions(colors);
    }

    if (_results.isEmpty) {
      return const Center(child: Text('No results'));
    }

    return NodeCollection(
      mode: _viewMode,
      nodes: _results,
      onNodeTap: _openNode,
      footer: _hasMore ? _buildLoadMoreButton() : null,
    );
  }

  Widget _buildSuggestions(ColorScheme colors) {
    if (_loadingSuggestions) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (_favorites.isNotEmpty) ...[
          const SectionTitle(icon: Icons.star_outline, label: 'Favorites'),
          const SizedBox(height: 8),
          FleetCard(
            child: Column(
              children: _favorites.asMap().entries.map((entry) {
                final node = entry.value;
                final isLast = entry.key == _favorites.length - 1;
                return Column(
                  children: [
                    ListTile(
                      leading: Icon(
                        _iconForNode(node),
                        color: colors.onSurfaceVariant,
                      ),
                      title: Text(node.displayName),
                      trailing: _favoriteTrailing(node),
                      onTap: () => _openNode(node),
                    ),
                    if (!isLast) const Divider(height: 1),
                  ],
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 28),
        ],
        const SectionTitle(icon: Icons.access_time, label: 'Recent pages'),
        const SizedBox(height: 8),
        FleetCard(
          child: _recents.isEmpty
              ? _buildEmptyTile('No recent pages')
              : Column(
                  children: _recents.asMap().entries.map((entry) {
                    final node = entry.value;
                    final isLast = entry.key == _recents.length - 1;
                    return Column(
                      children: [
                        ListTile(
                          leading: Icon(
                            _iconForNode(node),
                            color: colors.onSurfaceVariant,
                          ),
                          title: Text(node.displayName),
                          trailing: _favoriteTrailing(node),
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

  Widget _favoriteTrailing(Node node) {
    final isFavorite = _favoriteUuids.contains(node.uuid);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(
            isFavorite ? Icons.star : Icons.star_border,
            color: isFavorite ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          tooltip: isFavorite ? 'Remove favorite' : 'Add favorite',
          onPressed: () => _toggleFavorite(node),
        ),
        Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ],
    );
  }

  Widget _buildEmptyTile(String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Text(
          message,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }

  IconData _iconForNode(Node node) {
    if (node.isJournal) return Icons.calendar_today_outlined;
    if (node.isTask) return Icons.check_circle_outline;
    return Icons.description_outlined;
  }

  Widget _buildLoadMoreButton() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: _loadingMore
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            : TextButton.icon(
                onPressed: _loadMore,
                icon: const Icon(Icons.expand_more),
                label: const Text('Load more results'),
              ),
      ),
    );
  }
}
