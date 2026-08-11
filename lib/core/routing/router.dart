import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/error_reporter.dart';

import '../../data/repositories/node_repository.dart';
import '../../domain/models/search_filters.dart';
import '../../presentation/providers/auth_provider.dart';
import '../../presentation/screens/about_screen.dart';
import '../../presentation/screens/api_keys_screen.dart';
import '../../presentation/screens/archived_screen.dart';
import '../../presentation/screens/journal_continuous_screen.dart';
import '../../presentation/screens/login_screen.dart';
import '../../presentation/screens/main_shell_screen.dart';
import '../../presentation/screens/notifications_screen.dart';
import '../../presentation/screens/node_editor_screen.dart';
import '../../presentation/screens/onboarding_screen.dart';
import '../../presentation/screens/search_screen.dart';
import '../../presentation/screens/server_management_screen.dart';
import '../../presentation/screens/server_setup_screen.dart';
import '../../presentation/screens/keyboard_shortcuts_screen.dart';
import '../../presentation/screens/settings_screen.dart';
import '../../presentation/screens/splash_screen.dart';
import '../../presentation/screens/trash_screen.dart';
import '../../presentation/screens/user_profile_screen.dart';

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

GoRouter createRouter({required AuthProvider authProvider}) {
  return GoRouter(
    navigatorKey: apiErrorNavigatorKey,
    initialLocation: Routes.splash,
    refreshListenable: authProvider,
    redirect: (context, state) {
      final loading = authProvider.loading;
      final server = authProvider.activeServer;
      final authenticated = authProvider.isAuthenticated;
      final onboardingCompleted = authProvider.onboardingCompleted;
      final path = state.matchedLocation;

      if (loading) return null;

      if (server == null && path != Routes.serverSetup) {
        return Routes.serverSetup;
      }

      if (server != null && !authenticated) {
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
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: Routes.about,
        builder: (context, state) => const AboutScreen(),
      ),
      GoRoute(
        path: Routes.archived,
        builder: (context, state) => const ArchivedScreen(),
      ),
      GoRoute(
        path: '${Routes.settings}/servers',
        builder: (context, state) => const ServerManagementScreen(),
      ),
      GoRoute(
        path: '${Routes.settings}/profile',
        builder: (context, state) => const UserProfileScreen(),
      ),
      GoRoute(
        path: '${Routes.settings}/api-keys',
        builder: (context, state) => const ApiKeysScreen(),
      ),
      GoRoute(
        path: '${Routes.settings}/keyboard-shortcuts',
        builder: (context, state) => const KeyboardShortcutsScreen(),
      ),
      GoRoute(
        path: Routes.trash,
        builder: (context, state) => const TrashScreen(),
      ),
      GoRoute(
        path: '${Routes.editor}/:nodeUuid',
        builder: (context, state) {
          final nodeUuid = state.pathParameters['nodeUuid'] ?? '';
          return NodeEditorScreen(nodeUuid: nodeUuid);
        },
      ),
      GoRoute(
        path: Routes.journal,
        builder: (context, state) => const _JournalRedirect(),
      ),
      GoRoute(
        path: Routes.search,
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          return SearchScreen(
            initialQuery: extra?['query'] as String?,
            initialFilters: extra?['filters'] as SearchFilters?,
          );
        },
      ),
      GoRoute(
        path: Routes.library,
        builder: (context, state) => const MainShellScreen(initialIndex: 3),
      ),
      GoRoute(
        path: Routes.journals,
        builder: (context, state) => const JournalContinuousScreen(),
      ),
      GoRoute(
        path: Routes.tasks,
        builder: (context, state) => const MainShellScreen(initialIndex: 1),
      ),
      GoRoute(
        path: Routes.notifications,
        builder: (context, state) => const NotificationsScreen(),
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
