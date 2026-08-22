import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../core/constants/system.dart';
import '../../core/utils/ast_builder.dart';
import '../../core/utils/color_presets.dart';
import '../../data/models/node.dart';
import 'asset_block_widget.dart';
import 'ast_rich_text.dart';

/// A single editable block in the outliner tree.
class BlockNode {
  BlockNode({
    required this.node,
    required this.controller,
    this.parent,
    List<BlockNode>? children,
    this.collapsed = false,
    this.isNew = false,
  }) : children = children ?? [];

  Node node;
  final TextEditingController controller;
  BlockNode? parent;
  final List<BlockNode> children;
  bool collapsed;
  final bool isNew;

  int get id => node.id;

  int get depth {
    int d = 0;
    BlockNode? p = parent;
    // Guard against cyclic parent links in corrupt server data.
    final seen = <BlockNode>{};
    while (p != null && seen.add(p)) {
      d++;
      p = p.parent;
    }
    return d;
  }
}

/// Where a dragged block should be inserted relative to a target block.
enum DropPosition { before, after, child }

/// Actions available from the long-press context menu on a node/class link.
enum NodeLinkAction { open, edit, delete, unlink }

class BlockTreeEditor extends StatefulWidget {
  const BlockTreeEditor({
    super.key,
    required this.roots,
    required this.classNames,
    required this.dio,
    required this.focusedNode,
    required this.onFocus,
    required this.onDelete,
    required this.onMove,
    required this.onAddSibling,
    required this.onAddChild,
    required this.onIndent,
    required this.onOutdent,
    required this.onToggleCollapse,
    this.onInsertImage,
    this.onInsertAudio,
    this.onNodeLinkTap,
    this.onNodeLinkAction,
    this.onExternalLinkTap,
    this.onContentChanged,
    this.onToggleTask,
    this.linkColors,
  });

  final List<BlockNode> roots;
  final Map<String, String> classNames;
  final Dio dio;
  final BlockNode? focusedNode;
  final ValueChanged<BlockNode?> onFocus;
  final ValueChanged<BlockNode> onDelete;
  final void Function(BlockNode moved, BlockNode target, DropPosition position)
  onMove;
  final VoidCallback onAddSibling;
  final ValueChanged<BlockNode> onAddChild;
  final ValueChanged<BlockNode> onIndent;
  final ValueChanged<BlockNode> onOutdent;
  final ValueChanged<BlockNode> onToggleCollapse;
  final VoidCallback? onInsertImage;
  final VoidCallback? onInsertAudio;
  final ValueChanged<String>? onNodeLinkTap;

  /// Invoked when the user long-presses a node/class link inside a block.
  ///
  /// The parent editor receives the affected block, the chosen action, the raw
  /// link id and the rendered label. For [NodeLinkAction.edit], [newTarget]
  /// and [newLabel] contain the values entered by the user.
  final void Function(
    BlockNode block,
    NodeLinkAction action,
    String linkId,
    String label, {
    String? newTarget,
    String? newLabel,
  })?
  onNodeLinkAction;

  final ValueChanged<String>? onExternalLinkTap;

  /// Invoked whenever a block's text changes (for autosave).
  final VoidCallback? onContentChanged;

  /// Invoked when the user taps a task checkbox.
  final ValueChanged<BlockNode>? onToggleTask;

  /// Data colors for link targets (node/class uuid → color).
  final Map<String, Color>? linkColors;

  @override
  BlockTreeEditorState createState() => BlockTreeEditorState();
}

class BlockTreeEditorState extends State<BlockTreeEditor> {
  BlockNode? _dragging;
  final _focusNodes = <BlockNode, FocusNode>{};
  final _rowKeys = <BlockNode, GlobalKey>{};

  @override
  void dispose() {
    for (final focusNode in _focusNodes.values) {
      focusNode.dispose();
    }
    super.dispose();
  }

  GlobalKey _rowKeyFor(BlockNode node) =>
      _rowKeys.putIfAbsent(node, GlobalKey.new);

