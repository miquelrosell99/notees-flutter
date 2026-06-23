import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/models/node.dart';
import '../../data/repositories/node_repository.dart';
import '../providers/auth_provider.dart';

/// Modes for the node picker.
enum NodePickerMode {
  any,
  page,
  classNode,
  tag,
}

/// Bottom-sheet picker for selecting a node (page, class, tag, or any node).
class NodePicker extends StatefulWidget {
  const NodePicker({
    super.key,
    required this.mode,
  });

  final NodePickerMode mode;

  static Future<Node?> show(BuildContext context, {NodePickerMode mode = NodePickerMode.any}) {
    return showModalBottomSheet<Node>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.65,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => NodePicker(mode: mode),
      ),
    );
  }

  @override
  State<NodePicker> createState() => _NodePickerState();
}

class _NodePickerState extends State<NodePicker> {
  final _controller = TextEditingController();
  List<Node> _results = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!);
      final query = _controller.text.trim();
      List<Node> results;

      switch (widget.mode) {
        case NodePickerMode.classNode:
          results = await repo.fetchClasses();
          if (query.isNotEmpty) {
            final lower = query.toLowerCase();
            results = results
                .where((n) => n.displayName.toLowerCase().contains(lower))
                .toList();
          }
        case NodePickerMode.tag:
          results = [];
        case NodePickerMode.page:
        case NodePickerMode.any:
          if (query.isEmpty) {
            results = await repo.fetchRecentPages(limit: 20);
          } else {
            results = await repo.searchNodes(query, limit: 20);
          }
          if (widget.mode == NodePickerMode.page) {
            results = results.where((n) => n.isPage).toList();
          }
      }

      setState(() {
        _results = results;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  void _select(Node node) {
    HapticFeedback.lightImpact();
    Navigator.of(context).pop(node);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Select a node',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Search...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: colors.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
              onSubmitted: (_) => _search(),
              onChanged: (_) => _search(),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!, style: TextStyle(color: colors.error)),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final node = _results[index];
                      return ListTile(
                        leading: Icon(
                          node.isTask ? Icons.check_circle_outline : Icons.description_outlined,
                          color: colors.onSurfaceVariant,
                        ),
                        title: Text(node.displayName),
                        onTap: () => _select(node),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
