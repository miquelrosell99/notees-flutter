import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/routing/router.dart';

/// Placeholder for the graph view.
///
/// The full graph visualization is rendered inside the embedded web editor on
/// tablet/desktop; the native mobile shell currently shows this landing screen
/// with a path back to the dashboard.
class GraphScreen extends StatelessWidget {
  const GraphScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Graph'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => context.canPop() ? context.pop() : context.go(Routes.dashboard),
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.account_tree_outlined,
                size: 64,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                'Graph view',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Open this workspace in the web editor to explore the graph.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => context.go(Routes.dashboard),
                child: const Text('Go home'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
