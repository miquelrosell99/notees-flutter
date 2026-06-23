import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/ast_stringifier.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_repository.dart';
import '../providers/auth_provider.dart';
import '../widgets/fleet_card.dart';

/// Native page editor.
///
/// Edits the page title and body as plain text. Body lines are mapped 1:1 to
/// paragraph blocks. The editor intentionally does not preserve inline markup
/// (bold, links, etc.) — it is a lightweight, offline-friendly editing surface
/// rather than a full Lexical replacement.
class NodeEditorScreen extends StatefulWidget {
  const NodeEditorScreen({super.key, required this.nodeId});

  final int nodeId;

  @override
  State<NodeEditorScreen> createState() => _NodeEditorScreenState();
}

class _NodeEditorScreenState extends State<NodeEditorScreen> {
  final _titleController = TextEditingController();
  final _bodyController = TextEditingController();
  final _scrollController = ScrollController();

  Node? _page;
  List<Node> _blocks = [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPage();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadPage() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!);
      final page = await repo.fetchPageContent(widget.nodeId);
      final blocks = page.children.where((b) => !b.isPage).toList();
      final bodyLines = blocks.map((b) => astToPlainText(b.name)).toList();

      setState(() {
        _page = page;
        _blocks = blocks;
        _titleController.text = page.displayName;
        _bodyController.text = bodyLines.join('\n');
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    final title = _titleController.text.trim();
    final bodyLines = _bodyController.text.split('\n');

    setState(() => _saving = true);
    try {
      final repo = NodeRepository(dio: auth.dio!);

      // Update the page title.
      await repo.updateNode(widget.nodeId, name: title);

      // Map edited lines back to blocks.
      final updates = <Map<String, dynamic>>[];
      final creates = <Map<String, dynamic>>[];
      final deletions = <int>[];

      for (var i = 0; i < bodyLines.length; i++) {
        final text = bodyLines[i].trimRight();
        if (i < _blocks.length) {
          updates.add({
            'id': _blocks[i].id,
            'name': _buildParagraphAst(text),
            'sequence': i.toDouble(),
          });
        } else {
          creates.add({
            'parent_id': widget.nodeId,
            'name': _buildParagraphAst(text),
            'sequence': i.toDouble(),
          });
        }
      }

      for (var i = bodyLines.length; i < _blocks.length; i++) {
        deletions.add(_blocks[i].id);
      }

      if (updates.isNotEmpty) {
        await repo.batchUpdateNodes(updates);
      }
      if (creates.isNotEmpty) {
        await repo.batchCreateNodes(creates);
      }
      for (final id in deletions) {
        await repo.deleteNode(id);
      }

      await _loadPage();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved')),
        );
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _saving = false);
    }
  }

  String _buildParagraphAst(String text) {
    return jsonEncode([
      {
        'type': 'paragraph',
        'children': [
          {'type': 'text', 'text': text},
        ],
      },
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit page'),
        actions: [
          if (_saving)
            const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.check),
              tooltip: 'Save',
              onPressed: _save,
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadPage,
              child: ListView(
                controller: _scrollController,
                padding: const EdgeInsets.all(20),
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: FleetCard(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            _error!,
                            style: TextStyle(color: colors.error),
                          ),
                        ),
                      ),
                    ),
                  FleetCard(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: _titleController,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                        decoration: const InputDecoration(
                          hintText: 'Page title',
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 16),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  FleetCard(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: TextField(
                        controller: _bodyController,
                        maxLines: 12,
                        minLines: 12,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        decoration: const InputDecoration(
                          hintText: 'Start writing...',
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Center(
                    child: Text(
                      'Native editor — basic plain-text editing only.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
