import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:intl/intl.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:notees/app.dart';
import 'package:notees/core/constants/system.dart';
import 'package:notees/core/secure/secure_storage.dart';
import 'package:notees/core/utils/date_uuid.dart';
import 'package:notees/core/utils/uuid7.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/server_repository.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/features/auth/providers/auth_provider.dart';

/// Per-screen captures of the real app for visual review (sonarly's
/// scripts/screenshots pattern, ported to Flutter).
///
/// The real [NoteesApp] runs against a real local data layer: ffi SQLite
/// stands in for the platform SQLCipher store and
/// [AuthProvider.loginLocally] supplies a signed-in local session, seeded
/// below through the same relay-op path the app itself uses.
///
/// Screenshot capture is best-effort: [IntegrationTestWidgetsFlutterBinding
/// .takeScreenshot] only produces images on supported device targets, so
/// every capture is guarded and the flow keeps going without one.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> capture(String name) async {
    try {
      final bytes = await binding.takeScreenshot(name);
      debugPrint('📸 $name (${bytes.length} bytes)');
    } catch (e) {
      debugPrint('⚠️ screenshot "$name" skipped: $e');
    }
  }

  testWidgets('capture per-screen screenshots', (tester) async {
    // Local, offline data layer on the host: ffi SQLite + a temp documents
    // dir, so the local session gets a real derived cache to seed and read.
    final tempDir = Directory.systemTemp.createTempSync('notees_screenshots');
    sqfliteFfiInit();
    AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);

    // The bootstrap below touches a few platform channels that have no plugin
    // on a test host; answer them minimally (notifications init, intents).
    // The platform-interface fakes avoid the real plugin backends (DBus on the
    // Linux host, SQLCipher channel, …).
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const notificationsChannel =
        MethodChannel('dexterous.com/flutter/local_notifications');
    messenger.setMockMethodCallHandler(notificationsChannel, (call) async {
      if (call.method == 'initialize') return true;
      return null;
    });
    ConnectivityPlatform.instance = _FakeConnectivityPlatform();
    const intentsChannel = MethodChannel('com.notees.notees/intents');
    messenger.setMockMethodCallHandler(intentsChannel, (call) async {
      switch (call.method) {
        case 'getPendingQuickNoteTile':
        case 'getPendingAudioNoteTile':
          return false;
        default:
          return null;
      }
    });

    // Pretend to run on Android so the local SQLite store is "supported" and
    // the app's plugin-gated bootstrap paths exercise their mocks above.
    // Reset before the body ends: the test framework fails on debug-variable
    // changes that outlive the test body.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    SharedPreferences.setMockInitialValues(const {'onboarding_completed': true});
    final prefs = await SharedPreferences.getInstance();

    // The real app from lib/main.dart, minus the platform bootstrap pieces
    // (work manager, orientations) that have no test implementation.
    await tester.pumpWidget(NoteesApp(
      prefs: prefs,
      serverRepository: ServerRepository(prefs: prefs),
      secureStorage: const SecureStorage(),
    ));
    // Let the post-frame bootstrap (encryption, auth restore) run.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    // Phone-sized surface: the default 800x600 tester window both trips the
    // tablet rail breakpoint and overflows phone layouts.
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(412, 915) * 3.0;
    addTearDown(tester.view.reset);

    // Sign in via the ServerSetup screen's offline path, exactly like a user.
    await tester.tap(find.text('Continue offline'));
    await waitUntil(tester, () => tester.any(find.byType(NavigationBar)));

    final ctx = tester.element(find.byType(MaterialApp));
    final auth = ctx.read<AuthProvider>();

    await _seedScreenshotData(auth);

    Future<void> step(String name, Future<void> Function() action) async {
      try {
        await action();
        debugPrint('✅ $name');
      } catch (e) {
        debugPrint('❌ $name failed: $e');
      }
    }

    Future<void> popRoute() async {
      final shellCtx = tester.element(find.byType(NavigationBar));
      GoRouter.of(shellCtx).pop();
      await tester.pump(const Duration(milliseconds: 400));
    }

    // Home tab.
    await step('home', () async {
      await waitUntil(tester, () => tester.any(find.text(_todayLabel())));
      await capture('01-home');
    });

    // Tasks tab.
    await step('open tasks', () async {
      await tester.tap(find.text('Tasks'));
      await waitUntil(tester, () => tester.any(find.byTooltip('Create task')));
      await capture('02-tasks');
    });

    // Journal tab + calendar sheet.
    await step('open journal', () async {
      await tester.tap(find.text('Journal'));
      await waitUntil(tester, () => tester.any(find.text('Recent entries')));
      await capture('03-journal');
      await tester.tap(find.byTooltip('Jump to date'));
      await waitUntil(tester, () => tester.any(find.text('Jump to journal')));
      await capture('04-calendar');
      await tester.tap(find.byTooltip('Close'));
      await tester.pump(const Duration(milliseconds: 400));
    });

    // Library tab.
    await step('open library', () async {
      await tester.tap(find.text('Library'));
      await waitUntil(tester, () => tester.any(find.text('All pages')));
      await capture('05-library');
    });

    // Node editor via a favorites row on Home (plain page, no children).
    // Node editor via the Today card (seeded single-token AST children — the
    // owner grey-box scenario): the block body must actually render.
    await step('open editor', () async {
      await tester.tap(find.text('Home'));
      await waitUntil(tester, () => tester.any(find.text(_todayLabel())));
      await tester.tap(find.text(_todayLabel()));
      await waitUntil(
        tester,
        () => tester.any(_richTextContaining('Morning walk: 5km along the river')),
      );
      await capture('06-editor');
      await popRoute();
    });

    // Command palette, then Settings via its static command.
    await step('open search + settings', () async {
      await tester.tap(find.text('Search'));
      await waitUntil(tester, () => tester.any(find.text('Go to inbox')));
      await capture('07-search');
      await tester.tap(find.text('Go to settings'));
      await waitUntil(tester, () => tester.any(find.text('Appearance')));
      await capture('08-settings');
    });

    debugPrint('Screenshot flow complete.');
    debugDefaultTargetPlatformOverride = null;
  });
}

