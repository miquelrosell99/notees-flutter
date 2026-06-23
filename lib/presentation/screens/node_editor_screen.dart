import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/utils/ast_builder.dart';
import '../../data/models/node.dart';
import '../../data/models/property.dart';
import '../../data/repositories/node_repository.dart';
import '../providers/auth_provider.dart';
import '../widgets/editor_inline_toolbar.dart';
import '../widgets/fleet_card.dart';
import '../widgets/node_picker.dart';
import '../widgets/property_value_cell.dart';

/// Native page editor with lightweight Markdown-like block editing.
///
/// Supports inline styles (bold, italic, etc.), node/class/tag links, and a
/// read-only properties panel. System classes (code, asset, table, callouts)
/// are rendered with distinct chrome but edited as plain text.
class NodeEditorScreen extends StatefulWidget {
  const NodeEditorScreen({super.key, required this.nodeId});

  final int nodeId;

  @override
  State<NodeEditorScreen> createState() => _NodeEditorScreenState();
}

class _BlockEditor {
  _BlockEditor({required this.node, required this.controller});

  final Node node;
  final TextEditingController controller;
}

class _NodeEditorScreenState extends State<NodeEditorScreen> {
  final _titleController = TextEditingController();
  final _scrollController = ScrollController();
  final List<_BlockEditor> _blocks = [];

  List<NodePropertyValue> _properties = [];
  Map<int, String> _classNames = {};
  final Set<int> _deletedBlockIds = {};
  bool _loading = true;
  bool _saving = false;
  String? _error;
  int? _focusedBlockIndex;

