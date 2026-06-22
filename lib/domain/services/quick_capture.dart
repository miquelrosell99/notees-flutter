import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';

import '../../data/local/app_database.dart';
import '../../data/repositories/node_repository.dart';

/// Saves a quick note, falling back to the offline queue when there is no
/// connectivity.
class QuickCaptureService {
  QuickCaptureService({
    required this.dio,
    AppDatabase? database,
  }) : _database = database ?? AppDatabase();

  final Dio dio;
  final AppDatabase _database;

  Future<void> save(String name) async {
    final online = await _isOnline();
    if (online) {
      await NodeRepository(dio: dio).createQuickNote(name: name);
    } else {
      await _database.enqueueQuickNote(name);
    }
  }

  Future<int> pendingCount() async {
    final pending = await _database.pending();
    return pending.length;
  }

  static Future<bool> _isOnline() async {
    final results = await Connectivity().checkConnectivity();
    return results.isNotEmpty && !results.contains(ConnectivityResult.none);
  }
}
