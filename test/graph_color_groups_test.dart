import 'package:flutter_test/flutter_test.dart';
import 'package:notees/domain/graph/graph_color_group.dart';
import 'package:notees/domain/query/query_ast.dart';
import 'package:notees/domain/query/query_ast_v1_migration.dart';

/// The color-group pins: the pure v1→v2 mapping port (every condition
/// family lands on its v2 shape, fail-loud with the tree path), the
/// load-time migration contract (legacy DSL strings and stored v1 ASTs
/// rewrite or keep-and-mark-erroneous), and the first-match-wins
/// evaluation order.
void main() {
  const classA = '0192a000-0000-7000-8000-0000000000a1';
  const classB = '0192a000-0000-7000-8000-0000000000a2';

  group('mapQueryAstV1ToV2 (the pure mapping port)', () {
    Map<String, dynamic> v1Ast(Object child) => {
          'version': 1,
          'scope': const {'type': 'entire_workspace'},
          'root': {
            'type': 'group',
            'logic': 'and',
            'children': [child],
          },
        };

    Map<String, dynamic> mapped(Object child) {
      final result = mapQueryAstV1ToV2(v1Ast(child));
      expect(result['version'], 2);
      return ((result['root'] as Map)['children'] as List).single
          as Map<String, dynamic>;
    }

    test('classAny → member in ids (the many shape)', () {
      expect(mapped({'type': 'classAny', 'classIds': [classA, classB]}), {
        'type': 'member',
        'family': 'class',
        'op': 'in',
        'target': {
          'mode': 'ids',
          'ids': [classA, classB]
        },
      });
    });

    test('tag → member in ids (the one shape); classExact pins family+op',
        () {
      expect(mapped({'type': 'tag', 'tagId': classA}), {
        'type': 'member',
        'family': 'tags',
        'op': 'in',
        'target': {
          'mode': 'ids',
          'ids': [classA]
        },
      });
      expect(mapped({'type': 'classExact', 'classId': classA}), {
        'type': 'member',
        'family': 'class',
        'op': 'exact',
        'target': {
          'mode': 'ids',
          'ids': [classA]
        },
      });
    });

    test('the query/self/set hats become explicit target modes + exists',
        () {
      final queryShape = mapped({
        'type': 'linkedToQuery',
        'root': {
          'type': 'group',
          'logic': 'or',
          'children': [
            {'type': 'name', 'op': 'contains', 'value': 'x'}
          ],
        },
      });
      expect(queryShape['target'], {
        'mode': 'query',
        'root': {
          'type': 'group',
          'logic': 'or',
          'children': [
            {'type': 'name', 'op': 'contains', 'value': 'x'}
          ],
        },
      });
      expect(mapped({'type': 'parentOfSelf'}), {
        'type': 'member',
        'family': 'parent',
        'op': 'in',
        'target': {'mode': 'self'},
      });
      expect(mapped({'type': 'descendantSet'}), {
        'type': 'member',
        'family': 'childPath',
        'op': 'exists',
      });
    });

    test('contentSet → content exists; the ten date types fold', () {
      expect(mapped({'type': 'contentSet'}),
          {'type': 'content', 'op': 'exists'});
      expect(mapped({'type': 'createdWithin', 'period': 'week'}), {
        'type': 'date',
        'field': 'created',
        'op': 'within',
        'period': 'week',
      });
      expect(
          mapped({
            'type': 'updatedBetween',
            'from': '2026-01-01',
            'to': '2026-12-31'
          }),
          {
            'type': 'date',
            'field': 'updated',
            'op': 'between',
            'from': '2026-01-01',
            'to': '2026-12-31',
          });
      expect(
          mapped({
            'type': 'createdCmp',
            'op': '>=',
            'timestamp': '2026-06-01T00:00:00.000Z'
          }),
          {
            'type': 'date',
            'field': 'created',
            'op': '>=',
            'timestamp': '2026-06-01T00:00:00.000Z',
          });
    });

    test('isClass/isEmbedded fold to nodeField eq string booleans', () {
      expect(mapped({'type': 'isClass', 'isClass': true}), {
        'type': 'nodeField',
        'field': 'isClass',
        'op': 'eq',
        'value': 'true',
      });
      expect(mapped({'type': 'isEmbedded', 'isEmbedded': false}), {
        'type': 'nodeField',
        'field': 'isEmbedded',
        'op': 'eq',
        'value': 'false',
      });
    });

    test('not wrappers, nested groups, sort and scope pass through', () {
      final result = mapQueryAstV1ToV2({
        'version': 1,
        'scope': const {'type': 'pages'},
        'root': {
          'type': 'group',
          'logic': 'or',
          'children': [
            {
              'type': 'not',
              'child': {
                'type': 'group',
                'logic': 'and',
                'children': [
                  {'type': 'class', 'classId': classA},
                ],
              },
            },
          ],
        },
        'sort': const [
          {'field': 'name', 'direction': 'asc'}
        ],
      });
      expect(result['scope'], {'type': 'pages'});
      expect(result['sort'], [
        {'field': 'name', 'direction': 'asc'}
      ]);
      final not = (result['root'] as Map)['children'].single as Map;
      expect(not['type'], 'not');
      final inner = not['child'] as Map;
      expect(inner['logic'], 'and');
      expect((inner['children'] as List).single, {
        'type': 'member',
        'family': 'class',
        'op': 'in',
        'target': {
          'mode': 'ids',
          'ids': [classA]
        },
      });
    });

    test('fail-loud: unknown condition type throws with the tree path', () {
      expect(
        () => mapQueryAstV1ToV2(v1Ast({'type': 'nonsense'})),
        throwsA(isA<QueryAstV1MapError>().having(
          (e) => e.toString(),
          'message',
          contains(r'$.root.children[0]'),
        )),
      );
    });

    test('fail-loud: v2 input must NOT be re-mapped', () {
      expect(
        () => mapQueryAstV1ToV2({
          'version': 2,
          'scope': const {'type': 'entire_workspace'},
          'root': const {'type': 'group', 'logic': 'and', 'children': []},
        }),
        throwsA(isA<QueryAstV1MapError>()),
      );
    });

    test('isQueryAstV1: the structural guard', () {
      expect(isQueryAstV1(v1Ast({'type': 'name', 'op': 'contains', 'value': 'x'})), isTrue);
      expect(isQueryAstV1({'version': 2, 'root': const {}}), isFalse);
      expect(isQueryAstV1({'version': 1, 'scope': const {}, 'root': const {'type': 'notagroup', 'children': []}}), isFalse);
      expect(isQueryAstV1('nope'), isFalse);
    });
  });

  group('migrateColorGroup (the load-time migrations)', () {
    QueryAst memberClassAst() => QueryAst.parse({
          'version': 2,
          'scope': const {'type': 'entire_workspace'},
          'root': {
            'type': 'group',
            'logic': 'and',
            'children': [
              {
                'type': 'member',
                'family': 'class',
                'op': 'in',
                'target': {
                  'mode': 'ids',
                  'ids': [classA]
                },
              },
            ],
          },
        });

    test('a legacy DSL-string row parses through the injected DSL', () async {
      final group = await migrateColorGroup(
        const {
          'id': 'g1',
          'label': 'Papers',
          'color': 'sky',
          'query': 'class: Paper',
        },
        parseDsl: (_) async => memberClassAst(),
      );
      expect(group.id, 'g1');
      expect(group.color, 'sky');
      expect(group.error, isNull);
      expect(group.ast!.toJson(), memberClassAst().root.toJson());
    });

    test('a failing legacy parse keeps the group, painted nowhere', () async {
      final group = await migrateColorGroup(
        const {'id': 'g1', 'label': 'Broken', 'color': 'red', 'query': '???'},
        parseDsl: (dsl) async => throw FormatException('bad dsl: $dsl'),
      );
      expect(group.id, 'g1');
      expect(group.label, 'Broken');
      expect(group.ast, isNull);
      expect(group.error, contains('bad dsl'));
    });

    test('a stored v1 AST rewrites through the mapping', () async {
      final group = await migrateColorGroup(
        {
          'id': 'g1',
          'label': 'Legacy',
          'color': 'green',
          'ast': {
            'type': 'group',
            'logic': 'and',
            'children': [
              {'type': 'classAny', 'classIds': [classA, classB]},
            ],
          },
        },
        parseDsl: (_) async => memberClassAst(),
      );
      expect(group.error, isNull);
      expect(group.ast!.children.single, isA<MemberCondition>());
      final member = group.ast!.children.single as MemberCondition;
      expect(member.family, 'class');
      expect((member.target as IdsTarget).ids, [classA, classB]);
    });

    test('a v1 AST that fails the mapping keeps the group with the error',
        () async {
      final group = await migrateColorGroup(
        {
          'id': 'g1',
          'label': 'Broken',
          'color': 'red',
          'ast': {
            'type': 'group',
            'logic': 'and',
            'children': [
              {'type': 'nonsense'},
            ],
          },
        },
        parseDsl: (_) async => memberClassAst(),
      );
      expect(group.ast, isNull);
      expect(group.error, isNotNull);
    });

    test('an already-migrated v2 row passes through untouched', () async {
      final row = {
        'id': 'g1',
        'label': 'Meetings',
        'color': 'purple',
        'ast': memberClassAst().root.toJson(),
      };
      final group = await migrateColorGroup(row, parseDsl: (_) async {
        throw StateError('parseDsl must not run for a v2 row');
      });
      expect(group.error, isNull);
      expect(group.ast!.toJson(), memberClassAst().root.toJson());
    });
  });

  group('isV2ConditionTreeJson (the stored-tree guard)', () {
    test('v2 shapes pass; v1 condition types fail; not-wraps recurse', () {
      expect(
        isV2ConditionTreeJson([
          {'type': 'member', 'family': 'class', 'op': 'in', 'target': const {'mode': 'self'}},
          {'type': 'not', 'child': {'type': 'content', 'op': 'exists'}},
          {
            'type': 'group',
            'logic': 'or',
            'children': [
              {'type': 'nodeField', 'field': 'isClass', 'op': 'eq', 'value': 'true'},
            ],
          },
        ]),
        isTrue,
      );
      expect(isV2ConditionTreeJson(const [
        {'type': 'classAny', 'classIds': [classA]}
      ]), isFalse);
      expect(isV2ConditionTreeJson(const [
        {'type': 'not', 'child': {'type': 'tag', 'tagId': classA}}
      ]), isFalse);
      expect(isV2ConditionTreeJson('nope'), isFalse);
    });
  });

  group('evaluateColorGroups (first-match-wins)', () {
    // Each group carries a distinct content-exists condition; the stub
    // runner keys its canned results on that value — the AST shape is
    // irrelevant to the evaluation contract being pinned.
    GraphColorGroup contentGroup(String id, String color, String value) =>
        GraphColorGroup(
          id: id,
          label: id,
          color: color,
          ast: Group(
            logic: 'and',
            children: [ContentCondition(op: ContentOps.exists, value: value)],
          ),
        );

    Future<List<String>> stubRunner(
      QueryAst ast,
      Map<String, List<String>> resultsByValue,
    ) async {
      final child = ast.root.children.single as ContentCondition;
      final value = child.value!;
      if (value == 'boom') throw StateError('runner boom');
      return resultsByValue[value] ?? const [];
    }

    test('the FIRST matching group wins; later groups never overwrite',
        () async {
      final a = contentGroup('a', 'red', 'va');
      final b = contentGroup('b', 'sky', 'vb');
      final result = await evaluateColorGroups(
        [a, b],
        (ast) => stubRunner(ast, const {
          'va': ['n1', 'n2'],
          'vb': ['n2', 'n3'],
        }),
      );
      expect(result, {'n1': 'red', 'n2': 'red', 'n3': 'sky'});
    });

    test('erroneous and empty groups match nothing; a runner failure skips',
        () async {
      final broken = GraphColorGroup(
          id: 'broken', label: 'broken', color: 'red', error: 'bad');
      final empty = GraphColorGroup(
        id: 'empty',
        label: 'empty',
        color: 'sky',
        ast: const Group(logic: 'and', children: []),
      );
      final failing = contentGroup('failing', 'yellow', 'boom');
      final good = contentGroup('good', 'green', 'vg');
      final result = await evaluateColorGroups(
        [broken, empty, failing, good],
        (ast) => stubRunner(ast, const {
          'vg': ['n1'],
        }),
      );
      expect(result, {'n1': 'green'});
    });
  });

  group('colorGroupQueryAst (the workspace-scope wrapper)', () {
    test('wraps the root in the entire-workspace scope at version 2', () {
      final root = Group.fromJson(const {
        'type': 'group',
        'logic': 'and',
        'children': [
          {'type': 'content', 'op': 'exists'},
        ],
      });
      final ast = colorGroupQueryAst(root);
      expect(ast.scope, isA<EntireWorkspaceScope>());
      expect(identical(ast.root, root), isTrue);
      expect(ast.toJson()['version'], 2);
    });
  });

  group('GraphColorGroup (the row model)', () {
    test('toJson/fromJson round-trips the AST and the error slot', () {
      final ast = Group.fromJson(const {
        'type': 'group',
        'logic': 'and',
        'children': [
          {'type': 'name', 'op': 'contains', 'value': 'alpha'},
        ],
      });
      final group = GraphColorGroup(
        id: 'g1',
        label: 'Papers',
        color: '#a1b2c3',
        ast: ast,
      );
      final restored = GraphColorGroup.fromJson(group.toJson());
      expect(restored.id, 'g1');
      expect(restored.color, '#a1b2c3');
      expect(restored.ast!.toJson(), ast.toJson());
      expect(restored.error, isNull);

      final broken = GraphColorGroup(
          id: 'g2', label: 'Broken', color: 'red', error: 'nope');
      final restoredBroken = GraphColorGroup.fromJson(broken.toJson());
      expect(restoredBroken.ast, isNull);
      expect(restoredBroken.error, 'nope');
    });

    test('fromJson fails loud on a non-object and on missing strings', () {
      expect(() => GraphColorGroup.fromJson('nope'),
          throwsA(isA<FormatException>()));
      expect(() => GraphColorGroup.fromJson(const {'id': 'g1'}),
          throwsA(isA<FormatException>()));
    });
  });
}
