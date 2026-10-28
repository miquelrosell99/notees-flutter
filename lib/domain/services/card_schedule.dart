/// Card scheduling — the pure logic behind the Cards hub buckets and the
/// review-session queue, a 1:1 port of the web app's
/// `features/classview/CardBuckets.tsx` (partition), `features/cards/reviewQueue.ts`
/// (queue), `features/calendar/calendarViewUtils.ts` (datetime slot grammar)
/// and `features/cards/ReviewSession.tsx` (the SRS-state read).
library;

import '../../core/constants/system.dart';
import '../../core/utils/date_uuid.dart';
import '../../data/repositories/node_cache_repository.dart';
import 'srs.dart';

/// One orderable card row: the id plus the effective cardDue day
/// (null = fresh — the card has never been scheduled).
class CardScheduleRow {
  const CardScheduleRow({required this.id, this.due});

  final String id;
  final String? due;
}

/// The cards-bucket partition: due-or-before-today → [due], no day →
/// [fresh], future → [later].
class CardBuckets {
  const CardBuckets({required this.due, required this.fresh, required this.later});

  /// cardDue day on or before today — overdue or due now.
  final List<CardScheduleRow> due;

  /// No cardDue value — the never-reviewed set.
  final List<CardScheduleRow> fresh;

  /// cardDue day after today.
  final List<CardScheduleRow> later;
}

/// The cards-bucket partition: due-or-before-today → Due, no day → Fresh,
/// future → Later. Due and Later sort by day then id; Fresh keeps input
/// order (there is no day to sort by). (`CardBuckets.tsx` parity.)
CardBuckets partitionCardsIntoBuckets(List<CardScheduleRow> rows, String todayIso) {
  final due = <CardScheduleRow>[];
  final fresh = <CardScheduleRow>[];
  final later = <CardScheduleRow>[];
  for (final row in rows) {
    final day = row.due;
    if (day == null) {
      fresh.add(row);
    } else if (day.compareTo(todayIso) <= 0) {
      due.add(row);
    } else {
      later.add(row);
    }
  }
  int byDay(CardScheduleRow a, CardScheduleRow b) {
    final byDue = (a.due ?? '').compareTo(b.due ?? '');
    return byDue != 0 ? byDue : a.id.compareTo(b.id);
  }

  due.sort(byDay);
  later.sort(byDay);
  return CardBuckets(due: due, fresh: fresh, later: later);
}

/// The session's review order, ids only: due cards (due ≤ today) sorted by
/// due-date ascending — overdue first by construction — then fresh cards in
/// input order. Future-due rows are NOT reviewable and never enter the
/// queue, whatever the hand-off carried. (`reviewQueue.ts` parity.)
List<String> buildReviewQueue(List<CardScheduleRow> rows, String todayIso) {
  final due = <CardScheduleRow>[];
  final fresh = <CardScheduleRow>[];
  for (final row in rows) {
    final day = row.due;
    if (day == null) {
      fresh.add(row);
    } else if (day.compareTo(todayIso) <= 0) {
      due.add(row);
    }
    // Future-due: excluded — the Later bucket's set, never the session's.
  }
  due.sort((a, b) {
    final byDue = (a.due ?? '').compareTo(b.due ?? '');
    return byDue != 0 ? byDue : a.id.compareTo(b.id);
  });
  return [...due, ...fresh].map((row) => row.id).toList(growable: false);
}

// --- datetime value slots (SCHEMA.md "Datetime") ---------------------------------

String _pad2(int value) => value.toString().padLeft(2, '0');

/// `YYYY-MM-DD` from parsed date-node id parts.
String isoOfParsedDateNode(ParsedDateNodeId parts) {
  return '${parts.year.toString().padLeft(4, '0')}-${_pad2(parts.month)}-${_pad2(parts.day)}';
}

/// One normalized slot of a datetime value: a day node reference plus an
/// optional wall-clock time ("HH:MM" — absence IS the full-day register).
class DateValueSlot {
  const DateValueSlot({required this.nodeId, this.time});

  final String nodeId;
  final String? time;
}

/// Normalize one slot-ish piece of a datetime value: a point object
/// `{ "nodeId": …, "time"?: … }` or a legacy bare-uuid string (the archived
/// date encoding normalizes to an untimed slot at read time). Null for
/// anything else.
DateValueSlot? slotOf(Object? value) {
  if (value is String) return DateValueSlot(nodeId: value);
  if (value is! Map) return null;
  final nodeId = value['nodeId'];
  if (nodeId is! String) return null;
  final time = value['time'];
  return DateValueSlot(nodeId: nodeId, time: time is String ? time : null);
}

/// The `{ start, end }` view of a RANGE datetime value (either side open).
/// Null for points and non-date shapes.
class DateRangeSlots {
  const DateRangeSlots({this.start, this.end});

  final DateValueSlot? start;
  final DateValueSlot? end;
}

DateValueSlot? _rangeSide(Object? value) => value == null ? null : slotOf(value);

DateRangeSlots? rangeSlotsOf(Object? value) {
  if (value is! Map) return null;
  if (!value.containsKey('start') && !value.containsKey('end')) return null;
  return DateRangeSlots(start: _rangeSide(value['start']), end: _rangeSide(value['end']));
}

/// The local ISO day of one slot (null unless the target parses at day precision).
String? slotIsoOf(DateValueSlot? slot) {
  if (slot == null) return null;
  final parsed = parseDateNodeId(slot.nodeId);
  if (parsed == null || parsed.precision != DateNodePrecision.day) return null;
  return isoOfParsedDateNode(parsed);
}

/// The local ISO day a datetime value points at: a POINT's own day; a
/// RANGE's START slot day, falling back to the END slot's day when the
/// start side is open. Null unless the resolved slot parses at day
/// precision — the strictness is load-bearing (month/year-precision refs
/// never read as a day). (`calendarViewUtils.ts` `scheduledIsoOf` parity.)
String? scheduledIsoOf(Object? value) {
  final range = rangeSlotsOf(value);
  if (range != null) return slotIsoOf(range.start) ?? slotIsoOf(range.end);
  return slotIsoOf(slotOf(value));
}

/// The six card-family property values → a [CardSrsState]: missing or
/// unparseable fields read as the unseen defaults (the effective read is
/// the schedule's authority — a corrupt row reads as never-reviewed, never
/// crashes the session). (`ReviewSession.tsx` parity.)
CardSrsState srsStateOf(List<EffectiveProperty> props) {
  Object? valueOf(String schemaId) {
    for (final row in props) {
      if (row.propertySchemaId == schemaId) return row.value;
    }
    return null;
  }

  num? numOf(Object? value) => value is num && value.isFinite ? value : null;

  return CardSrsState(
    due: scheduledIsoOf(valueOf(SystemPropertyUuids.cardDue)),
    reps: numOf(valueOf(SystemPropertyUuids.cardReps)) ?? 0,
    interval: numOf(valueOf(SystemPropertyUuids.cardInterval)) ?? 0,
    ease: numOf(valueOf(SystemPropertyUuids.cardEase)),
    difficulty: numOf(valueOf(SystemPropertyUuids.cardDifficulty)),
    stability: numOf(valueOf(SystemPropertyUuids.cardStability)),
  );
}

/// Local `YYYY-MM-DD` for today — always local midnight, never UTC-derived.
String todayIsoLocal() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-${_pad2(now.month)}-${_pad2(now.day)}';
}
