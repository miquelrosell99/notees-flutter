import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/models/node.dart';
import 'package:notees/domain/query/builder_facts.dart';
import 'package:notees/domain/query/query_ast.dart';
import 'package:notees/domain/query/query_filter_query.dart';
import 'package:notees/features/editor/widgets/query_builder_sheet.dart';

/// The query builder sheet, widget level (slice 4): the draft edits, the
/// add-menu register, the operator morphs, the mode switch, the AND/OR
/// logic, the prune-on-Apply, the boolean single-selector ruling, and the
/// JSON arm as the aggregation-authoring escape hatch. No sqflite under
/// testWidgets: the facts + the node-pick seam are injected fakes per the
/// repo's service-seam convention.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const uuidClass = 'aaaaaaaa-0000-7000-8000-000000000001';
  const uuidTag = 'bbbbbbbb-0000-7000-8000-000000000002';

  BuilderFacts facts() => BuilderFacts(
        classes: const [
          BuilderClassInfo(id: uuidClass, name: 'Book'),
        ],
        boundProperties: const [
          BuilderPropertyInfo(id: uuidTag, name: 'Pages', type: 'number'),
          BuilderPropertyInfo(
            id: 'cccccccc-0000-7000-8000-000000000003',
            name: 'Read',
            type: 'boolean',
          ),
        ],
      );

  Node pickedNode() => Node(
        id: 0,
        uuid: uuidTag,
        name: jsonEncode([{'type': 'text', 'text': 'Urgent'}]),
        displayName: 'Urgent',
        classesUuid: const [],
        tagsUuid: const [],
      );

  /// Pumps a host whose button opens the builder through the production
  /// [.show] seam; [initialAst] seeds the token payload. Returns a future
  /// completing with the popped AST (null on dismiss).
  Future<Future<QueryAst?>> openBuilder(
    WidgetTester tester, {
    BuilderFacts? facts,
    QueryNodePicker? pickNode,
    QueryAst? initialAst,
    String? selfNodeId,
  }) async {
    final completer = Completer<QueryAst?>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              completer.complete(
                await QueryBuilderSheet.show(
                  context,
                  facts: facts ??
                      BuilderFacts(
                        classes: const [],
                        boundProperties: const [],
                      ),
                  pickNode: pickNode ?? (_) async => null,
                  initialAst: initialAst,
                  selfNodeId: selfNodeId,
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return completer.future;
  }

  Future<void> apply(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();
  }

  Future<void> addCondition(WidgetTester tester, String label) async {
    await tester.ensureVisible(
      find.widgetWithText(OutlinedButton, 'Add condition').first,
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Add condition').first);
    await tester.pumpAndSettle();
    final entry = find.text(label).last;
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
  }

  testWidgets('a fresh builder renders the head chrome and Apply pops the '
      'factory AST for an empty draft', (tester) async {
    final pending = await openBuilder(tester, facts: facts());
    expect(find.text('Query builder'), findsOneWidget);
    expect(find.text('Blocks'), findsOneWidget);
    expect(find.text('ALL'), findsOneWidget);
    expect(find.text('ANY'), findsOneWidget);

    await apply(tester);
    final ast = await pending;
    expect(ast, isNotNull);
    expect(ast!.root.children, isEmpty);
    expect(ast.scope, isA<EntireWorkspaceScope>());
  });

  testWidgets('the add menu offers the full register and a content row '
      'round-trips through Apply', (tester) async {
    final pending = await openBuilder(tester, facts: facts());
    await tester.tap(find.widgetWithText(OutlinedButton, 'Add condition'));
    await tester.pumpAndSettle();
    for (final option in filterKindOptions) {
      expect(find.text(option.label), findsWidgets, reason: option.label);
    }

    await tester.tap(find.text('Content').last);
    await tester.pumpAndSettle();
    expect(find.text('Content'), findsWidgets);

    await tester.enterText(find.byType(TextField).first, 'hello world');
    await tester.pump();
    await apply(tester);

    final ast = await pending;
    final condition = ast!.root.children.single as ContentCondition;
    expect(condition.op, 'contains');
    expect(condition.value, 'hello world');
  });

  testWidgets('an operator choice morphs the row (class contains → is set '
      're-materializes exists, no target)', (tester) async {
    final pending = await openBuilder(tester, facts: facts());
    await addCondition(tester, 'Class');

    // The class value rides the multi pick: the Add class chip shows.
    expect(find.text('Add class'), findsOneWidget);
    expect(find.text('contains'), findsOneWidget);

    // Flip the operator to "is set": the value pick vanishes (the set bits
    // carry no target).
    await tester.tap(find.text('contains'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('is set').last);
    await tester.pumpAndSettle();
    expect(find.text('Add class'), findsNothing);

    await apply(tester);
    final ast = await pending;
    final condition = ast!.root.children.single as MemberCondition;
    expect(condition.op, 'exists');
    expect(condition.target, isNull);
  });

  testWidgets('the member mode switch rebuilds ONLY the target (ids → '
      'query nests a group editor)', (tester) async {
    final pending = await openBuilder(tester, facts: facts());
    await addCondition(tester, 'Tags');

    expect(find.text('Manual'), findsOneWidget);
    expect(find.text('Query'), findsOneWidget);
    // No hosting page threaded: the Self mode is not offered.
    expect(find.text('Self'), findsNothing);

    await tester.tap(find.text('Query'));
    await tester.pumpAndSettle();
    expect(find.text('matching'), findsOneWidget);
    // The nested group editor renders its own add menu.
    expect(
      find.widgetWithText(OutlinedButton, 'Add condition'),
      findsNWidgets(2),
    );

    // A query target with an empty nested group prunes away — value the
    // nested row before Apply (the prune parity).
    await addCondition(tester, 'Content');
    await tester.enterText(find.byType(TextField).first, 'inner');
    await tester.pump();
    await apply(tester);

    final ast = await pending;
    final condition = ast!.root.children.single as MemberCondition;
    expect(condition.op, 'in');
    expect(condition.target, isA<QueryTarget>());
    final nested = (condition.target! as QueryTarget).root;
    expect(nested.children.single, isA<ContentCondition>());
  });

  testWidgets('the Self mode needs the hosting page (threaded → offered, '
      'and the row reads this page)', (tester) async {
    final pending = await openBuilder(
      tester,
      facts: facts(),
      selfNodeId: 'dddddddd-0000-7000-8000-000000000004',
    );
    await addCondition(tester, 'Page');

    expect(find.text('Self'), findsOneWidget);
    await tester.tap(find.text('Self'));
    await tester.pumpAndSettle();
    expect(find.text('this page'), findsOneWidget);

    await apply(tester);
    final ast = await pending;
    final condition = ast!.root.children.single as MemberCondition;
    expect(condition.target, isA<SelfTarget>());
  });

  testWidgets('the AND/OR toggle lands on the popped root', (tester) async {
    final pending = await openBuilder(tester, facts: facts());
    await addCondition(tester, 'Content');
    await tester.enterText(find.byType(TextField).first, 'x');
    await tester.pump();

    await tester.tap(find.text('ANY'));
    await tester.pumpAndSettle();
    await apply(tester);

    final ast = await pending;
    expect(ast!.root.logic, 'or');
  });

  testWidgets('a half-typed row prunes on Apply (blank content → factory '
      'AST)', (tester) async {
    final pending = await openBuilder(tester, facts: facts());
    await addCondition(tester, 'Content');
    // Leave the value blank.
    await apply(tester);

    final ast = await pending;
    expect(ast!.root.children, isEmpty);
  });

  testWidgets('the boolean single-selector ruling: a Type row carries no '
      'operator column; the value flips the wire boolean', (tester) async {
    final pending = await openBuilder(tester, facts: facts());
    await addCondition(tester, 'Type');

    // No operator dropdown for the boolean families (the ruling); the row
    // renders the value selector directly.
    expect(find.text('A class'), findsOneWidget);
    await tester.tap(find.text('A class'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not a class').last);
    await tester.pumpAndSettle();

    await apply(tester);
    final ast = await pending;
    final condition = ast!.root.children.single as NodeFieldCondition;
    expect(condition.field, 'isClass');
    expect(condition.value, 'false');
  });

  testWidgets('an Exclude (NOT) group renders the badge and nests its '
      'group editor', (tester) async {
    final pending = await openBuilder(tester, facts: facts());
    await addCondition(tester, 'Exclude (NOT)');

    expect(find.text('NOT'), findsOneWidget);
    // The NOT's nested group editor AND the root's foot each carry an add
    // menu (empty groups prune away — the chrome pin is the point here).
    expect(
      find.widgetWithText(OutlinedButton, 'Add condition'),
      findsNWidgets(2),
    );

    // Value the NOT's nested row: the wrapper survives the prune.
    await tester.ensureVisible(
      find.widgetWithText(OutlinedButton, 'Add condition').first,
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Add condition').first);
    await tester.pumpAndSettle();
    final entry = find.text('Content').last;
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'x');
    await tester.pump();

    await apply(tester);
    final ast = await pending;
    expect(ast!.root.children, hasLength(1));
    final not = ast.root.children.single as Not;
    final group = not.child as Group;
    expect(group.children.single, isA<ContentCondition>());
  });

  testWidgets('a boolean property folds the truth value into the value '
      'column (the operator register carries only the set bits)', (tester) async {
    final pending = await openBuilder(tester, facts: facts());
    await addCondition(tester, 'Property');

    // Pick the boolean schema: the value selector reads True immediately.
    await tester.tap(find.text('Pick a property'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read').last);
    await tester.pumpAndSettle();
    expect(find.text('True'), findsOneWidget);

    await apply(tester);
    final ast = await pending;
    final condition = ast!.root.children.single as PropertyCondition;
    expect(condition.op, 'eq');
    expect(condition.value, isTrue);
  });

  testWidgets('a manual ids pick appends a chip and lands the ids target',
      (tester) async {
    final pending = await openBuilder(
      tester,
      facts: facts(),
      pickNode: (_) async => pickedNode(),
    );
    await addCondition(tester, 'Tags');

    await tester.tap(find.text('Add tag'));
    await tester.pumpAndSettle();
    expect(find.text('Urgent'), findsOneWidget);

    await apply(tester);
    final ast = await pending;
    final condition = ast!.root.children.single as MemberCondition;
    expect(condition.target, isA<IdsTarget>());
    expect((condition.target! as IdsTarget).ids, [uuidTag]);
  });

  testWidgets('the single-slot register hides the add chip while filled',
      (tester) async {
    final pending = await openBuilder(
      tester,
      facts: facts(),
      pickNode: (_) async => pickedNode(),
    );
    await addCondition(tester, 'Parent');

    await tester.tap(find.text('Add parent'));
    await tester.pumpAndSettle();
    expect(find.text('Urgent'), findsOneWidget);
    expect(find.text('Add parent'), findsNothing);

    // Clear via the pill's ×, then Apply drops the half-typed row.
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pumpAndSettle();
    await apply(tester);
    final ast = await pending;
    expect(ast!.root.children, isEmpty);
  });

  testWidgets('the JSON arm edits the whole token AST — the aggregation '
      'escape hatch round-trips', (tester) async {
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
    final pending = await openBuilder(
      tester,
      facts: facts(),
      initialAst: QueryAst.parse(aggregateAst),
    );

    // The initial AST serializes into the JSON arm verbatim (aggregation
    // included — the blocks arm would drop it, the JSON arm is the
    // exchange format).
    await tester.tap(find.text('JSON'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"aggregation"'), findsOneWidget);

    await apply(tester);
    final ast = await pending;
    expect(ast!.aggregation, isNotNull);
    expect(ast.aggregation!.dimensions.single.kind, 'isClass');
    expect(ast.root.children, hasLength(1));
  });

  testWidgets('invalid JSON in the raw arm reports the error and never '
      'pops', (tester) async {
    final pending = await openBuilder(tester, facts: facts());
    await tester.tap(find.text('JSON'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '{nope');
    await tester.pump();
    await apply(tester);

    expect(find.textContaining('Invalid JSON'), findsOneWidget);
    await tester.tap(find.text('Blocks'));
    await tester.pumpAndSettle();
    await apply(tester);
    final ast = await pending;
    expect(ast, isNotNull);
  });
}
