import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/constants/system.dart';
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
import '../widgets/ast_rich_text.dart';
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
  Map<String, ClassProperty> _classProperties = {};
  List<Property> _availableProperties = [];
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
  bool _readerMode = false;
  bool _isFavorite = false;

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

      // Class-level property bindings (hidden/required/default) for this node's classes.
      final classProps = <String, ClassProperty>{};
      for (final classUuid in page.classesUuid) {
        try {
          for (final cp in await repo.fetchClassProperties(classUuid)) {
            classProps.putIfAbsent(cp.propertyUuid, () => cp);
          }
        } catch (_) {
          // Ignore classes that fail to resolve; properties still render.
        }
      }
      // Full property defs so required/default class props without a value still render.
      List<Property> available = const [];
      if (classProps.isNotEmpty) {
        try {
          available = await repo.fetchAvailableProperties(widget.nodeUuid);
        } catch (_) {}
      }

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
          _classProperties = classProps;
          _availableProperties = available;
          _properties = _buildDisplayProperties(properties, classProps, available);
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
        await _loadFavoriteStatus();
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

  Future<void> _loadFavoriteStatus() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      final uuids = await repo.fetchFavoriteUuids();
      if (mounted) setState(() => _isFavorite = uuids.contains(widget.nodeUuid));
    } catch (_) {
      if (mounted) setState(() => _isFavorite = false);
    }
  }

  Future<void> _toggleFavorite() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
    try {
      if (_isFavorite) {
        await repo.removeFavorite(widget.nodeUuid);
      } else {
        await repo.addFavorite(widget.nodeUuid);
      }
      if (mounted) setState(() => _isFavorite = !_isFavorite);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update favorite: $e')),
        );
      }
    }
  }

  Future<void> _sharePage() async {
    final auth = context.read<AuthProvider>();
    final server = auth.activeServer;
    final path = '${Routes.editor}/${widget.nodeUuid}';
    final url = server != null
        ? Uri.parse(server.url).replace(path: path).toString()
        : path;
    final text = '${_titleController.text.trim()}\n$url';
    await SharePlus.instance.share(ShareParams(text: text));
  }

  void _onReaderAddBlock() {
    HapticFeedback.lightImpact();
    setState(() => _readerMode = false);
    _addBlock();
  }

  Future<void> _onReaderAddTask() async {
    HapticFeedback.lightImpact();
    setState(() => _readerMode = false);

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

    await _convertToTask(newBlock);
  }

  void _onReaderBlockTap(BlockNode block) {
    HapticFeedback.lightImpact();
    setState(() {
      _readerMode = false;
      _focusedBlock = block;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _blockTreeKey.currentState?.requestFocusFor(block);
      _blockTreeKey.currentState?.scrollToBlock(block);
    });
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
      case EditorAction.heading:
        _applyHeadingCycle(controller);
      case EditorAction.heading1:
        _applyHeading(controller, 1);
      case EditorAction.heading2:
        _applyHeading(controller, 2);
      case EditorAction.heading3:
        _applyHeading(controller, 3);
      case EditorAction.bullet:
        _applyBullet(controller);
      case EditorAction.date:
        _insertDate(controller);
      case EditorAction.link:
      case EditorAction.classLink:
      case EditorAction.tagLink:
      case EditorAction.image:
      case EditorAction.property:
      case EditorAction.template:
        await _insertNodeLink(block, action);
      case EditorAction.task:
        await _convertToTask(block);
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

  void _applyHeadingCycle(TextEditingController controller) {
    final text = controller.text;
    final selection = controller.selection;
    final cursor = selection.isValid ? selection.start : 0;
    final lineStart = text.lastIndexOf('\n', cursor == 0 ? 0 : cursor - 1);
    final start = lineStart == -1 ? 0 : lineStart + 1;
    final afterLineStart = text.substring(start);
    final existing = RegExp(r'^#{1,3}\s*').firstMatch(afterLineStart);
    final level = existing != null
        ? ((afterLineStart.split(' ').first.length) % 3) + 1
        : 1;
    _applyHeading(controller, level);
  }

  void _applyBullet(TextEditingController controller) {
    final text = controller.text;
    final selection = controller.selection;
    final cursor = selection.isValid ? selection.start : 0;
    final lineStart = text.lastIndexOf('\n', cursor == 0 ? 0 : cursor - 1);
    final start = lineStart == -1 ? 0 : lineStart + 1;
    const replacement = '- ';
    final newText = text.replaceRange(start, start, replacement);
    controller
      ..text = newText
      ..selection = TextSelection.collapsed(
        offset: (cursor + replacement.length).clamp(0, newText.length),
      );
  }

  void _insertDate(TextEditingController controller) {
    final text = controller.text;
    final selection = controller.selection;
    final cursor = selection.isValid ? selection.start : 0;
    final now = DateTime.now();
    final replacement =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final newText = text.replaceRange(cursor, cursor, replacement);
    controller
      ..text = newText
      ..selection = TextSelection.collapsed(
        offset: (cursor + replacement.length).clamp(0, newText.length),
      );
  }

  Future<void> _convertToTask(BlockNode block) async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
    final text = block.controller.text.trim();
    final parentUuid = block.parent?.node.uuid ?? widget.nodeUuid;
    final isEmpty = text.isEmpty || block.node.uuid.isEmpty;

    final created = await repo.createInboxBlock(
      name: isEmpty ? '' : text,
      isTask: true,
      parentUuid: parentUuid,
    );
    if (!mounted) return;

    const pendingStatus = 'Pending';
    await repo.setNodeProperty(
      created.uuid,
      SystemPropertyUuids.taskStatus,
      pendingStatus,
    );
    if (!mounted) return;

    final taskNode = _copyNodeAsTask(
      created,
      status: pendingStatus,
    );

    if (isEmpty) {
      if (block.node.uuid.isNotEmpty) {
        _deletedBlockUuids.add(block.node.uuid);
      }
      block.node = taskNode;
      block.controller.text = _nodeNameToMarkdown(taskNode);
    } else {
      final newBlock = BlockNode(
        node: taskNode,
        controller: TextEditingController(text: _nodeNameToMarkdown(taskNode)),
        parent: block.parent,
      );
      final siblings = block.parent?.children ?? _roots;
      final index = siblings.indexOf(block);
      if (index >= 0) {
        siblings.insert(index + 1, newBlock);
      } else {
        siblings.add(newBlock);
      }
      _focusedBlock = newBlock;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _blockTreeKey.currentState?.requestFocusFor(newBlock);
      });
    }

    setState(() {});
  }

  Future<void> _onToggleTaskStatus(BlockNode block) async {
    if (block.node.uuid.isEmpty) return;
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
    final current = block.node.properties[SystemPropertyUuids.taskStatus] as String?;
    final isDone = current != null && TaskStatuses.closed.contains(current);
    final newStatus = isDone ? 'Pending' : 'Done';

    try {
      await repo.setNodeProperty(
        block.node.uuid,
        SystemPropertyUuids.taskStatus,
        newStatus,
      );
      if (!mounted) return;
      setState(() {
        block.node = _copyNodeWithProperty(
          block.node,
          SystemPropertyUuids.taskStatus,
          newStatus,
        );
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update task: $e')),
        );
      }
    }
  }

  String _nodeNameToMarkdown(Node node) {
    final ast = _tryParseAst(node.name);
    return AstBuilder.toMarkdown(ast);
  }

  Node _copyNodeAsTask(Node node, {String? status}) {
    final props = Map<String, dynamic>.from(node.properties);
    if (status != null) props[SystemPropertyUuids.taskStatus] = status;
    return Node(
      id: node.id,
      uuid: node.uuid,
      name: node.name,
      displayName: node.displayName,
      icon: node.icon,
      color: node.color,
      parentUuid: node.parentUuid,
      pageUuid: node.pageUuid,
      sequence: node.sequence,
      isPage: node.isPage,
      isTask: true,
      isDaily: node.isDaily,
      isMonthly: node.isMonthly,
      isYearly: node.isYearly,
      isTable: node.isTable,
      isAsset: node.isAsset,
      isComment: node.isComment,
      isPrivate: node.isPrivate,
      classes: node.classes,
      classesUuid: node.classesUuid,
      tags: node.tags,
      tagsUuid: node.tagsUuid,
      properties: props,
      children: node.children,
      createDate: node.createDate,
      writeDate: node.writeDate,
    );
  }

  Node _copyNodeWithProperty(Node node, String key, dynamic value) {
    final props = Map<String, dynamic>.from(node.properties)..[key] = value;
    return Node(
      id: node.id,
      uuid: node.uuid,
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
      classesUuid: node.classesUuid,
      tags: node.tags,
      tagsUuid: node.tagsUuid,
      properties: props,
      children: node.children,
      createDate: node.createDate,
      writeDate: node.writeDate,
    );
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
            icon: Icon(_readerMode ? MdiIcons.pencil : MdiIcons.eye),
            tooltip: _readerMode ? 'Edit' : 'Read',
            onPressed: () => setState(() => _readerMode = !_readerMode),
          ),
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
          : _readerMode
              ? _buildReaderBody()
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
      bottomNavigationBar: _readerMode ? _buildReaderBottomBar(colors) : null,
    );
  }

  /// Clean, read-only view of the page content.
  Widget _buildReaderBody() {
    return _PageReaderView(
      title: _titleController.text,
      roots: _roots,
      classNames: _classNames,
      linkColors: _linkColors,
      onBlockTap: _onReaderBlockTap,
      onToggleCollapse: _onToggleCollapse,
      onNodeLinkTap: _onNodeLinkTap,
      onToggleTask: _onToggleTaskStatus,
    );
  }

  /// Floating action bar shown only in reader mode.
  Widget _buildReaderBottomBar(ColorScheme colors) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Material(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _ReaderBarButton(
                  icon: MdiIcons.plus,
                  label: 'Add',
                  onPressed: _onReaderAddBlock,
                ),
                _ReaderBarButton(
                  icon: MdiIcons.checkboxMarkedOutline,
                  label: 'Task',
                  onPressed: _onReaderAddTask,
                ),
                _ReaderBarButton(
                  icon: MdiIcons.shareOutline,
                  label: 'Share',
                  onPressed: _sharePage,
                ),
                _ReaderBarButton(
                  icon: _isFavorite ? MdiIcons.star : MdiIcons.starOutline,
                  label: 'Favorite',
                  onPressed: _toggleFavorite,
                ),
              ],
            ),
          ),
        ),
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
          onToggleTask: _onToggleTaskStatus,
          linkColors: _linkColors,
        ),
      ),
    );
  }

  Widget _buildPropertiesSection(ColorScheme colors) {
    if (_properties.isEmpty) return const SizedBox.shrink();

    final visible = <NodePropertyValue>[];
    final hidden = <NodePropertyValue>[];
    for (final p in _properties) {
      final isHidden = _classProperties[p.property.uuid]?.hidden ?? false;
      (isHidden ? hidden : visible).add(p);
    }

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
            ...visible.map(_buildPropertyCell),
            if (hidden.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: Text(
                  'Hidden properties (${hidden.length})',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                ),
                children: hidden.map(_buildPropertyCell).toList(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPropertyCell(NodePropertyValue p) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: PropertyValueCell(
        property: p.property,
        values: p.values,
        readOnly: p.property.isReadOnly,
        required: _classProperties[p.property.uuid]?.required ?? false,
        onChanged: (value) => _setPropertyValue(p.property, value),
        onPickDate: _pickDateNode,
      ),
    );
  }

  /// Merges node property values with class-property bindings: drops internal
  /// `_`-prefixed system props and appends required/defaulted class props that
  /// have no value yet so they render editable/empty (matches the web).
  List<NodePropertyValue> _buildDisplayProperties(
    List<NodePropertyValue> base,
    Map<String, ClassProperty> classProps,
    List<Property> available,
  ) {
    final display = base.where((p) => !p.property.isHiddenSystem).toList();
    final present = display.map((p) => p.property.uuid).toSet();
    final byUuid = {for (final p in available) p.uuid: p};
    for (final cp in classProps.values) {
      if (present.contains(cp.propertyUuid)) continue;
      if (!(cp.required || cp.defaultValue != null)) continue;
      final def = byUuid[cp.propertyUuid];
      if (def == null || def.isHiddenSystem) continue;
      display.add(NodePropertyValue(property: def, values: const []));
    }
    return display;
  }

  Future<void> _setPropertyValue(Property property, dynamic value) async {
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;
    final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
    try {
      await repo.setNodeProperty(widget.nodeUuid, property.uuid, value);
      final refreshed = await repo.fetchNodeProperties(widget.nodeUuid);
      if (!mounted) return;
      setState(() {
        _properties = _buildDisplayProperties(refreshed, _classProperties, _availableProperties);
      });
    } on DioException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save ${property.name}: ${e.message ?? 'error'}')),
      );
    }
  }

  /// Resolves a date to its journal (day-page) node id for date-typed properties.
  Future<int> _pickDateNode(DateTime date) async {
    if (!mounted) return 0;
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return 0;
    final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
    final node = await repo.getOrCreateDailyJournal(date);
    return node.id;
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

/// A compact tappable button for the reader-mode floating bottom bar.
class _ReaderBarButton extends StatelessWidget {
  const _ReaderBarButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 64,
        height: 48,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: colors.onSurfaceVariant),
            const SizedBox(height: 2),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Read-only rendering of a page tree.
///
/// Displays the title as a warm, serif headline and the blocks as styled
/// paragraphs, headings, bullets, and task checkboxes. Collapsible children
/// are honored, node/class links render as tappable pills, and tapping any
/// block returns the caller to edit mode for that block.
class _PageReaderView extends StatelessWidget {
  const _PageReaderView({
    required this.title,
    required this.roots,
    required this.classNames,
    this.linkColors,
    required this.onBlockTap,
    required this.onToggleCollapse,
    required this.onNodeLinkTap,
    required this.onToggleTask,
  });

  final String title;
  final List<BlockNode> roots;
  final Map<String, String> classNames;
  final Map<String, Color>? linkColors;
  final ValueChanged<BlockNode> onBlockTap;
  final ValueChanged<BlockNode> onToggleCollapse;
  final ValueChanged<String> onNodeLinkTap;
  final ValueChanged<BlockNode> onToggleTask;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final paperColor = isDark ? const Color(0xFF1C1915) : const Color(0xFFFDFBF7);

    return Container(
      color: paperColor,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          children: [
            Text(
              title.isNotEmpty ? title : 'Untitled',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 24),
            ..._buildBlocks(context, roots, 0),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildBlocks(BuildContext context, List<BlockNode> nodes, int depth) {
    final rows = <Widget>[];
    for (final block in nodes) {
      rows.add(_buildBlockRow(context, block, depth));
      if (!block.collapsed) {
        rows.addAll(_buildBlocks(context, block.children, depth + 1));
      }
    }
    return rows;
  }

  Widget _buildBlockRow(BuildContext context, BlockNode block, int depth) {
    final blockColor = ColorPresets.tryResolve(block.node.color);

    Widget row = GestureDetector(
      onTap: () => onBlockTap(block),
      behavior: HitTestBehavior.translucent,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: depth * 24.0),
            SizedBox(width: 32, child: _leadingMarker(context, block)),
            Expanded(child: _buildContent(context, block)),
          ],
        ),
      ),
    );

    if (blockColor != null) {
      row = Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: blockColor, width: 3)),
        ),
        padding: const EdgeInsets.only(left: 6),
        child: row,
      );
    }

    return row;
  }

  Widget _leadingMarker(BuildContext context, BlockNode block) {
    final colors = Theme.of(context).colorScheme;

    if (block.children.isNotEmpty) {
      return IconButton(
        icon: Icon(
          block.collapsed ? MdiIcons.chevronRight : MdiIcons.chevronDown,
          size: 18,
          color: colors.onSurfaceVariant,
        ),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        onPressed: () => onToggleCollapse(block),
      );
    }

    if (block.node.isTask) return const SizedBox.shrink();

    if (_isBullet(block)) {
      return Center(
        child: Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: colors.onSurfaceVariant,
            shape: BoxShape.circle,
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildContent(BuildContext context, BlockNode block) {
    final ast = _tryParseAst(block.node.name);
    final isHeading = ast.isNotEmpty && ast.first['type'] == 'heading';
    final level = isHeading ? (ast.first['level'] as int? ?? 1) : null;
    final style = _contentStyle(context, isHeading, level);

    if (block.node.isTask) {
      final status = block.node.properties[SystemPropertyUuids.taskStatus] as String?;
      final isDone = status != null && TaskStatuses.closed.contains(status);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            value: isDone,
            onChanged: (_) => onToggleTask(block),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          Expanded(
            child: AstRichText(
              source: block.node.name,
              onNodeLinkTap: onNodeLinkTap,
              style: style,
              linkColors: linkColors,
            ),
          ),
        ],
      );
    }

    final source = _isBullet(block)
        ? _sourceWithoutBullet(block.node.name)
        : block.node.name;

    return AstRichText(
      source: source,
      onNodeLinkTap: onNodeLinkTap,
      style: style,
      linkColors: linkColors,
    );
  }

  TextStyle? _contentStyle(BuildContext context, bool isHeading, int? level) {
    final base = Theme.of(context).textTheme.bodyLarge;
    if (base == null) return null;
    if (isHeading) {
      return base.copyWith(
        fontWeight: FontWeight.w700,
        fontSize: base.fontSize! + (4 - level!.clamp(1, 3)) * 2,
      );
    }
    return base;
  }

  bool _isBullet(BlockNode block) {
    final ast = _tryParseAst(block.node.name);
    final markdown = AstBuilder.toMarkdown(ast);
    return markdown.startsWith('- ');
  }

  String _sourceWithoutBullet(String name) {
    final ast = _tryParseAst(name);
    final markdown = AstBuilder.toMarkdown(ast);
    final stripped = markdown.startsWith('- ') ? markdown.substring(2) : markdown;
    return AstBuilder.serialize(AstBuilder.parseInline(stripped));
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
}
