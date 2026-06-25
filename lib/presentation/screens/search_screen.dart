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

  @override
  void initState() {
    super.initState();
    _loadViewMode();
    _loadSavedSearches();
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

    final nodeRepo = NodeRepository(dio: auth.dio!);
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
      final repo = NodeRepository(dio: auth.dio!);
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
      return const Center(child: Text('Start typing to search'));
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
