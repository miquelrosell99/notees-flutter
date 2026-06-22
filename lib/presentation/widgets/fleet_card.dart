import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Fleet-styled card with 20 px radius, no elevation, and a subtle outline.
class FleetCard extends StatelessWidget {
  const FleetCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(4),
    this.margin = EdgeInsets.zero,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final card = Card(
      margin: margin,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outline.withAlpha((0.1 * 255).round()),
        ),
      ),
      child: Padding(
        padding: padding,
        child: child,
      ),
    );

    if (onTap == null) return card;

    return InkWell(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap!();
      },
      borderRadius: BorderRadius.circular(20),
      child: card,
    );
  }
}
