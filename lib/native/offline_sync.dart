import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/api/error_reporter.dart';
import '../core/secure/encryption_provider.dart';
import '../data/local/app_database.dart';
import '../domain/services/offline_queue.dart';
import '../domain/services/pending_asset_service.dart';
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
    // The local SQLite queue (sqflite_sqlcipher) only has Android/iOS
    // implementations; skip flushing on other platforms.
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }

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
      // Foreground drain of the background-asset queue: the flush above
      // pushed (and locally echoed) any outbox blocks, so attach targets
      // exist server-side. Runs before the pull, matching the worker order.
      try {
        final assetErrors = await PendingAssetService(
          database: AppDatabase(),
          dio: widget.dio,
          syncService: widget.syncService,
        ).drain();
        errors.addAll(assetErrors);
      } catch (e) {
        errors.add('Pending uploads error: $e');
      }
      try {
        await widget.syncService!.pull();
      } catch (e) {
        errors.add('Pull error: $e');
      }
    }

    if (errors.isNotEmpty && mounted) {
      // This widget sits above MaterialApp, so its own context has no
      // ScaffoldMessenger; use the router's navigator context (the same
      // pattern as the tile listeners in app.dart).
      final messengerContext = apiErrorNavigatorKey.currentContext;
      if (messengerContext != null && messengerContext.mounted) {
        ScaffoldMessenger.of(messengerContext).showSnackBar(
          SnackBar(
            content: Text('Some offline notes could not be synced: ${errors.first}'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