/// Pumps until [condition] holds or gives up after ~6s.
Future<void> waitUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 200));
    if (condition()) return;
  }
  throw StateError('timed out waiting for condition');
}

/// Matches RichText whose accumulated plain text contains [text] (the block
/// rows render through AstRichText spans, so find.text cannot see them).
Finder _richTextContaining(String text) => find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText().contains(text),
    );

/// The Today card title, computed exactly like the Home screen does.
String _todayLabel() => DateFormat.yMMMMEEEEd().format(DateTime.now());

/// Redirects path_provider to a temp directory on the test host.
class _FakePathProviderPlatform extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProviderPlatform(this._tempDir);

  final String _tempDir;

  @override
  Future<String?> getApplicationDocumentsPath() async => _tempDir;
}

/// Always-online connectivity without a real plugin backend.
class _FakeConnectivityPlatform extends ConnectivityPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      [ConnectivityResult.wifi];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream<ConnectivityResult>.empty().map((r) => [r]);
}

/// Seeds the local workspace with ~12 nodes covering every Home section plus
/// journal history, through the same emitLocal relay-op path the app uses.
Future<void> _seedScreenshotData(AuthProvider auth) async {
  final sync = auth.syncService;
  if (sync == null) {
    fail('local session has no sync service; cannot seed screenshot data');
  }
  final workspaceId = await sync.getWorkspaceId();
  if (workspaceId == null) {
    fail('local session has no workspace; cannot seed screenshot data');
  }
  final today = DateTime.now();
  String dayLabel(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  Future<void> create({
    required String uuid,
    required String title,
    List<String> classIds = const [],
    String? parentId,
  }) async {
    await sync.emitLocal(
      opType: 'object.create',
      payload: OperationPayloads.objectCreate(
        objectId: uuid,
        nodeType: parentId == null ? 'page' : 'block',
        name: title,
        classIds: classIds.isEmpty ? null : classIds,
        parentId: parentId,
      ),
      affectedNodeIds: [uuid],
    );
  }

  // Today's daily note with a body (drives the Home Today card + peek).
  final todayUuid = dateToDayUuid(today);
  await create(
    uuid: todayUuid,
    title: dayLabel(today),
    classIds: [SystemClassUuids.day],
  );
  await create(
    uuid: Uuid7.generate(),
    title: 'Morning walk: 5km along the river',
    parentId: todayUuid,
  );
  await create(
    uuid: Uuid7.generate(),
    title: 'Ideas: screenshot harness for visual review',
    parentId: todayUuid,
  );

  // Yesterday's entry so the journal list and calendar dots have history.
  final yesterday = today.subtract(const Duration(days: 1));
  final yesterdayUuid = dateToDayUuid(yesterday);
  await create(
    uuid: yesterdayUuid,
    title: dayLabel(yesterday),
    classIds: [SystemClassUuids.day],
  );
  await create(
    uuid: Uuid7.generate(),
    title: 'Read 20 pages of "The Design of Everyday Things"',
    parentId: yesterdayUuid,
  );

  // Pages for Favorites / Recent / Library.
  final readingList = Uuid7.generate();
  final meetingNotes = Uuid7.generate();
  final recipe = Uuid7.generate();
  await create(uuid: readingList, title: 'Reading list');
  await create(uuid: meetingNotes, title: 'Meeting notes');
  await create(uuid: recipe, title: 'Recipe — tortilla de patatas');

  // Tasks.
  await create(
    uuid: Uuid7.generate(),
    title: 'Water the plants',
    classIds: [SystemClassUuids.task],
  );
  await create(
    uuid: Uuid7.generate(),
    title: 'Reply to Sam about the trip',
    classIds: [SystemClassUuids.task],
  );

  // Inbox items.
  await create(
    uuid: Uuid7.generate(),
    title: 'Buy oat milk',
    parentId: SystemPageUuids.inbox,
  );
  await create(
    uuid: Uuid7.generate(),
    title: 'Idea: quick-capture home screen tile',
    parentId: SystemPageUuids.inbox,
  );
  await create(
    uuid: Uuid7.generate(),
    title: 'Screenshot: calendar month polish',
    parentId: SystemPageUuids.inbox,
  );

  // Pin a few nodes so the Favorites sections have content.
  final actorId = sync.hasUserActor ? sync.actorId : null;
  await sync.cache.addFavorite(workspaceId, readingList, actorId: actorId);
  await sync.cache.addFavorite(workspaceId, meetingNotes, actorId: actorId);
  await sync.cache.addFavorite(workspaceId, todayUuid, actorId: actorId);
}
