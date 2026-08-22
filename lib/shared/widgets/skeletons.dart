import 'package:flutter/material.dart';

import 'fleet_card.dart';
import 'motion.dart';
import 'responsive_card_grid_delegate.dart';

/// Composed loading skeletons built from [ShimmerBox]. Each mirrors the
/// layout of the screen it stands in for, so the loading → loaded swap
/// (a 200 ms [AnimatedSwitcher] fade at the call site) doesn't jump.

/// Skeleton for the tasks screen: one [FleetCard] with five task rows
/// (checkbox circle + title line + due-date pill line), matching the real
/// row padding of `TaskRow`.
class TaskListSkeleton extends StatelessWidget {
  const TaskListSkeleton({super.key, this.itemCount = 5});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        FleetCard(
          child: Column(
            children: [
              for (var i = 0; i < itemCount; i++) ...[
                const _TaskRowSkeleton(),
                if (i < itemCount - 1) const Divider(height: 1),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _TaskRowSkeleton extends StatelessWidget {
  const _TaskRowSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: Center(child: ShimmerBox(width: 22, height: 22, radius: 11)),
          ),
          SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ShimmerBox(height: 16),
                SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: ShimmerBox(width: 72, height: 16),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Skeleton for the dashboard Inbox card grid: bordered 20-radius cards on
/// the same responsive grid as `InboxCardView`.
class CardGridSkeleton extends StatelessWidget {
  const CardGridSkeleton({super.key, this.itemCount = 6});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: responsiveCardGridDelegate(context),
      itemCount: itemCount,
      itemBuilder: (context, index) => const _GridCardSkeleton(),
    );
  }
}

class _GridCardSkeleton extends StatelessWidget {
  const _GridCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withAlpha((0.1 * 255).round()),
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShimmerBox(width: 22, height: 22, radius: 6),
          SizedBox(height: 12),
          ShimmerBox(height: 14),
          SizedBox(height: 8),
          ShimmerBox(height: 12),
          SizedBox(height: 6),
          ShimmerBox(height: 12),
        ],
      ),
    );
  }
}

/// Skeleton for sectioned card lists (library screen, browse panel):
/// [sectionCount] cards, each with a section header row and
/// [rowsPerSection] list-tile rows, separated by 28 px gaps.
class CardListSkeleton extends StatelessWidget {
  const CardListSkeleton({
    super.key,
    this.sectionCount = 3,
    this.rowsPerSection = 3,
  });

  final int sectionCount;
  final int rowsPerSection;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        for (var s = 0; s < sectionCount; s++) ...[
          FleetCard(
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Row(
                    children: [
                      ShimmerBox(width: 18, height: 18, radius: 5),
                      SizedBox(width: 10),
                      ShimmerBox(width: 96, height: 14),
                    ],
                  ),
                ),
                const Divider(height: 1),
                for (var i = 0; i < rowsPerSection; i++) ...[
                  const ListTileSkeleton(),
                  if (i < rowsPerSection - 1) const Divider(height: 1),
                ],
              ],
            ),
          ),
          if (s < sectionCount - 1) const SizedBox(height: 28),
        ],
      ],
    );
  }
}

/// Generic list-row skeleton: leading circle, title + subtitle lines, and
/// an optional trailing circle. Used for search results, archived/trash
/// lists, and notifications.
class ListTileSkeleton extends StatelessWidget {
  const ListTileSkeleton({super.key, this.trailing = false});

  /// Whether to render a trailing placeholder (e.g. an action button).
  final bool trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const ShimmerBox(width: 24, height: 24, radius: 12),
          const SizedBox(width: 16),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ShimmerBox(height: 14),
                SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: ShimmerBox(width: 140, height: 12),
                ),
              ],
            ),
          ),
          if (trailing) ...[
            const SizedBox(width: 16),
            const ShimmerBox(width: 24, height: 24, radius: 12),
          ],
        ],
      ),
    );
  }
}

/// A scrollable column of [ListTileSkeleton] rows for screens whose content
/// is a plain list (search results, archived, trash, notifications).
class ListTileSkeletonList extends StatelessWidget {
  const ListTileSkeletonList({super.key, this.itemCount = 6, this.trailing = false});

  final int itemCount;
  final bool trailing;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (var i = 0; i < itemCount; i++) ListTileSkeleton(trailing: trailing),
      ],
    );
  }
}
