import 'package:flutter/material.dart';

/// A small rounded bar rendered at the top of modal bottom sheets.
///
/// Mirrors the handle used in [FilterBottomSheet] so every slide-up sheet
/// has a consistent drag affordance.
class BottomSheetDragHandle extends StatelessWidget {
  const BottomSheetDragHandle({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 12, bottom: 8),
        width: 32,
        height: 4,
        decoration: BoxDecoration(
          color: colors.onSurfaceVariant.withAlpha((0.35 * 255).round()),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
