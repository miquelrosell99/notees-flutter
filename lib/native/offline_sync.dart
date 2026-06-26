import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/secure/encryption_provider.dart';
import '../data/local/app_database.dart';
import '../domain/services/offline_queue.dart';
import '../domain/services/sync_v2_service.dart';

/// Watches connectivity and app lifecycle and drains the offline queue when
/// the device comes back online or the app returns to the foreground.
class OfflineSync extends StatefulWidget {
  const OfflineSync({
    super.key,
    required this.dio,
    this.syncService,
    required this.child,
  });

  final Dio dio;
  final SyncV2Service? syncService;
  final Widget child;

  @override
  State<OfflineSync> createState() => _OfflineSyncState();
}

class _OfflineSyncState extends State<OfflineSync> with WidgetsBindingObserver {
  late final OfflineQueue _queue;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool _wasOnline = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _queue = OfflineQueue(
      database: AppDatabase(),
      dio: widget.dio,
      syncService: widget.syncService,
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
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _flush();
    }
  }

  Future<void> _flush() async {
    final encryption = context.read<EncryptionProvider>();
    if (encryption.isEnabled && !encryption.isUnlocked) {
      // Do not attempt to open the encrypted database while locked.
      return;
    }

    final errors = await _queue.process();

    if (widget.syncService != null) {
      try {
        final syncErrors = await widget.syncService!.flush();
        errors.addAll(syncErrors);
      } catch (e) {
        errors.add('Sync error: $e');
      }
      try {
        await widget.syncService!.pull();
      } catch (e) {
        errors.add('Pull error: $e');
      }
    }

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
