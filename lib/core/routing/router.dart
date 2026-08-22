import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/error_reporter.dart';

import '../../data/repositories/node_repository.dart';
import '../../domain/models/search_filters.dart';
import '../../features/auth/providers/auth_provider.dart';
import '../../features/settings/screens/about_screen.dart';
import '../../features/auth/screens/api_keys_screen.dart';
import '../../features/library/screens/archived_screen.dart';
import '../../features/editor/screens/journal_continuous_screen.dart';
import '../../features/auth/screens/login_screen.dart';
import '../../features/home/screens/main_shell_screen.dart';
import '../../features/home/screens/notifications_screen.dart';
import '../../features/editor/screens/node_editor_screen.dart';
import '../../features/auth/screens/onboarding_screen.dart';
import '../../features/search/screens/search_screen.dart';
import '../../features/auth/screens/server_management_screen.dart';
import '../../features/auth/screens/server_setup_screen.dart';
import '../../features/settings/screens/keyboard_shortcuts_screen.dart';
import '../../features/settings/screens/settings_screen.dart';
import '../../features/auth/screens/splash_screen.dart';
import '../../features/library/screens/trash_screen.dart';
import '../../features/auth/screens/user_profile_screen.dart';

/// Route names.
abstract class Routes {
  static const splash = '/';
  static const serverSetup = '/server-setup';
  static const login = '/login';
  static const dashboard = '/dashboard';
  static const settings = '/settings';
  static const about = '/about';
  static const archived = '/archived';
  static const editor = '/editor';
  static const trash = '/trash';
  static const journal = '/journal';
  static const journals = '/journals';
  static const library = '/library';
  static const notifications = '/notifications';
  static const onboarding = '/onboarding';
  static const search = '/search';
  static const tasks = '/tasks';
}

