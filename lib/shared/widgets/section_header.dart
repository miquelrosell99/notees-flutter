import 'package:flutter/material.dart';

/// In-card section header with a primary-colored icon, used at the top of a
/// [FleetCard] section. For the muted title that sits between card groups,
/// see [SectionTitle].
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: colors.primary),
          const SizedBox(width: 10),
          Text(
            label,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
          ),
        ],
      ),
    );
  }
}