  void scrollToBlock(BlockNode block) {
    final key = _rowKeys[block];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 250),
        alignment: 0.35,
      );
    }
  }

  void requestFocusFor(BlockNode block) {
    _focusFor(block).requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final rows = <_VisibleRow>[];
    _flatten(widget.roots, rows);

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        return _buildRow(row, rows, index);
      },
    );
  }

  void _flatten(
    List<BlockNode> nodes,
    List<_VisibleRow> rows, [
    Set<BlockNode>? visited,
  ]) {
    visited ??= <BlockNode>{};
    for (final node in nodes) {
      // Skip already-visited nodes: corrupt server data can contain cycles.
      if (!visited.add(node)) continue;
      rows.add(_VisibleRow(node: node));
      if (!node.collapsed) {
        _flatten(node.children, rows, visited);
      }
    }
  }

  Widget _buildRow(_VisibleRow row, List<_VisibleRow> rows, int index) {
    final node = row.node;
    final colors = Theme.of(context).colorScheme;
    final isFocused = widget.focusedNode == node;
    final indent = node.depth * 24.0;

    Widget field;
    if (node.node.isAsset) {
      field = GestureDetector(
        onTap: () => widget.onFocus(node),
        child: AssetBlockWidget(
          dio: widget.dio,
          uuid: node.node.uuid,
          filename: node.controller.text.isNotEmpty
              ? node.controller.text
              : null,
        ),
      );
    } else if (isFocused) {
      field = TextField(
        controller: node.controller,
        focusNode: _focusFor(node),
        maxLines: null,
        minLines: 1,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        style: _isCode(node)
            ? TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: const ['monospace'],
                color: colors.onSurface,
              )
            : null,
        decoration: InputDecoration(
          hintText: _hintForBlock(node),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          isDense: true,
        ),
        onTap: () => widget.onFocus(node),
        onChanged: (value) {
          if (widget.focusedNode != node) {
            widget.onFocus(node);
          }
          widget.onContentChanged?.call();
        },
      );

      if (_calloutColor(node, colors) case final color?) {
        field = Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: color, width: 4)),
            color: color.withAlpha((0.08 * 255).round()),
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.only(left: 8),
          child: field,
        );
      }
    } else {
      field = GestureDetector(
        onTap: () => widget.onFocus(node),
        behavior: HitTestBehavior.translucent,
        child: AstRichText(
          source: node.node.name,
          onNodeLinkTap: widget.onNodeLinkTap,
          onNodeLinkLongPress: (linkId, label) =>
              _showNodeLinkMenu(node, linkId, label),
          onExternalLinkTap: widget.onExternalLinkTap,
          linkColors: widget.linkColors,
          style: _isCode(node)
              ? TextStyle(
                  fontFamily: 'monospace',
                  fontFamilyFallback: const ['monospace'],
                  color: colors.onSurface,
                )
              : null,
          maxLines: 100,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }

    final isTask = node.node.isTask;
    final isTaskDone = _isTaskDone(node);

    Widget content = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: indent),
        _DragHandle(
          node: node,
          onDragStarted: () => setState(() => _dragging = node),
          onDragEnded: () => setState(() => _dragging = null),
          onIndent: () => widget.onIndent(node),
          onOutdent: () => widget.onOutdent(node),
          child: isTask
              ? _TaskCheckbox(
                  done: isTaskDone,
                  onToggle: () => widget.onToggleTask?.call(node),
                  colors: colors,
                )
              : _Bullet(
                  collapsed: node.collapsed,
                  hasChildren: node.children.isNotEmpty,
                  onToggleCollapse: () => widget.onToggleCollapse(node),
                  colors: colors,
                ),
        ),
        Expanded(child: field),
        if (isFocused)
          IconButton(
            icon: Icon(MdiIcons.dotsVertical, size: 20),
            tooltip: 'Block options',
            color: colors.onSurfaceVariant,
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            padding: EdgeInsets.zero,
            onPressed: () => _showBlockMenu(node),
          ),
      ],
    );

    // A block's own data color renders as a left border (mirrors the web
    // app's BlockRow), independent of the theme accent.
    final blockColor = ColorPresets.tryResolve(node.node.color);
    if (blockColor != null) {
      content = Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: blockColor, width: 3)),
        ),
        padding: const EdgeInsets.only(left: 6),
        child: content,
      );
    }

    if (isFocused) {
      content = Container(
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withAlpha((0.35 * 255).round()),
        ),
        child: content,
      );
    }

    // Drop target: dropping on a row makes the dragged node a child.
    final disableAnimations = MediaQuery.of(context).disableAnimations;
    content = DragTarget<BlockNode>(
      onWillAcceptWithDetails: (details) =>
          details.data != node && !_isDescendant(details.data, node),
      onAcceptWithDetails: (details) {
        widget.onMove(details.data, node, DropPosition.child);
      },
      builder: (context, candidateData, rejectedData) {
        final active = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: disableAnimations
              ? Duration.zero
              : const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: active
                ? colors.primaryContainer.withAlpha((0.2 * 255).round())
                : null,
          ),
          child: content,
        );
      },
    );

    return Column(
      key: _rowKeyFor(node),
      mainAxisSize: MainAxisSize.min,
      children: [
        // Drop targets appear only while a drag is in progress, so idle rows
        // carry no extra vertical spacing.
        if (_dragging != null)
          _buildDropLine(node, DropPosition.before, colors),
        content,
        if (_dragging != null)
          _buildDropLine(node, DropPosition.after, colors),
      ],
    );
  }

  /// Slim drop zone between rows; highlights as a 2px accent line when the
  /// dragged block hovers it.
  Widget _buildDropLine(
    BlockNode node,
    DropPosition position,
    ColorScheme colors,
  ) {
    return DragTarget<BlockNode>(
      onWillAcceptWithDetails: (details) =>
          details.data != node && !_isDescendant(details.data, node),
      onAcceptWithDetails: (details) {
        widget.onMove(details.data, node, position);
      },
      builder: (context, candidateData, rejectedData) {
        return Container(
          height: 8,
          alignment: Alignment.center,
          child: Container(
            height: 2,
            decoration: BoxDecoration(
              color: candidateData.isNotEmpty
                  ? colors.primary
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        );
      },
    );
  }

  FocusNode _focusFor(BlockNode node) {
    return _focusNodes.putIfAbsent(node, () {
      final focusNode = FocusNode();
      focusNode.addListener(() {
        if (focusNode.hasFocus) {
          widget.onFocus(node);
        } else {
          // Sync the canonical AST with the edited Markdown text so the
          // read-only rich-text view shows the latest content.
          final ast = AstBuilder.parseInline(node.controller.text);
          node.node = _copyNodeWithName(node.node, AstBuilder.serialize(ast));
        }
      });
      return focusNode;
    });
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
      classes: node.classes,
      tags: node.tags,
      properties: node.properties,
      children: node.children,
      createDate: node.createDate,
      writeDate: node.writeDate,
    );
  }

  bool _isDescendant(BlockNode ancestor, BlockNode candidate) {
    BlockNode? current = candidate.parent;
    // Guard against cyclic parent links in corrupt server data.
    final seen = <BlockNode>{};
    while (current != null && seen.add(current)) {
      if (current == ancestor) return true;
      current = current.parent;
    }
    return false;
  }

  String _hintForBlock(BlockNode node) {
    if (node.node.isTable) return 'Table block';
    if (node.node.isAsset) return 'Asset block';
    if (_hasSystemClass(node, 'code')) return 'Code block';
    return 'Start writing...';
  }

  bool _isCode(BlockNode node) =>
      node.node.isTable || _hasSystemClass(node, 'code');

  bool _isTaskDone(BlockNode node) {
    final status =
        node.node.properties[SystemPropertyUuids.taskStatus] as String?;
    return status != null && TaskStatuses.closed.contains(status);
  }

  Color? _calloutColor(BlockNode node, ColorScheme colors) {
    if (_hasSystemClass(node, 'warning')) return colors.error;
    if (_hasSystemClass(node, 'danger')) return colors.error;
    if (_hasSystemClass(node, 'success')) return colors.primary;
    if (_hasSystemClass(node, 'info')) return colors.tertiary;
    if (_hasSystemClass(node, 'tip')) return colors.outline;
    if (_hasSystemClass(node, 'quote')) return colors.outline;
    return null;
  }

  bool _hasSystemClass(BlockNode node, String name) {
    final needle = name.toLowerCase();
    for (final classUuid in node.node.classesUuid) {
      if (widget.classNames[classUuid] == needle) return true;
    }
    return false;
  }

  void _showBlockMenu(BlockNode node) {
    showModalBottomSheet(
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
              leading: Icon(MdiIcons.eyeOutline),
              title: const Text('Focus view'),
              onTap: () {
                Navigator.of(ctx).pop();
                _showFocusedBlockView(node);
              },
            ),
            if (node.children.isNotEmpty)
              ListTile(
                leading: Icon(
                  node.collapsed ? MdiIcons.chevronDown : MdiIcons.chevronUp,
                ),
                title: Text(node.collapsed ? 'Expand' : 'Collapse'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  widget.onToggleCollapse(node);
                },
              ),
            if (node.id > 0)
              ListTile(
                leading: Icon(MdiIcons.plus),
                title: const Text('Add child'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  widget.onAddChild(node);
                },
              ),
            ListTile(
              leading: Icon(MdiIcons.formatIndentIncrease),
              title: const Text('Indent'),
              onTap: () {
                Navigator.of(ctx).pop();
                widget.onIndent(node);
              },
            ),
            ListTile(
              leading: Icon(MdiIcons.formatIndentDecrease),
              title: const Text('Outdent'),
              onTap: () {
                Navigator.of(ctx).pop();
                widget.onOutdent(node);
              },
            ),
            ListTile(
              leading: Icon(MdiIcons.deleteOutline),
              title: const Text('Delete block'),
              onTap: () {
                Navigator.of(ctx).pop();
                widget.onDelete(node);
              },
            ),
            if (widget.onInsertImage != null)
              ListTile(
                leading: Icon(MdiIcons.image),
                title: const Text('Insert image'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  widget.onInsertImage!();
                },
              ),
            if (widget.onInsertAudio != null)
              ListTile(
                leading: Icon(MdiIcons.microphone),
                title: const Text('Insert audio'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  widget.onInsertAudio!();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showFocusedBlockView(BlockNode block) {
    HapticFeedback.lightImpact();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        final colors = Theme.of(ctx).colorScheme;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          builder: (ctx, scrollController) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Focused view',
                      style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: colors.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: ListView(
                        controller: scrollController,
                        children: [
                          AstRichText(
                            source: block.node.name,
                            onNodeLinkTap: widget.onNodeLinkTap,
                            onNodeLinkLongPress: (linkId, label) {
                              Navigator.of(ctx).pop();
                              _showNodeLinkMenu(block, linkId, label);
                            },
                            onExternalLinkTap: widget.onExternalLinkTap,
                            linkColors: widget.linkColors,
                            style: Theme.of(ctx).textTheme.bodyLarge,
                          ),
                          ..._buildFocusedChildren(ctx, block.children, 1),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.tonalIcon(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        widget.onFocus(block);
                      },
                      icon: Icon(MdiIcons.pencilOutline),
                      label: const Text('Edit this block'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  List<Widget> _buildFocusedChildren(
    BuildContext context,
    List<BlockNode> children,
    int depth,
  ) {
    final rows = <Widget>[];
    for (final child in children) {
      rows.add(
        Padding(
          padding: EdgeInsets.only(left: depth * 20.0, top: 8),
          child: AstRichText(
            source: child.node.name,
            onNodeLinkTap: widget.onNodeLinkTap,
            onNodeLinkLongPress: (linkId, label) {
              Navigator.of(context).pop();
              _showNodeLinkMenu(child, linkId, label);
            },
            onExternalLinkTap: widget.onExternalLinkTap,
            linkColors: widget.linkColors,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      );
      if (child.children.isNotEmpty) {
        rows.addAll(_buildFocusedChildren(context, child.children, depth + 1));
      }
    }
    return rows;
  }

  void _showNodeLinkMenu(BlockNode block, String linkId, String label) {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(MdiIcons.openInApp),
              title: const Text('Open'),
              onTap: () {
                Navigator.of(ctx).pop();
                widget.onNodeLinkAction?.call(
                  block,
                  NodeLinkAction.open,
                  linkId,
                  label,
                );
              },
            ),
            ListTile(
              leading: Icon(MdiIcons.pencilOutline),
              title: const Text('Edit'),
              onTap: () async {
                Navigator.of(ctx).pop();
                final result = await _showEditLinkDialog(linkId, label);
                if (result == null || !mounted) return;
                widget.onNodeLinkAction?.call(
                  block,
                  NodeLinkAction.edit,
                  linkId,
                  label,
                  newTarget: result.target,
                  newLabel: result.label,
                );
              },
            ),
            ListTile(
              leading: Icon(MdiIcons.deleteOutline),
              title: const Text('Delete'),
              onTap: () {
                Navigator.of(ctx).pop();
                widget.onNodeLinkAction?.call(
                  block,
                  NodeLinkAction.delete,
                  linkId,
                  label,
                );
              },
            ),
            ListTile(
              leading: Icon(MdiIcons.linkOff),
              title: const Text('Unlink'),
              onTap: () {
                Navigator.of(ctx).pop();
                widget.onNodeLinkAction?.call(
                  block,
                  NodeLinkAction.unlink,
                  linkId,
                  label,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<({String target, String? label})?> _showEditLinkDialog(
    String linkId,
    String label,
  ) async {
    final target = linkId.split(':').first;
    final targetController = TextEditingController(text: target);
    final labelController = TextEditingController(text: label);

    final result = await showDialog<({String target, String? label})>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Edit link'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: targetController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Target UUID',
                  hintText: 'uuid or node id',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: labelController,
                decoration: const InputDecoration(
                  labelText: 'Label',
                  hintText: 'Visible text',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final newTarget = targetController.text.trim();
                if (newTarget.isEmpty) return;
                final newLabel = labelController.text.trim();
                Navigator.of(ctx).pop((
                  target: newTarget,
                  label: newLabel.isEmpty ? null : newLabel,
                ));
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    targetController.dispose();
    labelController.dispose();
    return result;
  }
}

class _VisibleRow {
  _VisibleRow({required this.node});
  final BlockNode node;
}

class _DragHandle extends StatefulWidget {
  const _DragHandle({
    required this.node,
    required this.onDragStarted,
    required this.onDragEnded,
    required this.onIndent,
    required this.onOutdent,
    required this.child,
  });

  final BlockNode node;
  final VoidCallback onDragStarted;
  final VoidCallback onDragEnded;
  final VoidCallback onIndent;
  final VoidCallback onOutdent;

  /// The gutter affordance (bullet dot or task checkbox).
  final Widget child;

  @override
  State<_DragHandle> createState() => _DragHandleState();
}

class _DragHandleState extends State<_DragHandle> {
  double _dragDelta = 0;
  static const _threshold = 24.0;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final feedback = Material(
      elevation: 0,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: MediaQuery.of(context).size.width - 32,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          widget.node.controller.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: (details) {
        _dragDelta += details.primaryDelta ?? 0;
      },
      onHorizontalDragEnd: (_) {
        if (_dragDelta > _threshold) {
          widget.onIndent();
        } else if (_dragDelta < -_threshold) {
          widget.onOutdent();
        }
        _dragDelta = 0;
      },
      child: LongPressDraggable<BlockNode>(
        data: widget.node,
        delay: const Duration(milliseconds: 250),
        onDragStarted: () {
          HapticFeedback.lightImpact();
          widget.onDragStarted();
        },
        onDragEnd: (_) => widget.onDragEnded(),
        feedback: feedback,
        childWhenDragging: Opacity(opacity: 0.35, child: widget.child),
        child: widget.child,
      ),
    );
  }
}

class _TaskCheckbox extends StatelessWidget {
  const _TaskCheckbox({
    required this.done,
    required this.onToggle,
    required this.colors,
  });

  final bool done;
  final VoidCallback onToggle;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onToggle();
      },
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? colors.primary : Colors.transparent,
              border: Border.all(
                color: done ? colors.primary : colors.outline,
                width: 2,
              ),
            ),
            child: done
                ? Icon(MdiIcons.check, size: 14, color: colors.onPrimary)
                : null,
          ),
        ),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({
    required this.collapsed,
    required this.hasChildren,
    required this.onToggleCollapse,
    required this.colors,
  });

  final bool collapsed;
  final bool hasChildren;
  final VoidCallback onToggleCollapse;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: hasChildren
          ? () {
              HapticFeedback.lightImpact();
              onToggleCollapse();
            }
          : null,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 36,
        height: 44,
        child: Center(
          child: hasChildren && collapsed
              ? Icon(
                  MdiIcons.chevronRight,
                  size: 18,
                  color: colors.onSurfaceVariant,
                )
              : Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: colors.onSurfaceVariant,
                    shape: BoxShape.circle,
                  ),
                ),
        ),
      ),
    );
  }
}
