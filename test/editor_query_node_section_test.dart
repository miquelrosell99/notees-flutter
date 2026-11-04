import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/models/node.dart';
import 'package:notees/domain/query/query_ast.dart';
import 'package:notees/domain/query/query_placeholders.dart';
import 'package:notees/domain/query/query_runner.dart';
import 'package:notees/domain/services/query_service.dart';
import 'package:notees/features/editor/widgets/block_tree_editor.dart';
import 'package:notees/features/editor/widgets/query_node_section.dart';

/// The slice-3 live query section, widget level: the editor's `query`
/// content token renders as a live section whose AST runs through the slice-1
/// QueryService seam with the HOSTING PAGE's node id as the `self` anchor
/// (the first Flutter surface exercising the `self` target mode — the
/// compiler fails loud without a host, so the id must always be threaded),
/// re-runs coalesced on store notifications, and converges deletions/renames
/// without a manual refresh. No sqflite under testWidgets: the service is
/// faked per the slice-1 seam convention; the DB-backed path is proven by
/// the query golden suite.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const host = 'aaaaaaaa-0000-7000-8000-0000000000ff';

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

  const unspecifiedAst = <String, dynamic>{
    'version': 2,
    'scope': {'type': 'entire_workspace'},
    'root': {'type': 'group', 'logic': 'and', 'children': <dynamic>[]},
  };

  const aggregateAst = <String, dynamic>{
    'version': 2,
    'scope': {'type': 'entire_workspace'},
    'root': {
      'type': 'group',
      'logic': 'and',
      'children': [
        {'type': 'content', 'op': 'contains', 'value': 'alpha'},
      ],
    },
    'aggregation': {
      'dimensions': [
        {'kind': 'isClass'},
      ],
      'measures': [
        {'function': 'count', 'kind': 'node'},
      ],
    },
  };

  /// A block content document whose first `query` token carries [ast].
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
    WidgetTester tester,
    _FakeQueryService service,
    StreamController<void> bus, {
    required String source,
    String selfNodeId = host,
    ValueChanged<String>? onOpenNode,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: QueryNodeSection(
      source: source,
      selfNodeId: selfNodeId,
      queryService: service,
          onOpenNode: onOpenNode,
          storeChanges: bus.stream,
        ),
      ),
    ));
    await tester.pump();
  }

  /// Completes the oldest pending run with [rows] and lets the result land.
  Future<void> finishRun(
    WidgetTester tester,
    _FakeQueryService service,
    List<Node> rows,
  ) async {
    expect(service.pending, isNotEmpty, reason: 'a run must be in flight');
    await tester.runAsync(() async {
      service.pending.removeAt(0).complete(rows);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
  }

  testWidgets(
      'query token renders a live section whose run carries the hosting '
      'page as selfNodeId', (tester) async {
    final service = _FakeQueryService();
    final bus = StreamController<void>.broadcast();
    final opened = <String>[];
    await pumpSection(
      tester,
      service,
      bus,
      source: contentWithQuery(plainAst),
      onOpenNode: opened.add,
    );

    // The render plan pin: exactly one run request, the token's AST
    // verbatim, the hosting page threaded as the `self` anchor.
    expect(service.runs, hasLength(1));
    expect(service.runs.single.ast.toJson(), plainAst);
    expect(service.runs.single.options.selfNodeId, host);

    // While the run is in flight the section renders nothing extra.
    expect(find.text('Alpha result'), findsNothing);

    await finishRun(tester, service, [
      resultNode('10000000-0000-7000-8000-000000000001', 'Alpha result'),
      resultNode('10000000-0000-7000-8000-000000000002', 'Second result'),
    ]);

    // The web row chrome: titles, open on tap.
    expect(find.text('Alpha result'), findsOneWidget);
    expect(find.text('Second result'), findsOneWidget);

    await tester.tap(find.text('Second result'));
    expect(opened, ['10000000-0000-7000-8000-000000000002']);
  });

  testWidgets('a store notification re-runs and replaces the rows '
      '(deletions/renames converge without a manual refresh)', (tester) async {
    final service = _FakeQueryService();
    final bus = StreamController<void>.broadcast();
    await pumpSection(tester, service, bus, source: contentWithQuery(plainAst));

    await finishRun(tester, service, [
      resultNode('10000000-0000-7000-8000-000000000001', 'Alpha result'),
    ]);
    expect(find.text('Alpha result'), findsOneWidget);

    // Local store changed (an envelope applied): the section re-runs.
    bus.add(null);
    await tester.pump();
    expect(service.runs, hasLength(2));

    // The rename/deletion lands by REPLACING the rows.
    await finishRun(tester, service, [
      resultNode('10000000-0000-7000-8000-000000000001', 'Alpha renamed'),
    ]);
    expect(find.text('Alpha result'), findsNothing);
    expect(find.text('Alpha renamed'), findsOneWidget);

    // Deleting the last match renders the honest empty state.
    bus.add(null);
    await tester.pump();
    await finishRun(tester, service, const []);
    expect(find.text('Alpha renamed'), findsNothing);
    expect(find.text('No results.'), findsOneWidget);
  });

  testWidgets('notification bursts during a run coalesce into exactly one '
      'trailing run', (tester) async {
    final service = _FakeQueryService();
    final bus = StreamController<void>.broadcast();
    await pumpSection(tester, service, bus, source: contentWithQuery(plainAst));

    // Two notifications land while the first run is in flight: they must
    // not start runs of their own (the web's at-most-two-executions rule).
    bus.add(null);
    bus.add(null);
    await tester.pump();
    expect(service.runs, hasLength(1));

    await finishRun(tester, service, [
      resultNode('10000000-0000-7000-8000-000000000001', 'First pass'),
    ]);

    // Exactly ONE trailing run for the burst — not one per notification.
    expect(service.runs, hasLength(2));
    await finishRun(tester, service, [
      resultNode('10000000-0000-7000-8000-000000000001', 'Converged'),
    ]);
    expect(find.text('First pass'), findsNothing);
    expect(find.text('Converged'), findsOneWidget);
    expect(service.runs, hasLength(2));
  });

  testWidgets('a rebuild with an unchanged (ast, version, self) identity '
      'does not re-run', (tester) async {
    final service = _FakeQueryService();
    final bus = StreamController<void>.broadcast();
    await pumpSection(tester, service, bus, source: contentWithQuery(plainAst));
    expect(service.runs, hasLength(1));

    // Repump an equivalent widget: didUpdateWidget fires, the identity is
    // already current, no second run request.
    await pumpSection(tester, service, bus, source: contentWithQuery(plainAst));
    expect(service.runs, hasLength(1));
  });

  testWidgets('a new selfNodeId is part of the run identity and re-runs',
      (tester) async {
    final service = _FakeQueryService();
    final bus = StreamController<void>.broadcast();
    await pumpSection(tester, service, bus, source: contentWithQuery(plainAst));
    expect(service.runs.single.options.selfNodeId, host);
    await finishRun(tester, service, const []);

    await pumpSection(
      tester,
      service,
      bus,
      source: contentWithQuery(plainAst),
      selfNodeId: 'bbbbbbbb-0000-7000-8000-0000000000ee',
    );
    expect(service.runs, hasLength(2));
    expect(
      service.runs.last.options.selfNodeId,
      'bbbbbbbb-0000-7000-8000-0000000000ee',
    );
  });

  testWidgets('a block without a payload token renders the unspecified '
      'state and never runs', (tester) async {
    final service = _FakeQueryService();
    final bus = StreamController<void>.broadcast();
    await pumpSection(
      tester,
      service,
      bus,
      source: jsonEncode([{'type': 'query', 'queryAst': unspecifiedAst}]),
    );

    expect(find.text('Set a query to see results.'), findsOneWidget);
    expect(service.runs, isEmpty);

    // Notifications never arm a run while unspecified.
    bus.add(null);
    await tester.pump();
    expect(service.runs, isEmpty);
  });

  testWidgets('a malformed token AST surfaces the invalid-query state '
      'without a run request', (tester) async {
    final service = _FakeQueryService();
    final bus = StreamController<void>.broadcast();
    await pumpSection(
      tester,
      service,
      bus,
      source: jsonEncode([
        {'type': 'query', 'queryAst': <String, dynamic>{'nope': true}},
      ]),
    );

    expect(find.text('invalid query'), findsOneWidget);
    expect(service.runs, isEmpty);
  });

  testWidgets('an aggregation AST runs through the aggregate seam and '
      'renders the grid', (tester) async {
    final service = _FakeQueryService();
    final bus = StreamController<void>.broadcast();
    await pumpSection(
      tester,
      service,
      bus,
      source: contentWithQuery(aggregateAst),
    );

    expect(service.aggregateRuns, hasLength(1));
    expect(service.aggregateRuns.single.ast.aggregation, isNotNull);
    expect(service.aggregateRuns.single.options.selfNodeId, host);

    await tester.runAsync(() async {
      service.pendingAggregates.removeAt(0).complete(AggregateResult(
            columns: ['isClass', 'count'],
            rows: [
              [true, 3],
              [null, 1],
            ],
          ));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();

    expect(find.text('isClass'), findsOneWidget);
    expect(find.text('count'), findsOneWidget);
    expect(find.text('true'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('—'), findsOneWidget); // the null cell read
  });

  testWidgets('BlockTreeEditor mounts the live section under a query-token '
      'block, threading the hosting page through', (tester) async {
    final service = _FakeQueryService();
    final bus = StreamController<void>.broadcast();
    final block = BlockNode(
      node: Node(
        id: 1,
        uuid: '10000000-0000-7000-8000-000000000010',
        name: contentWithQuery(plainAst),
        displayName: '',
      ),
      controller: TextEditingController(text: ''),
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BlockTreeEditor(
          roots: [block],
          classNames: const {},
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

    expect(find.byType(QueryNodeSection), findsOneWidget);
    expect(service.runs, hasLength(1));
    expect(service.runs.single.options.selfNodeId, host);

    await finishRun(tester, service, [
      resultNode('10000000-0000-7000-8000-000000000001', 'Alpha result'),
    ]);
    expect(find.text('Alpha result'), findsOneWidget);
  });

  testWidgets('BlockTreeEditor without the service seam renders no section '
      '(read-only projection)', (tester) async {
    final block = BlockNode(
      node: Node(
        id: 1,
        uuid: '10000000-0000-7000-8000-000000000010',
        name: contentWithQuery(plainAst),
        displayName: '',
      ),
      controller: TextEditingController(text: ''),
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BlockTreeEditor(
          roots: [block],
          classNames: const {},
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
        ),
      ),
    ));
    await tester.pump();

    expect(find.byType(QueryNodeSection), findsNothing);
  });
}

/// The service seam: records every run request (AST + compile options) and
/// hands out manually-completable futures so the coalescing windows are
/// deterministic under testWidgets.
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
