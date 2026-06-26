import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

const _clientIdKey = 'notees_client_id';

/// Returns a stable per-install client/device UUID used for vector-clock sync.
Future<String> getClientId(SharedPreferences prefs) async {
  var id = prefs.getString(_clientIdKey);
  if (id != null && id.isNotEmpty) return id;

  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  // Version 4 UUID layout
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  String two(int v) => v.toRadixString(16).padLeft(2, '0');
  id = '${two(bytes[0])}${two(bytes[1])}${two(bytes[2])}${two(bytes[3])}-'
      '${two(bytes[4])}${two(bytes[5])}-'
      '${two(bytes[6])}${two(bytes[7])}-'
      '${two(bytes[8])}${two(bytes[9])}-'
      '${two(bytes[10])}${two(bytes[11])}${two(bytes[12])}${two(bytes[13])}${two(bytes[14])}${two(bytes[15])}';

  await prefs.setString(_clientIdKey, id);
  return id;
}
