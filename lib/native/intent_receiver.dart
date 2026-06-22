import 'dart:async';

import 'package:flutter/services.dart';

/// Receives Android intents (share, deep link) via a platform MethodChannel.
class IntentReceiver {
  IntentReceiver._();
  static final IntentReceiver instance = IntentReceiver._();

  static const _channel = MethodChannel('com.notees.notees/intents');

  final _shareController = StreamController<String>.broadcast();
  final _deepLinkController = StreamController<String>.broadcast();

  Stream<String> get onShareText => _shareController.stream;
  Stream<String> get onDeepLink => _deepLinkController.stream;

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onShareText':
          final text = call.arguments as String?;
          if (text != null) _shareController.add(text);
          return null;
        case 'onDeepLink':
          final link = call.arguments as String?;
          if (link != null) _deepLinkController.add(link);
          return null;
      }
      return null;
    });

    try {
      final pendingShare = await _channel.invokeMethod<String>('getPendingShareText');
      if (pendingShare != null) _shareController.add(pendingShare);
      final pendingLink = await _channel.invokeMethod<String>('getPendingDeepLink');
      if (pendingLink != null) _deepLinkController.add(pendingLink);
    } on PlatformException catch (_) {
      // Platform channel not available (e.g., iOS or tests).
    }
  }
}
