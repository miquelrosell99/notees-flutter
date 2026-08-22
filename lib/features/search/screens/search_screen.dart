import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/routing/router.dart';
import '../../../core/utils/node_display_name.dart';
import '../../../core/utils/node_icon.dart';
import '../../../core/utils/view_mode_store.dart';
import '../../../data/models/node.dart';
import '../../../data/repositories/node_repository.dart';
import '../../../domain/models/search_filters.dart';
import '../../auth/providers/auth_provider.dart';
import '../../settings/providers/settings_provider.dart';
import '../../../shared/views/node_collection.dart';
import '../../../shared/views/node_view_mode.dart';
import '../widgets/filter_bottom_sheet.dart';
import '../widgets/filter_chip_bar.dart';
import '../../../shared/widgets/fleet_card.dart';
import '../../../shared/widgets/section_title.dart';
import '../../../shared/widgets/skeletons.dart';
import '../../../shared/widgets/view_mode_sheet.dart';

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
    _loadSuggestions();
    _loadSearchHistory();
    if (!_filters.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  Future<void> _loadViewMode() async {
    final mode = await _viewModeStore.getMode('search', NodeViewMode.list);
    if (!mounted) return;
    setState(() => _viewMode = mode);
  }

  Future<void> _setViewMode(NodeViewMode mode) async {
    await _viewModeStore.setMode('search', mode);
    if (!mounted) return;
    setState(() => _viewMode = mode);
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
        repo.fetchClasses(),
      ]);
      if (!mounted) return;
      setState(() {
        _recents = results[0] as List<Node>;
        _favorites = results[1] as List<Node>;
        _favoriteUuids = (results[2] as List<String>).toSet();
        _classIndex = {for (final c in results[3] as List<Node>) c.uuid: c};
        _loadingSuggestions = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingSuggestions = false);
    }
  }

  Future<void> _loadSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final history = prefs.getStringList(_searchHistoryKey) ?? [];
      if (!mounted) return;
      setState(() {
        _searchHistory = history;
        _loadingHistory = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingHistory = false);
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
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _clearSearchHistory() async {
    _searchHistory.clear();
    await _saveSearchHistory();
    if (!mounted) return;
    setState(() {});
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
      if (!mounted) return;
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

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onQueryChanged(String query) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), _search);
  }

  Future<void> _search({bool append = false}) async {
    final auth = context.read<AuthProvider>();
    final query = _controller.text.trim();

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
      }
    });

    try {
      if (auth.dio != null) {
        final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
        final results = await repo.searchWithFilters(searchFilters);
        if (!mounted) return;
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
      } else {
        if (mounted) {
          setState(() {
            _results = [];
            _hasMore = false;
          });
        }
      }
      if (query.isNotEmpty) {
        await _addSearchHistory(query);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
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
    setState(() => _filters = filters);
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
              if (!mounted) return;
              if (mode != null) await _setViewMode(mode);
            },
          ),
          IconButton(
            icon: Icon(MdiIcons.tune),
            tooltip: 'Filter',
            onPressed: () async {
              final updated = await FilterBottomSheet.show(context, _filters);
              if (!mounted) return;
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
          if (_controller.text.trim().isEmpty &&
              _filters.isEmpty &&
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
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _buildBody(colors),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme colors) {
    if (_loading && _results.isEmpty) {
      return const ListTileSkeletonList(key: ValueKey('search-loading'));
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(_error!, style: TextStyle(color: colors.error)),
        ),
      );
    }

    if (_controller.text.trim().isEmpty && _filters.isEmpty) {
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
      return const ListTileSkeletonList(key: ValueKey('suggestions-loading'));
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
