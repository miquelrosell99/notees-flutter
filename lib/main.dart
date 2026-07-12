import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/secure/secure_storage.dart';
import 'data/repositories/server_repository.dart';
import 'native/background_sync.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize background sync outside runApp so a Workmanager failure does
  // not take down the whole app. Users can still use the app without periodic
  // background sync.
  try {
    await BackgroundSync.initialize();
  } catch (e, stack) {
    debugPrint('BackgroundSync initialization failed: $e\n$stack');
  }

  // Lock to portrait on phones for the first release.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  final prefs = await SharedPreferences.getInstance();
  const secureStorage = SecureStorage();
  final serverRepository = ServerRepository(prefs: prefs);

  runApp(
    NoteesApp(
      prefs: prefs,
      serverRepository: serverRepository,
      secureStorage: secureStorage,
    ),
  );
}
