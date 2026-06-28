import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/routing/router.dart';
import 'core/secure/encryption_provider.dart';
import 'core/secure/secure_storage.dart';
import 'core/theme/theme_builder.dart';
import 'core/theme/theme_provider.dart';
import 'data/repositories/node_repository.dart';
import 'data/repositories/server_repository.dart';
import 'domain/services/quick_capture.dart';
import 'native/app_locker.dart';
import 'native/background_sync.dart';
import 'native/intent_receiver.dart';
import 'native/offline_sync.dart';
import 'presentation/providers/auth_provider.dart';
import 'presentation/providers/biometric_provider.dart';
import 'presentation/providers/connectivity_provider.dart';
import 'presentation/providers/settings_provider.dart';
import 'presentation/widgets/audio_recorder_sheet.dart';
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
            prefs: prefs,
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => BiometricProvider(prefs: prefs)..initialize(),
        ),
        ChangeNotifierProvider(create: (_) => ConnectivityProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider(prefs)),
        ChangeNotifierProvider(create: (_) => EncryptionProvider(prefs: prefs)..initialize()),
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
    final encryption = context.read<EncryptionProvider>();
    final auth = context.read<AuthProvider>();
    _router = createRouter(authProvider: auth);
    encryption.initialize().then((_) {
      auth.initialize().then((_) {
        if (auth.activeServer != null) {
          BackgroundSync.registerPeriodic();
        }
      });
    });
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
              child: QuickNoteTileListener(
                child: AudioNoteTileListener(
                  child: OfflineBanner(
                    child: OfflineSync(
                      dio: auth.dio ?? Dio(),
                      syncService: auth.syncService,
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

    // notees://editor/:nodeUuid
    if (host == 'editor' && pathSegments.isNotEmpty) {
      final nodeUuid = pathSegments.first;
      if (nodeUuid.isNotEmpty) {
        router.push('${Routes.editor}/$nodeUuid');
      }
      return;
    }

    // notees://:uuid — open the editor for the node UUID directly.
    if (host.isNotEmpty && _looksLikeUuid(host)) {
      router.push('${Routes.editor}/$host');
      return;
    }

    switch (host) {
      case 'journal':
        try {
          final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
          final journal = await repo.getOrCreateDailyJournal(DateTime.now());
          if (mounted) {
            router.push('${Routes.editor}/${journal.uuid}');
          }
        } catch (_) {}
      case 'journals':
        router.push(Routes.journals);
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
        final nodeUuid = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
        if (nodeUuid.isNotEmpty) router.push('${Routes.query}/$nodeUuid');
    }
  }

  bool _looksLikeUuid(String value) {
    return RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(value);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Listens for the Android Quick Settings "Quick note" tile and opens the
/// quick-capture bottom sheet.
class QuickNoteTileListener extends StatefulWidget {
  const QuickNoteTileListener({super.key, required this.child});
  final Widget child;

  @override
  State<QuickNoteTileListener> createState() => _QuickNoteTileListenerState();
}

class _QuickNoteTileListenerState extends State<QuickNoteTileListener> {
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = IntentReceiver.instance.onQuickNoteTile.listen(_onTile);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onTile(void _) {
    final ctx = context;
    if (!ctx.mounted) return;
    final auth = ctx.read<AuthProvider>();
    if (!auth.isAuthenticated) return;
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      builder: (_) => const QuickCaptureSheet(),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Listens for the Android Quick Settings "Audio note" tile and opens the
/// audio recorder sheet. When a recording is confirmed it is uploaded as an
/// asset block to the user's configured quick-capture destination.
class AudioNoteTileListener extends StatefulWidget {
  const AudioNoteTileListener({super.key, required this.child});
  final Widget child;

  @override
  State<AudioNoteTileListener> createState() => _AudioNoteTileListenerState();
}

class _AudioNoteTileListenerState extends State<AudioNoteTileListener> {
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = IntentReceiver.instance.onAudioNoteTile.listen(_onTile);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _onTile(void _) async {
    final ctx = context;
    if (!ctx.mounted) return;
    final auth = ctx.read<AuthProvider>();
    if (!auth.isAuthenticated || auth.dio == null) return;

    final file = await showModalBottomSheet<File>(
      context: ctx,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => const AudioRecorderSheet(),
    );
    if (file == null || !ctx.mounted) return;

    final settings = ctx.read<SettingsProvider>();
    final destination = settings.quickCaptureDestination;
    final parentUuid = await _resolveParentUuid(auth, destination);
    if (!ctx.mounted) return;

    try {
      await QuickCaptureService(
        dio: auth.dio!,
        syncService: auth.syncService,
      ).uploadAsset(file, parentUuid: parentUuid);
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('Audio note saved')),
        );
      }
    } catch (e) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('Audio upload failed: $e')),
        );
      }
    }
  }

  Future<String> _resolveParentUuid(
    AuthProvider auth,
    QuickCaptureDestination destination,
  ) async {
    final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
    return resolveQuickCaptureParentUuid(
      repository: repo,
      destination: destination,
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
