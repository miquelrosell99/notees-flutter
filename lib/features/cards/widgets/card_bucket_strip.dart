import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../domain/services/card_schedule.dart';

/// The Cards hub's bucket strip: the Due action (a review session over
/// due + fresh) plus the fresh/later count pills (`CardBuckets.tsx`
/// parity). Renders nothing when there are no cards at all — the hub's
/// own empty state covers that case.
class CardBucketStrip extends StatelessWidget {
  const CardBucketStrip({
    super.key,
    required this.buckets,
    required this.onReview,
  });

  final CardBuckets buckets;

  /// Starts a review session over the due + fresh ids.
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final reviewCount = buckets.due.length + buckets.fresh.length;
    final total = reviewCount + buckets.later.length;
    if (total == 0) return const SizedBox.shrink();

    final colors = Theme.of(context).colorScheme;
    final label = StringBuffer('Review ${buckets.due.length} due')
      ..write(buckets.fresh.isNotEmpty ? ' · ${buckets.fresh.length} new' : '');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          ActionChip(
            avatar: Icon(MdiIcons.play, size: 18, color: colors.primary),
            label: Text(label.toString()),
            onPressed: reviewCount == 0 ? null : onReview,
          ),
          const Spacer(),
          _CountPill(text: '${buckets.fresh.length} fresh'),
          const SizedBox(width: 8),
          _CountPill(text: '${buckets.later.length} later'),
        ],
      ),
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
      ),
    );
  }
}
