import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/secure/secure_storage.dart';
import 'data/repositories/server_repository.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
