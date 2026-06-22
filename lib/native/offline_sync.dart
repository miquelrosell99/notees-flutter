import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../data/local/app_database.dart';
import '../domain/services/offline_queue.dart';

/// Watches connectivity and drains the offline queue when the device comes
/// back online.
class OfflineSync extends StatefulWidget {
  const OfflineSync({super.key, required this.dio, required this.child});

  final Dio dio;
  final Widget child;

  @override
  State<OfflineSync> createState() => _OfflineSyncState();
}

class _OfflineSyncState extends State<OfflineSync> {
  late final OfflineQueue _queue;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool _wasOnline = true;

  @override
  void initState() {
    super.initState();
    _queue = OfflineQueue(
      database: AppDatabase(),
      dio: widget.dio,
    );
    _sub = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.isNotEmpty && !results.contains(ConnectivityResult.none);
      if (!_wasOnline && online) {
        _flush();
      }
      _wasOnline = online;
    });
    _flush();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _flush() async {
    final errors = await _queue.process();
    if (errors.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Some offline notes could not be synced: ${errors.first}'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
