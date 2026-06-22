import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models/node.dart';
import '../../data/repositories/node_repository.dart';
import '../../domain/models/search_filters.dart';
import 'filter_bottom_sheet.dart';
import 'filter_chip_bar.dart';

/// Reusable bottom-sheet node picker.
///
/// Provides the same search + advanced-filter UI as the Search tab and returns
/// the selected [Node] to the caller.
class NodePicker extends StatefulWidget {
  const NodePicker({
    super.key,
    required this.dio,
    this.title = 'Select a page',
    this.initialFilters = const SearchFilters(),
  });

  final Dio dio;
  final String title;
  final SearchFilters initialFilters;

  static Future<Node?> show(
    BuildContext context, {
    required Dio dio,
    String title = 'Select a page',
    SearchFilters initialFilters = const SearchFilters(
      nodeType: NodeType.page,
    ),
  }) {
    return showModalBottomSheet<Node>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => NodePicker(
        dio: dio,
        title: title,
        initialFilters: initialFilters,
      ),
    );
  }

  @override
  State<NodePicker> createState() => _NodePickerState();
}

class _NodePickerState extends State<NodePicker> {
  late final TextEditingController _queryController;
  late SearchFilters _filters;
  List<Node> _results = [];
  bool _loading = false;
  String? _error;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _filters = widget.initialFilters;
    _queryController = TextEditingController(text: _filters.query);
    _search();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final repo = NodeRepository(dio: widget.dio);
      final results = await repo.searchWithFilters(
        _filters.copyWith(query: query),
      );
      if (mounted) {
        setState(() {
          _results = results;
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

  void _onQueryChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), _search);
  }

  void _onFiltersChanged(SearchFilters filters) {
    setState(() => _filters = filters);
    _search();
  }

  void _select(Node node) {
    HapticFeedback.lightImpact();
    Navigator.of(context).pop(node);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              _buildHandle(colors),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text(
                  widget.title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _queryController,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Search...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.tune),
                      onPressed: () async {
                        final updated = await FilterBottomSheet.show(
                          context,
                          _filters,
                        );
                        if (updated != null) {
                          _onFiltersChanged(updated);
                        }
                      },
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onChanged: _onQueryChanged,
                ),
              ),
              FilterChipBar(
                filters: _filters,
                onChanged: _onFiltersChanged,
              ),
              Expanded(
                child: _buildResults(scrollController),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHandle(ColorScheme colors) {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 12, bottom: 8),
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: colors.outline.withAlpha((0.3 * 255).round()),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildResults(ScrollController controller) {
    if (_loading && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      );
    }

    if (_results.isEmpty) {
      return const Center(child: Text('No results'));
    }

    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final node = _results[index];
        return ListTile(
          leading: Icon(
            _iconForNode(node),
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          title: Text(node.name),
          onTap: () => _select(node),
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
