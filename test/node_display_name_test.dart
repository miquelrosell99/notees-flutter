import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/utils/date_uuid.dart';
import 'package:notees/core/utils/node_display_name.dart';
import 'package:notees/data/models/node.dart';
import 'package:notees/shared/views/_view_helpers.dart';

void main() {
  Node journalNode({
    required DateTime date,
    bool monthly = false,
    bool yearly = false,
  }) {
    final uuid = yearly
        ? dateToYearUuid(date)
        : monthly
            ? dateToMonthUuid(date)
            : dateToDayUuid(date);
    return Node(
      id: 0,
      uuid: uuid,
      name: '',
      displayName: '',
      isPage: true,
      isDaily: !monthly && !yearly,
      isMonthly: monthly,
      isYearly: yearly,
    );
  }

  final date = DateTime(2026, 8, 22);

  group('resolveNodeDisplayName journals', () {
    test('daily journals follow the user date format', () {
      final node = journalNode(date: date);
      expect(
        resolveNodeDisplayName(node, dateFormat: 'YYYY/MM/DD'),
        '2026/08/22',
      );
      expect(
        resolveNodeDisplayName(node, dateFormat: 'DD-MM-YYYY'),
        '22-08-2026',
      );
      expect(
        resolveNodeDisplayName(node, dateFormat: 'MM/DD/YYYY'),
        '08/22/2026',
      );
    });

    test('monthly journals follow the user date format', () {
      final node = journalNode(date: date, monthly: true);
      // Year-first formats keep the year first, with the format's separator.
      expect(
        resolveNodeDisplayName(node, dateFormat: 'YYYY/MM/DD'),
        '2026/08',
      );
      expect(
        resolveNodeDisplayName(node, dateFormat: 'YYYY-MM-DD'),
        '2026-08',
      );
      // Day/month-first formats put the month first.
      expect(
        resolveNodeDisplayName(node, dateFormat: 'DD/MM/YYYY'),
        '08/2026',
      );
      expect(
        resolveNodeDisplayName(node, dateFormat: 'DD-MM-YYYY'),
        '08-2026',
      );
      expect(
        resolveNodeDisplayName(node, dateFormat: 'MM/DD/YYYY'),
        '08/2026',
      );
      expect(
        resolveNodeDisplayName(node, dateFormat: 'MM-DD-YYYY'),
        '08-2026',
      );
    });

    test('monthly journals fall back to the long month name without a format',
        () {
      final node = journalNode(date: date, monthly: true);
      expect(resolveNodeDisplayName(node), 'August 2026');
    });

    test('yearly journals are always the 4-digit year', () {
      final node = journalNode(date: date, yearly: true);
      expect(resolveNodeDisplayName(node, dateFormat: 'DD/MM/YYYY'), '2026');
      expect(resolveNodeDisplayName(node), '2026');
    });
  });

  group('resolveNodeDisplayName pages', () {
    test('falls back to displayName, then Untitled', () {
      final named = Node(
        id: 0,
        uuid: 'f47ac10b-58cc-4372-a567-0e02b2c3d479',
        name: '',
        displayName: 'Shopping',
        isPage: true,
      );
      expect(resolveNodeDisplayName(named), 'Shopping');

      final unnamed = Node(
        id: 0,
        uuid: 'f47ac10b-58cc-4372-a567-0e02b2c3d479',
        name: '',
        displayName: '',
        isPage: true,
      );
      expect(resolveNodeDisplayName(unnamed), 'Untitled');
    });
  });

  /// Revision-11 render cascade as a user-facing label (typeLabel in
  /// lib/shared/views/_view_helpers.dart): is_class → Class; parentless →
  /// Page (document chrome, bit unread); a parented non-class node → Page
  /// when its present_as_main bit is set, Block when inline.
  group('typeLabel render-state cascade', () {
  Node node({
    bool isClass = false,
    bool? presentAsMain,
    String? parentUuid,
    bool isTask = false,
    bool isDaily = false,
  }) {
    return Node(
      id: 0,
      uuid: '00000000-0000-0000-0000-000000000001',
      name: '',
      displayName: '',
      isClass: isClass,
      presentAsMain: presentAsMain,
      parentUuid: parentUuid,
      isTask: isTask,
      isDaily: isDaily,
    );
  }

  test('is_class wins over everything (identity marker)', () {
    expect(
      typeLabel(node(isClass: true, presentAsMain: false, parentUuid: null)),
      'Class',
    );
  });

  test('parentless non-class nodes are Pages (bit unread)', () {
    expect(typeLabel(node(presentAsMain: false)), 'Page');
    expect(typeLabel(node(presentAsMain: null)), 'Page');
  });

  test('parented nodes follow the render bit', () {
    const parent = '00000000-0000-0000-0000-0000000000aa';
    expect(
      typeLabel(node(presentAsMain: true, parentUuid: parent)),
      'Page',
    );
    expect(typeLabel(node(presentAsMain: false, parentUuid: parent)), 'Block');
    // A parented node without the bit set is an inline block.
    expect(typeLabel(node(parentUuid: parent)), 'Block');
  });

  test('journal and task keep their dedicated labels', () {
    expect(typeLabel(node(isDaily: true)), 'Journal');
    expect(
      typeLabel(node(isTask: true, parentUuid: 'p')),
      'Task',
    );
  });
});
}
