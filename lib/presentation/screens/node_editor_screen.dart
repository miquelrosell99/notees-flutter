import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/utils/ast_builder.dart';
import '../../data/models/node.dart';
import '../../data/models/property.dart';
import '../../data/repositories/comment_repository.dart';
import '../../data/repositories/node_repository.dart';
import '../providers/auth_provider.dart';
import '../widgets/comments_bottom_sheet.dart';
import '../widgets/editor_inline_toolbar.dart';
import '../widgets/find_in_page_sheet.dart';
import '../widgets/fleet_card.dart';
import '../widgets/mention_picker.dart';
import '../widgets/node_picker.dart';
import '../widgets/property_value_cell.dart';
import '../widgets/shares_bottom_sheet.dart';
import '../widgets/slash_command_palette.dart';

/// Native page editor with lightweight Markdown-like block editing.
///
/// Supports inline styles (bold, italic, etc.), node/class/tag links, slash
/// commands, @ mentions, and find-in-page. System classes (code, asset, table,
/// callouts) are rendered with distinct chrome but edited as plain text.
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
  final _findState = ValueNotifier(FindState());

  List<NodePropertyValue> _properties = [];
  Map<int, String> _classNames = {};
  final Set<int> _deletedBlockIds = {};
  bool _loading = true;
  bool _saving = false;
  String? _error;
  int? _focusedBlockIndex;
  PersistentBottomSheetController? _findController;
  List<int> _findMatches = [];
  int _findMatchIndex = -1;
  int _commentCount = 0;

  @override
  void initState() {
    super.initState();
    _loadPage();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _scrollController.dispose();
    _findController?.close();
    _findState.dispose();
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
      final pageContent = await repo.fetchPageContent(widget.nodeId);
      final page = pageContent.node;
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
        _titleController.text = page.displayName.isNotEmpty ? page.displayName : 'Untitled';
        _properties = properties;
        _classNames = classNames;
        _deletedBlockIds.clear();
        _error = null;
      });
      if (mounted) {
        await _loadCommentCount();
      }
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final body = e.response?.data;
      setState(() => _error = 'Server error ${status ?? ""}\n$body\n${e.message}');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _loadCommentCount() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    try {
      final repo = CommentRepository(dio: auth.dio!);
      final count = await repo.fetchCommentCount(widget.nodeId);
      if (mounted) setState(() => _commentCount = count);
    } catch (_) {
      if (mounted) setState(() => _commentCount = 0);
    }
  }

  Future<void> _openComments() async {
    await CommentsBottomSheet.show(context, nodeId: widget.nodeId);
    if (mounted) await _loadCommentCount();
  }

  void _openShareSheet() {
    SharesBottomSheet.show(context, nodeId: widget.nodeId);
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

  Future<void> _onToolbarAction(EditorAction action) async {
    switch (action) {
      case EditorAction.slash:
        await _onSlashTriggered();
        return;
      case EditorAction.mention:
        await _onMentionTriggered();
        return;
      default:
        break;
    }

    final index = _focusedBlockIndex;
    if (index == null || index >= _blocks.length) return;

    await _applyEditorAction(_blocks[index], action);
  }

  Future<void> _applyEditorAction(_BlockEditor editor, EditorAction action) async {
    final controller = editor.controller;
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
      case EditorAction.underline:
        wrap('__');
      case EditorAction.strikethrough:
        wrap('~~');
      case EditorAction.code:
        wrap('`');
      case EditorAction.highlight:
        wrap('==');
      case EditorAction.heading1:
        _applyHeading(controller, 1);
      case EditorAction.heading2:
        _applyHeading(controller, 2);
      case EditorAction.heading3:
        _applyHeading(controller, 3);
      case EditorAction.link:
      case EditorAction.classLink:
      case EditorAction.tagLink:
      case EditorAction.image:
      case EditorAction.property:
      case EditorAction.template:
        await _insertNodeLink(editor, action);
      case EditorAction.task:
        final cursor = selection.isValid ? selection.start : 0;
        const replacement = '- [ ] ';
        final newText = text.replaceRange(cursor, cursor, replacement);
        controller
          ..text = newText
          ..selection = TextSelection.collapsed(offset: cursor + replacement.length);
      case EditorAction.table:
        final cursor = selection.isValid ? selection.start : 0;
        const replacement = '| Header | Header |\n| --- | --- |\n| Cell | Cell |';
        final newText = text.replaceRange(cursor, cursor, replacement);
        controller
          ..text = newText
          ..selection = TextSelection.collapsed(offset: cursor + replacement.length);
      case EditorAction.slash:
      case EditorAction.mention:
      case EditorAction.audio:
        // Handled before this method is called.
        return;
    }
  }

  void _applyHeading(TextEditingController controller, int level) {
    final text = controller.text;
    final selection = controller.selection;
    final prefix = '${'#' * level} ';
    final cursor = selection.isValid ? selection.start : 0;
    var lineStart = text.lastIndexOf('\n', cursor == 0 ? 0 : cursor - 1);
    lineStart = lineStart == -1 ? 0 : lineStart + 1;
    final afterLineStart = text.substring(lineStart);
    final existing = RegExp(r'^#{1,6}\s*').firstMatch(afterLineStart);
    String newText;
    int newOffset;
    if (existing != null) {
      newText = text.replaceRange(lineStart, lineStart + existing.end, prefix);
      newOffset = cursor - existing.end + prefix.length;
    } else {
      newText = text.replaceRange(lineStart, lineStart, prefix);
      newOffset = cursor + prefix.length;
    }
    controller
      ..text = newText
      ..selection = TextSelection.collapsed(offset: newOffset.clamp(0, newText.length));
  }

  Future<void> _insertNodeLink(_BlockEditor editor, EditorAction action) async {
    final mode = action == EditorAction.classLink
        ? NodePickerMode.classNode
        : action == EditorAction.tagLink
            ? NodePickerMode.tag
            : NodePickerMode.any;
    if (!mounted) return;
    final node = await NodePicker.show(context, mode: mode);
    if (node == null) return;

    final controller = editor.controller;
    final text = controller.text;
    final selection = controller.selection;
    final open = action == EditorAction.classLink ? '{{' : '[[';
    final close = action == EditorAction.classLink ? '}}' : ']]';
    final replacement = '$open${node.uuid}|${node.displayName}$close';
    final newText = text.replaceRange(selection.start, selection.end, replacement);
    final newOffset = selection.start + replacement.length;
    controller
      ..text = newText
      ..selection = TextSelection.collapsed(offset: newOffset);
  }

  Future<void> _onSlashTriggered([int? triggeredIndex]) async {
    final index = triggeredIndex ?? _focusedBlockIndex;
    if (index == null || index >= _blocks.length) return;

    setState(() => _focusedBlockIndex = index);
    final action = await SlashCommandPalette.show(context);
    if (!mounted || action == null) return;

    final editor = _blocks[index];
    final controller = editor.controller;
    final text = controller.text;
    final selection = controller.selection;
    final cursor = selection.isValid ? selection.start : 0;
    if (cursor > 0 && text.substring(cursor - 1, cursor) == '/') {
      final newText = text.replaceRange(cursor - 1, cursor, '');
      controller
        ..text = newText
        ..selection = TextSelection.collapsed(offset: (cursor - 1).clamp(0, newText.length));
    }

    await _applyEditorAction(editor, action);
  }

  Future<void> _onMentionTriggered([int? triggeredIndex]) async {
    final index = triggeredIndex ?? _focusedBlockIndex;
    if (index == null || index >= _blocks.length) return;

    setState(() => _focusedBlockIndex = index);
    final result = await MentionPicker.show(context);
    if (!mounted || result == null) return;

    final editor = _blocks[index];
    final controller = editor.controller;
    final text = controller.text;
    final selection = controller.selection;
    final cursor = selection.isValid ? selection.start : 0;

    final replacement = result.isUser
        ? '@${result.displayName}'
        : '[[${result.target}|${result.displayName}]]';

    final String newText;
    final int newOffset;
    if (cursor > 0 && text.substring(cursor - 1, cursor) == '@') {
      newText = text.replaceRange(cursor - 1, cursor, replacement);
      newOffset = cursor - 1 + replacement.length;
    } else {
      newText = text.replaceRange(selection.start, selection.end, replacement);
      newOffset = selection.start + replacement.length;
    }
    controller
      ..text = newText
      ..selection = TextSelection.collapsed(offset: newOffset.clamp(0, newText.length));
  }

  void _openFindSheet() {
    _findController?.close();
    _findController = FindInPageSheet.show(
      context: context,
      stateNotifier: _findState,
      onQueryChanged: _updateFindQuery,
      onPrevious: _findPrevious,
      onNext: _findNext,
    );
  }

  void _updateFindQuery(String query) {
    final lower = query.toLowerCase();
    final matches = lower.isEmpty
        ? <int>[]
        : _blocks
            .asMap()
            .entries
            .where((e) => e.value.controller.text.toLowerCase().contains(lower))
            .map((e) => e.key)
            .toList();
    _findMatchIndex = matches.isEmpty ? -1 : 0;
    _findMatches = matches;
    _findState.value = FindState(query: query, matchCount: matches.length, currentIndex: _findMatchIndex);
    setState(() {});
    _jumpToCurrentMatch();
  }

  void _findNext() {
    if (_findMatches.isEmpty) return;
    _findMatchIndex = (_findMatchIndex + 1) % _findMatches.length;
    _findState.value = _findState.value.copyWith(currentIndex: _findMatchIndex);
    setState(() {});
    _jumpToCurrentMatch();
  }

  void _findPrevious() {
    if (_findMatches.isEmpty) return;
    _findMatchIndex = (_findMatchIndex - 1 + _findMatches.length) % _findMatches.length;
    _findState.value = _findState.value.copyWith(currentIndex: _findMatchIndex);
    setState(() {});
    _jumpToCurrentMatch();
  }

  void _jumpToCurrentMatch() {
    if (_findMatchIndex < 0 || _findMatchIndex >= _findMatches.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollController.animateTo(
        _scrollController.offset,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final keyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit page'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Find in page',
            onPressed: _openFindSheet,
          ),
          IconButton(
            icon: Badge(
              isLabelVisible: _commentCount > 0,
              label: Text('$_commentCount'),
              child: const Icon(Icons.chat_bubble_outline),
            ),
            tooltip: 'Comments',
            onPressed: _openComments,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'More options',
            onSelected: (value) {
              if (value == 'share') _openShareSheet();
            },
            itemBuilder: (context) => [
              const PopupMenuItem<String>(
                value: 'share',
                child: Row(
                  children: [
                    Icon(Icons.share_outlined),
                    SizedBox(width: 12),
                    Text('Share'),
                  ],
                ),
              ),
            ],
          ),
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
                          final isMatch = _findState.value.query.isNotEmpty &&
                              editor.controller.text.toLowerCase().contains(_findState.value.query.toLowerCase());
                          final isCurrent = isMatch && _findMatches.isNotEmpty && _findMatches[_findMatchIndex] == index;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _BlockEditorTile(
                              editor: editor,
                              classNames: _classNames,
                              isFindMatch: isMatch,
                              isCurrentFindMatch: isCurrent,
                              onFocus: () => setState(() => _focusedBlockIndex = index),
                              onDelete: () => _deleteBlock(index),
                              onSlashTrigger: () => _onSlashTriggered(index),
                              onMentionTrigger: () => _onMentionTriggered(index),
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
                            'Native editor — use **bold**, *italic*, [[uuid|name]] links, / for commands, @ to mention.',
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
    this.isFindMatch = false,
    this.isCurrentFindMatch = false,
    this.onSlashTrigger,
    this.onMentionTrigger,
  });

  final _BlockEditor editor;
  final Map<int, String> classNames;
  final VoidCallback onFocus;
  final VoidCallback onDelete;
  final bool isFindMatch;
  final bool isCurrentFindMatch;
  final VoidCallback? onSlashTrigger;
  final VoidCallback? onMentionTrigger;

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
      onChanged: _onChanged,
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

    Widget card = FleetCard(
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

    if (isFindMatch) {
      card = Container(
        decoration: BoxDecoration(
          color: isCurrentFindMatch
              ? colors.primaryContainer.withAlpha((0.45 * 255).round())
              : colors.tertiaryContainer.withAlpha((0.35 * 255).round()),
          borderRadius: BorderRadius.circular(12),
          border: isCurrentFindMatch ? Border.all(color: colors.primary, width: 1.5) : null,
        ),
        child: card,
      );
    }

    return card;
  }

  void _onChanged(String value) {
    final controller = editor.controller;
    final selection = controller.selection;
    if (!selection.isValid || !selection.isCollapsed) return;
    final cursor = selection.baseOffset.clamp(0, value.length);
    if (cursor == 1 && value == '/') {
      onSlashTrigger?.call();
      return;
    }
    if (cursor > 0 && value.substring(cursor - 1, cursor) == '@') {
      if (cursor == 1 || RegExp(r'\s').hasMatch(value[cursor - 2])) {
        onMentionTrigger?.call();
      }
    }
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