/// Shared-axis-style push transition for detail routes: fade plus a slight
/// horizontal slide (300 ms easeInOutCubic, 250 ms reverse). Renders the
/// page statically when the user has disabled animations.
CustomTransitionPage<void> _pushTransitionPage({
  required LocalKey key,
  required Widget child,
}) {
  return CustomTransitionPage<void>(
    key: key,
    child: child,
    transitionDuration: const Duration(milliseconds: 300),
    reverseTransitionDuration: const Duration(milliseconds: 250),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      if (MediaQuery.disableAnimationsOf(context)) return child;
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeInOutCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.05, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

GoRouter createRouter({required AuthProvider authProvider}) {
  return GoRouter(
    navigatorKey: apiErrorNavigatorKey,
    initialLocation: Routes.splash,
    refreshListenable: authProvider,
    redirect: (context, state) {
      final loading = authProvider.loading;
      final server = authProvider.activeServer;
      final authenticated = authProvider.isAuthenticated;
      final isLocal = authProvider.isLocalMode;
      final onboardingCompleted = authProvider.onboardingCompleted;
      final path = state.matchedLocation;

      if (loading) return null;

      // A local (offline) session counts as configured: no server, no login.
      if (server == null && !isLocal && path != Routes.serverSetup) {
        return Routes.serverSetup;
      }

      if (server != null && !authenticated && !isLocal) {
        if (path != Routes.login && path != Routes.serverSetup) {
          return Routes.login;
        }
      }

      if (authenticated &&
          !onboardingCompleted &&
          path != Routes.onboarding) {
        return Routes.onboarding;
      }

      if (authenticated && (path == Routes.login || path == Routes.splash)) {
        return Routes.dashboard;
      }

      if (onboardingCompleted && path == Routes.onboarding) {
        return Routes.dashboard;
      }

      return null;
    },
    routes: [
      GoRoute(
        path: Routes.splash,
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: Routes.serverSetup,
        builder: (context, state) => const ServerSetupScreen(),
      ),
      GoRoute(
        path: Routes.login,
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: Routes.dashboard,
        builder: (context, state) => const MainShellScreen(),
      ),
      GoRoute(
        path: Routes.settings,
        pageBuilder: (context, state) => _pushTransitionPage(
          key: state.pageKey,
          child: const SettingsScreen(),
        ),
      ),
      GoRoute(
        path: Routes.about,
        pageBuilder: (context, state) => _pushTransitionPage(
          key: state.pageKey,
          child: const AboutScreen(),
        ),
      ),
      GoRoute(
        path: Routes.archived,
        pageBuilder: (context, state) => _pushTransitionPage(
          key: state.pageKey,
          child: const ArchivedScreen(),
        ),
      ),
      GoRoute(
        path: '${Routes.settings}/servers',
        pageBuilder: (context, state) => _pushTransitionPage(
          key: state.pageKey,
          child: const ServerManagementScreen(),
        ),
      ),
      GoRoute(
        path: '${Routes.settings}/profile',
        pageBuilder: (context, state) => _pushTransitionPage(
          key: state.pageKey,
          child: const UserProfileScreen(),
        ),
      ),
      GoRoute(
        path: '${Routes.settings}/api-keys',
        pageBuilder: (context, state) => _pushTransitionPage(
          key: state.pageKey,
          child: const ApiKeysScreen(),
        ),
      ),
      GoRoute(
        path: '${Routes.settings}/keyboard-shortcuts',
        pageBuilder: (context, state) => _pushTransitionPage(
          key: state.pageKey,
          child: const KeyboardShortcutsScreen(),
        ),
      ),
      GoRoute(
        path: Routes.trash,
        pageBuilder: (context, state) => _pushTransitionPage(
          key: state.pageKey,
          child: const TrashScreen(),
        ),
      ),
      GoRoute(
        path: '${Routes.editor}/:nodeUuid',
        pageBuilder: (context, state) {
          final nodeUuid = state.pathParameters['nodeUuid'] ?? '';
          return _pushTransitionPage(
            key: state.pageKey,
            child: NodeEditorScreen(nodeUuid: nodeUuid),
          );
        },
      ),
      GoRoute(
        path: Routes.journal,
        builder: (context, state) => const _JournalRedirect(),
      ),
      GoRoute(
        path: Routes.search,
        pageBuilder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          return _pushTransitionPage(
            key: state.pageKey,
            child: SearchScreen(
              initialQuery: extra?['query'] as String?,
              initialFilters: extra?['filters'] as SearchFilters?,
            ),
          );
        },
      ),
      GoRoute(
        path: Routes.library,
        builder: (context, state) => const MainShellScreen(initialIndex: 3),
      ),
      GoRoute(
        path: Routes.journals,
        pageBuilder: (context, state) => _pushTransitionPage(
          key: state.pageKey,
          child: const JournalContinuousScreen(),
        ),
      ),
      GoRoute(
        path: Routes.tasks,
        builder: (context, state) => const MainShellScreen(initialIndex: 1),
      ),
      GoRoute(
        path: Routes.notifications,
        pageBuilder: (context, state) => _pushTransitionPage(
          key: state.pageKey,
          child: const NotificationsScreen(),
        ),
      ),
      GoRoute(
        path: Routes.onboarding,
        builder: (context, state) => const OnboardingScreen(),
      ),
    ],
  );
}

/// Redirects `/journal` to today's daily journal editor page.
class _JournalRedirect extends StatefulWidget {
  const _JournalRedirect();

  @override
  State<_JournalRedirect> createState() => _JournalRedirectState();
}

class _JournalRedirectState extends State<_JournalRedirect> {
  @override
  void initState() {
    super.initState();
    _redirect();
  }

  Future<void> _redirect() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    try {
      final journal = await NodeRepository(dio: auth.dio!, syncService: auth.syncService).getOrCreateDailyJournal(DateTime.now());
      if (mounted) {
        context.go('${Routes.editor}/${journal.uuid}');
      }
    } catch (_) {
      if (mounted) {
        context.go(Routes.dashboard);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
