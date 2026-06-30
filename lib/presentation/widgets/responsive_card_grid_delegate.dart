import 'package:flutter/material.dart';

/// Returns a grid delegate that adapts card column width to the screen width.
///
/// Breakpoints match the fleet responsive scale:
/// - compact (< 600 dp): 220 dp cards
/// - medium (600–839 dp): 260 dp cards
/// - expanded (>= 840 dp): 300 dp cards
SliverGridDelegate responsiveCardGridDelegate(BuildContext context) {
  final width = MediaQuery.of(context).size.width;
  final maxExtent = width >= 840
      ? 300.0
      : width >= 600
          ? 260.0
          : 220.0;
  return SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: maxExtent,
    mainAxisSpacing: 12,
    crossAxisSpacing: 12,
    childAspectRatio: 1.1,
  );
}
