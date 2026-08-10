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
    this.onLongPress,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: padding,
      child: child,
    );

    return Card(
      margin: margin,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outline.withAlpha((0.1 * 255).round()),
        ),
      ),
      child: onTap == null && onLongPress == null
          ? content
          : InkWell(
              onTap: onTap == null
                  ? null
                  : () {
                      HapticFeedback.lightImpact();
                      onTap!();
                    },
              onLongPress: onLongPress == null
                  ? null
                  : () {
                      HapticFeedback.mediumImpact();
                      onLongPress!();
                    },
              borderRadius: BorderRadius.circular(20),
              child: content,
            ),
    );
  }
}
