import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../presentation/providers/biometric_provider.dart';
import '../presentation/screens/lock_screen.dart';

/// Observes app lifecycle and shows the biometric lock screen when the app
/// returns to the foreground and biometric lock is enabled.
class AppLocker extends StatefulWidget {
  const AppLocker({super.key, required this.child});

  final Widget child;

  @override
  State<AppLocker> createState() => _AppLockerState();
}

class _AppLockerState extends State<AppLocker> with WidgetsBindingObserver {
  bool _locked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      final provider = context.read<BiometricProvider>();
      if (provider.enabled) {
        setState(() => _locked = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_locked)
          LockScreen(
            onUnlock: () {
              HapticFeedback.lightImpact();
              setState(() => _locked = false);
            },
          ),
      ],
    );
  }
}
