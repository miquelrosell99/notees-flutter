/// Spaced-repetition scheduling for memorization cards — the pure v1
/// scheduler, a 1:1 port of the web app's `packages/domain/src/srs.ts`
/// (the source of truth). Two algorithms, one state shape:
///
/// - **SM-2** (the Anki classic): ease factor + fixed first intervals
///   (1, 6, then `interval * ease`), lapse resets to reps 0 / interval 1
///   with the ease floor at 1.3.
/// - **FSRS-5** (the default-parameter set, no fitting — v1): stability
///   `S` in days + difficulty `D` in [1,10]; the first review initializes
///   both from the weight vector, subsequent reviews move them through the
///   published FSRS-5 recurrence.
///
/// One [CardSrsState] carries BOTH algorithms' fields; the active
/// algorithm's fields move while the other's stay byte-for-byte stale
/// (the mid-deck algorithm-switch contract: an sm2-reviewed card graded
/// under fsrs initializes its fsrs fields from defaults and never touches
/// the stale `ease`, and symmetrically).
///
/// All date math is UTC ([DateTime.utc] + [Duration] days, formatted back
/// to `YYYY-MM-DD`) so day arithmetic never crosses a DST boundary.
library;

import 'dart:math' as math;

/// The four review grades (pinned by the `card.review` wire payload).
enum CardGrade { again, hard, good, easy }

enum SrsAlgorithm { sm2, fsrs }

/// The wire scalar for [SrsAlgorithm] — the `cardsAlgorithm` prefs value.
extension SrsAlgorithmWire on SrsAlgorithm {
  String get wire => switch (this) {
        SrsAlgorithm.sm2 => 'sm2',
        SrsAlgorithm.fsrs => 'fsrs',
      };
}

/// Parses the `cardsAlgorithm` wire scalar; null for anything else.
SrsAlgorithm? parseSrsAlgorithm(Object? raw) => switch (raw) {
      'sm2' => SrsAlgorithm.sm2,
      'fsrs' => SrsAlgorithm.fsrs,
      _ => null,
    };

/// Immutable SRS state; one shape carries both algorithms' fields.
class CardSrsState {
  const CardSrsState({
    this.due,
    required this.reps,
    required this.interval,
    this.ease,
    this.difficulty,
    this.stability,
  });

  /// YYYY-MM-DD; null = unseen.
  final String? due;

  final num reps;

  /// Days.
  final num interval;

  /// sm2.
  final num? ease;

  /// fsrs.
  final num? difficulty;

  /// fsrs, days.
  final num? stability;

  /// The state of a card that has never been reviewed.
  static const unseen = CardSrsState(reps: 0, interval: 0);

  @override
  bool operator ==(Object other) =>
      other is CardSrsState &&
      other.due == due &&
      other.reps == reps &&
      other.interval == interval &&
      other.ease == ease &&
      other.difficulty == difficulty &&
      other.stability == stability;

  @override
  int get hashCode => Object.hash(due, reps, interval, ease, difficulty, stability);

  @override
  String toString() =>
      'CardSrsState(due: $due, reps: $reps, interval: $interval, ease: $ease, difficulty: $difficulty, stability: $stability)';
}

/// The state of a card that has never been reviewed.
const unseenCardState = CardSrsState.unseen;

// SM-2 grade → Anki quality: again 1, hard 3, good 4, easy 5
const sm2Quality = {CardGrade.again: 1, CardGrade.hard: 3, CardGrade.good: 4, CardGrade.easy: 5};
const sm2InitialEase = 2.5;
const sm2EaseFloor = 1.3;

// FSRS-5 default parameters (fixed for v1; fitting from card_review history is a follow-up)
const fsrsW = [
  0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, //
  1.54575, 0.1192, 1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621,
];
const fsrsRating = {CardGrade.again: 1, CardGrade.hard: 2, CardGrade.good: 3, CardGrade.easy: 4};
const fsrsDMin = 1;
const fsrsDMax = 10;

/// Weight lookup — the vector is a compile-time constant with 19 fixed entries.
double w(int index) => fsrsW[index];

num clamp(num value, num lo, num hi) => math.min(hi, math.max(lo, value));

String _pad4(int value) => value.toString().padLeft(4, '0');
String _pad2(int value) => value.toString().padLeft(2, '0');

/// UTC day arithmetic: `iso` + `days`, formatted back to YYYY-MM-DD.
String addDays(String iso, int days) {
  final y = int.parse(iso.substring(0, 4));
  final m = int.parse(iso.substring(5, 7));
  final d = int.parse(iso.substring(8, 10));
  final date = DateTime.utc(y, m, d).add(Duration(days: days));
  return '${_pad4(date.year)}-${_pad2(date.month)}-${_pad2(date.day)}';
}

