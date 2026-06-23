import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/utils/ast_stringifier.dart';
import 'package:notees/data/models/node.dart';

void main() {
  group('astToPlainText', () {
    test('returns empty string for null', () {
      expect(astToPlainText(null), '');
    });

    test('returns empty string for empty input', () {
      expect(astToPlainText(''), '');
    });

    test('returns plain text for non-JSON input', () {
      expect(astToPlainText('Plain title'), 'Plain title');
    });

    test('extracts text from paragraph AST', () {
      const ast = '[{"type":"paragraph","children":[{"type":"text","text":"Hello world"}]}]';
      expect(astToPlainText(ast), 'Hello world');
    });

    test('extracts text from heading AST', () {
      const ast = '[{"type":"heading","children":[{"type":"text","text":"A heading"}]}]';
      expect(astToPlainText(ast), 'A heading');
    });

    test('unwraps formatting nodes', () {
      const ast = '[{"type":"paragraph","children":['
          '{"type":"text","text":"Hello "},'
          '{"type":"strong","children":[{"type":"text","text":"bold"}]},'
          '{"type":"text","text":" and "},'
          '{"type":"em","children":[{"type":"text","text":"italic"}]}'
          ']}]';
      expect(astToPlainText(ast), 'Hello bold and italic');
    });

    test('renders code and math as text', () {
      const ast = '[{"type":"paragraph","children":['
          '{"type":"code","text":"code"},'
          '{"type":"text","text":" "},'
          '{"type":"math","expression":"x^2"}'
          ']}]';
      expect(astToPlainText(ast), 'code x^2');
    });

    test('renders external link using its children', () {
      const ast = '[{"type":"paragraph","children":['
          '{"type":"external_link","url":"https://example.com","children":[{"type":"text","text":"Example"}]}'
          ']}]';
      expect(astToPlainText(ast), 'Example');
    });

    test('renders node_link label when present', () {
      const ast = '[{"type":"paragraph","children":['
          '{"type":"node_link","link_id":"uuid-1","label":"Linked page"}'
          ']}]';
      expect(astToPlainText(ast), 'Linked page');
    });

    test('renders ellipsis for node_link without label', () {
      const ast = '[{"type":"paragraph","children":['
          '{"type":"node_link","link_id":"uuid-1"}'
          ']}]';
      expect(astToPlainText(ast), '…');
    });

    test('renders user mention with @ prefix', () {
      const ast = '[{"type":"paragraph","children":['
          '{"type":"user_mention","user_id":"u1","label":"alice"}'
          ']}]';
      expect(astToPlainText(ast), '@alice');
    });

    test('extracts text from whiteboard elements', () {
      const ast = '[{"type":"whiteboard","data":{"elements":['
          '{"type":"text","text":"Sticky note"},'
          '{"type":"shape","text":"Shape text"}'
          ']}}]';
      expect(astToPlainText(ast), 'Sticky note Shape text');
    });

    test('ignores query blocks', () {
      const ast = '[{"type":"query","data":{}}]';
      expect(astToPlainText(ast), '');
    });

    test('joins multiple blocks with a single space', () {
      const ast = '[{"type":"paragraph","children":[{"type":"text","text":"First"}]},'
          '{"type":"paragraph","children":[{"type":"text","text":"Second"}]}]';
      expect(astToPlainText(ast), 'First Second');
    });

    test('collapses whitespace', () {
      const ast = '[{"type":"paragraph","children":[{"type":"text","text":"  lots   of   whitespace  "}]}]';
      expect(astToPlainText(ast), 'lots of whitespace');
    });
  });

  group('Node.fromJson displayName fallback', () {
    test('uses display_name when provided', () {
      final node = Node.fromJson({
        'id': 1,
        'uuid': 'uuid-1',
        'name': '[{"type":"paragraph","children":[{"type":"text","text":"Raw"}]}]',
        'display_name': 'Resolved name',
      });

      expect(node.displayName, 'Resolved name');
    });

    test('stringifies AST name when display_name is null', () {
      final node = Node.fromJson({
        'id': 1,
        'uuid': 'uuid-1',
        'name': '[{"type":"paragraph","children":[{"type":"text","text":"Raw AST title"}]}]',
        'display_name': null,
      });

      expect(node.displayName, 'Raw AST title');
    });

    test('stringifies AST name when display_name is missing', () {
      final node = Node.fromJson({
        'id': 1,
        'uuid': 'uuid-1',
        'name': '[{"type":"paragraph","children":[{"type":"text","text":"Another title"}]}]',
      });

      expect(node.displayName, 'Another title');
    });

    test('returns legacy plain name when name is not JSON', () {
      final node = Node.fromJson({
        'id': 1,
        'uuid': 'uuid-1',
        'name': 'Legacy title',
        'display_name': null,
      });

      expect(node.displayName, 'Legacy title');
    });
  });
}
