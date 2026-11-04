import 'package:flutter_test/flutter_test.dart';
import 'package:notees/domain/query/query_ast.dart';

/// The strict v2 parse matrix — a port of the zod grammar's pins: every
/// condition type/family/op/target-mode round-trips, the structural
/// couplings fail loud, and v1 plus every unknown shape rejects outright
/// (no dual-parse).
void main() {
  const uuidA = '0192a000-0000-7000-8000-000000000001';
  const uuidB = '0192a000-0000-7000-8000-000000000002';

  Map<String, dynamic> ast(Object? root, {Object? scope, int version = 2}) => {
        'version': version,
        'scope': scope ?? const {'type': 'entire_workspace'},
        'root': root,
      };

  Map<String, dynamic> groupWire(List<Object?> children,
          {String logic = 'and'}) =>
      {'type': 'group', 'logic': logic, 'children': children};

  T roundTrips<T>(T parsed, Object? wire) {
    expect((parsed as dynamic).toJson(), wire);
    return parsed;
  }

  group('scopes', () {
    test('all four scopes parse and round-trip', () {
      expect(QueryAst.parse(ast(groupWire([]), scope: const {'type': 'entire_workspace'})).scope,
          isA<EntireWorkspaceScope>());
      expect(QueryAst.parse(ast(groupWire([]), scope: const {'type': 'pages'})).scope,
          isA<PagesScope>());
      final subtree = QueryAst.parse(ast(groupWire([]),
          scope: {'type': 'subtree', 'pageId': uuidA}));
      expect((subtree.scope as SubtreeScope).pageId, uuidA);
      expect(roundTrips(subtree.scope, {'type': 'subtree', 'pageId': uuidA}),
          isA<SubtreeScope>());
      final linked = QueryAst.parse(ast(groupWire([]),
          scope: {'type': 'linkedTo', 'nodeId': uuidA}));
      expect((linked.scope as LinkedToScope).nodeId, uuidA);
      expect(roundTrips(linked.scope, {'type': 'linkedTo', 'nodeId': uuidA}),
          isA<LinkedToScope>());
    });

    test('unknown scope types and bad uuids reject', () {
      expect(() => QueryAst.parse(ast(groupWire([]), scope: const {'type': 'nope'})),
          throwsFormatException);
      expect(
          () => QueryAst.parse(
              ast(groupWire([]), scope: {'type': 'subtree', 'pageId': 'x'})),
          throwsFormatException);
      expect(() => QueryAst.parse(ast(groupWire([]), scope: {'type': 'pages', 'extra': 1})),
          throwsFormatException);
    });
  });

  group('member condition', () {
    test('in/not-in require a target; exists/not-exists forbid one', () {
      for (final op in ['in', 'not-in']) {
        expect(
          () => QueryAst.parse(ast(groupWire([
                {'type': 'member', 'family': 'class', 'op': op}
              ]))),
          throwsFormatException,
          reason: '$op without a target',
        );
      }
      for (final op in ['exists', 'not-exists']) {
        expect(
          () => QueryAst.parse(ast(groupWire([
                {
                  'type': 'member',
                  'family': 'tags',
                  'op': op,
                  'target': {'mode': 'ids', 'ids': [uuidA]},
                }
              ]))),
          throwsFormatException,
          reason: '$op carrying a target',
        );
      }
    });

    test('exact pins family class and a single-id list', () {
      expect(
        () => QueryAst.parse(ast(groupWire([
              {
                'type': 'member',
                'family': 'class',
                'op': 'exact',
                'target': {
                  'mode': 'ids',
                  'ids': [uuidA, uuidB]
                },
              }
            ]))),
        throwsFormatException,
      );
      expect(
        () => QueryAst.parse(ast(groupWire([
              {
                'type': 'member',
                'family': 'tags',
                'op': 'exact',
                'target': {'mode': 'ids', 'ids': [uuidA]},
              }
            ]))),
        throwsFormatException,
      );
      final parsed = QueryAst.parse(ast(groupWire([
        {
          'type': 'member',
          'family': 'class',
          'op': 'exact',
          'target': {'mode': 'ids', 'ids': [uuidA]},
        }
      ])));
      final member = (parsed.root.children.first as MemberCondition);
      expect(member.target, isA<IdsTarget>());
      expect((member.target! as IdsTarget).ids, [uuidA]);
    });

    test('all ten families over the three target modes parse', () {
      const families = [
        'class',
        'tags',
        'links',
        'referencePath',
        'parent',
        'child',
        'childPath',
        'page',
        'parentPath',
        'root',
      ];
      for (final family in families) {
        for (final target in [
          {'mode': 'ids', 'ids': [uuidA]},
          {'mode': 'ids', 'ids': [uuidA, uuidB]},
        ]) {
          final parsed = QueryAst.parse(ast(groupWire([
            {'type': 'member', 'family': family, 'op': 'in', 'target': target}
          ])));
          final member = parsed.root.children.first as MemberCondition;
          expect(member.family, family);
          expect(member.target, isA<IdsTarget>());
        }
        final self = QueryAst.parse(ast(groupWire([
          {'type': 'member', 'family': family, 'op': 'in', 'target': const {'mode': 'self'}}
        ])));
        expect((self.root.children.first as MemberCondition).target,
            isA<SelfTarget>());
        final dynamicArm = QueryAst.parse(ast(groupWire([
          {
            'type': 'member',
            'family': family,
            'op': 'not-in',
            'target': {
              'mode': 'query',
              'root': groupWire([
                {'type': 'nodeField', 'field': 'isClass', 'op': 'eq', 'value': 'true'}
              ]),
            },
          }
        ])));
        final target = (dynamicArm.root.children.first as MemberCondition).target!;
        expect(target, isA<QueryTarget>());
        expect((target as QueryTarget).root.logic, 'and');
      }
    });

    test('unknown families and ops reject', () {
      expect(
        () => QueryAst.parse(ast(groupWire([
              {
                'type': 'member',
                'family': 'cousin',
                'op': 'in',
                'target': {'mode': 'ids', 'ids': [uuidA]},
              }
            ]))),
        throwsFormatException,
      );
      expect(
        () => QueryAst.parse(ast(groupWire([
              {
                'type': 'member',
                'family': 'class',
                'op': 'overlaps',
                'target': {'mode': 'ids', 'ids': [uuidA]},
              }
            ]))),
        throwsFormatException,
      );
    });

    test('ids targets need at least one uuid', () {
      expect(
        () => QueryAst.parse(ast(groupWire([
              {'type': 'member', 'family': 'tags', 'op': 'in', 'target': const {'mode': 'ids', 'ids': []}}
            ]))),
        throwsFormatException,
      );
      expect(
        () => QueryAst.parse(ast(groupWire([
              {'type': 'member', 'family': 'tags', 'op': 'in', 'target': const {'mode': 'ids', 'ids': ['nope']}}
            ]))),
        throwsFormatException,
      );
    });
  });

  group('the five non-member condition types', () {
    test('content ops parse and round-trip', () {
      for (final op in ['contains', 'fts', 'eq', 'neq', 'starts', 'ends']) {
        final wire = {'type': 'content', 'op': op, 'value': 'needle'};
        final parsed = QueryAst.parse(ast(groupWire([wire])));
        final condition = parsed.root.children.first as ContentCondition;
        expect(condition.op, op);
        expect(condition.value, 'needle');
        expect(roundTrips(condition, wire), isA<ContentCondition>());
      }
      final existsWire = const {'type': 'content', 'op': 'exists'};
      final exists = QueryAst.parse(ast(groupWire([existsWire])));
      expect((exists.root.children.first as ContentCondition).value, isNull);
      expect(roundTrips(exists.root.children.first, existsWire),
          isA<ContentCondition>());
    });

    test('name ops parse', () {
      for (final op in ['eq', 'neq', 'contains', 'exists']) {
        final wire = {'type': 'name', 'op': op, 'value': 'Title'};
        final parsed = QueryAst.parse(ast(groupWire([wire])));
        expect((parsed.root.children.first as NameCondition).op, op);
      }
    });

    test('property folds value/from/to/period/includeDefaults', () {
      final wire = {
        'type': 'property',
        'schemaId': uuidA,
        'op': 'between',
        'from': 1,
        'to': 9,
      };
      final parsed = QueryAst.parse(ast(groupWire([wire])));
      final between = parsed.root.children.first as PropertyCondition;
      expect(between.op, 'between');
      expect(between.from, 1);
      expect(between.to, 9);
      final within = QueryAst.parse(ast(groupWire([
        {'type': 'property', 'schemaId': uuidA, 'op': 'within', 'period': 'this_week'}
      ])));
      expect((within.root.children.first as PropertyCondition).period, 'this_week');
      final eq = QueryAst.parse(ast(groupWire([
        {
          'type': 'property',
          'schemaId': uuidA,
          'op': 'eq',
          'value': 'x',
          'includeDefaults': false
        }
      ])));
      final eqCondition = eq.root.children.first as PropertyCondition;
      expect(eqCondition.includeDefaults, isFalse);
      expect(eqCondition.toJson(), {
        'type': 'property',
        'schemaId': uuidA,
        'op': 'eq',
        'value': 'x',
        'includeDefaults': false,
      });
      expect(
        () => QueryAst.parse(ast(groupWire([
              {'type': 'property', 'schemaId': 'nope', 'op': 'eq', 'value': 'x'}
            ]))),
        throwsFormatException,
      );
      expect(
        () => QueryAst.parse(ast(groupWire([
              {'type': 'property', 'schemaId': uuidA, 'op': 'within', 'period': 'someday'}
            ]))),
        throwsFormatException,
      );
    });

    test('date folds both fields over the full op set', () {
      for (final field in ['created', 'updated']) {
        for (final entry in [
          {'op': 'eq', 'timestamp': '2026-11-04'},
          {'op': 'neq', 'timestamp': '2026-11-04'},
          {'op': 'gt', 'timestamp': '2026-11-04'},
          {'op': 'gte', 'timestamp': '2026-11-04'},
          {'op': 'lt', 'timestamp': '2026-11-04'},
          {'op': 'lte', 'timestamp': '2026-11-04'},
          {'op': 'after', 'timestamp': '{today}'},
          {'op': 'before', 'timestamp': '{today}'},
          {'op': 'between', 'from': '2026-11-01', 'to': '2026-11-30'},
          {'op': 'within', 'period': 'this_month'},
        ]) {
          final wire = {'type': 'date', 'field': field, ...entry};
          final parsed = QueryAst.parse(ast(groupWire([wire])));
          final condition = parsed.root.children.first as DateCondition;
          expect(condition.field, field);
          expect(condition.op, entry['op']);
          expect(roundTrips(condition, wire), isA<DateCondition>());
        }
      }
      expect(
        () => QueryAst.parse(ast(groupWire([
              {'type': 'date', 'field': 'deleted', 'op': 'eq', 'timestamp': 'x'}
            ]))),
        throwsFormatException,
      );
    });

    test('nodeField folds the Revision-12 booleans and the wire predicates',
        () {
      for (final wire in [
        {'type': 'nodeField', 'field': 'isClass', 'op': 'eq', 'value': 'true'},
        {'type': 'nodeField', 'field': 'isEmbedded', 'op': 'eq', 'value': 'false'},
        {'type': 'nodeField', 'field': 'coverAsset', 'op': 'exists'},
        {'type': 'nodeField', 'field': 'bannerAsset', 'op': 'neq', 'value': uuidA},
        {'type': 'nodeField', 'field': 'aliasedNode', 'op': 'eq', 'value': uuidA},
      ]) {
        final parsed = QueryAst.parse(ast(groupWire([wire])));
        expect(roundTrips(parsed.root.children.first, wire),
            isA<NodeFieldCondition>());
      }
    });
  });

  group('group / not nesting', () {
    test('groups nest to depth and round-trip', () {
      final wire = groupWire([
        groupWire([
          {'type': 'name', 'op': 'contains', 'value': 'a'},
          {'type': 'name', 'op': 'contains', 'value': 'b'},
        ], logic: 'or'),
        const {'type': 'not', 'child': {'type': 'content', 'op': 'exists'}},
      ]);
      final parsed = QueryAst.parse(ast(wire));
      expect(parsed.root.children.first, isA<Group>());
      expect(parsed.root.children.last, isA<Not>());
      expect(parsed.root.toJson(), wire);
    });

    test('a query target nests a full group tree (depth 2)', () {
      final wire = {
        'type': 'member',
        'family': 'class',
        'op': 'in',
        'target': {
          'mode': 'query',
          'root': groupWire([
            groupWire([
              {'type': 'nodeField', 'field': 'isClass', 'op': 'eq', 'value': 'true'},
              const {'type': 'not', 'child': {'type': 'name', 'op': 'contains', 'value': 'x'}},
            ], logic: 'or'),
          ]),
        },
      };
      final parsed = QueryAst.parse(ast(groupWire([wire])));
      final target =
          (parsed.root.children.first as MemberCondition).target as QueryTarget;
      expect(target.root.children.first, isA<Group>());
      expect(parsed.root.toJson(), groupWire([wire]));
    });

    test('empty children and bad logic reject', () {
      expect(() => QueryAst.parse(ast(const {'type': 'group', 'logic': 'xor', 'children': []})),
          throwsFormatException);
    });
  });

  group('sort + aggregation', () {
    test('sort specs parse strictly', () {
      final parsed = QueryAst.parse({
        'version': 2,
        'scope': const {'type': 'pages'},
        'root': groupWire([]),
        'sort': [
          {'field': 'name', 'dir': 'asc'},
          {'field': 'createdAt', 'dir': 'desc'},
        ],
      });
      expect(parsed.sort!.map((s) => '${s.field}:${s.dir}'),
          ['name:asc', 'createdAt:desc']);
      expect(
        () => QueryAst.parse({
              'version': 2,
              'scope': const {'type': 'pages'},
              'root': groupWire([]),
              'sort': [
                {'field': 'relevance', 'dir': 'asc'}
              ],
            }),
        throwsFormatException,
      );
    });

    test('aggregation parses dimensions + measures', () {
      final wire = {
        'dimensions': [
          {'kind': 'class', 'id': uuidA},
          const {'kind': 'isClass'},
        ],
        'measures': [
          const {'function': 'count', 'kind': 'node'},
          {'function': 'avg', 'kind': 'property', 'id': uuidB},
        ],
      };
      final parsed = QueryAst.parse({
        'version': 2,
        'scope': const {'type': 'pages'},
        'root': groupWire([]),
        'aggregation': wire,
      });
      expect(parsed.aggregation!.dimensions, hasLength(2));
      expect(parsed.aggregation!.measures, hasLength(2));
      expect(parsed.aggregation!.toJson(), wire);
      expect(
        () => QueryAst.parse({
              'version': 2,
              'scope': const {'type': 'pages'},
              'root': groupWire([]),
              'aggregation': {
                'dimensions': const [],
                'measures': const [],
              },
            }),
        throwsFormatException,
      );
    });
  });

  group('the version + strictness gate', () {
    test('version 1 rejects outright — no dual-parse', () {
      expect(
        () => QueryAst.parse({
              'version': 1,
              'scope': const {'type': 'entire_workspace'},
              'root': groupWire([]),
            }),
        throwsFormatException,
      );
    });

    test('unknown condition types and unknown root keys reject', () {
      expect(
        () => QueryAst.parse(ast(groupWire([const {'type': 'style', 'op': 'x'}]))),
        throwsFormatException,
      );
      expect(
        () => QueryAst.parse({
              'version': 2,
              'scope': const {'type': 'entire_workspace'},
              'root': groupWire([]),
              'flags': const {'x': true},
            }),
        throwsFormatException,
      );
      expect(() => QueryAst.parse('nope'), throwsFormatException);
      expect(() => QueryAst.parse(null), throwsFormatException);
    });
  });
}
