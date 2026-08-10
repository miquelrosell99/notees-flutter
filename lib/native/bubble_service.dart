import 'dart:io';

import 'package:flutter/services.dart';

/// Method channel for a future native floating bubble service.
///
/// The current v1 bubble is an in-app widget, so this class is a stub that
/// documents the expected native contract. Once a system-level bubble is
/// implemented, call [startBubble] / [stopBubble] from the settings toggle and
/// replace the in-app bubble with the native overlay.
class BubbleService {
  BubbleService._();

  static const MethodChannel _channel = MethodChannel(
    'com.notees.notees/bubble',
  );

  static final BubbleService instance = BubbleService._();

  /// Returns `true` if the app can draw over other apps.
  ///
  /// On iOS or when no native implementation is present this always returns
  /// `true` so the in-app bubble can still be shown.
  Future<bool> canDrawOverlays() async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _channel.invokeMethod<bool?>('canDrawOverlays');
      return result ?? true;
    } on MissingPluginException {
      return true;
    }
  }

  /// Opens the system settings screen where the user can grant
  /// `SYSTEM_ALERT_WINDOW` permission.
  Future<void> requestOverlayPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('requestOverlayPermission');
    } on MissingPluginException {
      // Native implementation not yet wired up.
    }
  }

  /// Starts the native floating bubble service.
  ///
  /// The native side should create a small draggable window using
  /// `WindowManager.addView` and send tap/drag/save events back over the
  /// method channel.
  Future<void> startBubble() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('startBubble');
    } on MissingPluginException {
      // Native implementation not yet wired up.
    }
  }

  /// Stops the native floating bubble service and removes the overlay window.
  Future<void> stopBubble() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stopBubble');
    } on MissingPluginException {
      // Native implementation not yet wired up.
    }
  }
}
