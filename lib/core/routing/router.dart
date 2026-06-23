import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../data/repositories/node_repository.dart';
import '../../presentation/providers/auth_provider.dart';
import '../../presentation/screens/about_screen.dart';
import '../../presentation/screens/api_keys_screen.dart';
import '../../presentation/screens/login_screen.dart';
import '../../presentation/screens/main_shell_screen.dart';
import '../../presentation/screens/notifications_screen.dart';
import '../../presentation/screens/node_editor_screen.dart';
import '../../presentation/screens/server_management_screen.dart';
import '../../presentation/screens/server_setup_screen.dart';
import '../../presentation/screens/keyboard_shortcuts_screen.dart';
import '../../presentation/screens/settings_screen.dart';
import '../../presentation/screens/splash_screen.dart';
import '../../presentation/screens/templates_screen.dart';
import '../../presentation/screens/trash_screen.dart';
import '../../presentation/screens/user_profile_screen.dart';
import '../../presentation/screens/web_view_screen.dart';

/// Route names.
abstract class Routes {
  static const splash = '/';
  static const serverSetup = '/server-setup';
  static const login = '/login';
  static const dashboard = '/dashboard';
  static const settings = '/settings';
  static const about = '/about';
  static const editor = '/editor';
  static const trash = '/trash';
  static const journal = '/journal';
  static const notifications = '/notifications';
  static const pages = '/pages';
  static const tasks = '/tasks';
  static const templates = '/templates';
  static const graph = '/graph';
  static const whiteboard = '/whiteboard';
  static const timeline = '/timeline';
  static const gantt = '/gantt';
  static const chart = '/chart';
  static const pivot = '/pivot';
  static const query = '/query';
}

GoRouter createRouter({required AuthProvider authProvider}) {
  return GoRouter(
    initialLocation: Routes.splash,
    refreshListenable: authProvider,
    redirect: (context, state) {
      final loading = authProvider.loading;
      final server = authProvider.activeServer;
      final authenticated = authProvider.isAuthenticated;
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

      if (authenticated && (path == Routes.login || path == Routes.splash)) {
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
        path: '${Routes.editor}/:nodeId',
        builder: (context, state) {
          final nodeId = int.tryParse(state.pathParameters['nodeId'] ?? '');
          return NodeEditorScreen(nodeId: nodeId ?? 0);
        },
      ),
      GoRoute(
        path: Routes.journal,
        builder: (context, state) => const _JournalRedirect(),
      ),
      GoRoute(
        path: Routes.pages,
        builder: (context, state) => const MainShellScreen(initialIndex: 2),
      ),
      GoRoute(
        path: Routes.tasks,
        builder: (context, state) => const MainShellScreen(initialIndex: 1),
      ),
      GoRoute(
        path: Routes.graph,
        builder: (context, state) => const NoteesWebViewScreen(
          path: Routes.graph,
          title: 'Graph',
        ),
      ),
      GoRoute(
        path: Routes.whiteboard,
        builder: (context, state) => const NoteesWebViewScreen(
          path: Routes.whiteboard,
          title: 'Whiteboard',
        ),
      ),
      GoRoute(
        path: '${Routes.whiteboard}/:uuid',
        builder: (context, state) {
          final uuid = state.pathParameters['uuid'];
          return NoteesWebViewScreen(
            path: uuid != null ? '${Routes.whiteboard}/$uuid' : Routes.whiteboard,
            title: 'Whiteboard',
          );
        },
      ),
      GoRoute(
        path: Routes.timeline,
        builder: (context, state) => const NoteesWebViewScreen(
          path: Routes.timeline,
          title: 'Timeline',
        ),
      ),
      GoRoute(
        path: Routes.gantt,
        builder: (context, state) => const NoteesWebViewScreen(
          path: Routes.gantt,
          title: 'Gantt',
        ),
      ),
      GoRoute(
        path: Routes.chart,
        builder: (context, state) => const NoteesWebViewScreen(
          path: Routes.chart,
          title: 'Chart',
        ),
      ),
      GoRoute(
        path: Routes.pivot,
        builder: (context, state) => const NoteesWebViewScreen(
          path: Routes.pivot,
          title: 'Pivot',
        ),
      ),
      GoRoute(
        path: Routes.query,
        builder: (context, state) => const NoteesWebViewScreen(
          path: Routes.query,
          title: 'Query builder',
        ),
      ),
      GoRoute(
        path: '${Routes.query}/:nodeId',
        builder: (context, state) {
          final nodeId = state.pathParameters['nodeId'];
          return NoteesWebViewScreen(
            path: nodeId != null ? '${Routes.query}/$nodeId' : Routes.query,
            title: 'Query builder',
          );
        },
      ),
      GoRoute(
        path: Routes.templates,
        builder: (context, state) => const TemplatesScreen(),
      ),
      GoRoute(
        path: Routes.notifications,
        builder: (context, state) => const NotificationsScreen(),
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
      final journal = await NodeRepository(dio: auth.dio!).getOrCreateDailyJournal(DateTime.now());
      if (mounted) {
        context.go('${Routes.editor}/${journal.id}');
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
