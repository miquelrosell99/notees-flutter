import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// Prepares and registers the device for Firebase Cloud Messaging push
/// notifications.
///
/// The service is designed to degrade gracefully: if Firebase is not
/// configured for this build (no `google-services.json`), token registration
/// simply returns early and the rest of the app keeps working.
class PushNotificationService {
  PushNotificationService({required this._dio});

  final Dio _dio;
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  /// Exposes foreground push messages as a stream.

  Stream<RemoteMessage> get onForegroundMessage =>
      FirebaseMessaging.onMessage;

  /// Initializes Firebase (if available) and registers the FCM token with the
  /// Notees server.
  Future<void> initialize() async {
    if (!_firebaseAvailable) {
      return;
    }

    try {
      await Firebase.initializeApp();
    } catch (e) {
      debugPrint('Firebase initialization skipped or failed: $e');
      return;
    }

    await _requestPermissions();
    await _registerToken();

    _messaging.onTokenRefresh.listen(_onTokenRefresh);
  }

  Future<void> _requestPermissions() async {
    if (Platform.isIOS) {
      await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
    } else if (Platform.isAndroid) {
      // On Android 13+ the permission is also handled by the plugin; this call
      // is a no-op on older versions.
      await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
    }
  }

  Future<void> _registerToken() async {
    final token = await _messaging.getToken();
    if (token == null || token.isEmpty) {
      return;
    }
    await _sendTokenToServer(token);
  }

  Future<void> _onTokenRefresh(String token) async {
    await _sendTokenToServer(token);
  }

  Future<void> _sendTokenToServer(String token) async {
    try {
      await _dio.post<Map<String, dynamic>>(
        '/auth/device-token',
        data: {
          'token': token,
          'platform': Platform.operatingSystem,
        },
      );
    } catch (e) {
      debugPrint('Failed to register push token: $e');
    }
  }

  /// Returns `true` when Firebase dependencies are present and the current
  /// platform supports push messaging.
  bool get _firebaseAvailable {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }
}
