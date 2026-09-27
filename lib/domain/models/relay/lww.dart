/// Row-level last-write-wins winner tuple, ported from
/// `v2/packages/store/src/appliers.ts` compareLww.
///
/// v2 convergence: higher HLC wins; equal HLC breaks the tie on actor id
/// (lexicographic, deterministic). Property slots and OR-Set pairs all key
/// their winners by (hlc_physical, hlc_logical, actor_id).
typedef LwwWinner = ({int physical, int logical, String actor});

/// Compares two winners; positive when [a] wins over [b].
int compareLww(LwwWinner a, LwwWinner b) {
  if (a.physical != b.physical) return a.physical - b.physical;
  if (a.logical != b.logical) return a.logical - b.logical;
  if (a.actor != b.actor) return a.actor.compareTo(b.actor) < 0 ? -1 : 1;
  return 0;
}

/// The winning (hlc, actor) tuple stamped on a node row by the last applied
/// v2 `object.update`/`object.move`/`object.create`.
LwwWinner lwwWinnerFrom({
  required int physical,
  required int logical,
  required String actor,
}) => (physical: physical, logical: logical, actor: actor);
