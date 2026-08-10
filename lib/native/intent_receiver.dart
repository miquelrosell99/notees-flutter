import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Payload delivered by an incoming Android share intent.
class SharePayload {
  const SharePayload({this.text, this.imagePath});

  final String? text;
  final String? imagePath;

  bool get hasImage => imagePath != null && imagePath!.isNotEmpty;

  factory SharePayload.fromMap(dynamic arguments) {
    if (arguments is! Map) {
      return const SharePayload();
    }
    final map = arguments;
    final text = map['text'] as String?;
    final imagePath = map['imagePath'] as String?;
    return SharePayload(
      text: text?.isNotEmpty == true ? text : null,
      imagePath: imagePath?.isNotEmpty == true ? imagePath : null,
    );
  }

  Map<String, dynamic> toMap() => {
        if (text != null) 'text': text,
        if (imagePath != null) 'imagePath': imagePath,
      };
}

/// Receives Android intents (share, deep link) via a platform MethodChannel.
class IntentReceiver {
  IntentReceiver._();
  static final IntentReceiver instance = IntentReceiver._();

  static const _channel = MethodChannel('com.notees.notees/intents');

  final _shareController = StreamController<SharePayload>.broadcast();
  final _deepLinkController = StreamController<String>.broadcast();
  final _quickNoteTileController = StreamController<void>.broadcast();
  final _audioNoteTileController = StreamController<void>.broadcast();

  Stream<SharePayload> get onShare => _shareController.stream;
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
        case 'onShare':
          final payload = SharePayload.fromMap(call.arguments);
          _shareController.add(payload);
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
      final pendingShare = await _channel.invokeMethod<Map<dynamic, dynamic>>('getPendingShare');
      if (pendingShare != null) {
        _shareController.add(SharePayload.fromMap(pendingShare));
      }
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
