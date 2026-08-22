import 'dart:async';

import 'package:flutter/material.dart';

/// Motion primitives for the RosellRamos design system.
///
/// Timings: micro-interactions 100–150 ms, entrances 300–400 ms,
/// shimmer cycle 1.2–1.6 s. Curve everywhere: [Curves.easeInOutCubic].
///
/// Every widget honors `MediaQuery.disableAnimationsOf(context)`: when the
/// user disabled animations, everything renders in its final state instantly.

/// Wraps a tappable target and scales it to 0.96 while pressed
/// (100 ms, easeInOutCubic).
///
/// Press feedback is driven by pointer events (via [Listener]), which do not
/// compete in the gesture arena — so a child [InkWell]/[GestureDetector]
/// keeps its own tap handling. Provide [onTap] only when the child has no
/// tap handler of its own; it is then attached via an inner
/// [GestureDetector].
class PressScale extends StatefulWidget {
  const PressScale({
    super.key,
    required this.child,
    this.onTap,
  });

  final Widget child;

  /// Optional tap handler. Leave null when the child handles taps itself.
  final VoidCallback? onTap;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _scale = Tween<double>(begin: 1, end: 0.96).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onTap = widget.onTap;
    if (MediaQuery.disableAnimationsOf(context)) {
      if (onTap == null) return widget.child;
      return GestureDetector(onTap: onTap, child: widget.child);
    }

    Widget child = ScaleTransition(scale: _scale, child: widget.child);
    if (onTap != null) {
      child = GestureDetector(onTap: onTap, child: child);
    }
    return Listener(
      onPointerDown: (_) => _controller.forward(),
      onPointerUp: (_) => _controller.reverse(),
      onPointerCancel: (_) => _controller.reverse(),
      child: child,
    );
  }
}

/// Entrance animation: fades in while sliding 16 px upward,
/// 300 ms easeInOutCubic, with an optional [delay] for staggering.
///
/// Animates once when first inserted; rebuilds keep the completed state.
/// When animations are disabled the child renders directly.
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
  });

  /// Applies a staggered entrance: `delay = index * 60 ms`, capped so only
  /// the first [maxItems] entries wait longer than the last staggered one.
  factory FadeSlideIn.staggered(
    int index, {
    required Widget child,
    int maxItems = 8,
    Key? key,
  }) {
    final step = index < maxItems ? index : maxItems - 1;
    return FadeSlideIn(
      key: key,
      delay: Duration(milliseconds: 60 * step),
      child: child,
    );
  }

  final Widget child;
  final Duration delay;

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _curve;
  Timer? _delayTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _curve = CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _delayTimer?.cancel();
      _controller.value = 1;
      return;
    }
    if (_controller.isAnimating || _controller.isCompleted) return;
    if (_delayTimer != null) return;
    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      _delayTimer = Timer(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    return AnimatedBuilder(
      animation: _curve,
      child: widget.child,
      builder: (context, child) {
        final t = _curve.value;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 16),
            child: child,
          ),
        );
      },
    );
  }
}

/// Wraps [child] in a [FadeSlideIn] with `delay = index * 60 ms`,
/// capped at the first 8 items. See [FadeSlideIn.staggered].
Widget staggered(int index, Widget child) {
  return FadeSlideIn.staggered(index, child: child);
}

/// A [Column] whose children enter with a staggered [FadeSlideIn]
/// (60 ms per index, capped at the first 8 items).
class StaggeredColumn extends StatelessWidget {
  const StaggeredColumn({
    super.key,
    required this.children,
    this.crossAxisAlignment = CrossAxisAlignment.start,
  });

  final List<Widget> children;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: crossAxisAlignment,
      children: [
        for (var i = 0; i < children.length; i++) staggered(i, children[i]),
      ],
    );
  }
}

/// Rounded-rect placeholder that pulses between opacity 0.4 and 0.9
/// (1.4 s repeating reverse). Used to build the composed skeletons in
/// `skeletons.dart`.
///
/// When animations are disabled it renders as a static box at full opacity.
class ShimmerBox extends StatefulWidget {
  const ShimmerBox({
    super.key,
    this.width,
    this.height,
    this.radius = 8,
  });

  final double? width;
  final double? height;
  final double radius;

  @override
  State<ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<ShimmerBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _opacity = Tween<double>(begin: 0.4, end: 0.9).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
    );
    if (MediaQuery.disableAnimationsOf(context)) return box;
    return FadeTransition(opacity: _opacity, child: box);
  }
}
