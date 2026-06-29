import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/connectivity_provider.dart';

/// Shows a compact "Offline" banner at the top of the screen when the device
/// has no network connectivity.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final online = context.watch<ConnectivityProvider>().online;

    final disableAnimations = MediaQuery.of(context).disableAnimations;

    return Column(
      children: [
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.errorContainer,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
            child: SafeArea(
              bottom: false,
              child: Row(
                children: [
                  Icon(
                    Icons.signal_wifi_off,
                    size: 18,
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Offline — quick notes will sync when you reconnect',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onErrorContainer,
                            fontWeight: FontWeight.w500,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          crossFadeState: online
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          duration: disableAnimations
              ? Duration.zero
              : const Duration(milliseconds: 250),
        ),
        Expanded(child: child),
      ],
    );
  }
}
