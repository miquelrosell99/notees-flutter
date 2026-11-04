import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/utils/ast_builder.dart';
import 'package:notees/core/utils/query_tokens.dart';

/// The query-token write helpers (the web `queryTokens.ts` port) and the
/// editor text-form round-trip preservation: the `[query]` placeholder
/// label must carry the payload through a toMarkdown → controller text →
/// re-parse save cycle, and deleting the label must drop the token.
void main() {
  const ast = <String, dynamic>{
    'version': 2,
    'scope': {'type': 'entire_workspace'},
    'root': {'type': 'group', 'logic': 'and', 'children': <dynamic>[]},
  };

  List<Map<String, dynamic>> content() => [
        {'type': 'text', 'text': 'Tracked items'},
        {'type': 'query', 'queryAst': ast},
      ];

  group('the token splice helpers', () {
    test('firstQueryTokenIndex finds the first query token, -1 when none', () {
      expect(firstQueryTokenIndex(content()), 1);
      expect(
        firstQueryTokenIndex(const [
          {'type': 'text', 'text': 'plain'},
        ]),
        -1,
      );
    });

    test('withQueryTokenAst rewrites only the indexed token', () {
      final next = withQueryTokenAst(content(), 1, {'version': 2});
      expect(next, hasLength(2));
      expect(next[0], content().first);
      expect(next[1]['type'], 'query');
      expect(next[1]['queryAst'], {'version': 2});
    });

    test('appendQueryToken adds the payload token at the end', () {
      final next = appendQueryToken(const [
        {'type': 'text', 'text': 'hello'},
      ], ast);
      expect(next, hasLength(2));
      expect(next[1]['type'], 'query');
      expect(next[1]['queryAst'], ast);
    });
  });

  group('the text-form round-trip preservation', () {
    test('a query token survives toMarkdown → parse with its payload', () {
      final tokens = content();
      final markdown = AstBuilder.toMarkdown(tokens);
      expect(markdown, contains('[query]'));
      final reparsed = AstBuilder.parseInlinePreservingQuery(
        markdown,
        queryTokensOf(tokens),
      );
      expect(reparsed, hasLength(2));
      expect(reparsed[1]['type'], 'query');
      expect(reparsed[1]['queryAst'], ast);
    });

    test('plain content without placeholders rides verbatim', () {
      final reparsed = AstBuilder.parseInlinePreservingQuery(
        'hello **world**',
        const [
          {'type': 'query', 'queryAst': 'x'},
        ],
      );
      // No placeholder in the text: the preserved token has no anchor and
      // drops (deleting the label deletes the token).
      expect(reparsed.any((token) => token['type'] == 'query'), isFalse);
    });

    test('multiple placeholders restore in occurrence order', () {
      const first = {'type': 'query', 'queryAst': 'first'};
      const second = {'type': 'query', 'queryAst': 'second'};
      final reparsed = AstBuilder.parseInlinePreservingQuery(
        'a [query] b [query] c',
        const [first, second],
      );
      final restored = queryTokensOf(reparsed);
      expect(restored, hasLength(2));
      expect(restored[0]['queryAst'], 'first');
      expect(restored[1]['queryAst'], 'second');
    });

    test('with no preserved tokens the parse is the plain parse', () {
      final plain = AstBuilder.parseInline('x [query] y');
      final preserved = AstBuilder.parseInlinePreservingQuery('x [query] y', const []);
      expect(preserved, plain);
      expect(preserved.every((token) => token['type'] != 'query'), isTrue);
    });
  });
}
