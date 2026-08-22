import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

/// Exposes the current network connectivity state.
class ConnectivityProvider extends ChangeNotifier {
  ConnectivityProvider([Connectivity? connectivity])
      : _connectivity = connectivity ?? Connectivity() {
    _init();
  }

  final Connectivity _connectivity;
  StreamSubscription<List<ConnectivityResult>>? _sub;

  bool _online = true;

  bool get online => _online;

  void _init() {
    _connectivity.checkConnectivity().then(_update);
    _sub = _connectivity.onConnectivityChanged.listen(_update);
  }

  void _update(List<ConnectivityResult> results) {
    final wasOnline = _online;
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
