import 'package:go_router/go_router.dart';

import '../../presentation/providers/auth_provider.dart';
import '../../presentation/screens/about_screen.dart';
import '../../presentation/screens/api_keys_screen.dart';
import '../../presentation/screens/login_screen.dart';
import '../../presentation/screens/main_shell_screen.dart';
import '../../presentation/screens/server_management_screen.dart';
import '../../presentation/screens/server_setup_screen.dart';
import '../../presentation/screens/settings_screen.dart';
import '../../presentation/screens/splash_screen.dart';
import '../../presentation/screens/user_profile_screen.dart';
import '../../presentation/screens/node_editor_screen.dart';

/// Route names.
abstract class Routes {
  static const splash = '/';
  static const serverSetup = '/server-setup';
  static const login = '/login';
  static const dashboard = '/dashboard';
  static const settings = '/settings';
  static const about = '/about';
  static const editor = '/editor';
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
        path: '${Routes.editor}/:nodeId',
        builder: (context, state) {
          final nodeId = int.tryParse(state.pathParameters['nodeId'] ?? '');
          return NodeEditorScreen(nodeId: nodeId ?? 0);
        },
      ),
    ],
  );
}
