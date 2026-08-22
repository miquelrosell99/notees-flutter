import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:provider/provider.dart';

import '../../auth/providers/auth_provider.dart';
import '../../settings/providers/settings_provider.dart';
import './floating_capture_sheet.dart';

/// In-app floating quick-capture bubble.
///
/// This v1 implementation lives inside the Notees app so it works without a
/// native foreground service or `SYSTEM_ALERT_WINDOW` runtime permission. A
/// future version can swap the widget for a system-level overlay managed by
/// [BubbleService].
class FloatingCaptureBubble extends StatefulWidget {
  const FloatingCaptureBubble({super.key, required this.child});

  final Widget child;

  @override
  State<FloatingCaptureBubble> createState() => _FloatingCaptureBubbleState();
}

class _FloatingCaptureBubbleState extends State<FloatingCaptureBubble>
    with TickerProviderStateMixin {
  late final AnimationController _bounceController;
  late final Animation<double> _bounceAnimation;
  Offset _offset = const Offset(0, 0);
  bool _isDragging = false;
  bool _initialized = false;

  static const double _bubbleSize = 56;
  static const double _margin = 16;

  @override
  void initState() {
    super.initState();
    _bounceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _bounceAnimation = CurvedAnimation(
      parent: _bounceController,
      curve: Curves.elasticOut,
    );
  }

  @override
  void dispose() {
    _bounceController.dispose();
    super.dispose();
  }

  void _snapToEdge(BoxConstraints constraints) {
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;

    final currentDx = _offset.dx;
    final currentDy = _offset.dy.clamp(
      _margin.toDouble(),
      max(_margin, height - _bubbleSize - _margin).toDouble(),
    );

    final center = currentDx + _bubbleSize / 2;
    final nearestEdgeDx = center < width / 2
        ? _margin.toDouble()
        : max(_margin, width - _bubbleSize - _margin).toDouble();

    setState(() {
      _offset = Offset(nearestEdgeDx, currentDy);
    });
  }

  void _onPanStart(DragStartDetails details) {
    HapticFeedback.lightImpact();
    setState(() => _isDragging = true);
  }

  void _onPanUpdate(DragUpdateDetails details, BoxConstraints constraints) {
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;

    setState(() {
      _offset += details.delta;
      _offset = Offset(
        _offset.dx.clamp(
          _margin.toDouble(),
          max(_margin, width - _bubbleSize - _margin).toDouble(),
        ),
        _offset.dy.clamp(
          _margin.toDouble(),
          max(_margin, height - _bubbleSize - _margin).toDouble(),
        ),
      );
    });
  }

  void _onPanEnd(DragEndDetails details, BoxConstraints constraints) {
    setState(() => _isDragging = false);
    _snapToEdge(constraints);
  }

  Future<void> _onTap(BuildContext context) async {
    if (_isDragging) return;

    final auth = context.read<AuthProvider>();
    final scaffoldMessenger = ScaffoldMessenger.maybeOf(context);
    if (!auth.isAuthenticated) {
      _showToast(scaffoldMessenger, 'Sign in to capture notes');
      return;
    }

    var saved = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => FloatingCaptureSheet(
        onSaved: () => saved = true,
      ),
    );

    if (!mounted) return;
    if (saved) {
      _bounceController.forward(from: 0);
      _showToast(scaffoldMessenger, 'Saved to Inbox.');
    }
  }

  void _showToast(ScaffoldMessengerState? scaffold, String message) {
    if (scaffold == null) return;
    scaffold.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final enabled = settings.floatingCaptureBubbleEnabled;

    if (!enabled) return widget.child;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (!_initialized) {
          _initialized = true;
          _offset = Offset(
            max(_margin, constraints.maxWidth - _bubbleSize - _margin)
                .toDouble(),
            constraints.maxHeight / 2 - _bubbleSize / 2,
          );
        }

        return Stack(
          children: [
            widget.child,
            Positioned(
              left: _offset.dx,
              top: _offset.dy,
              child: AnimatedBuilder(
                animation: _bounceAnimation,
                builder: (context, child) {
                  return Transform.scale(
                    scale: 1 + (_bounceAnimation.value * 0.25),
                    child: child,
                  );
                },
                child: GestureDetector(
                  onTap: () => _onTap(context),
                  onLongPress: () => HapticFeedback.mediumImpact(),
                  onPanStart: _onPanStart,
                  onPanUpdate: (details) => _onPanUpdate(details, constraints),
                  onPanEnd: (details) => _onPanEnd(details, constraints),
                  child: Material(
                    elevation: 4,
                    shape: const CircleBorder(),
                    color: Theme.of(context).colorScheme.primaryContainer,
                    child: Container(
                      width: _bubbleSize,
                      height: _bubbleSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      child: Icon(
                        MdiIcons.plus,
                        color: Theme.of(context).colorScheme.onPrimary,
                        size: 28,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
