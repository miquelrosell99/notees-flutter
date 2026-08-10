import '../models/relay/hlc.dart';

/// Hybrid logical clock used when generating local operations.
///
/// The clock keeps track of the last issued [Hlc] and advances it when asked
/// for a new timestamp. It also merges remote HLCs so that local time never
/// moves backwards.
class HlcClock {
  HlcClock({Hlc? last}) : _last = last ?? const Hlc(physical: 0, logical: 0);

  Hlc _last;

  Hlc get last => _last;

  /// Returns a new HLC for the given physical time (defaults to now).
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

  /// Merges a remote HLC into the local clock.
  ///
  /// Mirrors the server's `Clock.update`: the result is the maximum of the local
  /// and received HLCs, adjusted for the current wall time so that the clock
  /// never moves backwards and a follow-up local advance is always strictly
  /// greater than the remote event.
  void update(Hlc remote, [int? physicalTime]) {
    final physical = physicalTime ?? DateTime.now().millisecondsSinceEpoch;
    if (physical > _last.physical && physical > remote.physical) {
      _last = Hlc(physical: physical, logical: 0);
    } else {
      final maxPhysical =
          _last.physical > remote.physical ? _last.physical : remote.physical;
      int logical;
      if (maxPhysical == _last.physical && maxPhysical == remote.physical) {
        logical = (_last.logical > remote.logical
                ? _last.logical
                : remote.logical) +
            1;
      } else if (maxPhysical == _last.physical) {
        logical = _last.logical + 1;
      } else {
        logical = remote.logical + 1;
      }
      _last = Hlc(physical: maxPhysical, logical: logical);
    }
  }
}
