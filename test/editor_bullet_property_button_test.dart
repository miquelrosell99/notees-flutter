import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import 'package:notees/data/models/node.dart';
import 'package:notees/features/editor/widgets/block_tree_editor.dart';

/// Widget acceptance for the §34.89 block-bullet value button (the
/// PropertyIconButton port): the current option's MDI icon renders tinted
/// (unset = the dimmed hollow circle), tapping opens the option sheet, a
/// pick fires the resolved write through [BlockTreeEditor.onBulletPropertyWrite],
/// the None row clears when the binding isn't required, and a null handler
/// renders a read-only projection that never opens the sheet.
void main() {
  const blockUuid = 'aaaaaaaa-0000-0000-0000-0000000000ff';
  const schemaId = 'bbbbbbbb-0000-0000-0000-000000000001';

  BlockNode block() => BlockNode(
        node: Node(id: 1, uuid: blockUuid, name: '[]', displayName: ''),
        controller: TextEditingController(text: ''),
      );

  BulletPropertyOption option(String id, String label,
          {String? icon, String? color}) =>
      BulletPropertyOption(id: id, label: label, icon: icon, color: color);

  BulletPropertyValue selectValue({
    List<String> selectedIds = const [],
    List<BulletPropertyElement> elements = const [],
    bool required = false,
    String display = 'bullet',
  }) =>
      BulletPropertyValue(
        propertySchemaId: schemaId,
        label: 'Status',
        display: display,
        type: 'select',
        required: required,
        options: [
          option('backlog', 'Backlog', icon: 'mdiCircleOutline', color: 'gray'),
          option('doing', 'Doing', icon: 'mdiCircleHalfFull', color: 'orange'),
          option('done', 'Done', icon: 'mdiCheckCircle', color: 'green'),
        ],
        selectedIds: selectedIds,
        elements: elements,
      );

  Widget host(
    BlockNode root,
    Map<String, List<BulletPropertyValue>> props,
    Future<void> Function(BlockNode node, BulletPropertyWrite write)? onWrite,
  ) {
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
          bulletProperties: props,
          onBulletPropertyWrite: onWrite,
        ),
      ),
    );
  }

  testWidgets('renders the current option glyph; unset renders the dimmed '
      'hollow circle', (tester) async {
    final root = block();
    await tester.pumpWidget(host(root, {
      blockUuid: [selectValue(selectedIds: ['doing'], elements: const [
        BulletPropertyElement(idx: 0, ids: ['doing']),
      ])],
    }, (_, _) async {}));

    expect(find.byIcon(MdiIcons.circleHalfFull), findsOneWidget);
    expect(find.byTooltip('Status: Doing'), findsOneWidget);

    // Unset: the dimmed circleOutline. The same root re-pumps with the
    // cleared value (mirrors the editor's in-place rebuilds).
    await tester.pumpWidget(host(root, {
      blockUuid: [selectValue()],
    }, (_, _) async {}));
    expect(find.byIcon(MdiIcons.circleOutline), findsOneWidget);
    expect(find.byTooltip('Status: none'), findsOneWidget);
  });

  testWidgets('tap opens the sheet; picking an option fires the resolved '
      'write at idx 0', (tester) async {
    final writes = <BulletPropertyWrite>[];
    final root = block();
    await tester.pumpWidget(host(root, {
      blockUuid: [selectValue(selectedIds: ['doing'], elements: const [
        BulletPropertyElement(idx: 0, ids: ['doing']),
      ])],
    }, (node, write) async {
      writes.add(write);
    }));

    await tester.tap(find.byTooltip('Status: Doing'));
    await tester.pumpAndSettle();
    // Header + the three options + the None clear row.
    expect(find.text('Status: Doing'), findsOneWidget);
    expect(find.text('Backlog'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('None'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(writes, hasLength(1));
    expect(writes.single.unset, isFalse);
    expect(writes.single.propertySchemaId, schemaId);
    expect(writes.single.value, 'done');
    expect(writes.single.idx, 0);
  });

  testWidgets('multi_select toggles: an unselected pick merges into the '
      'carrying element array; the last id out unsets the element', (tester) async {
    final writes = <BulletPropertyWrite>[];
    final multi = BulletPropertyValue(
      propertySchemaId: schemaId,
      label: 'Tags',
      display: 'bullet',
      type: 'multi_select',
      required: false,
      options: [
        option('a', 'Alpha', icon: 'mdiCircle', color: 'yellow'),
        option('b', 'Beta', icon: 'mdiCircle', color: 'blue'),
      ],
      selectedIds: const ['a'],
      elements: const [BulletPropertyElement(idx: 0, ids: ['a'])],
    );
    await tester.pumpWidget(host(block(), {
      blockUuid: [multi],
    }, (_, write) async {
      writes.add(write);
    }));
    await tester.tap(find.byTooltip('Tags: Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(writes.single.value, ['a', 'b']);
    expect(writes.single.idx, 0);

    // Toggle off the only carried id → element unset at its idx. The sheet
    // re-opens on the same value; the write list was cleared in between.
    writes.clear();
    await tester.tap(find.byTooltip('Tags: Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(writes.single.unset, isTrue);
    expect(writes.single.idx, 0);
  });

  testWidgets('boolean renders the synthetic check-circle; picking False '
      'writes the JSON boolean', (tester) async {
    final writes = <BulletPropertyWrite>[];
    final boolean = BulletPropertyValue(
      propertySchemaId: schemaId,
      label: 'Urgent',
      display: 'inline',
      type: 'boolean',
      required: false,
      options: const [],
      selectedIds: const ['true'],
      elements: const [BulletPropertyElement(idx: 0, ids: ['true'])],
    );
    await tester.pumpWidget(host(block(), {
      blockUuid: [boolean],
    }, (_, write) async {
      writes.add(write);
    }));

    expect(find.byIcon(MdiIcons.checkCircle), findsOneWidget);
    await tester.tap(find.byTooltip('Urgent: True'));
    await tester.pumpAndSettle();
    expect(find.text('True'), findsOneWidget);
    expect(find.text('False'), findsOneWidget);

    await tester.tap(find.text('False'));
    await tester.pumpAndSettle();
    expect(writes.single.value, isFalse);
    expect(writes.single.idx, 0);
  });

  testWidgets('the None row clears a set value when the binding is not '
      'required — and is hidden for required bindings', (tester) async {
    final writes = <BulletPropertyWrite>[];
    final root = block();
    await tester.pumpWidget(host(root, {
      blockUuid: [selectValue(selectedIds: ['doing'], elements: const [
        BulletPropertyElement(idx: 0, ids: ['doing']),
      ])],
    }, (_, write) async {
      writes.add(write);
    }));
    await tester.tap(find.byTooltip('Status: Doing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('None'));
    await tester.pumpAndSettle();
    expect(writes.single.unset, isTrue);
    expect(writes.single.propertySchemaId, schemaId);

    // Required: no None row. The same root re-pumps with the required value.
    await tester.pumpWidget(host(root, {
      blockUuid: [selectValue(
        selectedIds: ['doing'],
        elements: const [BulletPropertyElement(idx: 0, ids: ['doing'])],
        required: true,
      )],
    }, (_, _) async {}));
    await tester.tap(find.byTooltip('Status: Doing'));
    await tester.pumpAndSettle();
    expect(find.text('None'), findsNothing);
  });

  testWidgets('read-only projection (no write handler) renders the icon but '
      'never opens the sheet', (tester) async {
    await tester.pumpWidget(host(block(), {
      blockUuid: [selectValue(selectedIds: ['doing'], elements: const [
        BulletPropertyElement(idx: 0, ids: ['doing']),
      ])],
    }, null));

    expect(find.byIcon(MdiIcons.circleHalfFull), findsOneWidget);
    // No Tooltip wrapper marks the read-only glyph; tapping does nothing.
    expect(find.byTooltip('Status: Doing'), findsNothing);
    await tester.tap(find.byIcon(MdiIcons.circleHalfFull));
    await tester.pumpAndSettle();
    expect(find.text('Backlog'), findsNothing);
  });
}
