import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:notees/core/utils/class_icon_resolver.dart';
import 'package:notees/core/utils/color_presets.dart';
import 'package:notees/data/models/node.dart';

void main() {
  const firstClass = '0192a000-0000-7000-8000-0000000000c1';
  const secondClass = '0192a000-0000-7000-8000-0000000000c2';
  const parentClass = '0192a000-0000-7000-8000-0000000000c3';

  Node classNode({
    required String uuid,
    List<String> extendsUuid = const [],
    String? icon,
    String? color,
  }) {
    return Node(
      id: 0,
      uuid: uuid,
      name: '',
      displayName: '',
      isClass: true,
      extendsUuid: extendsUuid,
      icon: icon,
      color: color,
    );
  }

  Node pageNode({
    String? icon,
    String? color,
    List<String> classesUuid = const [],
  }) {
    return Node(
      id: 0,
      uuid: '0192a000-0000-7000-8000-0000000000n1',
      name: '',
      displayName: 'Page',
      isPage: true,
      icon: icon,
      color: color,
      classesUuid: classesUuid,
    );
  }

  group('ResolvedClassStyle.iconField', () {
    test('carries the raw icon string of the defining class', () {
      final styles = resolveClassStyles([
        classNode(uuid: firstClass, icon: 'mdiCalendarToday'),
      ]);
      expect(styles[firstClass]!.icon!.iconData, MdiIcons.calendarToday);
      expect(styles[firstClass]!.iconField, 'mdiCalendarToday');
    });

    test('inherits the parent chain iconField through class extension', () {
      final styles = resolveClassStyles([
        classNode(uuid: firstClass, extendsUuid: [parentClass]),
        classNode(uuid: parentClass, icon: '📅'),
      ]);
      expect(styles[firstClass]!.icon!.emoji, '📅');
      expect(styles[firstClass]!.iconField, '📅');
      expect(styles[firstClass]!.sourceUuid, parentClass);
    });
  });

  group('resolveNodeStyle', () {
    final classStyles = resolveClassStyles([
      classNode(uuid: firstClass, icon: 'mdiCalendarToday'),
      classNode(uuid: secondClass, color: 'var(--color-preset-green)'),
    ]);

    test('the node\'s own icon and color win over its classes', () {
      final style = resolveNodeStyle(
        pageNode(
          icon: 'mdiStar',
          color: '#112233',
          classesUuid: [firstClass, secondClass],
        ),
        classStyles,
      );
      expect(style.iconField, 'mdiStar');
      expect(style.color, const Color(0xFF112233));
    });

    test('a JSON icon wrapper with no glyph or emoji counts as absent', () {
      final style = resolveNodeStyle(
        pageNode(
          icon: '{"color":"var(--color-preset-red)"}',
          classesUuid: [firstClass],
        ),
        classStyles,
      );
      // The wrapper has no glyph, so the icon falls through to the class;
      // its embedded color stays inside the icon field and is not promoted.
      expect(style.iconField, 'mdiCalendarToday');
      expect(style.color, isNull);
    });

    test('falls back to the first assigned class in class order', () {
      final styles = resolveClassStyles([
        classNode(uuid: firstClass, icon: 'mdiCalendarToday'),
        classNode(uuid: secondClass, color: 'var(--color-preset-green)'),
        classNode(uuid: parentClass, icon: 'mdiStar', color: '#000001'),
      ]);

      // firstClass carries an icon, secondClass a color: each missing piece
      // is taken from the first class in assignment order that has it.
      final style = resolveNodeStyle(
        pageNode(classesUuid: [firstClass, secondClass, parentClass]),
        styles,
      );
      expect(style.iconField, 'mdiCalendarToday');
      expect(style.color, ColorPresets.tryResolve('var(--color-preset-green)'));

      // A class supplying both pieces loses per piece to earlier classes.
      final parentFirst = resolveNodeStyle(
        pageNode(classesUuid: [parentClass, firstClass, secondClass]),
        styles,
      );
      expect(parentFirst.iconField, 'mdiStar');
      expect(parentFirst.color, const Color(0xFF000001));
    });

    test('unassigned and unstyled nodes resolve to nothing', () {
      final style = resolveNodeStyle(pageNode(), classStyles);
      expect(style.iconField, isNull);
      expect(style.color, isNull);
    });

    test('unknown class uuids are skipped', () {
      final style = resolveNodeStyle(
        pageNode(classesUuid: ['does-not-exist', firstClass]),
        classStyles,
      );
      expect(style.iconField, 'mdiCalendarToday');
    });
  });

  group('EffectiveNodeIcon', () {
    testWidgets('renders the effective class icon and color', (tester) async {
      final classStyles = resolveClassStyles([
        classNode(
          uuid: firstClass,
          icon: 'mdiCalendarToday',
          color: 'var(--color-preset-green)',
        ),
      ]);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EffectiveNodeIcon(
            node: pageNode(classesUuid: [firstClass]),
            classStyles: classStyles,
          ),
        ),
      ));

      final icon = tester.widget<Icon>(find.byIcon(MdiIcons.calendarToday));
      expect(icon.color, ColorPresets.tryResolve('var(--color-preset-green)'));
    });

    testWidgets('renders the fallback icon when nothing resolves', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EffectiveNodeIcon(
            node: pageNode(),
            classStyles: const {},
            fallbackIcon: MdiIcons.checkCircleOutline,
          ),
        ),
      ));

      expect(find.byIcon(MdiIcons.checkCircleOutline), findsOneWidget);
    });
  });
}
