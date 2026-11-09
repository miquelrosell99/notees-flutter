import 'package:flutter_test/flutter_test.dart';
import 'package:notees/domain/query/query_ast.dart';
import 'package:notees/domain/query/query_compiler.dart';
import 'package:notees/domain/query/query_placeholders.dart';

/// The compiler pins: SQL text + positional param vectors for the subtle
/// cases (bind order is part of the contract — every predicate is built
/// before the string composes), the documented schema deltas (F1 renames,
/// F2 active predicate, F3 fresh-scope alias, F4 class_cache demote join,
/// F5 FTS backend), the fail-loud arms, sort, and aggregation.
void main() {
  const uuidA = '0192a000-0000-7000-8000-000000000001';
  const uuidB = '0192a000-0000-7000-8000-000000000002';
  const uuidC = '0192a000-0000-7000-8000-000000000003';

  QueryAst ast(
    Object? child, {
    Object? scope = const {'type': 'entire_workspace'},
    List<Object?>? sort,
    Object? aggregation,
  }) =>
      QueryAst.parse({
        'version': 2,
        'scope': scope,
        'root': {
          'type': 'group',
          'logic': 'and',
          'children': [child],
        },
        'sort': ?sort,
        'aggregation': ?aggregation,
      });

  group('buildMatchExpression (the pure FTS match builder)', () {
    test('bare terms become prefix tokens ANDed together', () {
      expect(buildMatchExpression('hello world'), 'hello* AND world*');
    });

    test('splits at every non-alphanumeric boundary (unicode61 mirror)', () {
      expect(buildMatchExpression('11607-1'), '11607* AND 1*');
    });

    test('quoted segments become exact phrases; the rest stays bare', () {
      expect(buildMatchExpression('meet "grand canyon" now'),
          '"grand canyon" AND meet* AND now*');
    });

    test('unicode letters and digits are terms; punctuation is not', () {
      expect(buildMatchExpression('Perú vídeo 42'), 'Perú* AND vídeo* AND 42*');
    });

    test('nothing searchable yields null', () {
      expect(buildMatchExpression('  --  '), isNull);
      expect(buildMatchExpression(''), isNull);
    });
  });

  group('the whole-query shape', () {
    test('content contains: the F1/F2/F5 deltas in one SQL', () {
      final compiled = compile(ast({'type': 'content', 'op': 'contains', 'value': 'needle'}));
      expect(compiled.sql, startsWith('SELECT n.*\nFROM node_cache n\nWHERE '));
      expect(compiled.sql, contains("(n.is_deleted = 0 AND n.is_archived = 0)"));
      expect(compiled.sql, contains('search_index_fts_docid d'));
      expect(compiled.sql, contains('JOIN search_index_fts s ON s.rowid = d.docid'));
      expect(compiled.sql, contains("s.content LIKE '%' || ? || '%'"));
      expect(compiled.sql, endsWith('ORDER BY n.uuid ASC'));
      expect(compiled.params, ['needle']);
    });

    test('fts rides MATCH with the prefix-AND expression', () {
      final compiled = compile(ast({'type': 'content', 'op': 'fts', 'value': 'grand canyon'}));
      expect(compiled.sql, contains('search_index_fts MATCH ?'));
      expect(compiled.params, ['grand* AND canyon*']);
    });

    test('content exists probes a non-empty plaintext', () {
      final compiled = compile(ast(const {'type': 'content', 'op': 'exists'}));
      expect(compiled.sql, contains('length(s.content) > 0'));
      expect(compiled.params, isEmpty);
    });

    test('the pages scope carries the parentlessRole demote (F4)', () {
      final compiled = compile(
        ast(const {'type': 'name', 'op': 'exists'}, scope: const {'type': 'pages'}),
      );
      expect(
        compiled.sql,
        contains(
          'n.is_class = 0 AND (n.parent_uuid IS NULL OR n.is_embedded = 0)',
        ),
      );
      expect(compiled.sql, contains('JOIN class_cache c ON c.uuid = ch.ancestor_id'));
      expect(compiled.sql, contains("c.parentless_role = 'block'"));
    });
  });

  group('member families — the in/not-in arms', () {
    test('class ids: closure-aware ANY-of, params in id order', () {
      final compiled = compile(ast({
        'type': 'member',
        'family': 'class',
        'op': 'in',
        'target': {'mode': 'ids', 'ids': [uuidA, uuidB]},
      }));
      expect(
        compiled.sql,
        contains(
          'WHERE value IN (SELECT class_id FROM class_hierarchy WHERE ancestor_id IN (?, ?))',
        ),
      );
      expect(compiled.params, [uuidA, uuidB]);
    });

    test('class exact: single-id equality, no closure', () {
      final compiled = compile(ast({
        'type': 'member',
        'family': 'class',
        'op': 'exact',
        'target': {'mode': 'ids', 'ids': [uuidA]},
      }));
      expect(compiled.sql, contains('(SELECT COUNT(*) FROM json_each(n.classes_uuid)) = 1'));
      expect(compiled.params, [uuidA]);
    });

    test('tags ids: probes the projected tag_ids column', () {
      final compiled = compile(ast({
        'type': 'member',
        'family': 'tags',
        'op': 'in',
        'target': {'mode': 'ids', 'ids': [uuidA]},
      }));
      expect(compiled.sql, contains('json_each(n.tag_ids)'));
      expect(compiled.params, [uuidA]);
    });

    test('tags dynamic: the F3 fresh-scope alias m, never the outer n', () {
      final compiled = compile(ast({
        'type': 'member',
        'family': 'tags',
        'op': 'in',
        'target': {
          'mode': 'query',
          'root': {
            'type': 'group',
            'logic': 'and',
            'children': [
              {'type': 'nodeField', 'field': 'isClass', 'op': 'eq', 'value': 'true'},
            ],
          },
        },
      }));
      expect(compiled.sql, contains('FROM node_cache m WHERE (m.is_deleted = 0 AND m.is_archived = 0)'));
      expect(compiled.sql, contains('m.is_class = ?'));
      // The dynamic target subquery is the only `node_cache m` scope.
      expect(RegExp('FROM node_cache m').allMatches(compiled.sql).length, greaterThanOrEqualTo(1));
    });

    test('parent ids: ONE json_each param carrying the JSON list', () {
      final compiled = compile(ast({
        'type': 'member',
        'family': 'parent',
        'op': 'in',
        'target': {'mode': 'ids', 'ids': [uuidA, uuidB]},
      }));
      expect(compiled.sql, contains("COALESCE(n.parent_uuid, '') IN (SELECT value FROM json_each(?))"));
      expect(compiled.params, ['["$uuidA","$uuidB"]']);
    });

    test('childPath ids: the golden bind order — anchors, then the exclude list', () {
      final compiled = compile(ast({
        'type': 'member',
        'family': 'childPath',
        'op': 'in',
        'target': {'mode': 'ids', 'ids': [uuidA, uuidB]},
      }));
      expect(
        compiled.params,
        [uuidA, uuidB, '["$uuidA","$uuidB"]'],
        reason: 'the anchor ids bind in text order, then the ONE json_each '
            'exclude param (unindexed ? placeholders number per occurrence)',
      );
      expect(compiled.sql, contains('NOT IN (SELECT value FROM json_each(?))'));
    });

    test('links ids: the backlinksWithRollup CTE over the anchor list', () {
      final compiled = compile(ast({
        'type': 'member',
        'family': 'links',
        'op': 'in',
        'target': {'mode': 'ids', 'ids': [uuidA]},
      }));
      expect(compiled.sql, contains('WITH RECURSIVE anchors AS ('));
      expect(compiled.sql, contains('hits AS ('));
      expect(compiled.sql, contains('SELECT id, MIN(distance) AS distance FROM hits GROUP BY id'));
      expect(compiled.params, [uuidA]);
    });

    test('page ids: the pick reaches the correlated containing-page subquery', () {
      final compiled = compile(ast({
        'type': 'member',
        'family': 'page',
        'op': 'in',
        'target': {'mode': 'ids', 'ids': [uuidA]},
      }));
      expect(compiled.sql, contains('json_each(?)'));
      expect(compiled.sql, contains('WITH RECURSIVE up(id, depth) AS ('));
      expect(compiled.params, ['["$uuidA"]']);
    });

    test('root ids: the correlated rootId subquery', () {
      final compiled = compile(ast({
        'type': 'member',
        'family': 'root',
        'op': 'in',
        'target': {'mode': 'ids', 'ids': [uuidA]},
      }));
      expect(compiled.sql, contains('value = (SELECT pg.uuid FROM node_cache pg WHERE pg.uuid = ('));
      expect(compiled.params, ['["$uuidA"]']);
    });

    test('parentPath ids: the strict-ancestor recursive walk', () {
      final compiled = compile(ast({
        'type': 'member',
        'family': 'parentPath',
        'op': 'in',
        'target': {'mode': 'ids', 'ids': [uuidA]},
      }));
      expect(compiled.sql, contains('WITH RECURSIVE anc(id, depth) AS ('));
      expect(compiled.sql, contains('SELECT 1 FROM anc JOIN json_each(?) ON value = anc.id'));
      expect(compiled.params, ['["$uuidA"]']);
    });

    test('referencePath ids: self-or-ancestor rollup with the edge arm', () {
      final compiled = compile(ast({
        'type': 'member',
        'family': 'referencePath',
        'op': 'in',
        'target': {'mode': 'ids', 'ids': [uuidA]},
      }));
      expect(compiled.sql, contains('SELECT value AS id FROM json_each(?)'));
      expect(compiled.sql, contains('e.target_id = tv.id AND e.source_id IN (SELECT id FROM anc)'));
      expect(compiled.params, ['["$uuidA"]']);
    });

    test('not-in negates the membership predicate; not wraps a group', () {
      final notIn = compile(ast({
        'type': 'member',
        'family': 'tags',
        'op': 'not-in',
        'target': {'mode': 'ids', 'ids': [uuidA]},
      }));
      expect(notIn.sql, contains('NOT (EXISTS ('));
      final notGroup = compile(ast({
        'type': 'not',
        'child': {'type': 'name', 'op': 'contains', 'value': 'x'},
      }));
      expect(notGroup.sql, contains("NOT ((SELECT group_concat(json_extract(j.value, '\$.text'), ' ')"));
      expect(notGroup.params, ['x']);
    });

    test('self with the host binds selfNodeId', () {
      final compiled = compile(
        QueryAst.parse({
          'version': 2,
          'scope': {'type': 'entire_workspace'},
          'root': {
            'type': 'group',
            'logic': 'and',
            'children': [
              {
                'type': 'member',
                'family': 'child',
                'op': 'in',
                'target': {'mode': 'self'},
              }
            ],
          },
        }),
        const CompileOptions(selfNodeId: uuidC),
      );
      expect(compiled.sql, contains('c.uuid = ?'));
      expect(compiled.params, [uuidC]);
    });

    test('self without the host throws', () {
      expect(
        () => compile(QueryAst.parse({
              'version': 2,
              'scope': {'type': 'entire_workspace'},
              'root': {
                'type': 'group',
                'logic': 'and',
                'children': [
                  {
                    'type': 'member',
                    'family': 'child',
                    'op': 'in',
                    'target': {'mode': 'self'},
                  }
                ],
              },
            })),
        throwsStateError,
      );
    });
  });

  group('member families — the exists arms', () {
    test('class/tags count the JSON lists', () {
      final classExists = compile(ast(const {'type': 'member', 'family': 'class', 'op': 'exists'}));
      expect(classExists.sql, contains('(SELECT COUNT(*) FROM json_each(n.classes_uuid)) > 0'));
      final tagsExists = compile(ast(const {'type': 'member', 'family': 'tags', 'op': 'exists'}));
      expect(tagsExists.sql, contains('(SELECT COUNT(*) FROM json_each(n.tag_ids)) > 0'));
    });

    test('links probes the edge index; child the parent column', () {
      final links = compile(ast(const {'type': 'member', 'family': 'links', 'op': 'exists'}));
      expect(links.sql, contains('EXISTS (SELECT 1 FROM edge WHERE target_id = n.uuid)'));
      final child = compile(ast(const {'type': 'member', 'family': 'child', 'op': 'exists'}));
      expect(child.sql, contains('c.parent_uuid = n.uuid'));
      final page = compile(ast(const {'type': 'member', 'family': 'page', 'op': 'exists'}));
      expect(page.sql, contains('!= n.uuid'));
    });

    test('referencePath/root exists fail loud (no emptiness semantics)', () {
      for (final family in ['referencePath', 'root']) {
        expect(
          () => compile(ast({'type': 'member', 'family': family, 'op': 'exists'})),
          throwsStateError,
          reason: '$family has no emptiness read',
        );
      }
    });
  });

  group('property conditions', () {
    Map<String, Object?> propertyAst(String op, [Object? extra]) => {
          'type': 'property',
          'schemaId': uuidA,
          'op': op,
          if (extra is Map) ...extra,
        };

    test('eq: the effective CTEs then the bound — params in text order', () {
      final compiled = compile(ast(propertyAst('eq', {'value': 'needle'})));
      // CTE params first (schema, binding schema, shadow schema), then the bound.
      expect(compiled.params, [uuidA, uuidA, uuidA, 'needle']);
      expect(compiled.sql, contains('WITH authored AS ('));
      expect(compiled.sql, contains('derived AS ('));
      expect(compiled.sql, contains('json_extract(value, \'\$\') = ?'));
    });

    test('includeDefaults false skips the derived CTE arm', () {
      final compiled = compile(
        ast(propertyAst('eq', {'value': 'needle', 'includeDefaults': false})),
      );
      expect(compiled.sql, isNot(contains('derived AS (')));
      expect(compiled.params, [uuidA, 'needle']);
    });

    test('an ISO-date bound gains the date-node-ref containment arm', () {
      final compiled = compile(ast(propertyAst('eq', {'value': '2026-11-04'})));
      expect(compiled.sql, contains("substr(json_extract(value, '\$.nodeId'), 22, 2) = 'dd'"));
      // CTE params (3) then the point-arm params in arm order:
      // day, month, year payloads, then the range-arm start + end bounds.
      expect(
        compiled.params,
        [uuidA, uuidA, uuidA, '2026-11-04', '20261104', '202611', '2026', '202611040000', '20261104', '202611', '2026'],
      );
    });

    test('between with ISO bounds gates the scalar arm to non-objects', () {
      final compiled = compile(
        ast(propertyAst('between', {'from': '2026-11-01', 'to': '2026-11-30'})),
      );
      expect(compiled.sql, contains("json_type(value, '\$') != 'object'"));
      expect(compiled.params, [
        uuidA,
        uuidA,
        uuidA,
        '2026-11-01',
        '2026-11-30',
        '202611010000',
        '202611010000',
        '202611300000',
        '202611300000',
      ]);
    });

    test('a null bound on a value op fails loud', () {
      expect(() => compile(ast(propertyAst('eq'))), throwsStateError);
      expect(() => compile(ast(propertyAst('gt'))), throwsStateError);
    });

    test('contains casts the scalar to text', () {
      final compiled = compile(ast(propertyAst('contains', {'value': 'needle'})));
      expect(compiled.sql, contains("CAST(json_extract(value, '\$') AS TEXT) LIKE '%' || ? || '%'"));
    });
  });

  group('date conditions', () {
    final options = CompileOptions(now: DateTime(2026, 11, 4, 12));

    test('eq is day-granular over the local day (UTC bounds)', () {
      final compiled = compile(
        ast({
          'type': 'date',
          'field': 'created',
          'op': 'eq',
          'timestamp': '2026-11-04',
        }),
        options,
      );
      expect(
        compiled.sql,
        contains('n.created_at >= ? AND n.created_at <= ?'),
      );
      expect(
        compiled.params,
        [
          DateTime(2026, 11, 4).toUtc().toIso8601String(),
          DateTime(2026, 11, 4, 23, 59, 59, 999).toUtc().toIso8601String(),
        ],
      );
    });

    test('neq negates the day match; gt compares against the instant', () {
      final neq = compile(
        ast({'type': 'date', 'field': 'updated', 'op': 'neq', 'timestamp': '2026-11-04'}),
        options,
      );
      expect(neq.sql, contains('NOT (n.updated_at >= ? AND n.updated_at <= ?)'));
      final gt = compile(
        ast({'type': 'date', 'field': 'created', 'op': 'gt', 'timestamp': '2026-11-04T10:00:00.000Z'}),
        options,
      );
      expect(gt.sql, contains('n.created_at > ?'));
      expect(gt.params, ['2026-11-04T10:00:00.000Z']);
    });

    test('after/before resolve placeholders; between needs both bounds', () {
      final after = compile(
        ast({'type': 'date', 'field': 'created', 'op': 'after', 'timestamp': '{today}'}),
        options,
      );
      expect(after.params, [DateTime(2026, 11, 4).toUtc().toIso8601String()]);
      expect(
        () => compile(ast({'type': 'date', 'field': 'created', 'op': 'between', 'from': '2026-11-01'})),
        throwsStateError,
      );
    });

    test('within resolves the period bounds against the pinned clock', () {
      final compiled = compile(
        ast({'type': 'date', 'field': 'created', 'op': 'within', 'period': 'today'}),
        options,
      );
      expect(
        compiled.params,
        [
          DateTime(2026, 11, 4).toUtc().toIso8601String(),
          DateTime(2026, 11, 4, 23, 59, 59, 999).toUtc().toIso8601String(),
        ],
      );
    });

    test('a missing timestamp on a comparison op fails loud', () {
      expect(
        () => compile(ast({'type': 'date', 'field': 'created', 'op': 'gt'})),
        throwsStateError,
      );
    });
  });

  group('nodeField + name conditions', () {
    test('isClass/isEmbedded ride eq with "true"/"false"', () {
      final compiled = compile(
        ast({'type': 'nodeField', 'field': 'isClass', 'op': 'eq', 'value': 'true'}),
      );
      expect(compiled.sql, contains('n.is_class = ?'));
      expect(compiled.params, [1]);
      expect(
        () => compile(ast({'type': 'nodeField', 'field': 'isClass', 'op': 'neq', 'value': 'true'})),
        throwsStateError,
      );
      expect(
        () => compile(ast({'type': 'nodeField', 'field': 'isEmbedded', 'op': 'eq', 'value': 'yes'})),
        throwsStateError,
      );
    });

    test('coverAsset exists is the IS NOT NULL probe', () {
      final compiled = compile(
        ast(const {'type': 'nodeField', 'field': 'coverAsset', 'op': 'exists'}),
      );
      expect(compiled.sql, contains('n.cover_asset_id IS NOT NULL'));
      expect(compiled.params, isEmpty);
    });

    test('aliasedNode eq/neq compare the reference id', () {
      final compiled = compile(
        ast({'type': 'nodeField', 'field': 'aliasedNode', 'op': 'neq', 'value': uuidA}),
      );
      expect(compiled.sql, contains('n.aliased_node_id != ?'));
      expect(compiled.params, [uuidA]);
    });

    test('name contains LIKEs the flattened title; eq is exact BINARY', () {
      final containsResult = compile(ast({'type': 'name', 'op': 'contains', 'value': 'x'}));
      expect(containsResult.sql, contains("LIKE '%' || ? || '%'"));
      expect(containsResult.params, ['x']);
      final eq = compile(ast({'type': 'name', 'op': 'eq', 'value': 'Exact'}));
      expect(eq.sql, contains('= ?'));
      final existsResult = compile(ast(const {'type': 'name', 'op': 'exists'}));
      expect(existsResult.sql, contains('COALESCE(length('));
      expect(existsResult.sql, isNot(contains('LIKE')));
    });
  });

  group('scopes, sort, aggregation', () {
    test('subtree joins the recursive set with the distance column', () {
      final compiled = compile(
        ast(const {'type': 'name', 'op': 'exists'}, scope: {'type': 'subtree', 'pageId': uuidA}),
      );
      expect(compiled.sql, startsWith('SELECT n.*, sc.distance AS distance\nFROM node_cache n\nJOIN ('));
      expect(compiled.sql, contains('WITH RECURSIVE sub(id, distance) AS ('));
      expect(compiled.sql, contains('sc.id = n.uuid'));
      expect(compiled.params, [uuidA]);
    });

    test('linkedTo joins the backlinksWithRollup set', () {
      final compiled = compile(
        ast(const {'type': 'name', 'op': 'exists'}, scope: {'type': 'linkedTo', 'nodeId': uuidA}),
      );
      expect(compiled.sql, contains('FROM hits GROUP BY id'));
      expect(compiled.params, [uuidA]);
    });

    test('sort: NULLS-last via IS NULL, NOCASE on the name, id tiebreak', () {
      final compiled = compile(
        ast(const {'type': 'name', 'op': 'exists'}, sort: [
          {'field': 'name', 'dir': 'asc'},
          {'field': 'createdAt', 'dir': 'desc'},
        ]),
      );
      final orderBy = compiled.sql.split('ORDER BY ').last;
      expect(
        orderBy,
        contains("IS NULL, (SELECT group_concat(json_extract(j.value, '\$.text'), ' ') FROM json_each(n.name) j WHERE json_extract(j.value, '\$.type') = 'text') COLLATE NOCASE ASC"),
      );
      expect(orderBy, contains('n.created_at IS NULL, n.created_at DESC'));
      expect(orderBy, endsWith(', n.uuid ASC'));
    });

    test('aggregation: the filtered CTE, deterministic columns, no sort', () {
      final compiled = compileAggregate(QueryAst.parse({
        'version': 2,
        'scope': {'type': 'entire_workspace'},
        'root': {
          'type': 'group',
          'logic': 'and',
          'children': [
            {'type': 'nodeField', 'field': 'isClass', 'op': 'eq', 'value': 'false'},
          ],
        },
        'aggregation': {
          'dimensions': [
            {'kind': 'isClass'},
          ],
          'measures': [
            {'function': 'count', 'kind': 'node'},
            {'function': 'countDistinct', 'kind': 'node'},
          ],
        },
      }));
      expect(compiled.columns, ['isClass', 'count', 'countDistinct']);
      expect(compiled.sql, startsWith('WITH filtered AS ('));
      expect(compiled.sql, contains('COUNT(*) AS "count"'));
      expect(compiled.sql, contains('COUNT(DISTINCT f.uuid) AS "countDistinct"'));
      expect(compiled.sql, contains('GROUP BY "isClass"'));
      expect(compiled.sql, contains('ORDER BY "isClass" ASC'));
    });

    test('zero dimensions is the grand total (no GROUP BY)', () {
      final compiled = compileAggregate(QueryAst.parse({
        'version': 2,
        'scope': {'type': 'entire_workspace'},
        'root': {
          'type': 'group',
          'logic': 'and',
          'children': [],
        },
        'aggregation': {
          'dimensions': [],
          'measures': [
            {'function': 'count', 'kind': 'node'},
          ],
        },
      }));
      expect(compiled.columns, ['count']);
      expect(compiled.sql, isNot(contains('GROUP BY')));
    });

    test('compile() redirects an aggregation AST to the aggregate SQL', () {
      final redirected = compile(QueryAst.parse({
        'version': 2,
        'scope': {'type': 'entire_workspace'},
        'root': {
          'type': 'group',
          'logic': 'and',
          'children': [],
        },
        'aggregation': {
          'dimensions': [],
          'measures': [
            {'function': 'count', 'kind': 'node'},
          ],
        },
      }));
      expect(redirected.sql, startsWith('WITH filtered AS ('));
    });

    test('compileAggregate without an aggregation fails loud', () {
      expect(
        () => compileAggregate(QueryAst.parse({
              'version': 2,
              'scope': {'type': 'entire_workspace'},
              'root': {'type': 'group', 'logic': 'and', 'children': []},
            })),
        throwsStateError,
      );
    });
  });
}
