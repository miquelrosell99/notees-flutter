import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Receives Android intents (share, deep link) via a platform MethodChannel.
class IntentReceiver {
  IntentReceiver._();
  static final IntentReceiver instance = IntentReceiver._();

  static const _channel = MethodChannel('com.notees.notees/intents');

  final _shareController = StreamController<String>.broadcast();
  final _deepLinkController = StreamController<String>.broadcast();
  final _quickNoteTileController = StreamController<void>.broadcast();
  final _audioNoteTileController = StreamController<void>.broadcast();

  Stream<String> get onShareText => _shareController.stream;
  Stream<String> get onDeepLink => _deepLinkController.stream;
  Stream<void> get onQuickNoteTile => _quickNoteTileController.stream;
  Stream<void> get onAudioNoteTile => _audioNoteTileController.stream;

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    // The intents channel only has an Android implementation.
    if (defaultTargetPlatform != TargetPlatform.android) return;
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
        case 'onQuickNoteTile':
          _quickNoteTileController.add(null);
          return null;
        case 'onAudioNoteTile':
          _audioNoteTileController.add(null);
          return null;
      }
      return null;
    });

    try {
      final pendingShare = await _channel.invokeMethod<String>('getPendingShareText');
      if (pendingShare != null) _shareController.add(pendingShare);
      final pendingLink = await _channel.invokeMethod<String>('getPendingDeepLink');
      if (pendingLink != null) _deepLinkController.add(pendingLink);
      final pendingQuickNote = await _channel.invokeMethod<bool>('getPendingQuickNoteTile');
      if (pendingQuickNote == true) _quickNoteTileController.add(null);
      final pendingAudioNote = await _channel.invokeMethod<bool>('getPendingAudioNoteTile');
      if (pendingAudioNote == true) _audioNoteTileController.add(null);
    } on PlatformException catch (_) {
      // Platform channel not available (e.g., iOS or tests).
    }
  }
}
