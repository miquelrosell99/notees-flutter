import 'widgets/block_tree_editor.dart';

/// Pure helpers for block multi-select, kept widget-free so they are unit
/// testable without pumping the editor.

/// Drops selected blocks that have a selected ancestor, so batch operations
/// (delete, duplicate) are not applied twice to nested selections.
List<BlockNode> effectiveSelection(Set<BlockNode> selected) {
  return selected
      .where((block) => !_hasSelectedAncestor(block, selected))
      .toList();
}

bool _hasSelectedAncestor(BlockNode block, Set<BlockNode> selected) {
  // Guard against cyclic parent links in corrupt server data.
  final seen = <BlockNode>{};
  BlockNode? current = block.parent;
  while (current != null && seen.add(current)) {
    if (selected.contains(current)) return true;
    current = current.parent;
  }
  return false;
}

/// Returns the effective selection (see [effectiveSelection]) in visible tree
/// order (depth-first), so batch indent/outdent/duplicate keep relative order.
List<BlockNode> orderBlocksByTree(
  List<BlockNode> roots,
  Set<BlockNode> selected,
) {
  final effective = effectiveSelection(selected).toSet();
  final ordered = <BlockNode>[];
  final visited = <BlockNode>{};

  void visit(List<BlockNode> nodes) {
    for (final node in nodes) {
      if (!visited.add(node)) continue;
      if (effective.contains(node)) ordered.add(node);
      visit(node.children);
    }
  }

  visit(roots);
  return ordered;
}
