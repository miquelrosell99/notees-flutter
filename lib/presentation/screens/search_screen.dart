import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/system.dart';
import '../../core/routing/router.dart';
import '../../core/utils/node_display_name.dart';
import '../../core/utils/node_icon.dart';
import '../../core/utils/view_mode_store.dart';
import '../../data/local/app_database.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_cache_repository.dart';
import '../../data/repositories/node_repository.dart';
import '../../data/repositories/node_view_repository.dart';
import '../../domain/models/search_filters.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../views/node_collection.dart';
import '../views/node_view_mode.dart';
import '../widgets/filter_bottom_sheet.dart';
import '../widgets/filter_chip_bar.dart';
import '../widgets/fleet_card.dart';
import '../widgets/section_title.dart';
import '../widgets/view_mode_sheet.dart';

/// Live search across nodes with advanced filters.
class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    this.initialQuery,
    this.initialFilters,
  });

  final String? initialQuery;
  final SearchFilters? initialFilters;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  static const _searchHistoryKey = 'search_history';
  static const _maxHistoryItems = 10;

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

  List<String> _searchHistory = [];
  bool _loadingHistory = true;

  NodeCacheRepository? _cacheRepo;
  Set<String> _localResultUuids = {};
  Set<String> _serverResultUuids = {};

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

  /// Class uuid → class node, used for colored class pills in card results.
  Map<String, Node> _classIndex = {};

  @override
  void initState() {
    super.initState();
    if (AppDatabase.isSupported) {
      _cacheRepo = NodeCacheRepository(AppDatabase());
    }
    final initialQuery = widget.initialQuery;
    final initialFilters = widget.initialFilters;
    if (initialQuery != null && initialQuery.isNotEmpty) {
      _controller.text = initialQuery;
      _filters = _filters.copyWith(query: initialQuery);
    }
    if (initialFilters != null) {
      _filters = initialFilters;
      if (initialQuery != null && initialQuery.isNotEmpty) {
        _filters = _filters.copyWith(query: initialQuery);
      }
    }
    _loadViewMode();
    _loadSavedSearches();
    _loadSuggestions();
    _loadSearchHistory();
    if (!_filters.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
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
          _classIndex = {for (final c in classes) c.uuid: c};
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

  Future<void> _loadSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final history = prefs.getStringList(_searchHistoryKey) ?? [];
      if (mounted) {
        setState(() {
          _searchHistory = history;
          _loadingHistory = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingHistory = false);
    }
  }

  Future<void> _saveSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_searchHistoryKey, _searchHistory);
    } catch (_) {
      // History is best-effort; ignore persistence failures.
    }
  }

  Future<void> _addSearchHistory(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    _searchHistory.remove(trimmed);
    _searchHistory.insert(0, trimmed);
    if (_searchHistory.length > _maxHistoryItems) {
      _searchHistory = _searchHistory.take(_maxHistoryItems).toList();
    }
    await _saveSearchHistory();
    if (mounted) setState(() {});
  }

  Future<void> _clearSearchHistory() async {
    _searchHistory.clear();
    await _saveSearchHistory();
    if (mounted) setState(() {});
  }

  void _runHistoryQuery(String query) {
    _controller.text = query;
    _controller.selection = TextSelection.collapsed(offset: query.length);
    _onQueryChanged(query);
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
    final query = _controller.text.trim();
    final isPlainTextSearch = query.isNotEmpty && _filters.isEmpty;

    if (append && _hasMore && isPlainTextSearch) {
      // Plain text search merges local and a single server page; there is no
      // meaningful "load more" because local results are not paginated.
      return;
    }

    final page = append ? _currentPage + 1 : 1;
    final searchFilters = _filters.copyWith(
      query: query,
      page: page,
    );

    setState(() {
      if (append) {
        _loadingMore = true;
      } else {
        _loading = true;
        _localResultUuids = {};
        _serverResultUuids = {};
      }
    });

    try {
      if (isPlainTextSearch && _cacheRepo != null) {
        await _searchPlainText(query, auth);
      } else if (auth.dio != null) {
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
      } else {
        if (mounted) {
          setState(() {
            _results = [];
            _hasMore = false;
          });
        }
      }
      if (query.isNotEmpty && isPlainTextSearch) {
        await _addSearchHistory(query);
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

  Future<void> _searchPlainText(String query, AuthProvider auth) async {
    final localUuids = await _cacheRepo!.searchLocal(query, limit: _filters.limit);
    final localNodes = <Node>[];
    for (final uuid in localUuids) {
      final node = await _cacheRepo!.getByUuid(uuid);
      if (node != null) localNodes.add(node);
    }

    if (mounted) {
      setState(() {
        _results = localNodes;
        _localResultUuids = localNodes.map((n) => n.uuid).toSet();
        _serverResultUuids = {};
        _hasMore = false;
      });
    }

    final shouldFetchServer = auth.dio != null && localNodes.length < _filters.limit;
    if (!shouldFetchServer) return;

    final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
    final serverResults = await repo.searchNodes(query, limit: _filters.limit);
    final serverUuids = serverResults.map((n) => n.uuid).toSet();
    final localOnly = localNodes.where((n) => !serverUuids.contains(n.uuid)).toList();

    if (mounted) {
      setState(() {
        _results = [...serverResults, ...localOnly];
        _serverResultUuids = serverUuids;
        _hasMore = false;
      });
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
            prefixIcon: Icon(MdiIcons.magnify),
            suffixIcon: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (context, value, child) {
                if (value.text.isEmpty) return const SizedBox.shrink();
                return IconButton(
                  icon: Icon(MdiIcons.close),
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
          onSubmitted: (value) {
            _debounceTimer?.cancel();
            _search();
          },
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
            icon: Icon(MdiIcons.tune),
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
              leading: Icon(MdiIcons.magnifyScan, color: colors.primary),
              title: Text(_activeSavedView!.name),
              subtitle: const Text('Saved search'),
              trailing: IconButton(
                icon: Icon(MdiIcons.close),
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
                          ? MdiIcons.tableRow
                          : MdiIcons.viewList,
                      size: 18,
                    ),
                    label: Text(view.name),
                    onPressed: () => _runSavedSearch(view),
                  );
                }).toList(),
              ),
            ),
          if (_controller.text.trim().isEmpty &&
              _filters.isEmpty &&
              _activeSavedView == null &&
              !_loadingHistory &&
              _searchHistory.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      'Recent searches',
                      style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(MdiIcons.closeCircleOutline),
                    tooltip: 'Clear history',
                    onPressed: _clearSearchHistory,
                  ),
                ],
              ),
            ),
          if (_controller.text.trim().isEmpty &&
              _filters.isEmpty &&
              _activeSavedView == null &&
              !_loadingHistory &&
              _searchHistory.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: _searchHistory.map((query) {
                  return ActionChip(
                    avatar: Icon(MdiIcons.history, size: 18),
                    label: Text(query),
                    onPressed: () => _runHistoryQuery(query),
                  );
                }).toList(),
              ),
            ),
          if (_controller.text.trim().isNotEmpty) _buildSourceIndicator(colors),
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
      classIndex: _classIndex,
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
          SectionTitle(icon: MdiIcons.starOutline, label: 'Favorites'),
          const SizedBox(height: 8),
          FleetCard(
            child: Column(
              children: _favorites.asMap().entries.map((entry) {
                final node = entry.value;
                final isLast = entry.key == _favorites.length - 1;
                return Column(
                  children: [
                    ListTile(
                      leading: NodeIcon(
                        iconField: node.icon,
                        fallbackIcon: _iconForNode(node),
                        fallbackColor: colors.onSurfaceVariant,
                      ),
                      title: Text(resolveNodeDisplayName(node, dateFormat: _dateFormat())),
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
        SectionTitle(icon: MdiIcons.clockOutline, label: 'Recent pages'),
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
                          title: Text(resolveNodeDisplayName(node, dateFormat: _dateFormat())),
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

  String _dateFormat() {
    try {
      return context.read<SettingsProvider>().dateFormat;
    } catch (_) {
      return '';
    }
  }

  Widget _favoriteTrailing(Node node) {
    final isFavorite = _favoriteUuids.contains(node.uuid);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(
            isFavorite ? MdiIcons.star : MdiIcons.starOutline,
            color: isFavorite ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          tooltip: isFavorite ? 'Remove favorite' : 'Add favorite',
          onPressed: () => _toggleFavorite(node),
        ),
        Icon(MdiIcons.chevronRight, color: Theme.of(context).colorScheme.onSurfaceVariant),
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
    if (node.isJournal) return MdiIcons.calendarOutline;
    if (node.isTask) return MdiIcons.checkCircleOutline;
    return MdiIcons.fileDocumentOutline;
  }

  Widget _buildSourceIndicator(ColorScheme colors) {
    final hasLocal = _localResultUuids.isNotEmpty;
    final hasServer = _serverResultUuids.isNotEmpty;
    String label;
    if (hasLocal && hasServer) {
      label = 'Local + server results';
    } else if (hasServer) {
      label = 'Server results';
    } else if (hasLocal) {
      label = 'Local results';
    } else if (_loading) {
      label = 'Searching…';
    } else {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
        ),
      ),
    );
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
                icon: Icon(MdiIcons.chevronDown),
                label: const Text('Load more results'),
              ),
      ),
    );
  }
}
