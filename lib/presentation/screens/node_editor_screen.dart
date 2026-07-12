import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/routing/router.dart';
import '../../core/utils/ast_builder.dart';
import '../../core/utils/color_presets.dart';
import '../../core/utils/node_icon.dart';
import '../../data/models/breadcrumb_item.dart';
import '../../data/models/linked_reference.dart';
import '../../data/models/node.dart';
import '../../data/models/property.dart';
import '../../data/repositories/comment_repository.dart';
import '../../data/repositories/node_repository.dart';
import '../providers/auth_provider.dart';
import '../widgets/block_tree_editor.dart';
import '../widgets/comments_bottom_sheet.dart';
import '../widgets/editor_inline_toolbar.dart';
import '../widgets/fleet_card.dart';
import '../widgets/mention_picker.dart';
import '../widgets/node_picker.dart';
import '../widgets/property_value_cell.dart';
import '../widgets/shares_bottom_sheet.dart';
import '../widgets/slash_command_palette.dart';

/// Native page editor with a web-app-like bullet tree and breadcrumbs.
///
/// Child blocks are rendered as a nested, collapsible bullet list (via
/// [BlockTreeEditor]). The title sits above the tree, and breadcrumbs sit
/// below the app bar. Inline styles, node/class/tag links, slash commands and
/// @ mentions are supported.
class NodeEditorScreen extends StatefulWidget {
  const NodeEditorScreen({super.key, required this.nodeUuid});

  final String nodeUuid;

  @override
  State<NodeEditorScreen> createState() => _NodeEditorScreenState();
}

class _NodeEditorScreenState extends State<NodeEditorScreen> {
  final _titleController = TextEditingController();
  final _scrollController = ScrollController();
  final _blockTreeKey = GlobalKey<BlockTreeEditorState>();
  final List<BlockNode> _roots = [];

  List<BreadcrumbItem> _breadcrumbs = [];
  List<NodePropertyValue> _properties = [];
  Map<String, String> _classNames = {};
  Map<String, Color> _linkColors = {};
  String? _pageColor;
  String? _pageIcon;
  bool _pageIsPrivate = false;
  final Set<String> _deletedBlockUuids = {};
  bool _loading = true;
  bool _saving = false;
  String? _error;
  BlockNode? _focusedBlock;
  int _commentCount = 0;
  List<LinkedReference> _linkedReferences = [];
  int _linkedRefsTotal = 0;

