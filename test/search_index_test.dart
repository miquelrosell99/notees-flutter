import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/utils/search_index_builder.dart';
import 'package:notees/data/models/node.dart';

void main() {
  group('tokenize', () {
    test('lowercases terms', () {
      expect(tokenize('Hello World'), {'hello', 'world'});
    });

    test('splits on whitespace and punctuation', () {
      expect(
        tokenize('Hello, world! How are you?'),
        {'hello', 'world', 'how', 'are', 'you'},
      );
    });

    test('removes tokens shorter than 2 characters', () {
      expect(tokenize('a bb ccc'), {'bb', 'ccc'});
    });

    test('deduplicates terms', () {
      expect(tokenize('hello hello world'), {'hello', 'world'});
    });

    test('returns empty set for empty input', () {
      expect(tokenize(''), isEmpty);
    });

    test('handles unicode letters', () {
      expect(tokenize('Café résumé naïve'), {'café', 'résumé', 'naïve'});
    });
  });

  group('buildSearchIndexRows', () {
    test('indexes display name with higher rank than AST name text', () {
      final node = Node(
        id: 1,
        uuid: 'uuid-1',
        name: '[{"type":"paragraph","children":[{"type":"text","text":"Raw AST title"}]}]',
        displayName: 'Resolved name',
      );

      final rows = buildSearchIndexRows(node);

      final displayRows = rows.where((r) => r.field == 'display_name');
      final nameRows = rows.where((r) => r.field == 'name');

      expect(displayRows.every((r) => r.rank == 2), isTrue);
      expect(nameRows.every((r) => r.rank == 1), isTrue);
      expect(displayRows.map((r) => r.term), contains('resolved'));
      expect(nameRows.map((r) => r.term), contains('raw'));
    });

    test('falls back to plain name text when name is not JSON', () {
      final node = Node(
        id: 1,
        uuid: 'uuid-1',
        name: 'Legacy title',
        displayName: 'Legacy title',
      );

      final rows = buildSearchIndexRows(node);
      final terms = rows.map((r) => r.term).toSet();

      expect(terms, contains('legacy'));
      expect(terms, contains('title'));
    });

    test('uses node uuid on every row', () {
      final node = Node(
        id: 1,
        uuid: 'node-abc',
        name: 'Title',
        displayName: 'Title',
      );

      final rows = buildSearchIndexRows(node);
      expect(rows.every((r) => r.nodeUuid == 'node-abc'), isTrue);
    });

    test('deduplicates terms within each field', () {
      final node = Node(
        id: 1,
        uuid: 'uuid-1',
        name: 'Repeat repeat repeat',
        displayName: 'Repeat repeat repeat',
      );

      final rows = buildSearchIndexRows(node);
      expect(rows.where((r) => r.field == 'display_name').length, 1);
      expect(rows.where((r) => r.field == 'name').length, 1);
    });
  });

  group('rankSearchResults', () {
    test('ranks nodes by total matched rank', () {
      final rows = [
        const SearchIndexRow(term: 'hello', nodeUuid: 'a', field: 'display_name', rank: 2),
        const SearchIndexRow(term: 'world', nodeUuid: 'a', field: 'display_name', rank: 2),
        const SearchIndexRow(term: 'hello', nodeUuid: 'b', field: 'name', rank: 1),
      ];

      final ranked = rankSearchResults(rows, 'hello world');

      expect(ranked, ['a', 'b']);
    });

    test('ranks multi-term matches higher', () {
      final rows = [
        const SearchIndexRow(term: 'dart', nodeUuid: 'a', field: 'name', rank: 1),
        const SearchIndexRow(term: 'flutter', nodeUuid: 'a', field: 'name', rank: 1),
        const SearchIndexRow(term: 'dart', nodeUuid: 'b', field: 'display_name', rank: 2),
      ];

      final ranked = rankSearchResults(rows, 'dart flutter');

      // a scores 2, b scores 2 -> tie-break by uuid ascending.
      expect(ranked, ['a', 'b']);
    });

    test('ignores terms not in the query', () {
      final rows = [
        const SearchIndexRow(term: 'hello', nodeUuid: 'a', field: 'display_name', rank: 2),
        const SearchIndexRow(term: 'goodbye', nodeUuid: 'a', field: 'name', rank: 1),
      ];

      final ranked = rankSearchResults(rows, 'hello');

      expect(ranked, ['a']);
    });

    test('returns empty list when query has no usable terms', () {
      final rows = [
        const SearchIndexRow(term: 'hello', nodeUuid: 'a', field: 'display_name', rank: 2),
      ];

      expect(rankSearchResults(rows, 'a'), isEmpty);
      expect(rankSearchResults(rows, ''), isEmpty);
    });
  });
}
