import 'package:flutter_test/flutter_test.dart';
import 'package:notees/domain/query/query_ast.dart';
import 'package:notees/domain/query/query_dsl.dart';

/// The text query DSL parity pins — a port of
/// `packages/query/test/dsl.test.ts`'s case list: every field kind, every
/// operator, boolean composition, quoting, value coercion, name resolution
/// (injected resolvers) and the fail-loud error surface (unknown fields
/// list the known ones, unresolvable names, bad operators, unterminated
/// strings, missing values). The emitted shapes are the v2 AST wires the
/// strict parser accepts.
void main() {
  // A small fixed world for resolution.
  const classPaper = '0192a000-0000-7000-8000-000000000201';
  const classBook = '0192a000-0000-7000-8000-000000000202';
  const schemaYear = '0192a000-0000-7000-8000-000000000301';
  const schemaTitle = '0192a000-0000-7000-8000-000000000302';
  const schemaCitekey = '0192a000-0000-7000-8000-000000000303';
  const schemaAuthor = '0192a000-0000-7000-8000-000000000304';
  const nodeParis = '0192a000-0000-7000-8000-000000000401';

  const knownFields = ['year', 'title'];

  final resolvers = QueryLanguageResolvers(
    resolveClass: (name) => switch (name.toLowerCase()) {
      'paper' => classPaper,
      'book' => classBook,
      _ => null,
    },
    resolvePropertySchema: (name) => switch (name.toLowerCase()) {
      'year' => schemaYear,
      'title' => schemaTitle,
      'citekey' => schemaCitekey,
      'author' => schemaAuthor,
      _ => null,
    },
    resolveNode: (name) =>
        name.toLowerCase() == 'paris' ? nodeParis : null,
  );

  /// The v2 shape `class:Name` / `linked:Name` emit: member in over an ids
  /// target.
  Map<String, dynamic> memberIn(String family, List<String> ids) => {
        'type': 'member',
        'family': family,
        'op': 'in',
        'target': {'mode': 'ids', 'ids': ids},
      };

  QueryAst parse(
    String text, {
    Scope? scope,
    QueryLanguageResolvers? resolversOverride,
    List<String>? knownFieldsOverride,
  }) =>
      parseQueryLanguage(
        text,
        ParseQueryLanguageOptions(
          scope: scope,
          resolvers: resolversOverride ?? resolvers,
          knownFields: knownFieldsOverride ?? knownFields,
        ),
      );

  List<QueryAstChild> children(QueryAst ast) => ast.root.children;

  QueryAstChild only(QueryAst ast) {
    final kids = children(ast);
    expect(kids, hasLength(1));
    return kids.first;
  }

  group('parseQueryLanguage: fields', () {
    test('parses an empty query to an everything-matching AST', () {
      final ast = parse('   ');
      expect(ast.toJson()['version'], 2);
      expect(ast.scope.toJson(), {'type': 'entire_workspace'});
      expect(ast.root.toJson(), {
        'type': 'group',
        'logic': 'and',
        'children': <Object?>[],
      });
    });

    test('honours a caller-supplied scope', () {
      const scope = PagesScope();
      expect(parse('class:paper', scope: scope).scope, isA<PagesScope>());
    });

    test('class:Name resolves the class by name', () {
      expect(only(parse('class:paper')).toJson(),
          memberIn('class', [classPaper]));
      expect(only(parse('class:book')).toJson(),
          memberIn('class', [classBook]));
    });

    test(
        'isClass:true|false and isEmbedded:true|false emit nodeField eq '
        'conditions (case-insensitive field)', () {
      expect(only(parse('isClass:true')).toJson(), {
        'type': 'nodeField',
        'field': 'isClass',
        'op': 'eq',
        'value': 'true',
      });
      expect(only(parse('isclass:false')).toJson(), {
        'type': 'nodeField',
        'field': 'isClass',
        'op': 'eq',
        'value': 'false',
      });
      expect(only(parse('isEmbedded:true')).toJson(), {
        'type': 'nodeField',
        'field': 'isEmbedded',
        'op': 'eq',
        'value': 'true',
      });
      expect(only(parse('isembedded:FALSE')).toJson(), {
        'type': 'nodeField',
        'field': 'isEmbedded',
        'op': 'eq',
        'value': 'false',
      });
    });

    test('text:term and bare words emit content-contains conditions', () {
      expect(only(parse('text:relativity')).toJson(), {
        'type': 'content',
        'op': 'contains',
        'value': 'relativity',
      });
      expect(only(parse('relativity')).toJson(), {
        'type': 'content',
        'op': 'contains',
        'value': 'relativity',
      });
    });

    test('name:term / name:=term / bare name: emit title conditions', () {
      // Bare ":" is a title contains (LIKE — ASCII case-insensitive at
      // compile).
      expect(only(parse('name:paris')).toJson(),
          {'type': 'name', 'op': 'contains', 'value': 'paris'});
      // ":=" / "=" are exact title equality (case-sensitive at compile).
      expect(only(parse('name:=Paris')).toJson(),
          {'type': 'name', 'op': 'eq', 'value': 'Paris'});
      expect(only(parse('name=Paris')).toJson(),
          {'type': 'name', 'op': 'eq', 'value': 'Paris'});
      expect(only(parse('name!=Paris')).toJson(),
          {'type': 'name', 'op': 'neq', 'value': 'Paris'});
      // Bare ":" with no value is the exists arm (the prop: precedent)…
      expect(only(parse('name:')).toJson(), {'type': 'name', 'op': 'exists'});
      // …also before a boolean keyword.
      expect(parse('name: NOT class:paper').root.toJson(), {
        'type': 'group',
        'logic': 'and',
        'children': [
          {'type': 'name', 'op': 'exists'},
          {
            'type': 'not',
            'child': memberIn('class', [classPaper]),
          },
        ],
      });
      // Field names are case-insensitive like the rest of the grammar.
      expect(only(parse('NAME:paris')).toJson(),
          {'type': 'name', 'op': 'contains', 'value': 'paris'});
      // Quoted multi-word titles survive whole.
      expect(only(parse('name:"Lone Page"')).toJson(),
          {'type': 'name', 'op': 'contains', 'value': 'Lone Page'});
      expect(only(parse('name:="Lone Page"')).toJson(),
          {'type': 'name', 'op': 'eq', 'value': 'Lone Page'});
    });

    test('linked:Name resolves the node by name', () {
      expect(only(parse('linked:Paris')).toJson(),
          memberIn('links', [nodeParis]));
    });

    test('prop:<name>:<value> with a bare colon is contains', () {
      expect(only(parse('prop:title:revolution')).toJson(), {
        'type': 'property',
        'schemaId': schemaTitle,
        'op': 'contains',
        'value': 'revolution',
      });
    });

    test('prop with no value is exists (also before AND/OR/NOT)', () {
      expect(only(parse('prop:year')).toJson(),
          {'type': 'property', 'schemaId': schemaYear, 'op': 'exists'});
      expect(only(parse('prop:year:')).toJson(),
          {'type': 'property', 'schemaId': schemaYear, 'op': 'exists'});
      expect(parse('prop:year NOT class:paper').root.toJson(), {
        'type': 'group',
        'logic': 'and',
        'children': [
          {'type': 'property', 'schemaId': schemaYear, 'op': 'exists'},
          {
            'type': 'not',
            'child': memberIn('class', [classPaper]),
          },
        ],
      });
    });

    test('a bare property-schema field is shorthand for prop: (year:>2010)',
        () {
      expect(only(parse('year:>2010')).toJson(), {
        'type': 'property',
        'schemaId': schemaYear,
        'op': 'gt',
        'value': 2010,
      });
      expect(only(parse('title:revolution')).toJson(), {
        'type': 'property',
        'schemaId': schemaTitle,
        'op': 'contains',
        'value': 'revolution',
      });
    });

    test('citekey:/author: pin the bare-schema shorthand (property '
        'conditions)', () {
      expect(only(parse('citekey:doe2024')).toJson(), {
        'type': 'property',
        'schemaId': schemaCitekey,
        'op': 'contains',
        'value': 'doe2024',
      });
      expect(only(parse('author:doe')).toJson(), {
        'type': 'property',
        'schemaId': schemaAuthor,
        'op': 'contains',
        'value': 'doe',
      });
      expect(only(parse('citekey:="doe2024"')).toJson(), {
        'type': 'property',
        'schemaId': schemaCitekey,
        'op': 'eq',
        'value': 'doe2024',
      });
    });

    test(
        'coverAsset:/bannerAsset:/aliasedNode: bare is the set probe, a value '
        'is eq (uuid passthrough or node-name resolution)', () {
      const assetUuid = '0192a000-0000-7000-8000-000000000501';
      const otherUuid = '0192a000-0000-7000-8000-000000000502';
      expect(only(parse('coverAsset:')).toJson(),
          {'type': 'nodeField', 'field': 'coverAsset', 'op': 'exists'});
      // Bare colon before a boolean keyword still reads exists (the prop:
      // precedent).
      expect(parse('coverAsset: NOT bannerAsset:').root.toJson(), {
        'type': 'group',
        'logic': 'and',
        'children': [
          {'type': 'nodeField', 'field': 'coverAsset', 'op': 'exists'},
          {
            'type': 'not',
            'child': {'type': 'nodeField', 'field': 'bannerAsset', 'op': 'exists'},
          },
        ],
      });
      // A uuid value skips name resolution.
      expect(only(parse('coverAsset:$assetUuid')).toJson(), {
        'type': 'nodeField',
        'field': 'coverAsset',
        'op': 'eq',
        'value': assetUuid,
      });
      expect(only(parse('bannerAsset:=$assetUuid')).toJson(), {
        'type': 'nodeField',
        'field': 'bannerAsset',
        'op': 'eq',
        'value': assetUuid,
      });
      // A non-uuid value resolves through the node-name resolver (linked:
      // precedent).
      expect(only(parse('aliasedNode:Paris')).toJson(), {
        'type': 'nodeField',
        'field': 'aliasedNode',
        'op': 'eq',
        'value': nodeParis,
      });
      // "!=" is neq (SQL NULL semantics: unset matches neither — "is unset"
      // is NOT coverAsset:).
      expect(only(parse('coverAsset!=$otherUuid')).toJson(), {
        'type': 'nodeField',
        'field': 'coverAsset',
        'op': 'neq',
        'value': otherUuid,
      });
      // Field names are case-insensitive like the rest of the grammar.
      expect(only(parse('CoverAsset:')).toJson(),
          {'type': 'nodeField', 'field': 'coverAsset', 'op': 'exists'});
    });
  });

  group('parseQueryLanguage: operators', () {
    final ops = <(String, String, Object)>[
      (':=', 'eq', 1950),
      ('=', 'eq', 1950),
      ('!=', 'neq', 1950),
      (':>', 'gt', 1950),
      ('>', 'gt', 1950),
      (':>=', 'gte', 1950),
      ('>=', 'gte', 1950),
      (':<', 'lt', 1950),
      ('<', 'lt', 1950),
      (':<=', 'lte', 1950),
      ('<=', 'lte', 1950),
    ];
    for (final (syntax, op, value) in ops) {
      test('prop:year$syntax' '1950 → $op', () {
        expect(only(parse('prop:year$syntax' '1950')).toJson(), {
          'type': 'property',
          'schemaId': schemaYear,
          'op': op,
          'value': value,
        });
      });
    }

    test('numeric values coerce to JSON numbers; ISO dates stay strings',
        () {
      expect((only(parse('year:>2010')) as PropertyCondition).value, 2010);
      final date = parse(
        'prop:published:>=2024-01-01',
        resolversOverride: QueryLanguageResolvers(
          resolvePropertySchema: (n) =>
              n == 'published' ? schemaTitle : null,
        ),
      );
      expect(only(date).toJson(), {
        'type': 'property',
        'schemaId': schemaTitle,
        'op': 'gte',
        'value': '2024-01-01',
      });
    });

    test('values with colons/slashes survive whole (URLs, DOIs)', () {
      expect(only(parse('text:https://example.com/x')).toJson(), {
        'type': 'content',
        'op': 'contains',
        'value': 'https://example.com/x',
      });
      expect(only(parse('prop:title:10.2307/2333763')).toJson(), {
        'type': 'property',
        'schemaId': schemaTitle,
        'op': 'contains',
        'value': '10.2307/2333763',
      });
    });
  });

  group('parseQueryLanguage: composition', () {
    test('multiple bare words AND implicitly', () {
      expect(parse('capital france').root.toJson(), {
        'type': 'group',
        'logic': 'and',
        'children': [
          {'type': 'content', 'op': 'contains', 'value': 'capital'},
          {'type': 'content', 'op': 'contains', 'value': 'france'},
        ],
      });
    });

    test('AND / OR / NOT / parens compose exactly', () {
      expect(parse('class:paper AND year:>2010 OR NOT class:book').root.toJson(), {
        'type': 'group',
        'logic': 'or',
        'children': [
          {
            'type': 'group',
            'logic': 'and',
            'children': [
              memberIn('class', [classPaper]),
              {
                'type': 'property',
                'schemaId': schemaYear,
                'op': 'gt',
                'value': 2010,
              },
            ],
          },
          {
            'type': 'not',
            'child': memberIn('class', [classBook]),
          },
        ],
      });
    });

    test('parenthesized groups nest', () {
      expect(parse('(class:paper OR class:book) AND text:revolution').root.toJson(), {
        'type': 'group',
        'logic': 'and',
        'children': [
          {
            'type': 'group',
            'logic': 'or',
            'children': [
              memberIn('class', [classPaper]),
              memberIn('class', [classBook]),
            ],
          },
          {'type': 'content', 'op': 'contains', 'value': 'revolution'},
        ],
      });
    });

    test('NOT negates a parenthesized group', () {
      expect(parse('NOT (class:paper OR class:book)').root.toJson(), {
        'type': 'group',
        'logic': 'and',
        'children': [
          {
            'type': 'not',
            'child': {
              'type': 'group',
              'logic': 'or',
              'children': [
                memberIn('class', [classPaper]),
                memberIn('class', [classBook]),
              ],
            },
          },
        ],
      });
    });

    test('!= negates class, boolean and linked conditions', () {
      expect(only(parse('class!=paper')).toJson(), {
        'type': 'not',
        'child': memberIn('class', [classPaper]),
      });
      expect(only(parse('isClass!=true')).toJson(), {
        'type': 'not',
        'child': {
          'type': 'nodeField',
          'field': 'isClass',
          'op': 'eq',
          'value': 'true',
        },
      });
      expect(only(parse('isEmbedded!=false')).toJson(), {
        'type': 'not',
        'child': {
          'type': 'nodeField',
          'field': 'isEmbedded',
          'op': 'eq',
          'value': 'false',
        },
      });
      expect(only(parse('linked!=Paris')).toJson(), {
        'type': 'not',
        'child': memberIn('links', [nodeParis]),
      });
    });

    test('quoted phrases are content-contains terms (usable as field values '
        'too)', () {
      expect(only(parse('"scientific revolutions"')).toJson(), {
        'type': 'content',
        'op': 'contains',
        'value': 'scientific revolutions',
      });
      expect(only(parse('prop:title:"The Structure of Scientific Revolutions"'))
          .toJson(), {
        'type': 'property',
        'schemaId': schemaTitle,
        'op': 'contains',
        'value': 'The Structure of Scientific Revolutions',
      });
    });

    test('the emitted AST validates against the strict queryAstSchema', () {
      expect(() => QueryAst.parse(parse('class:paper AND year:>2010').toJson()),
          returnsNormally);
      expect(
          () => QueryAst.parse(
              parse('name:="Lone Page" AND class:paper').toJson()),
          returnsNormally);
    });
  });

  group('parseQueryLanguage: errors (fail loud)', () {
    test('unknown field lists the known fields', () {
      try {
        parse('wobble:42');
        fail('expected a QueryLanguageError');
      } on QueryLanguageError catch (error) {
        expect(
          error.message,
          "unknown field 'wobble' (known fields: class, isclass, "
          'presentasmain, prop, text, name, linked, coverasset, '
          'bannerasset, aliasednode, year, title)',
        );
      }
    });

    test('unknown class / schema / node names fail at resolution', () {
      expect(() => parse('class:galaxy'),
          throwsA(predicate<QueryLanguageError>(
              (e) => e.message.contains("unknown class 'galaxy'"))));
      expect(() => parse('prop:mass:>1'),
          throwsA(predicate<QueryLanguageError>(
              (e) => e.message.contains("unknown field 'mass'"))));
      expect(() => parse('linked:Berlin'),
          throwsA(predicate<QueryLanguageError>(
              (e) => e.message.contains("unknown node 'Berlin'"))));
      expect(() => parse('coverAsset:Berlin'),
          throwsA(predicate<QueryLanguageError>(
              (e) => e.message.contains("unknown node 'Berlin'"))));
    });

    test(
        'wire node-field predicates reject operators that do not fit uuid '
        'references', () {
      expect(
          () => parse('coverAsset:>x'),
          throwsA(predicate<QueryLanguageError>(
              (e) => e.message.contains('not supported here'))));
      expect(
          () => parse('bannerAsset:x contains y'),
          throwsA(predicate<QueryLanguageError>(
              (e) => e.message.contains("unknown node 'x'"))));
    });

    test(
        'unresolvable names surface the resolver miss even '
        'case-insensitively', () {
      // Resolvers here are exact: 'PAPER' does not resolve.
      expect(
        () => parseQueryLanguage(
          'class:PAPER',
          ParseQueryLanguageOptions(
            resolvers: QueryLanguageResolvers(
              resolveClass: (n) => n == 'paper' ? classPaper : null,
            ),
          ),
        ),
        throwsA(predicate<QueryLanguageError>(
            (e) => e.message.contains("unknown class 'PAPER'"))),
      );
    });

    test('rejects unsupported operators per field', () {
      expect(
          () => parse('class:paper>3'),
          throwsA(predicate<QueryLanguageError>(
              (e) => e.message.contains("unexpected '>'"))));
      expect(
          () => parse('text!=foo'),
          throwsA(predicate<QueryLanguageError>(
              (e) => e.message.contains('not supported for text'))));
      expect(
          () => parse('name:>paris'),
          throwsA(predicate<QueryLanguageError>(
              (e) => e.message.contains('not supported for name'))));
      expect(
          () => parse('name:>=paris'),
          throwsA(predicate<QueryLanguageError>(
              (e) => e.message.contains('not supported for name'))));
      expect(
          () => parse('isClass:galaxy'),
          throwsA(predicate<QueryLanguageError>((e) =>
              e.message.contains("unknown isClass value 'galaxy'") &&
              e.message.contains('expected true or false'))));
      expect(
          () => parse('isEmbedded:1'),
          throwsA(predicate<QueryLanguageError>(
              (e) => e.message.contains("unknown isEmbedded value '1'"))));
    });

    test('rejects a comparison operator without a value', () {
      expect(
          () => parse('year:>'),
          throwsA(predicate<QueryLanguageError>(
              (e) => e.message.contains('requires a value'))));
      expect(
          () => parse('name:='),
          throwsA(predicate<QueryLanguageError>(
              (e) => e.message.contains('requires a value'))));
      expect(
          () => parse('name!='),
          throwsA(predicate<QueryLanguageError>(
              (e) => e.message.contains('requires a value'))));
    });

    test('rejects unterminated strings, stray parens and trailing tokens',
        () {
      expect(
          () => parse('"unterminated'),
          throwsA(predicate<QueryLanguageError>(
              (e) => e.message.contains('unterminated string'))));
      expect(
          () => parse('(class:paper'),
          throwsA(predicate<QueryLanguageError>(
              (e) => e.message.contains("expected ')'"))));
      expect(
          () => parse('class:paper)'),
          throwsA(predicate<QueryLanguageError>(
              (e) => e.message.contains('unexpected'))));
      expect(
          () => parse('year!x'),
          throwsA(predicate<QueryLanguageError>(
              (e) => e.message.contains("unexpected character '!'"))));
    });

    test('errors carry the source position', () {
      try {
        parse('class:paper)');
        fail('expected a QueryLanguageError');
      } on QueryLanguageError catch (error) {
        expect(error.position, 11);
      }
    });
  });

  group('looksLikeQueryLanguage', () {
    test('detects field prefixes, boolean keywords and quoted phrases', () {
      expect(looksLikeQueryLanguage('class:paper AND year:>2010'), isTrue);
      expect(looksLikeQueryLanguage('year:1950'), isTrue);
      expect(looksLikeQueryLanguage('notes AND reminders'), isTrue);
      expect(looksLikeQueryLanguage('"exact phrase"'), isTrue);
    });

    test('leaves plain text alone (incl. URL-scheme and clock-time colons)',
        () {
      expect(looksLikeQueryLanguage('meeting notes'), isFalse);
      expect(looksLikeQueryLanguage('https://example.com/docs'), isFalse);
      expect(looksLikeQueryLanguage('12:30 lunch'), isFalse);
      expect(looksLikeQueryLanguage(''), isFalse);
    });
  });
}
