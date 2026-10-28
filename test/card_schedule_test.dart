import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/constants/system.dart';
import 'package:notees/core/utils/date_uuid.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/services/card_schedule.dart';
import 'package:notees/domain/services/srs.dart';

/// Pins the Cards-hub partition, the review queue, the datetime slot
/// grammar and the SRS-state read — parity with the web behaviors
/// (CardBuckets.tsx / reviewQueue.ts / calendarViewUtils.ts /
/// ReviewSession.tsx).
void main() {
  const today = '2026-10-28';

  // Deterministic date-node ids (the web dateToDayUuid encodings).
  const dayB = '00000000-0000-0000-00dd-202610270000'; // 2026-10-27
  const dayC = '00000000-0000-0000-00dd-202610280000'; // 2026-10-28
  const dayD = '00000000-0000-0000-00dd-202611050000'; // 2026-11-05
  const dayE = '00000000-0000-0000-00dd-202612010000'; // 2026-12-01
  const monthNode = '00000000-0000-0000-00aa-202610000000'; // 2026-10
  const yearNode = '00000000-0000-0000-00bb-202600000000'; // 2026
  const notDate = '11111111-2222-3333-4444-555566667777';

  group('parseDateNodeId', () {
    test('parses day/month/year precisions', () {
      expect(parseDateNodeId(dayC)?.precision, DateNodePrecision.day);
      expect(parseDateNodeId(dayC)?.year, 2026);
      expect(parseDateNodeId(dayC)?.month, 10);
      expect(parseDateNodeId(dayC)?.day, 28);
      expect(parseDateNodeId(monthNode)?.precision, DateNodePrecision.month);
      expect(parseDateNodeId(monthNode)?.day, 1);
      expect(parseDateNodeId(yearNode)?.precision, DateNodePrecision.year);
    });

    test('rejects non-date ids and out-of-range parts', () {
      expect(parseDateNodeId(notDate), isNull);
      expect(parseDateNodeId('short'), isNull);
      // month 13
      expect(parseDateNodeId('00000000-0000-0000-00dd-202613010000'), isNull);
      // day 32
      expect(parseDateNodeId('00000000-0000-0000-00dd-202610320000'), isNull);
      // year below the 1900 window
      expect(parseDateNodeId('00000000-0000-0000-00bb-189900000000'), isNull);
      // non-digit payload
      expect(parseDateNodeId('00000000-0000-0000-00dd-2026102xxxxx'), isNull);
    });
  });

  group('scheduledIsoOf — the datetime slot grammar', () {
    test('null and garbage read as null', () {
      expect(scheduledIsoOf(null), isNull);
      expect(scheduledIsoOf(42), isNull);
      expect(scheduledIsoOf(<String>[]), isNull);
      expect(scheduledIsoOf(<String, dynamic>{}), isNull);
      expect(scheduledIsoOf(<String, dynamic>{'nodeId': 7}), isNull);
    });

    test('point: bare uuid string and {nodeId, time} read their day', () {
      expect(scheduledIsoOf(dayC), '2026-10-28');
      expect(scheduledIsoOf(<String, dynamic>{'nodeId': dayC, 'time': '14:30'}), '2026-10-28');
      expect(scheduledIsoOf(<String, dynamic>{'nodeId': dayC}), '2026-10-28');
    });

    test('range: the start day wins; an open start falls back to the end day', () {
      expect(
        scheduledIsoOf(<String, dynamic>{
          'start': <String, dynamic>{'nodeId': dayC},
          'end': <String, dynamic>{'nodeId': dayE},
        }),
        '2026-10-28',
      );
      expect(
        scheduledIsoOf(<String, dynamic>{
          'start': null,
          'end': <String, dynamic>{'nodeId': dayE},
        }),
        '2026-12-01',
      );
    });

    test('month/year-precision refs never read as a day (the load-bearing strictness)', () {
      expect(scheduledIsoOf(monthNode), isNull);
      expect(scheduledIsoOf(yearNode), isNull);
      expect(
        scheduledIsoOf(<String, dynamic>{
          'start': <String, dynamic>{'nodeId': monthNode},
          'end': <String, dynamic>{'nodeId': dayD},
        }),
        '2026-11-05',
      );
      expect(
        scheduledIsoOf(<String, dynamic>{
          'start': <String, dynamic>{'nodeId': monthNode},
          'end': <String, dynamic>{'nodeId': yearNode},
        }),
        isNull,
      );
    });
  });

  group('partitionCardsIntoBuckets', () {
    final rows = [
      const CardScheduleRow(id: 'a', due: '2026-10-28'),
      const CardScheduleRow(id: 'c'),
      const CardScheduleRow(id: 'd', due: '2026-11-05'),
      const CardScheduleRow(id: 'b', due: '2026-10-20'),
      const CardScheduleRow(id: 'f', due: '2026-12-01'),
      const CardScheduleRow(id: 'e', due: '2026-10-27'),
    ];

    test('due ≤ today (day-asc, then id), fresh in input order, later day-asc', () {
      final buckets = partitionCardsIntoBuckets(rows, today);
      expect(buckets.due.map((r) => r.id).toList(), ['b', 'e', 'a']);
      expect(buckets.fresh.map((r) => r.id).toList(), ['c']);
      expect(buckets.later.map((r) => r.id).toList(), ['d', 'f']);
    });

    test('due-day ties break by id', () {
      final tied = [
        const CardScheduleRow(id: 'z', due: '2026-10-28'),
        const CardScheduleRow(id: 'm', due: '2026-10-28'),
        const CardScheduleRow(id: 'q', due: '2026-10-28'),
      ];
      final buckets = partitionCardsIntoBuckets(tied, today);
      expect(buckets.due.map((r) => r.id).toList(), ['m', 'q', 'z']);
    });

    test('every row lands in exactly one bucket', () {
      final buckets = partitionCardsIntoBuckets(rows, today);
      expect(buckets.due.length + buckets.fresh.length + buckets.later.length, rows.length);
    });
  });

  group('buildReviewQueue', () {
    final rows = [
      const CardScheduleRow(id: 'a', due: '2026-10-28'),
      const CardScheduleRow(id: 'c'),
      const CardScheduleRow(id: 'd', due: '2026-11-05'),
      const CardScheduleRow(id: 'b', due: '2026-10-20'),
      const CardScheduleRow(id: 'e', due: '2026-10-27'),
    ];

    test('due-first (day-asc, then id), then fresh in input order', () {
      expect(buildReviewQueue(rows, today), ['b', 'e', 'a', 'c']);
    });

    test('future-due ids are dropped, never queued', () {
      expect(buildReviewQueue([const CardScheduleRow(id: 'd', due: '2026-11-05')], today), isEmpty);
      expect(buildReviewQueue([const CardScheduleRow(id: 'd', due: '2027-01-01')], today), isEmpty);
    });

    test('a hand-off carrying only future-due and fresh ids queues the fresh set', () {
      final queue = buildReviewQueue(
        [
          const CardScheduleRow(id: 'd', due: '2026-11-05'),
          const CardScheduleRow(id: 'x'),
        ],
        today,
      );
      expect(queue, ['x']);
    });
  });

  group('srsStateOf', () {
    EffectiveProperty row(String schemaId, dynamic value) {
      return EffectiveProperty(
        propertySchemaId: schemaId,
        idx: 0,
        elementId: 'el-$schemaId',
        schema: null,
        value: value,
        metadata: null,
        source: 'authored',
        boundBy: null,
        hideWhenEmpty: null,
        display: null,
      );
    }

    test('empty reads are the unseen defaults', () {
      final state = srsStateOf(const []);
      expect(state.due, isNull);
      expect(state.reps, 0);
      expect(state.interval, 0);
      expect(state.ease, isNull);
      expect(state.difficulty, isNull);
      expect(state.stability, isNull);
      expect(state, unseenCardState);
    });

    test('the six card-family values read exactly', () {
      final state = srsStateOf([
        row(SystemPropertyUuids.cardDue, <String, dynamic>{'nodeId': dayB}),
        row(SystemPropertyUuids.cardReps, 3),
        row(SystemPropertyUuids.cardInterval, 7),
        row(SystemPropertyUuids.cardEase, 2.5),
        row(SystemPropertyUuids.cardDifficulty, 5),
        row(SystemPropertyUuids.cardStability, 3.17),
      ]);
      expect(state.due, '2026-10-27');
      expect(state.reps, 3);
      expect(state.interval, 7);
      expect(state.ease, 2.5);
      expect(state.difficulty, 5);
      expect(state.stability, 3.17);
    });

    test('missing or unparseable fields read as unseen defaults — a corrupt row never crashes', () {
      final state = srsStateOf([
        row(SystemPropertyUuids.cardDue, 'not-a-slot'),
        row(SystemPropertyUuids.cardReps, '3'),
        row(SystemPropertyUuids.cardInterval, double.nan),
        row(SystemPropertyUuids.cardEase, double.infinity),
      ]);
      expect(state.due, isNull);
      expect(state.reps, 0);
      expect(state.interval, 0);
      expect(state.ease, isNull);
      expect(state, unseenCardState);
    });

    test('duplicate schema ids resolve to the first row (the find() parity)', () {
      final state = srsStateOf([
        row(SystemPropertyUuids.cardReps, 2),
        row(SystemPropertyUuids.cardReps, 9),
      ]);
      expect(state.reps, 2);
    });
  });

  group('todayIsoLocal', () {
    test('formats local today as YYYY-MM-DD', () {
      final now = DateTime.now();
      final expected =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      expect(todayIsoLocal(), expected);
      expect(RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(todayIsoLocal()), isTrue);
    });
  });
}
