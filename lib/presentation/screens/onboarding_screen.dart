import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:provider/provider.dart';

import '../../core/routing/router.dart';
import '../../domain/services/onboarding_service.dart';
import '../providers/auth_provider.dart';
import '../widgets/fleet_card.dart';
import '../widgets/quick_capture_sheet.dart';

/// First-run onboarding flow.
///
/// Walks the user through the privacy promise, quick-capture setup, widget
/// offer, and a first capture action before entering the main app.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _currentPage = 0;

  static const _pageCount = 4;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final auth = context.read<AuthProvider>();
    final service = OnboardingService(prefs: auth.prefs);
    await service.markCompleted();
    await auth.refreshOnboarding();
    if (mounted) context.go(Routes.dashboard);
  }

  void _next() {
    if (_currentPage < _pageCount - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _finish();
    }
  }

  void _openFirstCapture() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => const QuickCaptureSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _finish,
                child: const Text('Skip'),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (index) => setState(() => _currentPage = index),
                children: const [
                  _WelcomePage(),
                  _QuickCapturePage(),
                  _WidgetPage(),
                  _FirstCapturePage(),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(_pageCount, (index) {
                        final selected = index == _currentPage;
                        return Container(
                          width: selected ? 20 : 8,
                          height: 8,
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(
                            color: selected
                                ? colors.primary
                                : colors.outlineVariant,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        );
                      }),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _next,
                    icon: Icon(
                      _currentPage == _pageCount - 1
                          ? MdiIcons.check
                          : MdiIcons.arrowRight,
                    ),
                    label: Text(
                      _currentPage == _pageCount - 1 ? 'Get started' : 'Next',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WelcomePage extends StatelessWidget {
  const _WelcomePage();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return _OnboardingPageLayout(
      icon: MdiIcons.noteTextOutline,
      title: 'Your notes. Your server.',
      body: Column(
        children: [
          Text(
            'Notees is a private, self-hosted notebook that lives in your pocket. '
            'Everything you write syncs through your own server — never a third-party cloud.',
            style: textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FleetCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _PromiseRow(
                    icon: MdiIcons.lockOutline,
                    text: 'End-to-end privacy on your infrastructure.',
                  ),
                  const SizedBox(height: 12),
                  _PromiseRow(
                    icon: MdiIcons.cloudOffOutline,
                    text: 'Works offline; syncs when you are back online.',
                  ),
                  const SizedBox(height: 12),
                  _PromiseRow(
                    icon: MdiIcons.shieldLockOutline,
                    text: 'Optional biometric lock and local encryption.',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      color: colors.primary,
    );
  }
}

class _QuickCapturePage extends StatelessWidget {
  const _QuickCapturePage();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return _OnboardingPageLayout(
      icon: MdiIcons.lightningBoltOutline,
      title: 'Capture in under three seconds',
      body: Column(
        children: [
          Text(
            'Notees is built for frictionless input. Add the Quick Settings tile, '
            'enable the floating bubble, or share from any app to get ideas out of your head.',
            style: textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FleetCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _PromiseRow(
                    icon: MdiIcons.cellphoneCheck,
                    text: 'Quick Settings tile: capture without opening the app.',
                  ),
                  const SizedBox(height: 12),
                  _PromiseRow(
                    icon: MdiIcons.messagePlusOutline,
                    text: 'Floating bubble: one tap, type, save.',
                  ),
                  const SizedBox(height: 12),
                  _PromiseRow(
                    icon: MdiIcons.shareOutline,
                    text: 'Share sheet target for text, URLs, and images.',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      color: colors.primary,
    );
  }
}

class _WidgetPage extends StatelessWidget {
  const _WidgetPage();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return _OnboardingPageLayout(
      icon: MdiIcons.widgetsOutline,
      title: 'Today\'s tasks, at a glance',
      body: Column(
        children: [
          Text(
            'Add the Notees home-screen widget to see today\'s tasks and check them '
            'off without opening the app.',
            style: textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          FleetCard(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Icon(
                    MdiIcons.checkboxMarkedCircleOutline,
                    size: 48,
                    color: colors.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Tasks sync to the widget automatically. Tap a checkbox to complete; '
                    'tap Add to capture a new task.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      color: colors.primary,
    );
  }
}

class _FirstCapturePage extends StatelessWidget {
  const _FirstCapturePage();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    return _OnboardingPageLayout(
      icon: MdiIcons.pencilOutline,
      title: 'Make your first capture',
      body: Column(
        children: [
          Text(
            'Create a note or task now to feel the offline speed. You can always sync '
            'when you are back online.',
            style: textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          FilledButton.icon(
            onPressed: () => context.findAncestorStateOfType<_OnboardingScreenState>()?._openFirstCapture(),
            icon: Icon(MdiIcons.plus),
            label: const Text('Capture something'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => context.findAncestorStateOfType<_OnboardingScreenState>()?._finish(),
            child: const Text('I\'ll do it later'),
          ),
        ],
      ),
      color: colors.primary,
    );
  }
}

class _OnboardingPageLayout extends StatelessWidget {
  const _OnboardingPageLayout({
    required this.icon,
    required this.title,
    required this.body,
    required this.color,
  });

  final IconData icon;
  final String title;
  final Widget body;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Icon(icon, size: 48, color: color),
          ),
          const SizedBox(height: 32),
          Text(
            title,
            style: textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          body,
        ],
      ),
    );
  }
}

class _PromiseRow extends StatelessWidget {
  const _PromiseRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: colors.primary),
        const SizedBox(width: 12),
        Expanded(child: Text(text)),
      ],
    );
  }
}