  @override
  void initState() {
    super.initState();
    _loadPage();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _scrollController.dispose();
    for (final b in _blocks) {
      b.controller.dispose();
    }
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

      for (final b in _blocks) {
        b.controller.dispose();
      }
      _blocks.clear();

      for (final block in blocks) {
        final ast = _tryParseAst(block.name);
        final markdown = AstBuilder.toMarkdown(ast);
        _blocks.add(_BlockEditor(
          node: block,
          controller: TextEditingController(text: markdown),
        ));
      }

      final properties = await repo.fetchNodeProperties(widget.nodeId);
      final classes = await repo.fetchClasses();
      final classNames = {
        for (final c in classes)
          if (c.id > 0) c.id: c.displayName.toLowerCase(),
      };

      setState(() {
        _titleController.text = page.displayName;
        _properties = properties;
        _classNames = classNames;
        _deletedBlockIds.clear();
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> _tryParseAst(String name) {
    try {
      final parsed = jsonDecode(name);
      if (parsed is List) {
        return parsed.cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    return AstBuilder.parseInline(name);
  }

  Future<void> _save() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    final title = _titleController.text.trim();

    setState(() => _saving = true);
    try {
      final repo = NodeRepository(dio: auth.dio!);

      final titleAst = AstBuilder.serialize(AstBuilder.parseInline(title));
      await repo.updateNode(widget.nodeId, name: titleAst);

      final updates = <Map<String, dynamic>>[];
      final creates = <Map<String, dynamic>>[];

      for (var i = 0; i < _blocks.length; i++) {
        final editor = _blocks[i];
        final text = editor.controller.text;
        final ast = AstBuilder.parseInline(text);
        final astJson = AstBuilder.serialize(ast);

        if (editor.node.id > 0) {
          updates.add({
            'id': editor.node.id,
            'name': astJson,
            'sequence': i.toDouble(),
          });
        } else {
          creates.add({
            'parent_id': widget.nodeId,
            'name': astJson,
            'sequence': i.toDouble(),
          });
        }
      }

      if (updates.isNotEmpty) {
        await repo.batchUpdateNodes(updates);
      }
      if (creates.isNotEmpty) {
        await repo.batchCreateNodes(creates);
      }
      for (final id in _deletedBlockIds) {
        await repo.deleteNode(id);
      }
      _deletedBlockIds.clear();

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

  void _addBlock() {
    HapticFeedback.lightImpact();
    setState(() {
      _blocks.add(_BlockEditor(
        node: Node(
          id: 0,
          uuid: '',
          name: '',
          displayName: '',
        ),
        controller: TextEditingController(),
      ));
    });
  }

  void _deleteBlock(int index) {
    HapticFeedback.lightImpact();
    setState(() {
      final editor = _blocks.removeAt(index);
      if (editor.node.id > 0) {
        _deletedBlockIds.add(editor.node.id);
      }
      editor.controller.dispose();
    });
  }

  void _onToolbarAction(EditorAction action) async {
    final index = _focusedBlockIndex;
    if (index == null || index >= _blocks.length) return;

    final controller = _blocks[index].controller;
    final text = controller.text;
    final selection = controller.selection;

    String wrap(String marker, {String? defaultText}) {
      final selected = selection.isValid && !selection.isCollapsed
          ? text.substring(selection.start, selection.end)
          : defaultText ?? marker;
      final replacement = '$marker$selected$marker';
      final newText = text.replaceRange(selection.start, selection.end, replacement);
      final newOffset = selection.start + replacement.length;
      controller
        ..text = newText
        ..selection = TextSelection.collapsed(offset: newOffset);
      return newText;
    }

    switch (action) {
      case EditorAction.bold:
        wrap('**');
      case EditorAction.italic:
        wrap('*');
      case EditorAction.strikethrough:
        wrap('~~');
      case EditorAction.code:
        wrap('`');
      case EditorAction.highlight:
        wrap('==');
      case EditorAction.link:
      case EditorAction.classLink:
      case EditorAction.tagLink:
        final mode = action == EditorAction.classLink
            ? NodePickerMode.classNode
            : action == EditorAction.tagLink
                ? NodePickerMode.tag
                : NodePickerMode.any;
        final node = await NodePicker.show(context, mode: mode);
        if (node == null) return;
        final open = action == EditorAction.classLink ? '{{' : '[[';
        final close = action == EditorAction.classLink ? '}}' : ']]';
        final replacement = '$open${node.uuid}|${node.displayName}$close';
        final newText = text.replaceRange(selection.start, selection.end, replacement);
        final newOffset = selection.start + replacement.length;
        controller
          ..text = newText
          ..selection = TextSelection.collapsed(offset: newOffset);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final keyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;

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
          : Column(
              children: [
                Expanded(
                  child: RefreshIndicator(
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
                        _buildTitleField(),
                        const SizedBox(height: 20),
                        ..._blocks.asMap().entries.map((entry) {
                          final index = entry.key;
                          final editor = entry.value;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _BlockEditorTile(
                              editor: editor,
                              classNames: _classNames,
                              onFocus: () => setState(() => _focusedBlockIndex = index),
                              onDelete: () => _deleteBlock(index),
                            ),
                          );
                        }),
                        TextButton.icon(
                          onPressed: _addBlock,
                          icon: const Icon(Icons.add),
                          label: const Text('Add block'),
                        ),
                        const SizedBox(height: 20),
                        _buildPropertiesSection(colors),
                        const SizedBox(height: 24),
                        Center(
                          child: Text(
                            'Native editor — use **bold**, *italic*, [[uuid|name]] links, etc.',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (keyboardVisible)
                  EditorInlineToolbar(onAction: _onToolbarAction),
              ],
            ),
    );
  }

  Widget _buildTitleField() {
    return FleetCard(
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
    );
  }

  Widget _buildPropertiesSection(ColorScheme colors) {
    if (_properties.isEmpty) return const SizedBox.shrink();

    return FleetCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Properties',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 12),
            ..._properties.map((p) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: PropertyValueCell(
                  property: p.property,
                  values: p.values,
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _BlockEditorTile extends StatelessWidget {
  // ignore: prefer_const_constructors_in_immutables
  _BlockEditorTile({
    required this.editor,
    required this.classNames,
    required this.onFocus,
    required this.onDelete,
  });

  final _BlockEditor editor;
  final Map<int, String> classNames;
  final VoidCallback onFocus;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isCode = editor.node.isTable || _hasSystemClass(editor.node, 'code');
    final calloutColor = _calloutColor(editor.node, colors);

    Widget field = TextField(
      controller: editor.controller,
      maxLines: null,
      minLines: 1,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      style: isCode
          ? TextStyle(
              fontFamily: 'monospace',
              fontFamilyFallback: const ['monospace'],
              color: colors.onSurface,
            )
          : null,
      decoration: InputDecoration(
        hintText: _hintForBlock(editor.node),
        border: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      onTap: onFocus,
    );

    if (calloutColor != null) {
      field = Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: calloutColor, width: 4)),
          color: calloutColor.withAlpha((0.08 * 255).round()),
          borderRadius: BorderRadius.circular(8),
        ),
        child: field,
      );
    }

    return FleetCard(
      child: Row(
        children: [
          Expanded(child: field),
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () {
              showModalBottomSheet(
                context: context,
                builder: (ctx) => SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.delete_outline),
                        title: const Text('Delete block'),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          onDelete();
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  String _hintForBlock(Node node) {
    if (node.isTable) return 'Table block';
    if (node.isAsset) return 'Asset block';
    if (_hasSystemClass(node, 'code')) return 'Code block';
    return 'Start writing...';
  }

  Color? _calloutColor(Node node, ColorScheme colors) {
    if (_hasSystemClass(node, 'warning')) return Colors.orange;
    if (_hasSystemClass(node, 'danger')) return colors.error;
    if (_hasSystemClass(node, 'success')) return Colors.green;
    if (_hasSystemClass(node, 'info')) return Colors.blue;
    if (_hasSystemClass(node, 'tip')) return Colors.teal;
    if (_hasSystemClass(node, 'quote')) return colors.outline;
    return null;
  }

  bool _hasSystemClass(Node node, String name) {
    final needle = name.toLowerCase();
    for (final classId in node.classes) {
      if (classNames[classId] == needle) return true;
    }
    return false;
  }
}
