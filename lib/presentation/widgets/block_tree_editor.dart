import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../data/models/node.dart';
import 'asset_block_widget.dart';

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
    while (p != null) {
      d++;
      p = p.parent;
    }
    return d;
  }

}

/// Where a dragged block should be inserted relative to a target block.
enum DropPosition { before, after, child }

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
  });

  final List<BlockNode> roots;
  final Map<int, String> classNames;
  final Dio dio;
  final BlockNode? focusedNode;
  final ValueChanged<BlockNode?> onFocus;
  final ValueChanged<BlockNode> onDelete;
  final void Function(BlockNode moved, BlockNode target, DropPosition position) onMove;
  final VoidCallback onAddSibling;
  final ValueChanged<BlockNode> onAddChild;
  final ValueChanged<BlockNode> onIndent;
  final ValueChanged<BlockNode> onOutdent;
  final ValueChanged<BlockNode> onToggleCollapse;
  final VoidCallback? onInsertImage;
  final VoidCallback? onInsertAudio;

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

  GlobalKey _rowKeyFor(BlockNode node) => _rowKeys.putIfAbsent(node, GlobalKey.new);

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

  void _flatten(List<BlockNode> nodes, List<_VisibleRow> rows) {
    for (final node in nodes) {
      rows.add(_VisibleRow(node: node));
      if (!node.collapsed) {
        _flatten(node.children, rows);
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
          filename: node.controller.text.isNotEmpty ? node.controller.text : null,
        ),
      );
    } else {
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
    }

    Widget content = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: indent),
        _DragHandle(
          node: node,
          dragging: _dragging == node,
          collapsed: node.children.isNotEmpty && node.collapsed,
          onDragStarted: () => setState(() => _dragging = node),
          onDragEnded: () => setState(() => _dragging = null),
          onToggleCollapse: () => widget.onToggleCollapse(node),
          onIndent: () => widget.onIndent(node),
          onOutdent: () => widget.onOutdent(node),
        ),
        Expanded(child: field),
        if (isFocused) ...[
          _BlockToolbarButton(
            icon: Icons.format_indent_increase,
            tooltip: 'Indent',
            onPressed: () => widget.onIndent(node),
          ),
          _BlockToolbarButton(
            icon: Icons.format_indent_decrease,
            tooltip: 'Outdent',
            onPressed: () => widget.onOutdent(node),
          ),
          _BlockToolbarButton(
            icon: Icons.add,
            tooltip: 'Add child',
            onPressed: () => widget.onAddChild(node),
          ),
          _BlockToolbarButton(
            icon: Icons.more_vert,
            tooltip: 'Block options',
            onPressed: () => _showBlockMenu(node),
          ),
        ],
      ],
    );

    if (isFocused) {
      content = Container(
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withAlpha((0.5 * 255).round()),
          borderRadius: BorderRadius.circular(8),
        ),
        child: content,
      );
    }

    // Drop target: dropping on a row makes the dragged node a child.
    content = DragTarget<BlockNode>(
      onWillAcceptWithDetails: (details) =>
          details.data != node && !_isDescendant(details.data, node),
      onAcceptWithDetails: (details) {
        widget.onMove(details.data, node, DropPosition.child);
      },
      builder: (context, candidateData, rejectedData) {
        final active = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: active ? colors.primaryContainer.withAlpha((0.25 * 255).round()) : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: content,
        );
      },
    );

    return Column(
      key: _rowKeyFor(node),
      mainAxisSize: MainAxisSize.min,
      children: [
        // Drop before this row.
        DragTarget<BlockNode>(
          onWillAcceptWithDetails: (details) =>
              details.data != node && !_isDescendant(details.data, node),
          onAcceptWithDetails: (details) {
            widget.onMove(details.data, node, DropPosition.before);
          },
          builder: (context, candidateData, rejectedData) {
            return Container(
              height: 4,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: candidateData.isNotEmpty ? colors.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: content,
        ),
        // Drop after this row.
        DragTarget<BlockNode>(
          onWillAcceptWithDetails: (details) =>
              details.data != node && !_isDescendant(details.data, node),
          onAcceptWithDetails: (details) {
            widget.onMove(details.data, node, DropPosition.after);
          },
          builder: (context, candidateData, rejectedData) {
            return Container(
              height: 4,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: candidateData.isNotEmpty ? colors.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            );
          },
        ),
      ],
    );
  }

  FocusNode _focusFor(BlockNode node) {
    return _focusNodes.putIfAbsent(node, () {
      final focusNode = FocusNode();
      focusNode.addListener(() {
        if (focusNode.hasFocus) {
          widget.onFocus(node);
        }
      });
      return focusNode;
    });
  }

  bool _isDescendant(BlockNode ancestor, BlockNode candidate) {
    BlockNode? current = candidate.parent;
    while (current != null) {
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

  bool _isCode(BlockNode node) => node.node.isTable || _hasSystemClass(node, 'code');

  Color? _calloutColor(BlockNode node, ColorScheme colors) {
    if (_hasSystemClass(node, 'warning')) return Colors.orange;
    if (_hasSystemClass(node, 'danger')) return colors.error;
    if (_hasSystemClass(node, 'success')) return Colors.green;
    if (_hasSystemClass(node, 'info')) return Colors.blue;
    if (_hasSystemClass(node, 'tip')) return Colors.teal;
    if (_hasSystemClass(node, 'quote')) return colors.outline;
    return null;
  }

  bool _hasSystemClass(BlockNode node, String name) {
    final needle = name.toLowerCase();
    for (final classId in node.node.classes) {
      if (widget.classNames[classId] == needle) return true;
    }
    return false;
  }

  void _showBlockMenu(BlockNode node) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Add child'),
              onTap: () {
                Navigator.of(ctx).pop();
                widget.onAddChild(node);
              },
            ),
            ListTile(
              leading: const Icon(Icons.format_indent_increase),
              title: const Text('Indent'),
              onTap: () {
                Navigator.of(ctx).pop();
                widget.onIndent(node);
              },
            ),
            ListTile(
              leading: const Icon(Icons.format_indent_decrease),
              title: const Text('Outdent'),
              onTap: () {
                Navigator.of(ctx).pop();
                widget.onOutdent(node);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete block'),
              onTap: () {
                Navigator.of(ctx).pop();
                widget.onDelete(node);
              },
            ),
            if (widget.onInsertImage != null)
              ListTile(
                leading: const Icon(Icons.image),
                title: const Text('Insert image'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  widget.onInsertImage!();
                },
              ),
            if (widget.onInsertAudio != null)
              ListTile(
                leading: const Icon(Icons.mic),
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
}

class _VisibleRow {
  _VisibleRow({required this.node});
  final BlockNode node;
}

class _DragHandle extends StatefulWidget {
  const _DragHandle({
    required this.node,
    required this.dragging,
    required this.collapsed,
    required this.onDragStarted,
    required this.onDragEnded,
    required this.onToggleCollapse,
    required this.onIndent,
    required this.onOutdent,
  });

  final BlockNode node;
  final bool dragging;
  final bool collapsed;
  final VoidCallback onDragStarted;
  final VoidCallback onDragEnded;
  final VoidCallback onToggleCollapse;
  final VoidCallback onIndent;
  final VoidCallback onOutdent;

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
      elevation: 3,
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

    final bullet = _Bullet(
      collapsed: widget.collapsed,
      onTap: widget.onToggleCollapse,
      colors: colors,
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
        onDragStarted: widget.onDragStarted,
        onDragEnd: (_) => widget.onDragEnded(),
        feedback: feedback,
        childWhenDragging: Opacity(
          opacity: 0.35,
          child: bullet,
        ),
        child: bullet,
      ),
    );
  }
}

class _BlockToolbarButton extends StatelessWidget {
  const _BlockToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      color: colors.onSurfaceVariant,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({
    required this.collapsed,
    required this.onTap,
    required this.colors,
  });

  final bool collapsed;
  final VoidCallback onTap;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 28,
        height: 44,
        child: Center(
          child: collapsed
              ? Icon(Icons.chevron_right, size: 18, color: colors.onSurfaceVariant)
              : Container(
                  width: 6,
                  height: 6,
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