  /// Autosave: edits mark the page dirty and debounce a background save.
  Timer? _autosaveTimer;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _titleController.addListener(_markDirty);
    _loadPage();
  }

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    _titleController.dispose();
    _scrollController.dispose();
    for (final block in _allBlocks()) {
      block.controller.dispose();
    }
    super.dispose();
  }

  /// Marks the page dirty and schedules a debounced autosave.
  void _markDirty() {
    if (_loading) return;
    _dirty = true;
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(const Duration(seconds: 2), _autosave);
  }

  void _autosave() {
    if (!_dirty || !mounted) return;
    if (_saving) {
      // A save is already in flight; retry shortly.
      _autosaveTimer = Timer(const Duration(seconds: 2), _autosave);
      return;
    }
    _save(manual: false);
  }

  Future<void> _loadPage() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      final pageContent = await repo.fetchPageContent(widget.nodeUuid);
      final page = pageContent.node;

      for (final block in _allBlocks()) {
        block.controller.dispose();
      }
      _roots.clear();
      _roots.addAll(_nodesToBlockTree(page.children.where((b) => !b.isPage).toList()));

      final properties = await repo.fetchNodeProperties(widget.nodeUuid);
      final classes = await repo.fetchClasses();
      final breadcrumbs = await repo.fetchBreadcrumbs(widget.nodeUuid);
      final classNames = {
        for (final c in classes)
          if (c.uuid.isNotEmpty) c.uuid: c.displayName.toLowerCase(),
      };

      // Data colors for link chips: the page's own blocks plus all classes.
      final linkColors = <String, Color>{};
      void collectColors(List<Node> nodes) {
        for (final n in nodes) {
          final color = ColorPresets.tryResolve(n.color);
          if (color != null) linkColors[n.uuid] = color;
          collectColors(n.children);
        }
      }
      collectColors(page.children);
      for (final c in classes) {
        final color = ColorPresets.tryResolve(c.color);
        if (color != null) linkColors[c.uuid] = color;
      }

      if (mounted) {
        setState(() {
          _titleController.text = page.displayName.isNotEmpty ? page.displayName : 'Untitled';
          _properties = properties;
          _classNames = classNames;
          _linkColors = linkColors;
          _pageColor = page.color;
          _pageIcon = page.icon;
          _pageIsPrivate = page.isPrivate;
          _breadcrumbs = breadcrumbs;
          _deletedBlockUuids.clear();
          _error = null;
          _focusedBlock = null;
        });
      }
      if (mounted) {
        await _loadCommentCount();
        await _loadLinkedReferences();
      }
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final body = e.response?.data;
      if (mounted) {
        setState(() => _error = 'Server error ${status ?? ""}\n$body\n${e.message}');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadCommentCount() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    try {
      final repo = CommentRepository(dio: auth.dio!);
      final count = await repo.fetchCommentCount(widget.nodeUuid);
      if (mounted) setState(() => _commentCount = count);
    } catch (_) {
      if (mounted) setState(() => _commentCount = 0);
    }
  }

  Future<void> _loadLinkedReferences() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      final result = await repo.fetchLinkedReferences(widget.nodeUuid);
      if (mounted) {
        setState(() {
          _linkedReferences = result.references;
          _linkedRefsTotal = result.totalCount;
        });
      }
    } catch (_) {
      // Non-critical: hide the section on failure.
      if (mounted) {
        setState(() {
          _linkedReferences = [];
          _linkedRefsTotal = 0;
        });
      }
    }
  }

  Future<void> _openComments() async {
    await CommentsBottomSheet.show(context, nodeUuid: widget.nodeUuid);
    if (mounted) await _loadCommentCount();
  }

  void _openShareSheet() {
    SharesBottomSheet.show(context, nodeUuid: widget.nodeUuid);
  }

  List<BlockNode> _nodesToBlockTree(List<Node> nodes, {BlockNode? parent, Set<String>? visited}) {
    visited ??= <String>{};
    final sorted = List<Node>.from(nodes)..sort((a, b) => a.sequence.compareTo(b.sequence));
    return sorted.map((node) {
      final ast = _tryParseAst(node.name);
      final markdown = AstBuilder.toMarkdown(ast);
      final block = BlockNode(
        node: node,
        controller: TextEditingController(text: markdown),
        parent: parent,
        collapsed: false,
      );
      // Guard against cyclic children in corrupt server data.
      if (visited!.add(node.uuid)) {
        block.children.addAll(_nodesToBlockTree(node.children, parent: block, visited: visited));
      }
      return block;
    }).toList();
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

  Future<void> _save({bool manual = true}) async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;
    if (_saving) return; // avoid overlapping saves

    final title = _titleController.text.trim();

    setState(() => _saving = true);
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);

      final titleAst = AstBuilder.serialize(AstBuilder.parseInline(title));
      await repo.updateNode(widget.nodeUuid, name: titleAst);

      // Ensure every focused block's AST is synced before serializing.
      _syncAllBlockNames();

      final updates = <Map<String, dynamic>>[];
      final creates = <Map<String, dynamic>>[];

      _assignSequences(_roots, 0);
      _collectWrites(_roots, updates, creates);

      if (updates.isNotEmpty) {
        await repo.batchUpdateNodes(updates);
      }
      if (creates.isNotEmpty) {
        final created = await repo.batchCreateNodes(creates);
        _assignCreatedUuids(_roots, created);
      }
      for (final uuid in _deletedBlockUuids) {
        await repo.deleteNode(uuid);
      }
      _deletedBlockUuids.clear();
      _dirty = false;

      // Autosaves must not reload the page: that would steal focus and
      // rebuild the block controllers while the user is typing.
      if (manual && mounted) await _loadPage();
      if (manual && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved')),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
      if (!manual && mounted) {
        // Stay dirty and retry in the background.
        _autosaveTimer?.cancel();
        _autosaveTimer = Timer(const Duration(seconds: 5), _autosave);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _syncAllBlockNames() {
    for (final block in _allBlocks()) {
      final ast = AstBuilder.parseInline(block.controller.text);
      block.node = _copyNodeWithName(block.node, AstBuilder.serialize(ast));
    }
  }

  double _assignSequences(List<BlockNode> nodes, double start) {
    var sequence = start;
    for (final node in nodes) {
      node.node = _copyNodeWithSequence(node.node, sequence);
      sequence += 1.0;
      if (node.children.isNotEmpty) {
        sequence = _assignSequences(node.children, sequence);
      }
    }
    return sequence;
  }

  void _collectWrites(
    List<BlockNode> nodes,
    List<Map<String, dynamic>> updates,
    List<Map<String, dynamic>> creates,
  ) {
    for (final block in nodes) {
      final parentUuid = block.parent?.node.uuid ?? widget.nodeUuid;
      final astJson = block.node.name;
      if (block.node.uuid.isNotEmpty) {
        updates.add({
          'uuid': block.node.uuid,
          'name': astJson,
          'sequence': block.node.sequence,
          'parent_uuid': parentUuid,
          'collapsed': block.collapsed,
        });
      } else {
        creates.add({
          'parent_uuid': parentUuid,
          'name': astJson,
          'sequence': block.node.sequence,
        });
      }
      _collectWrites(block.children, updates, creates);
    }
  }

  void _assignCreatedUuids(List<BlockNode> nodes, List<Node> created) {
    var index = 0;
    void visit(List<BlockNode> list) {
      for (final node in list) {
        if (node.node.uuid.isEmpty && index < created.length) {
          node.node = _copyNodeWithId(node.node, created[index].id, created[index].uuid);
          index++;
        }
        visit(node.children);
      }
    }
    visit(nodes);
  }

  Node _copyNodeWithId(Node node, int id, String uuid) {
    return Node(
      id: id,
      uuid: uuid,
      name: node.name,
      displayName: node.displayName,
      icon: node.icon,
      color: node.color,
      parentUuid: node.parentUuid,
      pageUuid: node.pageUuid,
      sequence: node.sequence,
      isPage: node.isPage,
      isTask: node.isTask,
      isDaily: node.isDaily,
      isMonthly: node.isMonthly,
      isYearly: node.isYearly,
      isTable: node.isTable,
      isAsset: node.isAsset,
      isComment: node.isComment,
      isPrivate: node.isPrivate,
      classes: node.classes,
      tags: node.tags,
      properties: node.properties,
      children: node.children,
      createDate: node.createDate,
      writeDate: node.writeDate,
    );
  }

  Node _copyNodeWithName(Node node, String name) {
    return Node(
      id: node.id,
      uuid: node.uuid,
      name: name,
      displayName: node.displayName,
      icon: node.icon,
      color: node.color,
      parentUuid: node.parentUuid,
      pageUuid: node.pageUuid,
      sequence: node.sequence,
      isPage: node.isPage,
      isTask: node.isTask,
      isDaily: node.isDaily,
      isMonthly: node.isMonthly,
      isYearly: node.isYearly,
      isTable: node.isTable,
      isAsset: node.isAsset,
      isComment: node.isComment,
      isPrivate: node.isPrivate,
      classes: node.classes,
      tags: node.tags,
      properties: node.properties,
      children: node.children,
      createDate: node.createDate,
      writeDate: node.writeDate,
    );
  }

  Node _copyNodeWithSequence(Node node, double sequence) {
    return Node(
      id: node.id,
      uuid: node.uuid,
      name: node.name,
      displayName: node.displayName,
      icon: node.icon,
      color: node.color,
      parentUuid: node.parentUuid,
      pageUuid: node.pageUuid,
      sequence: sequence,
      isPage: node.isPage,
      isTask: node.isTask,
      isDaily: node.isDaily,
      isMonthly: node.isMonthly,
      isYearly: node.isYearly,
      isTable: node.isTable,
      isAsset: node.isAsset,
      isComment: node.isComment,
      isPrivate: node.isPrivate,
      classes: node.classes,
      tags: node.tags,
      properties: node.properties,
      children: node.children,
      createDate: node.createDate,
      writeDate: node.writeDate,
    );
  }

  void _addBlock() {
    HapticFeedback.lightImpact();
    final newBlock = BlockNode(
      node: Node(id: 0, uuid: '', name: '', displayName: ''),
      controller: TextEditingController(),
      parent: null,
      isNew: true,
    );
    setState(() {
      _roots.add(newBlock);
      _focusedBlock = newBlock;
    });
    _markDirty();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _blockTreeKey.currentState?.requestFocusFor(newBlock);
    });
  }

  void _onAddChild(BlockNode parent) {
    if (parent.node.uuid.isEmpty) return;
    HapticFeedback.lightImpact();
    final newBlock = BlockNode(
      node: Node(id: 0, uuid: '', name: '', displayName: ''),
      controller: TextEditingController(),
      parent: parent,
      isNew: true,
    );
    setState(() {
      parent.collapsed = false;
      parent.children.add(newBlock);
      _focusedBlock = newBlock;
    });
    _markDirty();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _blockTreeKey.currentState?.requestFocusFor(newBlock);
    });
  }

  void _onDelete(BlockNode block) {
    HapticFeedback.lightImpact();
    setState(() {
      if (block.node.uuid.isNotEmpty) {
        _deletedBlockUuids.add(block.node.uuid);
      }
      _removeBlockFromTree(block);
      if (_focusedBlock == block) {
        _focusedBlock = null;
      }
      block.controller.dispose();
    });
    _markDirty();
  }

  void _removeBlockFromTree(BlockNode block) {
    if (block.parent == null) {
      _roots.remove(block);
    } else {
      block.parent!.children.remove(block);
    }
  }

  void _onIndent(BlockNode block) {
    HapticFeedback.lightImpact();
    final siblings = block.parent?.children ?? _roots;
    final index = siblings.indexOf(block);
    if (index <= 0) return;

    final newParent = siblings[index - 1];
    setState(() {
      siblings.removeAt(index);
      block.parent = newParent;
      newParent.children.add(block);
      newParent.collapsed = false;
    });
    _markDirty();
  }

  void _onOutdent(BlockNode block) {
    HapticFeedback.lightImpact();
    final parent = block.parent;
    if (parent == null) return;

    final grandparent = parent.parent;
    final siblings = grandparent?.children ?? _roots;
    final parentIndex = siblings.indexOf(parent);
    if (parentIndex < 0) return;

    setState(() {
      parent.children.remove(block);
      block.parent = grandparent;
      siblings.insert(parentIndex + 1, block);
    });
    _markDirty();
  }

  void _onMove(BlockNode moved, BlockNode target, DropPosition position) {
    HapticFeedback.lightImpact();
    setState(() {
      _removeBlockFromTree(moved);
      switch (position) {
        case DropPosition.before:
          moved.parent = target.parent;
          final siblings = target.parent?.children ?? _roots;
          siblings.insert(siblings.indexOf(target), moved);
        case DropPosition.after:
          moved.parent = target.parent;
          final siblings = target.parent?.children ?? _roots;
          siblings.insert(siblings.indexOf(target) + 1, moved);
        case DropPosition.child:
          moved.parent = target;
          target.children.add(moved);
          target.collapsed = false;
      }
    });
    _markDirty();
  }

  void _onToggleCollapse(BlockNode block) {
    HapticFeedback.lightImpact();
    setState(() => block.collapsed = !block.collapsed);
    _markDirty();
  }

  void _onFocus(BlockNode? block) {
    setState(() => _focusedBlock = block);
  }

  void _onNodeLinkTap(String target) {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;
    final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
    if (_looksLikeUuid(target)) {
      repo.fetchNodeByUuid(target).then((node) {
        if (mounted) context.push('${Routes.editor}/${node.uuid}');
      }).catchError((_) {});
    } else {
      final id = int.tryParse(target);
      if (id != null && mounted) {
        context.push('${Routes.editor}/$id');
      }
    }
  }

  bool _looksLikeUuid(String value) {
    return RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(value);
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

    final block = _focusedBlock;
    if (block == null) return;

    await _applyEditorAction(block, action);
  }

  Future<void> _applyEditorAction(BlockNode block, EditorAction action) async {
    final controller = block.controller;
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
        await _insertNodeLink(block, action);
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
        return;
    }
    _markDirty();
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

  Future<void> _insertNodeLink(BlockNode block, EditorAction action) async {
    final mode = action == EditorAction.classLink
        ? NodePickerMode.classNode
        : action == EditorAction.tagLink
            ? NodePickerMode.tag
            : NodePickerMode.any;
    if (!mounted) return;
    final node = await NodePicker.show(context, mode: mode);
    if (node == null) return;

    final controller = block.controller;
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

  Future<void> _onSlashTriggered([BlockNode? triggeredBlock]) async {
    final block = triggeredBlock ?? _focusedBlock;
    if (block == null) return;

    setState(() => _focusedBlock = block);
    final action = await SlashCommandPalette.show(context);
    if (!mounted || action == null) return;

    final controller = block.controller;
    final text = controller.text;
    final selection = controller.selection;
    final cursor = selection.isValid ? selection.start : 0;
    if (cursor > 0 && text.substring(cursor - 1, cursor) == '/') {
      final newText = text.replaceRange(cursor - 1, cursor, '');
      controller
        ..text = newText
        ..selection = TextSelection.collapsed(offset: (cursor - 1).clamp(0, newText.length));
    }

    await _applyEditorAction(block, action);
  }

  Future<void> _onMentionTriggered([BlockNode? triggeredBlock]) async {
    final block = triggeredBlock ?? _focusedBlock;
    if (block == null) return;

    setState(() => _focusedBlock = block);
    final result = await MentionPicker.show(context);
    if (!mounted || result == null) return;

    final controller = block.controller;
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
    _markDirty();
  }

  List<BlockNode> _allBlocks() {
    final result = <BlockNode>[];
    void visit(List<BlockNode> nodes) {
      for (final node in nodes) {
        result.add(node);
        visit(node.children);
      }
    }
    visit(_roots);
    return result;
  }

  void _openBreadcrumbNode(BreadcrumbItem item) {
    context.push('${Routes.editor}/${item.uuid}');
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final keyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;

    return Scaffold(
      appBar: AppBar(
        title: _breadcrumbs.isEmpty ? null : _buildBreadcrumbRow(),
        actions: [
          IconButton(
            icon: Badge(
              isLabelVisible: _commentCount > 0,
              label: Text('$_commentCount'),
              child: Icon(MdiIcons.chatOutline),
            ),
            tooltip: 'Comments',
            onPressed: _openComments,
          ),
          PopupMenuButton<String>(
            icon: Icon(MdiIcons.dotsVertical),
            tooltip: 'More options',
            onSelected: (value) {
              if (value == 'share') _openShareSheet();
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: 'share',
                child: Row(
                  children: [
                    Icon(MdiIcons.shareOutline),
                    const SizedBox(width: 12),
                    const Text('Share'),
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
              icon: Icon(MdiIcons.check),
              tooltip: 'Save now',
              onPressed: () => _save(),
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
                        _buildBlockTree(colors),
                        TextButton.icon(
                          onPressed: _addBlock,
                          icon: Icon(MdiIcons.plus),
                          label: const Text('Add block'),
                        ),
                        const SizedBox(height: 20),
                        _buildPropertiesSection(colors),
                        _buildLinkedReferencesSection(colors),
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

  /// Compact breadcrumb row shown in the app bar title slot.
  Widget _buildBreadcrumbRow() {
    final colors = Theme.of(context).colorScheme;
    final items = <Widget>[];

    for (var i = 0; i < _breadcrumbs.length; i++) {
      final item = _breadcrumbs[i];
      final isLast = i == _breadcrumbs.length - 1;
      final label = item.displayName.isNotEmpty ? item.displayName : 'Untitled';

      items.add(
        InkWell(
          onTap: isLast ? null : () => _openBreadcrumbNode(item),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item.icon?.isNotEmpty == true) ...[
                  NodeIcon(
                    iconField: item.icon,
                    size: 16,
                    fallbackColor: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: isLast ? colors.onSurface : colors.onSurfaceVariant,
                        fontWeight: isLast ? FontWeight.w600 : FontWeight.normal,
                      ),
                ),
              ],
            ),
          ),
        ),
      );
      if (!isLast) {
        items.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Icon(MdiIcons.chevronRight, size: 16, color: colors.outline),
          ),
        );
      }
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: items),
    );
  }

  Widget _buildTitleField() {
    final colors = Theme.of(context).colorScheme;
    final pageColor = ColorPresets.tryResolve(_pageColor);
    return FleetCard(
      child: Container(
        decoration: pageColor != null
            ? BoxDecoration(
                border: Border(left: BorderSide(color: pageColor, width: 4)),
              )
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            NodeIcon(iconField: _pageIcon, size: 28),
            const SizedBox(width: 12),
            Expanded(
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
            if (_pageIsPrivate) ...[
              const SizedBox(width: 8),
              Icon(
                MdiIcons.lockOutline,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBlockTree(ColorScheme colors) {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return const SizedBox.shrink();

    return FleetCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: BlockTreeEditor(
          key: _blockTreeKey,
          roots: _roots,
          classNames: _classNames,
          dio: auth.dio!,
          focusedNode: _focusedBlock,
          onFocus: _onFocus,
          onDelete: _onDelete,
          onMove: _onMove,
          onAddSibling: _addBlock,
          onAddChild: _onAddChild,
          onIndent: _onIndent,
          onOutdent: _onOutdent,
          onToggleCollapse: _onToggleCollapse,
          onNodeLinkTap: _onNodeLinkTap,
          onContentChanged: _markDirty,
          linkColors: _linkColors,
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

  Widget _buildLinkedReferencesSection(ColorScheme colors) {
    if (_linkedReferences.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Linked References ($_linkedRefsTotal)',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 4),
          ..._linkedReferences.map((ref) {
            final page = ref.sourcePage;
            final subtitle = page != null && page.uuid != ref.sourceNode.uuid
                ? page.displayName
                : null;
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: NodeIcon(
                iconField: ref.sourceNode.icon,
                fallbackColor: colors.onSurfaceVariant,
                size: 22,
              ),
              title: Text(
                ref.sourceNode.displayName.isNotEmpty
                    ? ref.sourceNode.displayName
                    : 'Untitled',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: subtitle != null
                  ? Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis)
                  : null,
              onTap: () => context.push('${Routes.editor}/${ref.sourceNode.uuid}'),
            );
          }),
        ],
      ),
    );
  }
}
