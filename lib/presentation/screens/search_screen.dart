import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/routing/router.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_repository.dart';
import '../../domain/models/search_filters.dart';
import '../providers/auth_provider.dart';
import '../views/node_collection.dart';
import '../views/node_view_mode.dart';
import '../widgets/filter_bottom_sheet.dart';
import '../widgets/filter_chip_bar.dart';

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
  Timer? _debounceTimer;

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
    setState(() => _filters = filters);
    _search();
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
                    _search();
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

    if (_controller.text.trim().isEmpty && _filters.isEmpty) {
      return const Center(child: Text('Start typing to search'));
    }

    if (_results.isEmpty) {
      return const Center(child: Text('No results'));
    }

    return NodeCollection(
      mode: NodeViewMode.list,
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
