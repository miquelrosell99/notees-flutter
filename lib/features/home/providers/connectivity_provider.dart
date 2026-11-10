import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:material_ui/material_ui.dart';

/// Exposes the current network connectivity state.
class ConnectivityProvider extends ChangeNotifier {
  ConnectivityProvider([Connectivity? connectivity])
      : _connectivity = connectivity ?? Connectivity() {
    _init();
  }

  final Connectivity _connectivity;
  StreamSubscription<List<ConnectivityResult>>? _sub;

  bool _online = true;
  List<ConnectivityResult> _results = const [];

  bool get online => _online;

  /// Whether the current connection is likely unmetered (the snapshot
  /// auto-upload's "Wi-Fi only" gate). Heuristic over the pinned
  /// connectivity_plus major: wifi/ethernet/vpn/bluetooth/other read as
  /// unmetered, mobile/satellite as metered, offline never unmetered. A
  /// mobile result alongside wifi (dual-transport phones) reads metered —
  /// the conservative side of the guess.
  bool get unmetered => isUnmetered(_results);

  static bool isUnmetered(List<ConnectivityResult> results) {
    if (results.isEmpty || results.contains(ConnectivityResult.none)) {
      return false;
    }
    return !results.contains(ConnectivityResult.mobile) &&
        !results.contains(ConnectivityResult.satellite);
  }

  void _init() {
    _connectivity.checkConnectivity().then(_update);
    _sub = _connectivity.onConnectivityChanged.listen(_update);
  }

  void _update(List<ConnectivityResult> results) {
    final wasOnline = _online;
    _results = results;
    _online = results.isNotEmpty && !results.contains(ConnectivityResult.none);
    if (wasOnline != _online) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
