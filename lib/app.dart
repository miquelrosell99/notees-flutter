import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/routing/router.dart';
import 'core/secure/secure_storage.dart';
import 'core/theme/theme_builder.dart';
import 'core/theme/theme_provider.dart';
import 'data/repositories/node_repository.dart';
import 'data/repositories/server_repository.dart';
import 'native/app_locker.dart';
import 'native/intent_receiver.dart';
import 'native/offline_sync.dart';
import 'presentation/providers/auth_provider.dart';
import 'presentation/providers/biometric_provider.dart';
import 'presentation/providers/connectivity_provider.dart';
import 'presentation/providers/settings_provider.dart';
import 'presentation/widgets/offline_banner.dart';
import 'presentation/widgets/quick_capture_sheet.dart';

class NoteesApp extends StatelessWidget {
  const NoteesApp({
    super.key,
    required this.prefs,
    required this.serverRepository,
    required this.secureStorage,
  });

  final SharedPreferences prefs;
  final ServerRepository serverRepository;
  final SecureStorage secureStorage;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider(prefs)),
        ChangeNotifierProvider(
          create: (_) => AuthProvider(
            serverRepository: serverRepository,
            secureStorage: secureStorage,
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => BiometricProvider(prefs: prefs)..initialize(),
        ),
        ChangeNotifierProvider(create: (_) => ConnectivityProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider(prefs)),
      ],
      child: const _NoteesAppBody(),
    );
  }
}

class _NoteesAppBody extends StatefulWidget {
  const _NoteesAppBody();

  @override
  State<_NoteesAppBody> createState() => _NoteesAppBodyState();
}

class _NoteesAppBodyState extends State<_NoteesAppBody> {
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthProvider>();
    _router = createRouter(authProvider: auth);
    auth.initialize();
    IntentReceiver.instance.initialize();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();

    return NoteesDynamicTheme(
      provider: themeProvider,
      builder: (context, light, dark) {
        final auth = context.watch<AuthProvider>();
        return AppLocker(
          child: ShareListener(
            child: DeepLinkListener(
              child: OfflineBanner(
                child: OfflineSync(
                  dio: auth.dio ?? Dio(),
                  child: MaterialApp.router(
                    title: 'Notees',
                    debugShowCheckedModeBanner: false,
                    theme: light,
                    darkTheme: dark,
                    themeMode: _flutterThemeMode(themeProvider.themeMode),
                    routerConfig: _router,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  ThemeMode _flutterThemeMode(AppThemeMode mode) {
    return switch (mode) {
      AppThemeMode.light => ThemeMode.light,
      AppThemeMode.dark => ThemeMode.dark,
      AppThemeMode.system => ThemeMode.system,
    };
  }
}

/// Listens for incoming share intents and shows a quick-capture bottom sheet
/// whenever another app sends text to Notees.
class ShareListener extends StatefulWidget {
  const ShareListener({super.key, required this.child});
  final Widget child;

  @override
  State<ShareListener> createState() => _ShareListenerState();
}

class _ShareListenerState extends State<ShareListener> {
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = IntentReceiver.instance.onShareText.listen(_onShare);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onShare(String text) {
    final ctx = context;
    if (!ctx.mounted) return;
    final auth = ctx.read<AuthProvider>();
    if (!auth.isAuthenticated) return;
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      builder: (_) => QuickCaptureSheet(initialText: text),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Listens for incoming deep links from [IntentReceiver] and navigates the
/// app to the corresponding route.
class DeepLinkListener extends StatefulWidget {
  const DeepLinkListener({super.key, required this.child});
  final Widget child;

  @override
  State<DeepLinkListener> createState() => _DeepLinkListenerState();
}

class _DeepLinkListenerState extends State<DeepLinkListener> {
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = IntentReceiver.instance.onDeepLink.listen(_onDeepLink);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _onDeepLink(String link) async {
    final router = GoRouter.of(context);
    final auth = context.read<AuthProvider>();
    if (!auth.isAuthenticated || auth.dio == null) return;

    final uri = Uri.tryParse(link);
    if (uri == null) return;

    final host = uri.host;
    final pathSegments = uri.pathSegments;

    // notees://editor/:nodeId
    if (host == 'editor' && pathSegments.isNotEmpty) {
      final nodeId = int.tryParse(pathSegments.first);
      if (nodeId != null) {
        router.push('${Routes.editor}/$nodeId');
      }
      return;
    }

    // notees://:uuid — resolve the UUID to a node id and open the editor.
    if (host.isNotEmpty && _looksLikeUuid(host)) {
      try {
        final repo = NodeRepository(dio: auth.dio!);
        final node = await repo.fetchNodeByUuid(host);
        if (mounted) {
          router.push('${Routes.editor}/${node.id}');
        }
      } catch (_) {
        // Ignore unresolvable deep links.
      }
      return;
    }

    switch (host) {
      case 'journal':
        try {
          final repo = NodeRepository(dio: auth.dio!);
          final journal = await repo.getOrCreateDailyJournal(DateTime.now());
          if (mounted) {
            router.push('${Routes.editor}/${journal.id}');
          }
        } catch (_) {}
      case 'pages':
        router.push(Routes.pages);
      case 'tasks':
        router.push(Routes.tasks);
      case 'graph':
        router.push(Routes.graph);
      case 'whiteboard':
        final uuid = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
        router.push(uuid != null ? '${Routes.whiteboard}/$uuid' : Routes.whiteboard);
      case 'timeline':
        router.push(Routes.timeline);
      case 'gantt':
        router.push(Routes.gantt);
      case 'chart':
        router.push(Routes.chart);
      case 'pivot':
        router.push(Routes.pivot);
      case 'query':
        final nodeId = int.tryParse(uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '');
        if (nodeId != null) router.push('${Routes.query}/$nodeId');
    }
  }

  bool _looksLikeUuid(String value) {
    return RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(value);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
