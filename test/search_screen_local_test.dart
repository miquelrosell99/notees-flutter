import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/models/node.dart';
import 'package:notees/data/repositories/server_repository.dart';
import 'package:notees/core/secure/secure_storage.dart';
import 'package:notees/domain/query/query_ast.dart';
import 'package:notees/domain/query/query_placeholders.dart';
import 'package:notees/domain/services/query_service.dart';
import 'package:notees/features/auth/providers/auth_provider.dart';
import 'package:notees/features/search/screens/search_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The slice-1 search surface, widget level: SearchScreen with a NULL Dio
/// (the offline case that used to short-circuit to an empty list) renders
/// the LOCAL runner's results. The DB-backed execution path (SearchFilters →
/// AST → compiler → sqflite) is proven by the query golden suite; per repo
/// convention the widget test seamms the service (no sqflite under
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
    // Flush the initial real-async loads (suggestions/history/view mode).
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
  }

  testWidgets('typing a query shows local results while offline (null Dio)',
      (tester) async {
    final service = _FakeQueryService([
      node(found, 'Quantum found page'),
    ]);
    await pumpScreen(tester, service);

    await tester.enterText(find.byType(TextField).first, 'quantum');
    await tester.pump(const Duration(milliseconds: 400)); // the debounce
    await tester.pump();
    // The fake resolves synchronously; let the post-frame setState land.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(find.text('Quantum found page'), findsOneWidget);
    expect(service.seenAsts, hasLength(1));
    // The translation rides the query surface: content contains + the id
    // tiebreak order (no sort spec).
    final ast = service.seenAsts.first;
    expect(ast.scope, isA<EntireWorkspaceScope>());
    expect(ast.root.children, hasLength(1));
    expect(ast.sort, isNull);
  });

  testWidgets('a query with no matches shows the empty state, not an error',
      (tester) async {
    final service = _FakeQueryService(const []);
    await pumpScreen(tester, service);

    await tester.enterText(find.byType(TextField).first, 'nomatchwhatsoever');
    await tester.pump(const Duration(milliseconds: 400)); // the debounce
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('No results'), findsOneWidget);
    expect(find.text('Quantum found page'), findsNothing);
  });
}

class _FakeQueryService extends QueryService {
  _FakeQueryService(this.results)
      : super(database: null, cache: null);

  final List<Node> results;
  final List<QueryAst> seenAsts = [];

  @override
  Future<List<Node>> runNodes(
    QueryAst ast, {
    CompileOptions options = const CompileOptions(),
  }) async {
    seenAsts.add(ast);
    return results;
  }
}
