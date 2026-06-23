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
  String? _error;
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

  Future<void> _search() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!);
      final results = await repo.searchWithFilters(
        _filters.copyWith(query: _controller.text.trim()),
      );
      if (mounted) {
        setState(() {
          _results = results;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

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
          decoration: const InputDecoration(
            hintText: 'Search notes, tasks, pages...',
            border: InputBorder.none,
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

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final node = _results[index];
        return ListTile(
          leading: Icon(
            _iconForNode(node),
            color: colors.onSurfaceVariant,
          ),
          title: Text(node.displayName),
          trailing: Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
          onTap: () => _openNode(node),
        );
      },
    );
  }

  IconData _iconForNode(Node node) {
    if (node.isJournal) return Icons.calendar_today_outlined;
    if (node.isTask) return Icons.check_circle_outline;
    return Icons.description_outlined;
  }
}
