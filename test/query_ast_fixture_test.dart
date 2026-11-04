import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notees/domain/query/query_ast.dart';
import 'package:notees/domain/query/query_compiler.dart';
import 'package:notees/domain/query/query_placeholders.dart';

/// The fixture gate's parse-through arm: the vendored query-AST v2 fixture
/// (byte-pinned corpus — never edited here) strict-parses, walks every
/// condition shape in it, and compiles against the local schema (self
/// hosted — the fixture's `self` targets need a host). Plus the fail-loud
/// pins: v1 rejection and the structural couplings.
void main() {
  const fixturePath = 'test/fixtures/wire/query-ast-v2.json';

  Map<String, dynamic> loadFixtureAst() {
    final raw =
        jsonDecode(File(fixturePath).readAsStringSync()) as Map<String, dynamic>;
    final envelopes = raw['envelopes'] as List<dynamic>;
    for (final envelope in envelopes) {
      final payload = (envelope as Map<String, dynamic>)['payload']
          as Map<String, dynamic>;
      final contentAst = payload['contentAst'];
      if (contentAst is! List) continue;
      for (final token in contentAst) {
        if (token is Map<String, dynamic> && token['type'] == 'query') {
          return token['queryAst'] as Map<String, dynamic>;
        }
      }
    }
    throw StateError('the fixture carries no query token');
  }

  /// Walks every condition/group/not node in the AST.
  void walkAst(QueryAstNode node, void Function(QueryAstNode) visit) {
    visit(node);
    if (node is Group) {
      for (final child in node.children) {
        walkAst(child, visit);
      }
    } else if (node is Not) {
      walkAst(node.child, visit);
    } else if (node is MemberCondition) {
      final target = node.target;
      if (target is QueryTarget) {
        walkAst(target.root, visit);
      }
    }
  }

  group('the query-ast-v2 fixture', () {
    test('strict-parses and carries one of every v2 condition type', () {
      final ast = QueryAst.parse(loadFixtureAst());
      expect(ast.scope, isA<EntireWorkspaceScope>());

      final typeCounts = <String, int>{};
      final families = <String>{};
      final targetModes = <String>{};
      var maxDepth = 0;
      void tally(QueryAstNode node, [int depth = 0]) {
        maxDepth = depth > maxDepth ? depth : maxDepth;
        typeCounts[node.runtimeType.toString()] =
            (typeCounts[node.runtimeType.toString()] ?? 0) + 1;
        if (node is MemberCondition) {
          families.add(node.family);
          targetModes.add(node.target?.mode ?? '(none)');
        }
        walkAst(node, (child) {});
      }

      void walk(QueryAstNode node, int depth) {
        tally(node, depth);
        if (node is Group) {
          for (final child in node.children) {
            walk(child, depth + 1);
          }
        } else if (node is Not) {
          walk(node.child, depth);
        } else if (node is MemberCondition) {
          final target = node.target;
          if (target is QueryTarget) walk(target.root, depth + 1);
        }
      }

      walk(ast.root, 0);
      for (final type in [
        'MemberCondition',
        'ContentCondition',
        'NameCondition',
        'PropertyCondition',
        'DateCondition',
        'NodeFieldCondition',
        'Group',
        'Not',
      ]) {
        expect(typeCounts[type], greaterThan(0), reason: 'the fixture pins $type');
      }
      expect(families, hasLength(10), reason: 'all ten member families');
      expect(targetModes, containsAll(['ids', 'query', 'self']));
      expect(maxDepth, greaterThanOrEqualTo(2),
          reason: 'the depth-2 member-in-query nesting');
    });

    test('compiles against the local schema (self hosted) and round-trips',
        () {
      final ast = QueryAst.parse(loadFixtureAst());
      final compiled = compile(
        ast,
        const CompileOptions(
          selfNodeId: '0192a000-0000-7000-8000-00000000e1a1',
        ),
      );
      expect(compiled.sql, startsWith('SELECT n.*\nFROM node_cache n\nWHERE '));
      expect(compiled.params, isNotEmpty);
      // The serialized round-trip is byte-stable through the model.
      expect(QueryAst.parse(ast.toJson()).toJson(), ast.toJson());
    });
  });

  group('the fail-loud pins', () {
    Map<String, dynamic> withAst(Map<String, dynamic> ast) => {
          'version': 2,
          'scope': const {'type': 'entire_workspace'},
          'root': {
            'type': 'group',
            'logic': 'and',
            'children': [ast],
          },
        };

    test('version 1 rejects outright', () {
      final v1 = loadFixtureAst()..['version'] = 1;
      expect(() => QueryAst.parse(v1), throwsFormatException);
    });

    test('an unknown family rejects', () {
      expect(
        () => QueryAst.parse(withAst(const {
          'type': 'member',
          'family': 'cousin',
          'op': 'in',
          'target': {
            'mode': 'ids',
            'ids': ['0192a000-0000-7000-8000-000000000001'],
          },
        })),
        throwsFormatException,
      );
    });

    test('exists carrying a target rejects', () {
      expect(
        () => QueryAst.parse(withAst(const {
          'type': 'member',
          'family': 'class',
          'op': 'exists',
          'target': {
            'mode': 'ids',
            'ids': ['0192a000-0000-7000-8000-000000000001'],
          },
        })),
        throwsFormatException,
      );
    });

    test('exact with two ids rejects', () {
      expect(
        () => QueryAst.parse(withAst(const {
          'type': 'member',
          'family': 'class',
          'op': 'exact',
          'target': {
            'mode': 'ids',
            'ids': [
              '0192a000-0000-7000-8000-000000000001',
              '0192a000-0000-7000-8000-000000000002',
            ],
          },
        })),
        throwsFormatException,
      );
    });

    test('a self target without the host fails at compile time', () {
      final ast = QueryAst.parse(withAst(const {
        'type': 'member',
        'family': 'childPath',
        'op': 'in',
        'target': {'mode': 'self'},
      }));
      expect(() => compile(ast), throwsStateError);
    });

    test('referencePath/root exists fails at compile time', () {
      for (final family in ['referencePath', 'root']) {
        final ast = QueryAst.parse(withAst({'type': 'member', 'family': family, 'op': 'exists'}));
        expect(() => compile(ast), throwsStateError, reason: family);
      }
    });
  });
}
