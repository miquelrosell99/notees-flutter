import 'dart:math' as math;

import '../models/relay/hlc.dart';

/// Hybrid logical clock used when generating local operations.
///
/// Semantics verified against `v2/packages/protocol/src/hlc.ts` (the v2 norm):
/// [advance] mirrors `Clock.now` and [update] mirrors `Clock.update` —
/// `physical = max(wallClock, last.physical, received.physical)` with the
/// logical counter resolved per branch. The clock never moves backwards, and
/// a follow-up local advance is always strictly greater than a merged remote
/// event.
class HlcClock {
  HlcClock({Hlc? last}) : _last = last ?? const Hlc(physical: 0, logical: 0);

  Hlc _last;

  Hlc get last => _last;

  /// Returns a new HLC for the given physical time (defaults to now).
  ///
  /// Mirrors `Clock.now`: a physical time ahead of the last one resets the
  /// logical counter to zero; otherwise the counter increments while the
  /// physical component is held.
  Hlc advance([int? physicalTime]) {
    final physical = physicalTime ?? DateTime.now().millisecondsSinceEpoch;
    if (physical > _last.physical) {
      _last = Hlc(physical: physical, logical: 0);
    } else {
      _last = Hlc(
        physical: _last.physical,
        logical: _last.logical + 1,
      );
    }
    return _last;
  }

  /// Merges a remote HLC into the local clock (`Clock.update`).
  ///
  /// `physical = max(wallClock, last.physical, received.physical)`; the
  /// logical component then resolves by which operand(s) won the max:
  /// both → `max(last, received) + 1`; last only → `last + 1`; received only
  /// → `received + 1`; wall clock beat both → `0`.
  Hlc update(Hlc received, [int? physicalTime]) {
    final wall = physicalTime ?? DateTime.now().millisecondsSinceEpoch;
    final physical =
        math.max(wall, math.max(_last.physical, received.physical));
    final logical = physical == _last.physical &&
            physical == received.physical
        ? math.max(_last.logical, received.logical) + 1
        : physical == _last.physical
            ? _last.logical + 1
            : physical == received.physical
                ? received.logical + 1
                : 0;
    _last = Hlc(physical: physical, logical: logical);
    return _last;
  }
}
