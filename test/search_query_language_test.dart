import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/models/node.dart';
import 'package:notees/data/repositories/server_repository.dart';
import 'package:notees/core/secure/secure_storage.dart';
import 'package:notees/domain/query/query_ast.dart';
import 'package:notees/domain/query/query_dsl.dart';
import 'package:notees/domain/query/query_placeholders.dart';
import 'package:notees/domain/services/query_service.dart';
import 'package:notees/features/auth/providers/auth_provider.dart';
import 'package:notees/features/search/screens/search_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The slice-2 search wiring, widget level: a query-language input routes
/// through the text query DSL (`looksLikeQueryLanguage` gate →
/// QueryService.parseQueryLanguage with the local-store resolvers) and the
/// DSL root rides the search AST INSTEAD of the plain content-contains
/// term; a plain input keeps the slice-1 path untouched; a DSL parse error
/// surfaces on the error pane (the DSL fails loud — no silent text-search
/// fallback). Per repo convention the service is faked (no sqflite under
/// testWidgets).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const found = '10000000-0000-7000-8000-0000000000a1';

  Node node(String uuid, String title) => Node(
        id: 0,
        uuid: uuid,
        name: jsonEncode([
          {'type': 'text', 'text': title}
        ]),
        displayName: title,
        isPage: true,
        classesUuid: const [],
        tagsUuid: const [],
        isEmbedded: false,
        createDate: '2026-11-01T09:00:00.000Z',
        writeDate: '2026-11-01T09:00:00.000Z',
      );

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> pumpScreen(WidgetTester tester, QueryService service) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<QueryService>.value(value: service),
          ChangeNotifierProvider<AuthProvider>(
            create: (_) => AuthProvider(
              serverRepository: ServerRepository(prefs: prefs),
              secureStorage: const SecureStorage(),
              prefs: prefs,
            ),
          ),
        ],
        child: MaterialApp(home: SearchScreen()),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
  }

  Future<void> typeQuery(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField).first, query);
    await tester.pump(const Duration(milliseconds: 400)); // the debounce
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
  }

  testWidgets('a query-language input routes through the DSL instead of the '
      'plain text filter', (tester) async {
    final service = _FakeQueryService([node(found, 'Quantum found page')]);
    await pumpScreen(tester, service);

    await typeQuery(tester, 'class:paper AND year:>2010');

    expect(service.parseCalls, ['class:paper AND year:>2010']);
    expect(find.text('Quantum found page'), findsOneWidget);
    // The DSL root rides the search AST instead of the content-contains
    // term: one AND child, no content condition.
    final ast = service.seenAsts.single;
    expect(ast.scope, isA<EntireWorkspaceScope>());
    expect(ast.root.children, hasLength(1));
    expect(ast.root.children.single, isA<Group>());
    expect(
      (ast.root.children.single as Group).children,
      everyElement(isNot(isA<ContentCondition>())),
    );
  });

  testWidgets('plain text keeps the slice-1 path (content contains, no DSL '
      'parse)', (tester) async {
    final service = _FakeQueryService([node(found, 'Quantum found page')]);
    await pumpScreen(tester, service);

    await typeQuery(tester, 'quantum');

    expect(service.parseCalls, isEmpty);
    final ast = service.seenAsts.single;
    expect(ast.root.children, hasLength(1));
    expect(ast.root.children.single.toJson(), {
      'type': 'content',
      'op': 'contains',
      'value': 'quantum',
    });
  });

  testWidgets('a DSL parse error lands on the error surface (fail loud, no '
      'silent fallback)', (tester) async {
    final service = _FakeQueryService(const [],
        parseError: const QueryLanguageError("unknown class 'galaxy'", 6));
    await pumpScreen(tester, service);

    await typeQuery(tester, 'class:galaxy');

    expect(service.parseCalls, ['class:galaxy']);
    expect(service.seenAsts, isEmpty);
    expect(find.textContaining("unknown class 'galaxy'"), findsOneWidget);
  });

  testWidgets('clock-time and URL inputs stay on the plain path (the '
      'heuristic leaves them alone)', (tester) async {
    final service = _FakeQueryService([node(found, 'Lunch page')]);
    await pumpScreen(tester, service);

    await typeQuery(tester, '12:30 lunch');

    expect(service.parseCalls, isEmpty);
    expect(
      service.seenAsts.single.root.children.single.toJson(),
      {'type': 'content', 'op': 'contains', 'value': '12:30 lunch'},
    );
  });
}

class _FakeQueryService extends QueryService {
  _FakeQueryService(this.results, {this.parseError})
      : super(database: null, cache: null);

  final List<Node> results;
  final QueryLanguageError? parseError;
  final List<QueryAst> seenAsts = [];
  final List<String> parseCalls = [];

  @override
  Future<List<Node>> runNodes(
    QueryAst ast, {
    CompileOptions options = const CompileOptions(),
  }) async {
    seenAsts.add(ast);
    return results;
  }

  @override
  Future<QueryAst> parseQueryLanguage(String text) async {
    parseCalls.add(text);
    final error = parseError;
    if (error != null) throw error;
    // A stand-in DSL parse: a single class-member condition (the shape the
    // real parser emits for `class:paper`).
    return QueryAst(
      scope: const EntireWorkspaceScope(),
      root: Group(
        logic: 'and',
        children: [
          MemberCondition(
            family: MemberFamilies.class_,
            op: 'in',
            target: const IdsTarget(
                ids: ['0192a000-0000-7000-8000-000000000201']),
          ),
        ],
      ),
    );
  }
}