/// Whole days from `from` to `to` (UTC math; non-negative on due-or-late reviews).
int dayDiff(String from, String to) {
  final y1 = int.parse(from.substring(0, 4));
  final m1 = int.parse(from.substring(5, 7));
  final d1 = int.parse(from.substring(8, 10));
  final y2 = int.parse(to.substring(0, 4));
  final m2 = int.parse(to.substring(5, 7));
  final d2 = int.parse(to.substring(8, 10));
  return DateTime.utc(y2, m2, d2).difference(DateTime.utc(y1, m1, d1)).inDays;
}

/// SM-2 ease update: `max(1.3, ease + 0.1 - (5-q)(0.08 + (5-q)0.02))`.
num nextSm2Ease(num ease, int quality) {
  final delta = 5 - quality;
  return math.max(sm2EaseFloor, ease + 0.1 - delta * (0.08 + delta * 0.02));
}

CardSrsState nextSm2State(CardSrsState state, CardGrade grade, String todayIso) {
  final quality = sm2Quality[grade]!;
  // SM-2 never touches the fsrs fields; ease initializes from the SM-2
  // default when the card arrives from the fsrs algorithm (or unseen).
  final ease = nextSm2Ease(state.ease ?? sm2InitialEase, quality);
  final num reps;
  final num interval;
  if (grade == CardGrade.again) {
    reps = 0;
    interval = 1;
  } else {
    reps = state.reps + 1;
    if (state.reps == 0) {
      interval = 1;
    } else if (state.reps == 1) {
      interval = 6;
    } else {
      interval = (state.interval * (state.ease ?? sm2InitialEase)).round();
    }
  }
  return CardSrsState(
    due: addDays(todayIso, interval.toInt()),
    reps: reps,
    interval: interval,
    ease: ease,
    difficulty: state.difficulty,
    stability: state.stability,
  );
}

/// Retrievability R(t,S) = (1 + t/(9S))^-1, t in elapsed days.
double retrievability(num elapsedDays, num stability) {
  return math.pow(1 + elapsedDays / (9 * stability), -1).toDouble();
}

CardSrsState nextFsrsState(CardSrsState state, CardGrade grade, String todayIso) {
  final rating = fsrsRating[grade]!;
  // FSRS never touches the sm2 ease field.
  final ease = state.ease;

  // First-review path: the incoming state lacks THIS algorithm's fields
  // (mid-deck switch or unseen) — initialize from the FSRS-5 default
  // weights, regardless of reps, same-day re-view (interval 0).
  if (state.stability == null || state.difficulty == null) {
    final stability = w(rating - 1);
    final difficulty = clamp(w(4), fsrsDMin, fsrsDMax);
    return CardSrsState(
      due: todayIso,
      reps: rating == 1 ? 0 : 1,
      interval: 0,
      ease: ease,
      difficulty: difficulty,
      stability: stability,
    );
  }

  final stability = state.stability!;
  final difficulty = state.difficulty!;
  // Elapsed days since the last review: the scheduled interval plus the
  // slip (or lead) between the due date and today.
  final elapsed = state.interval + (state.due == null ? 0 : dayDiff(state.due!, todayIso));
  final r = retrievability(math.max(0, elapsed), stability);

  // Difficulty first — the FSRS-5 stability recurrence consumes D', the
  // post-update difficulty.
  final nextDifficulty = clamp(difficulty - w(6) * (rating - 3), fsrsDMin, fsrsDMax);
  final num nextStability;
  if (rating == 1) {
    // Lapse path: S' = w11 * D'^-w12 * ((S+1)^w13 - 1) * e^((1-R)w14)
    nextStability =
        w(11) * math.pow(nextDifficulty, -w(12)) * (math.pow(stability + 1, w(13)) - 1) * math.exp((1 - r) * w(14));
  } else {
    // S' = S * (1 + e^w8 * (11-D') * S^-w9 * (e^((1-R)w10) - 1))
    nextStability = stability *
        (1 +
            math.exp(w(8)) *
                (11 - nextDifficulty) *
                math.pow(stability, -w(9)) *
                (math.exp((1 - r) * w(10)) - 1));
  }

  final interval = math.max(0, nextStability.round());
  final reps = rating == 1 ? 0 : state.reps + 1;
  return CardSrsState(
    due: addDays(todayIso, interval.toInt()),
    reps: reps,
    interval: interval,
    ease: ease,
    difficulty: nextDifficulty,
    stability: nextStability,
  );
}

/// The next SRS state after grading [grade] with [algorithm] on [todayIso]
/// (YYYY-MM-DD). Pure: returns a fresh state, never mutates.
CardSrsState nextCardState(
  CardSrsState state,
  CardGrade grade,
  SrsAlgorithm algorithm,
  String todayIso,
) {
  return algorithm == SrsAlgorithm.sm2 ? nextSm2State(state, grade, todayIso) : nextFsrsState(state, grade, todayIso);
}

/// A card is due when unseen, due today, or overdue — string compare on YYYY-MM-DD is chronological.
bool isCardStateDue(CardSrsState state, String todayIso) {
  return state.due == null || state.due!.compareTo(todayIso) <= 0;
}
