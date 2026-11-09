import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/models/node.dart';
import 'package:notees/domain/query/query_ast.dart';
import 'package:notees/domain/query/query_placeholders.dart';
import 'package:notees/domain/query/query_runner.dart';
import 'package:notees/domain/services/query_service.dart';
import 'package:notees/features/editor/widgets/block_tree_editor.dart';
import 'package:notees/features/editor/widgets/query_node_section.dart';

/// The slice-4 authoring affordance on the live query section: the
/// unspecified state becomes the tappable "Set a query" door when the
/// authoring seam is threaded, the result states carry the edit button,
/// and the section now mounts for a query-CLASS-marked block without a
/// payload token (the class marks the block, the first Apply creates the
/// token — the web's QueryNodeSection contract). No sqflite under
/// testWidgets: the service seam is faked per the slice-3 convention.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const host = 'aaaaaaaa-0000-7000-8000-0000000000ff';
  const blockUuid = '10000000-0000-7000-8000-000000000010';

  const plainAst = <String, dynamic>{
    'version': 2,
    'scope': {'type': 'entire_workspace'},
    'root': {
      'type': 'group',
      'logic': 'and',
      'children': [
        {'type': 'content', 'op': 'contains', 'value': 'alpha'},
      ],
    },
  };

  String contentWithQuery(Map<String, dynamic> ast) => jsonEncode([
        {'type': 'text', 'text': 'Tracked items'},
        {'type': 'query', 'queryAst': ast},
      ]);

  Node resultNode(String uuid, String title) => Node(
        id: 0,
        uuid: uuid,
        name: jsonEncode([{'type': 'text', 'text': title}]),
        displayName: title,
        isPage: true,
        classesUuid: const [],
        tagsUuid: const [],
        isEmbedded: false,
        createDate: '2026-11-01T09:00:00.000Z',
        writeDate: '2026-11-01T09:00:00.000Z',
      );

  Future<void> pumpSection(
    WidgetTester tester, {
    required String source,
    VoidCallback? onEditQuery,
  }) async {
    final service = _FakeQueryService();
    final bus = StreamController<void>.broadcast();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: QueryNodeSection(
          source: source,
          selfNodeId: host,
          queryService: service,
          onEditQuery: onEditQuery,
          storeChanges: bus.stream,
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('the unspecified state renders the tappable Set a query '
      'affordance when the authoring seam is threaded', (tester) async {
    var opened = 0;
    await pumpSection(
      tester,
      source: contentWithQuery(const {
        'version': 2,
        'scope': {'type': 'entire_workspace'},
        'root': {'type': 'group', 'logic': 'and', 'children': <dynamic>[]},
      }),
      onEditQuery: () => opened += 1,
    );

    expect(find.text('Set a query to see results.'), findsOneWidget);
    await tester.tap(find.text('Set a query to see results.'));
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('the unspecified state without the seam stays the plain '
      'read-only line', (tester) async {
    await pumpSection(
      tester,
      source: contentWithQuery(const {
        'version': 2,
        'scope': {'type': 'entire_workspace'},
        'root': {'type': 'group', 'logic': 'and', 'children': <dynamic>[]},
      }),
    );
    expect(find.text('Set a query to see results.'), findsOneWidget);
    // No InkWell wrapper: the read-only projection has no door.
    expect(
      find.ancestor(
        of: find.text('Set a query to see results.'),
        matching: find.byType(InkWell),
      ),
      findsNothing,
    );
  });

  testWidgets('the result states carry the edit affordance, firing the '
      'seam on tap', (tester) async {
    final service = _FakeQueryService();
    final bus = StreamController<void>.broadcast();
    var opened = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: QueryNodeSection(
          source: contentWithQuery(plainAst),
          selfNodeId: host,
          queryService: service,
          onEditQuery: () => opened += 1,
          storeChanges: bus.stream,
        ),
      ),
    ));
    await tester.pump();
    await tester.runAsync(() async {
      service.pending.removeAt(0).complete([
        resultNode('20000000-0000-7000-8000-000000000001', 'Alpha result'),
      ]);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();

    expect(find.text('Alpha result'), findsOneWidget);
    // The edit affordance rides the tooltip'd pencil above the rows.
    final edit = find.byTooltip('Edit query');
    expect(edit, findsOneWidget);
    await tester.tap(edit);
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('BlockTreeEditor mounts the section for a query-classed '
      'block WITHOUT a token (the no-payload Set a query state)', (
    tester,
  ) async {
    final service = _FakeQueryService();
    final bus = StreamController<void>.broadcast();
    // No `query` token in the content; the query system class marks it.
    final block = BlockNode(
      node: Node(
        id: 1,
        uuid: blockUuid,
        name: jsonEncode([{'type': 'text', 'text': 'just text'}]),
        displayName: '',
        classesUuid: const ['00000000-0000-0000-0001-000000000007'],
      ),
      controller: TextEditingController(text: 'just text'),
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BlockTreeEditor(
          roots: [block],
          classNames: const {
            '00000000-0000-0000-0001-000000000007': 'query',
          },
          dio: Dio(),
          focusedNode: null,
          onFocus: (_) {},
          onDelete: (_) {},
          onMove: (_, _, _) {},
          onAddSibling: () {},
          onAddChild: (_) {},
          onIndent: (_) {},
          onOutdent: (_) {},
          onToggleCollapse: (_) {},
          queryService: service,
          hostNodeUuid: host,
          storeChanges: bus.stream,
        ),
      ),
    ));
    await tester.pump();

    // The section mounts on the class-marked block; with no payload the
    // unspecified line renders and the run never fires.
    expect(find.byType(QueryNodeSection), findsOneWidget);
    expect(find.text('Set a query to see results.'), findsOneWidget);
    expect(service.runs, isEmpty);
    expect(service.aggregateRuns, isEmpty);
  });
}

/// The service seam (the slice-3 fake, minimal): records run requests and
/// hands out manually-completable futures.
class _FakeQueryService extends QueryService {
  _FakeQueryService() : super(database: null, cache: null);

  final List<({QueryAst ast, CompileOptions options})> runs = [];
  final List<({QueryAst ast, CompileOptions options})> aggregateRuns = [];
  final List<Completer<List<Node>>> pending = [];
  final List<Completer<AggregateResult>> pendingAggregates = [];

  @override
  Future<List<Node>> runNodes(
    QueryAst ast, {
    CompileOptions options = const CompileOptions(),
  }) {
    runs.add((ast: ast, options: options));
    final completer = Completer<List<Node>>();
    pending.add(completer);
    return completer.future;
  }

  @override
  Future<AggregateResult> runAggregate(
    QueryAst ast, {
    CompileOptions options = const CompileOptions(),
  }) {
    aggregateRuns.add((ast: ast, options: options));
    final completer = Completer<AggregateResult>();
    pendingAggregates.add(completer);
    return completer.future;
  }
}
