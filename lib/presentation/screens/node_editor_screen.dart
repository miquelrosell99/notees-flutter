import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/system.dart';
import '../../core/routing/router.dart';
import '../../core/utils/ast_builder.dart';
import '../../core/utils/color_presets.dart';
import '../../core/utils/node_display_name.dart';
import '../../core/utils/node_icon.dart';
import '../../data/models/breadcrumb_item.dart';
import '../../data/models/linked_reference.dart';
import '../../data/models/node.dart';
import '../../data/models/property.dart';
import '../../data/repositories/node_repository.dart';
import '../../domain/services/sync_v2_service.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../views/node_list_view.dart';
import '../widgets/block_tree_editor.dart';
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
  List<Node> _childPages = [];

  List<BreadcrumbItem> _breadcrumbs = [];
  List<NodePropertyValue> _properties = [];
  Map<String, ClassProperty> _classProperties = {};
  List<Property> _availableProperties = [];
  List<Node> _classes = [];
  Map<String, String> _classNames = {};
  Map<String, Color> _linkColors = {};
  Map<dynamic, String> _propertyValueNames = {};
  String? _pageColor;
  String? _pageIcon;
  bool _pageIsPrivate = false;
  bool _isDaily = false;
  bool _isMonthly = false;
  bool _isYearly = false;
  List<String> _pageClassUuids = const [];
  final Set<String> _deletedBlockUuids = {};
  bool _loading = true;
  bool _saving = false;
  String? _error;
  BlockNode? _focusedBlock;
  List<LinkedReference> _linkedReferences = [];
  int _linkedRefsTotal = 0;
  bool _isFavorite = false;
  bool _propertiesExpanded = false;

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
    final dateFormat = context.read<SettingsProvider>().dateFormat;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(
        dio: auth.dio!,
        syncService: auth.syncService,
      );
      final pageContent = await repo.fetchPageContent(widget.nodeUuid);
      final page = pageContent.node;

      for (final block in _allBlocks()) {
        block.controller.dispose();
      }
      _roots.clear();
      _childPages = page.children.where((b) => b.isPage).toList();
      _roots.addAll(
        _nodesToBlockTree(page.children.where((b) => !b.isPage).toList()),
      );

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

      final propertyValueNames = await _buildPropertyValueNameMap(repo, properties, dateFormat);

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
          _titleController.text = resolveNodeDisplayName(page);
          _classProperties = classProps;
          _availableProperties = available;
          _properties = _buildDisplayProperties(
            properties,
            classProps,
            available,
          );
          _classes = classes;
          _classNames = classNames;
          _linkColors = linkColors;
          _propertyValueNames = propertyValueNames;
          _pageColor = page.color;
          _pageIcon = page.icon;
          _pageIsPrivate = page.isPrivate;
          _isDaily = page.isDaily;
          _isMonthly = page.isMonthly;
          _isYearly = page.isYearly;
          _pageClassUuids = page.classesUuid;
          _breadcrumbs = breadcrumbs;
          _deletedBlockUuids.clear();
          _error = null;
          _focusedBlock = null;
        });
      }
      if (mounted) {
        await _loadFavoriteStatus();
        await _loadLinkedReferences();
      }
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final body = e.response?.data;
      if (mounted) {
        setState(
          () => _error = 'Server error ${status ?? ""}\n$body\n${e.message}',
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadLinkedReferences() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    try {
      final repo = NodeRepository(
        dio: auth.dio!,
        syncService: auth.syncService,
      );
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
      final repo = NodeRepository(
        dio: auth.dio!,
        syncService: auth.syncService,
      );
      final uuids = await repo.fetchFavoriteUuids();
      if (mounted) {
        setState(() => _isFavorite = uuids.contains(widget.nodeUuid));
      }
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

  Future<void> _showRenameTitleDialog() async {
    final isJournalDatePage = _isDaily || _isMonthly || _isYearly;
    if (isJournalDatePage) return;

    final controller = TextEditingController(text: _titleController.text);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename page'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Page title'),
          onSubmitted: (value) => Navigator.of(ctx).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (name == null || name.isEmpty || name == _titleController.text) return;
    await _renamePage(name);
  }

  Future<void> _renamePage(String name) async {
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _saving = true);
    try {
      final repo = NodeRepository(
        dio: auth.dio!,
        syncService: auth.syncService,
      );
      final titleAst = AstBuilder.serialize(AstBuilder.parseInline(name));
      await repo.updateNode(widget.nodeUuid, name: titleAst);
      if (mounted) {
        setState(() => _titleController.text = name);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Page renamed')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not rename page: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showPageOptionsMenu() {
    HapticFeedback.lightImpact();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(_isFavorite ? MdiIcons.star : MdiIcons.starOutline),
              title: Text(_isFavorite ? 'Remove favorite' : 'Add favorite'),
              onTap: () {
                Navigator.of(ctx).pop();
                _toggleFavorite();
              },
            ),
            ListTile(
              leading: Icon(MdiIcons.shareOutline),
              title: const Text('Share'),
              onTap: () {
                Navigator.of(ctx).pop();
                _openShareSheet();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _openShareSheet() {
    SharesBottomSheet.show(context, nodeUuid: widget.nodeUuid);
  }

  List<BlockNode> _nodesToBlockTree(
    List<Node> nodes, {
    BlockNode? parent,
    Set<String>? visited,
  }) {
    visited ??= <String>{};
    final sorted = List<Node>.from(nodes)
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
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
        block.children.addAll(
          _nodesToBlockTree(node.children, parent: block, visited: visited),
        );
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

    setState(() => _saving = true);
    try {
      final service = auth.syncService;
      if (service == null) {
        throw StateError('Sync service not available');
      }

      // Page title changes are handled explicitly via _renamePage; do not
      // rewrite the title here so autosave cannot accidentally overwrite it.

      // Ensure every focused block's AST is synced before serializing.
      _syncAllBlockNames();
      _assignSequences(_roots, 0);

      // Identify new blocks before assigning UUIDs so we can emit create ops
      // for them and update ops for existing blocks.
      final newBlocks = _collectNewBlocks(_roots);

      // Assign fresh UUIDs to every new block so creates can reference their
      // own parent UUIDs and future saves treat them as updates.
      _assignUuidsToNewBlocks(_roots);

      // Enqueue updates for existing blocks and creates for new blocks.
      await _enqueueBlockWrites(service, _roots, newBlocks);

      for (final uuid in _deletedBlockUuids) {
        await service.enqueue(type: 'delete', nodeUuid: uuid);
      }
      _deletedBlockUuids.clear();

      await service.flush();
      if (!mounted) return;
      _dirty = false;

      // Autosaves must not reload the page: that would steal focus and
      // rebuild the block controllers while the user is typing.
      if (manual && mounted) await _loadPage();
      if (manual && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Saved')));
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

  Set<BlockNode> _collectNewBlocks(List<BlockNode> nodes) {
    final result = <BlockNode>{};
    for (final block in nodes) {
      if (block.node.uuid.isEmpty) {
        result.add(block);
      }
      result.addAll(_collectNewBlocks(block.children));
    }
    return result;
  }

  void _assignUuidsToNewBlocks(List<BlockNode> nodes) {
    for (final block in nodes) {
      if (block.node.uuid.isEmpty) {
        block.node = _copyNodeWithId(
          block.node,
          0,
          const Uuid().v7(),
        );
      }
      _assignUuidsToNewBlocks(block.children);
    }
  }

  Future<void> _enqueueBlockWrites(
    SyncV2Service service,
    List<BlockNode> nodes,
    Set<BlockNode> newBlocks,
  ) async {
    for (final block in nodes) {
      final parentUuid = block.parent?.node.uuid ?? widget.nodeUuid;
      final contentAst = AstBuilder.parseInline(block.controller.text);
      if (newBlocks.contains(block)) {
        await service.enqueue(
          type: 'create',
          nodeUuid: block.node.uuid,
          parentUuid: parentUuid,
          contentAst: contentAst,
        );
      } else {
        await service.enqueue(
          type: 'update_content',
          nodeUuid: block.node.uuid,
          contentAst: contentAst,
        );
        if (block.node.parentUuid != parentUuid) {
          await service.enqueue(
            type: 'move',
            nodeUuid: block.node.uuid,
            parentUuid: parentUuid,
          );
        }
      }
      await _enqueueBlockWrites(service, block.children, newBlocks);
    }
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
      repo
          .fetchNodeByUuid(target)
          .then((node) {
            if (mounted) context.push('${Routes.editor}/${node.uuid}');
          })
          .catchError((_) {});
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

  void _onNodeLinkAction(
    BlockNode block,
    NodeLinkAction action,
    String linkId,
    String label, {
    String? newTarget,
    String? newLabel,
  }) {
    final target = linkId.split(':').first;
    switch (action) {
      case NodeLinkAction.open:
        _onNodeLinkTap(target);
        return;
      case NodeLinkAction.edit:
        if (newTarget == null || newTarget.isEmpty) return;
        final ast = AstBuilder.parseInline(block.controller.text);
        final newLinkId = _replaceLinkTarget(linkId, newTarget);
        final newAst = _mutateAstLinks(
          ast,
          matcher: (node) => _matchesNodeLink(node, linkId, label),
          transformer: (node) {
            final refType = node['ref_type'] as String? ?? 'node';
            return AstBuilder.nodeLink(
              targetId: newLinkId,
              label: newLabel,
              refType: refType,
            );
          },
        );
        _updateBlockFromAst(block, newAst);
      case NodeLinkAction.delete:
        final ast = AstBuilder.parseInline(block.controller.text);
        final newAst = _mutateAstLinks(
          ast,
          matcher: (node) => _matchesNodeLink(node, linkId, label),
          transformer: (_) => null,
        );
        _updateBlockFromAst(block, newAst);
      case NodeLinkAction.unlink:
        final ast = AstBuilder.parseInline(block.controller.text);
        final text = label.isNotEmpty ? label : target;
        final newAst = _mutateAstLinks(
          ast,
          matcher: (node) => _matchesNodeLink(node, linkId, label),
          transformer: (_) => AstBuilder.text(text),
        );
        _updateBlockFromAst(block, newAst);
    }
    _markDirty();
  }

  String _replaceLinkTarget(String linkId, String newTarget) {
    final colon = linkId.indexOf(':');
    if (colon >= 0) {
      return '$newTarget${linkId.substring(colon)}';
    }
    return newTarget;
  }

  bool _matchesNodeLink(
    Map<String, dynamic> node,
    String linkId,
    String label,
  ) {
    if (node['type'] != 'node_link') return false;
    final nodeLinkId = node['link_id'] as String? ?? '';
    if (nodeLinkId == linkId) return true;
    // Fall back to matching by visible target + label for links that do not
    // carry a uuid suffix.
    final nodeLabel = node['label'] as String? ?? '';
    return nodeLinkId.split(':').first == linkId.split(':').first &&
        nodeLabel == label;
  }

  void _updateBlockFromAst(BlockNode block, List<Map<String, dynamic>> ast) {
    final markdown = AstBuilder.toMarkdown(ast);
    block.controller.text = markdown;
    block.node = _copyNodeWithName(block.node, AstBuilder.serialize(ast));
  }

  List<Map<String, dynamic>> _mutateAstLinks(
    List<Map<String, dynamic>> ast, {
    required bool Function(Map<String, dynamic> node) matcher,
    required Map<String, dynamic>? Function(Map<String, dynamic> node)
    transformer,
  }) {
    return ast
        .map(
          (block) => _mutateBlockLinks(
            block,
            matcher: matcher,
            transformer: transformer,
          ),
        )
        .toList();
  }

  Map<String, dynamic> _mutateBlockLinks(
    Map<String, dynamic> block, {
    required bool Function(Map<String, dynamic> node) matcher,
    required Map<String, dynamic>? Function(Map<String, dynamic> node)
    transformer,
  }) {
    final copy = Map<String, dynamic>.of(block);
    final children = block['children'];
    if (children is List) {
      copy['children'] = _mutateInlineLinks(
        children.cast<Map<String, dynamic>>(),
        matcher: matcher,
        transformer: transformer,
      );
    }
    return copy;
  }

  List<Map<String, dynamic>> _mutateInlineLinks(
    List<Map<String, dynamic>> nodes, {
    required bool Function(Map<String, dynamic> node) matcher,
    required Map<String, dynamic>? Function(Map<String, dynamic> node)
    transformer,
  }) {
    final result = <Map<String, dynamic>>[];
    for (final node in nodes) {
      if (matcher(node)) {
        final transformed = transformer(node);
        if (transformed != null) {
          result.add(transformed);
        }
        continue;
      }
      final copy = Map<String, dynamic>.of(node);
      final children = node['children'];
      if (children is List) {
        copy['children'] = _mutateInlineLinks(
          children.cast<Map<String, dynamic>>(),
          matcher: matcher,
          transformer: transformer,
        );
      }
      result.add(copy);
    }
    return result;
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
      final newText = text.replaceRange(
        selection.start,
        selection.end,
        replacement,
      );
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
        if (!mounted) return;
      case EditorAction.task:
        await _convertToTask(block);
        if (!mounted) return;
      case EditorAction.table:
        final cursor = selection.isValid ? selection.start : 0;
        const replacement =
            '| Header | Header |\n| --- | --- |\n| Cell | Cell |';
        final newText = text.replaceRange(cursor, cursor, replacement);
        controller
          ..text = newText
          ..selection = TextSelection.collapsed(
            offset: cursor + replacement.length,
          );
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
      ..selection = TextSelection.collapsed(
        offset: newOffset.clamp(0, newText.length),
      );
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

    final taskNode = _copyNodeAsTask(created, status: pendingStatus);

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
    final current =
        block.node.properties[SystemPropertyUuids.taskStatus] as String?;
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to update task: $e')));
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
    if (!mounted) return;
    if (node == null) return;

    final controller = block.controller;
    final text = controller.text;
    final selection = controller.selection;
    final open = action == EditorAction.classLink ? '{{' : '[[';
    final close = action == EditorAction.classLink ? '}}' : ']]';
    final replacement = '$open${node.uuid}|${node.displayName}$close';
    final newText = text.replaceRange(
      selection.start,
      selection.end,
      replacement,
    );
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
        ..selection = TextSelection.collapsed(
          offset: (cursor - 1).clamp(0, newText.length),
        );
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
      ..selection = TextSelection.collapsed(
        offset: newOffset.clamp(0, newText.length),
      );
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
    final settings = context.watch<SettingsProvider>();

    return Scaffold(
      appBar: AppBar(
        title: _breadcrumbs.isEmpty ? null : _buildBreadcrumbRow(),
        actions: [
          IconButton(
            icon: Icon(MdiIcons.dotsVertical),
            tooltip: 'More options',
            onPressed: _showPageOptionsMenu,
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
                        _buildClassPills(colors),
                        const SizedBox(height: 8),
                        _buildPropertiesSection(colors),
                        const SizedBox(height: 8),
                        _buildBlockTree(colors),
                        const SizedBox(height: 80),
                        _buildChildPagesSection(colors, settings.dateFormat),
                        _buildLinkedReferencesSection(colors),
                      ],
                    ),
                  ),
                ),
                if (_focusedBlock != null)
                  EditorInlineToolbar(onAction: _onToolbarAction),
              ],
            ),
      floatingActionButton: _loading
          ? null
          : FloatingActionButton.small(
              onPressed: _addBlock,
              tooltip: 'Add block',
              child: Icon(MdiIcons.plus),
            ),
    );
  }

  /// Compact breadcrumb row shown in the app bar title slot.
  Widget _buildBreadcrumbRow() {
    final colors = Theme.of(context).colorScheme;
    final dateFormat = context.read<SettingsProvider>().dateFormat;
    final items = <Widget>[];

    for (var i = 0; i < _breadcrumbs.length; i++) {
      final item = _breadcrumbs[i];
      final isLast = i == _breadcrumbs.length - 1;
      final label = resolveNodeDisplayName(
        Node(id: 0, uuid: item.uuid, name: item.name, displayName: item.displayName, icon: item.icon),
        dateFormat: dateFormat,
      );

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
    final isJournalDatePage = _isDaily || _isMonthly || _isYearly;
    final canRename = !isJournalDatePage;

    return TextField(
      controller: _titleController,
      readOnly: true,
      canRequestFocus: false,
      onTap: canRename ? _showRenameTitleDialog : null,
      style: Theme.of(
        context,
      ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      decoration: InputDecoration(
        hintText: 'Untitled',
        prefixIcon: NodeIcon(
          iconField: _pageIcon,
          size: 28,
          fallbackColor: colors.onSurfaceVariant,
        ),
        suffixIcon: _pageIsPrivate
            ? Icon(
                MdiIcons.lockOutline,
                size: 18,
                color: colors.onSurfaceVariant,
              )
            : null,
        enabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(
            color: pageColor ?? colors.outline.withAlpha((0.2 * 255).round()),
            width: pageColor != null ? 2 : 1,
          ),
        ),
        disabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(
            color: pageColor ?? colors.outline.withAlpha((0.2 * 255).round()),
            width: pageColor != null ? 2 : 1,
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
      ),
    );
  }

  Widget _buildClassPills(ColorScheme colors) {
    if (_pageClassUuids.isEmpty) return const SizedBox.shrink();

    final classByUuid = {for (final c in _classes) c.uuid: c};

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _pageClassUuids.map((uuid) {
          final cls = classByUuid[uuid];
          final name = cls?.displayName ?? _classNames[uuid] ?? 'class';
          final chipColor = _linkColors[uuid] ?? colors.primary;
          return ActionChip(
            avatar: Icon(MdiIcons.tagOutline, size: 16, color: chipColor),
            label: Text(name),
            labelStyle: TextStyle(color: chipColor),
            backgroundColor: chipColor.withAlpha((0.10 * 255).round()),
            side: BorderSide(color: chipColor.withAlpha((0.30 * 255).round())),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            onPressed: () {},
          );
        }).toList(),
      ),
    );
  }

  Widget _buildBlockTree(ColorScheme colors) {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return const SizedBox.shrink();

    return BlockTreeEditor(
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
      onNodeLinkAction: _onNodeLinkAction,
      onContentChanged: _markDirty,
      onToggleTask: _onToggleTaskStatus,
      linkColors: _linkColors,
    );
  }

  Widget _buildChildPagesSection(ColorScheme colors, String dateFormat) {
    if (_childPages.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Child pages',
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        NodeListView(
          nodes: _childPages,
          onNodeTap: (node) => context.push('${Routes.editor}/${node.uuid}'),
          shrinkWrap: true,
          dateFormat: dateFormat,
        ),
        const SizedBox(height: 20),
      ],
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
            InkWell(
              onTap: () => setState(() => _propertiesExpanded = !_propertiesExpanded),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      _propertiesExpanded ? MdiIcons.chevronDown : MdiIcons.chevronRight,
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Properties',
                      style: Theme.of(
                        context,
                      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    Text(
                      '${visible.length}',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_propertiesExpanded) ...[
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
        displayNameResolver: (value) => _propertyValueNames[value],
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
    final dateFormat = context.read<SettingsProvider>().dateFormat;
    try {
      await repo.setNodeProperty(widget.nodeUuid, property.uuid, value);
      final refreshed = await repo.fetchNodeProperties(widget.nodeUuid);
      final refreshedNames = await _buildPropertyValueNameMap(repo, refreshed, dateFormat);
      if (!mounted) return;
      setState(() {
        _properties = _buildDisplayProperties(
          refreshed,
          _classProperties,
          _availableProperties,
        );
        _propertyValueNames = refreshedNames;
      });
    } on DioException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to save ${property.name}: ${e.message ?? 'error'}',
          ),
        ),
      );
    }
  }

  /// Builds a lookup table from raw property values (uuids/ids) to human-readable
  /// node display names so relation, date, image and text properties do not
  /// render as raw identifiers.
  Future<Map<dynamic, String>> _buildPropertyValueNameMap(
    NodeRepository repo,
    List<NodePropertyValue> properties,
    String dateFormat,
  ) async {
    final targetUuids = <String>{};
    for (final p in properties) {
      for (final v in p.values) {
        final target = _extractPropertyTargetUuid(v);
        if (target != null) targetUuids.add(target);
      }
    }
    if (targetUuids.isEmpty) return const {};

    final nodes = await repo.fetchNodesByUuids(targetUuids.toList());
    return {
      for (final node in nodes)
        if (node.uuid.isNotEmpty) node.uuid: resolveNodeDisplayName(node, dateFormat: dateFormat),
    };
  }

  String? _extractPropertyTargetUuid(dynamic value) {
    if (value is String && _looksLikeUuid(value)) return value;
    if (value is Map<String, dynamic>) {
      final candidate = value['target_node_id'] ??
          value['target_id'] ??
          value['node_id'] ??
          value['uuid'];
      if (candidate is String && _looksLikeUuid(candidate)) return candidate;
    }
    return null;
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
    final dateFormat = context.read<SettingsProvider>().dateFormat;

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Linked References ($_linkedRefsTotal)',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          ..._linkedReferences.map((ref) {
            final page = ref.sourcePage;
            final subtitle = page != null && page.uuid != ref.sourceNode.uuid
                ? resolveNodeDisplayName(page, dateFormat: dateFormat)
                : null;
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: NodeIcon(
                iconField: ref.sourceNode.icon,
                fallbackColor: colors.onSurfaceVariant,
                size: 22,
              ),
              title: Text(
                resolveNodeDisplayName(ref.sourceNode, dateFormat: dateFormat),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: subtitle != null
                  ? Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis)
                  : null,
              onTap: () =>
                  context.push('${Routes.editor}/${ref.sourceNode.uuid}'),
            );
          }),
        ],
      ),
    );
  }
}


