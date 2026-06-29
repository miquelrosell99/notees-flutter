import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../core/api/api_client.dart';
import '../core/secure/secure_storage.dart';
import '../core/utils/client_id.dart';
import '../data/local/app_database.dart';
import '../data/repositories/server_repository.dart';
import '../domain/services/offline_queue.dart';
import '../domain/services/sync_v2_service.dart';

/// Unique identifier for the background sync Workmanager task.
const _backgroundSyncTask = 'notees.backgroundSync';

/// Unique name for the periodic sync work request.
const _periodicSyncName = 'notees-periodic-sync';

/// Top-level callback invoked by the Android Workmanager in a background
/// isolate. It drains the offline queue against the active server.
@pragma('vm:entry-point')
void _backgroundSyncCallback() {
  Workmanager().executeTask((task, inputData) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Background isolates cannot access an in-memory encryption key, so skip
      // all local-DB work while encryption is enabled.
      if (prefs.getBool('encryption_enabled') ?? false) {
        return Future.value(true);
      }

      const secureStorage = SecureStorage();
      final serverRepository = ServerRepository(prefs: prefs);
      final activeServer = await serverRepository.getActiveServer();
      if (activeServer == null) {
        return Future.value(true);
      }

      final dio = createApiClient(
        baseUrl: activeServer.url,
        secureStorage: secureStorage,
        trustSelfSigned: activeServer.trustSelfSigned,
      );
      final clientId = await getClientId(prefs);
      final syncService = SyncV2Service(
        database: AppDatabase(),
        dio: dio,
        clientId: clientId,
      );
      final queue = OfflineQueue(
        database: AppDatabase(),
        dio: dio,
        syncService: syncService,
      );
      await queue.process();
      await syncService.flush();
      await syncService.pull();

      return Future.value(true);
    } on DioException {
      // Network/server errors are expected in the background; retry later.
      return Future.value(false);
    } catch (_) {
      return Future.value(false);
    }
  });
}

/// Schedules and manages background sync on mobile.
class BackgroundSync {
  BackgroundSync._();

  static bool _initialized = false;

  /// Must be called once before [runApp].
  static Future<void> initialize() async {
    if (_initialized) return;
    await Workmanager().initialize(_backgroundSyncCallback);
    _initialized = true;
  }

  /// Returns whether [initialize] completed successfully.
  static bool get isInitialized => _initialized;

  /// Registers a 15-minute periodic sync task that only runs when online.
  static Future<void> registerPeriodic() async {
    await Workmanager().registerPeriodicTask(
      _periodicSyncName,
      _backgroundSyncTask,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }

  /// Cancels the periodic sync task.
  static Future<void> cancel() async {
    await Workmanager().cancelByUniqueName(_periodicSyncName);
  }
}
