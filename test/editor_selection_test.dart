import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/models/node.dart';
import 'package:notees/features/editor/selection_utils.dart';
import 'package:notees/features/editor/widgets/block_tree_editor.dart';

BlockNode _block(String uuid) => BlockNode(
  node: Node(id: 0, uuid: uuid, name: '', displayName: uuid),
  controller: TextEditingController(),
);

void main() {
  // Tree under test:
  //   a
  //     b
  //     c
  //       d
  //   e
  late BlockNode a, b, c, d, e;
  late List<BlockNode> roots;

  setUp(() {
    a = _block('a');
    b = _block('b');
    c = _block('c');
    d = _block('d');
    e = _block('e');
    a.children.addAll([b, c]);
    b.parent = a;
    c.parent = a;
    c.children.add(d);
    d.parent = c;
    roots = [a, e];
  });

  group('effectiveSelection', () {
    test('drops blocks with a selected ancestor', () {
      expect(effectiveSelection({a, c}), [a]);
      expect(effectiveSelection({a, b, c, d}), [a]);
    });

    test('keeps nested selection when the ancestor is not selected', () {
      expect(effectiveSelection({c, d}), unorderedEquals([c, d]));
    });

    test('keeps siblings across different parents', () {
      expect(effectiveSelection({b, e}), unorderedEquals([b, e]));
    });

    test('returns empty for empty input', () {
      expect(effectiveSelection({}), isEmpty);
    });
  });

  group('orderBlocksByTree', () {
    test('returns the selection in visible depth-first order', () {
      expect(orderBlocksByTree(roots, {e, b, c}), [b, c, e]);
    });

    test('applies effectiveSelection before ordering', () {
      expect(orderBlocksByTree(roots, {a, c, e}), [a, e]);
    });

    test('returns empty when nothing is selected', () {
      expect(orderBlocksByTree(roots, {}), isEmpty);
    });
  });
}
