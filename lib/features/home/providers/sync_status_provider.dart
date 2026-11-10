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
/// closes it. [failCatchUp] switches the overlay to error mode (the failure
/// stays until the user retries or dismisses — the pull path also ends the
/// overlay on success, and [timeout] is a pure safety net, NOT web
/// behavior: a pull that never completes or never reports can never leave
/// the overlay up forever). A legit first-sync snapshot restore takes
/// minutes, so the backstop is generous (10 minutes).
class SyncStatusProvider extends ChangeNotifier {
  SyncStatusProvider({this.timeout = const Duration(minutes: 10)});

  /// The safety-net duration after which a still-open overlay is ended even
  /// without a completion signal (a stuck pull can never block the app
  /// forever). Not web behavior — the web has no such timeout. Error mode
  /// cancels the backstop: a surfaced failure stays until the user acts.
  final Duration timeout;
  Timer? _backstopTimer;

  bool _showCatchUpOverlay = false;
  double? _fraction;
  String? _pullError;

  bool get showCatchUpOverlay => _showCatchUpOverlay;

  /// The live catch-up fraction 0–1, or null before the first progress
  /// event of the current catch-up.
  double? get fraction => _fraction;

  /// The pull failure when the overlay is in error mode, or null.
  String? get pullError => _pullError;

  /// Whether the overlay is showing a failed pull (with retry/dismiss
  /// affordances) instead of progress.
  bool get isPullFailed => _pullError != null;

  /// "Catching up… N%" (floored, web copy) when a fraction is live, plain
  /// "Catching up…" otherwise. Null while the overlay is hidden or in error
  /// mode.
  String? get progressLabel {
    if (!_showCatchUpOverlay || _pullError != null) return null;
    final value = _fraction;
    if (value == null) return 'Catching up…';
    final percent = (value.clamp(0.0, 1.0) * 100).floor();
    return 'Catching up… $percent%';
  }

  /// Opens the overlay for a workspace-entry catch-up: clears any previous
  /// error, drops any stale fraction, and re-arms the backstop.
  void beginCatchUp() {
    _backstopTimer?.cancel();
    _showCatchUpOverlay = true;
    _fraction = null;
    _pullError = null;
    _backstopTimer = Timer(timeout, endCatchUp);
    notifyListeners();
  }

  /// Forwards a pull progress event. Silent while no overlay is up or while
  /// in error mode (later catch-ups stay silent; a surfaced error is never
  /// swept away by a stale progress event). A page whose total has caught
  /// up with the applied count means the pull is done — end the overlay.
  void updateProgress(int applied, int total) {
    if (!_showCatchUpOverlay || _pullError != null) return;
    if (total <= applied) {
      endCatchUp();
      return;
    }
    _fraction = applied / total;
    notifyListeners();
  }

  /// Closes the overlay on pull completion (or via the timeout backstop),
  /// clearing any stale error. No-op when already hidden.
  void endCatchUp() {
    if (!_showCatchUpOverlay) return;
    _backstopTimer?.cancel();
    _backstopTimer = null;
    _showCatchUpOverlay = false;
    _fraction = null;
    _pullError = null;
    notifyListeners();
  }

  /// Switches the overlay to error mode: the failure stays up (with retry /
  /// dismiss affordances) until the user acts — the backstop is cancelled,
  /// so a surfaced error never self-dismisses.
  void failCatchUp(String error) {
    _backstopTimer?.cancel();
    _backstopTimer = null;
    _showCatchUpOverlay = true;
    _fraction = null;
    _pullError = error;
    notifyListeners();
  }

  /// Hides the overlay after a surfaced failure (the Dismiss action); the
  /// error state is cleared. The next [beginCatchUp] starts fresh.
  void dismissError() {
    if (_pullError == null) return;
    _pullError = null;
    _showCatchUpOverlay = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _backstopTimer?.cancel();
    super.dispose();
  }
}
