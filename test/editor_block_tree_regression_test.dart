import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:notees/data/models/node.dart';
import 'package:notees/features/editor/widgets/block_tree_editor.dart';

/// Regression for the "grey box where page content should be" bug: rows must
/// render for every content shape the grammar produces (and for corrupt
/// data), and one bad block must degrade to a quiet placeholder instead of
/// taking down the page body.
///
/// Root cause of the original bug: `_buildRow`'s DragTarget builder closure
/// captured the `content` local by reference, so by the time the builder ran
/// `content` was the DragTarget itself — an infinitely deep widget tree,
/// a stack overflow, and an ErrorWidget over the whole block body. The
/// seeded-repository counterpart of this scenario (real app, real cache)
/// runs in integration_test/screenshots_test.dart, which opens the seeded
/// daily note in the node editor.
void main() {
  BlockNode block(String uuid, String name) => BlockNode(
        node: Node(id: 1, uuid: uuid, name: name, displayName: ''),
        controller: TextEditingController(text: ''),
      );

  Widget host(BlockNode root) {
    return MaterialApp(
      home: Scaffold(
        body: BlockTreeEditor(
          roots: [root],
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
    );
  }

  /// Matches the plain text accumulated by a RichText (AstRichText renders
  /// through spans, so find.text cannot see it).
  Finder richTextContaining(String text) => find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText().contains(text),
      );

  testWidgets('single-token AST blocks render rows', (tester) async {
    final root = block('aaaaaaaa-0000-0000-0000-000000000001',
        '[{"type":"text","text":"Morning walk: 5km along the river"}]');
    await tester.pumpWidget(host(root));

    expect(
      richTextContaining('Morning walk: 5km along the river'),
      findsOneWidget,
    );
  });

  testWidgets('cyclic children graph renders without overflow', (tester) async {
    final a = block(
      'aaaaaaaa-0000-0000-0000-000000000001',
      '[{"type":"text","text":"Alpha"}]',
    );
    final b = block(
      'aaaaaaaa-0000-0000-0000-000000000002',
      '[{"type":"text","text":"Beta"}]',
    );
    a.children.add(b);
    b.parent = a;
    b.children.add(a); // Corrupt cycle back to the root.

    await tester.pumpWidget(host(a));
    await tester.pump();

    expect(richTextContaining('Alpha'), findsOneWidget);
    expect(richTextContaining('Beta'), findsOneWidget);
  });

  testWidgets('every token shape renders', (tester) async {
    final root = block(
      'aaaaaaaa-0000-0000-0000-000000000001',
      '[{"type":"text","text":"plain "},'
      '{"type":"hard_break"},'
      '{"type":"mention","targetNodeId":"11111111-2222-3333-4444-555555555555","displayText":"Mention"},'
      '{"type":"class_chip","classId":"11111111-2222-3333-4444-555555555555","displayText":"Chip"},'
      '{"type":"typed_link","text":"Typed"},'
      '{"type":"external_link","href":"https://example.com","text":"Link"},'
      '{"type":"math","expression":"e=mc^2"},'
      '{"type":"quote","children":[{"type":"text","text":"Quoted"}]}]',
    );
    await tester.pumpWidget(host(root));

    expect(richTextContaining('plain'), findsOneWidget);
    expect(richTextContaining('Mention'), findsOneWidget);
    expect(richTextContaining('Chip'), findsOneWidget);
    expect(richTextContaining('Typed'), findsOneWidget);
    expect(richTextContaining('Link'), findsOneWidget);
    expect(richTextContaining('e=mc^2'), findsOneWidget);
    expect(richTextContaining('Quoted'), findsOneWidget);
  });

  testWidgets('unknown token types degrade to their text', (tester) async {
    final root = block('aaaaaaaa-0000-0000-0000-000000000001',
        '[{"type":"future_widget","text":"survives"}]');
    await tester.pumpWidget(host(root));

    expect(richTextContaining('survives'), findsOneWidget);
  });

  testWidgets('unparseable content shows the inline placeholder', (tester) async {
    final root = block(
      'aaaaaaaa-0000-0000-0000-000000000001',
      '[1,2,3]', // parses to a list with no tokens
    );
    await tester.pumpWidget(host(root));

    expect(find.text('Content unavailable'), findsOneWidget);
  });
}
