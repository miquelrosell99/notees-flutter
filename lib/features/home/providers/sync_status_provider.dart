import 'dart:async';

import 'package:flutter/foundation.dart';

/// Drives the bootstrap "Catching up…" overlay, the counterpart of the web
/// client's ConnectingScreen during the workspace connect: the FIRST pull
/// after a workspace session begins shows an opaque full-screen surface
/// with the catch-up progress; later catch-ups (realtime-triggered,
/// connectivity-driven) stay silent.
///
/// Lifecycle: [beginCatchUp] opens the overlay when a workspace-entry pull
/// kicks; [updateProgress] forwards the sync service's per-page pull
/// progress and ends the overlay when a page reports completion (total <=
/// applied, i.e. the server has no remaining envelopes); [endCatchUp]
/// closes it. The pull path also ends the overlay in a `finally`, and
/// [_timeout] is a pure safety net (NOT web behavior): a pull that never
/// completes or never reports can never leave the overlay up forever.
class SyncStatusProvider extends ChangeNotifier {
  SyncStatusProvider({this.timeout = const Duration(seconds: 60)});

  /// The safety-net duration after which a still-open overlay is ended even
  /// without a completion signal (a stuck pull can never block the app
  /// forever). Not web behavior — the web has no such timeout.
  final Duration timeout;
  Timer? _backstopTimer;

  bool _showCatchUpOverlay = false;
  double? _fraction;

  bool get showCatchUpOverlay => _showCatchUpOverlay;

  /// The live catch-up fraction 0–1, or null before the first progress
  /// event of the current catch-up.
  double? get fraction => _fraction;

  /// "Catching up… N%" (floored, web copy) when a fraction is live, plain
  /// "Catching up…" otherwise. Null while the overlay is hidden.
  String? get progressLabel {
    if (!_showCatchUpOverlay) return null;
    final value = _fraction;
    if (value == null) return 'Catching up…';
    final percent = (value.clamp(0.0, 1.0) * 100).floor();
    return 'Catching up… $percent%';
  }

  /// Opens the overlay for a workspace-entry catch-up and arms the timeout
  /// backstop. Re-beginning restarts the backstop and drops any stale
  /// fraction.
  void beginCatchUp() {
    _backstopTimer?.cancel();
    _showCatchUpOverlay = true;
    _fraction = null;
    _backstopTimer = Timer(timeout, endCatchUp);
    notifyListeners();
  }

  /// Forwards a pull progress event. Silent while no overlay is up (later
  /// catch-ups stay silent). A page whose total has caught up with the
  /// applied count means the pull is done — end the overlay.
  void updateProgress(int applied, int total) {
    if (!_showCatchUpOverlay) return;
    if (total <= applied) {
      endCatchUp();
      return;
    }
    _fraction = applied / total;
    notifyListeners();
  }

  /// Closes the overlay (pull completion, pull failure, timeout backstop).
  /// No-op when already hidden.
  void endCatchUp() {
    if (!_showCatchUpOverlay) return;
    _backstopTimer?.cancel();
    _backstopTimer = null;
    _showCatchUpOverlay = false;
    _fraction = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _backstopTimer?.cancel();
    super.dispose();
  }
}
