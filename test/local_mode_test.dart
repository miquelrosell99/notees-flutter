import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/constants/system.dart';
import 'package:notees/core/secure/secure_storage.dart';
import 'package:notees/core/utils/ast_builder.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/server_repository.dart';
import 'package:notees/domain/services/local_workspace_seed.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:notees/features/auth/providers/auth_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  // loginLocally opens the on-device database path; path_provider has no
  // implementation on the test host, so serve a temp directory.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => '/tmp',
  );

  group('AuthProvider local profile', () {
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    AuthProvider buildAuth() => AuthProvider(
          serverRepository: ServerRepository(prefs: prefs),
          secureStorage: const SecureStorage(),
          prefs: prefs,
        );

    test('loginLocally creates a persisted offline profile', () async {
      final auth = buildAuth();

      await auth.loginLocally();

      expect(auth.error, isNull);
      expect(auth.isAuthenticated, isTrue);
      expect(auth.isLocalMode, isTrue);
      expect(auth.user?.isLocal, isTrue);
      expect(auth.user?.email, 'local@local');
      expect(auth.user?.displayName, 'Local user');
      // The web client gates on capabilities; here all server-only
      // capabilities must be off.
      expect(auth.canManageServers, isFalse);
      expect(auth.canManageWorkspaces, isFalse);
      expect(auth.canManageAccount, isFalse);
      expect(auth.canShare, isFalse);
      expect(auth.canUploadAssets, isFalse);
      // The choice persists so a relaunch skips server setup.
      expect(prefs.getString('local_profile_uuid'), auth.user?.uuid);
    });

    test('initialize restores the local session when no server is configured',
        () async {
      SharedPreferences.setMockInitialValues(
        const {'local_profile_uuid': 'local-uuid-1'},
      );
      prefs = await SharedPreferences.getInstance();
      final auth = buildAuth();

      await auth.initialize();

      expect(auth.activeServer, isNull);
      expect(auth.isLocalMode, isTrue);
      expect(auth.user?.uuid, 'local-uuid-1');
    });

    test('initialize without server or local profile stays unauthenticated',
        () async {
      final auth = buildAuth();

      await auth.initialize();

      expect(auth.activeServer, isNull);
      expect(auth.isAuthenticated, isFalse);
      expect(auth.isLocalMode, isFalse);
    });
  });

  group('serverless SyncV2Service', () {
    late AppDatabase database;
    late SyncV2Service syncService;

    setUp(() async {
      final ffiDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb);
      await database.initializeSchema();
      syncService = SyncV2Service(
        database: database,
        // No base URL: any network attempt would throw, so tests passing
        // prove push/pull perform no network I/O.
        dio: Dio(),
        clientId: 'test-client',
        serverless: true,
      );
      await syncService.setWorkspaceId('local-ws');
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
    });

    test('flush applies envelopes locally and keeps the outbox', () async {
      await syncService.enqueue(
        type: 'create',
        nodeUuid: 'n-1',
        contentAst: AstBuilder.parseInline('Hello'),
        isPage: true,
      );

      await syncService.flush();

      final node = await syncService.cache.getByUuid('n-1');
      expect(node, isNotNull);
      expect(node!.displayName, 'Hello');
      expect(node.isPage, isTrue);

      final db = await database.database;
      // The outbox keeps the row so a later server attach can push it.
      expect(await db.query('relay_outbox'), hasLength(1));
      final ops = await db.query('relay_operations');
      expect(ops, hasLength(1));
      expect(ops.first['is_local'], 1);

      // A repeated flush is a deduped no-op.
      await syncService.flush();
      expect(await db.query('relay_operations'), hasLength(1));
      expect(await db.query('relay_outbox'), hasLength(1));
    });

    test('pull is a no-op', () async {
      await syncService.pull();
      expect(await syncService.cache.getByUuid('n-1'), isNull);
    });

    test('remapWorkspace rewrites outbox, operations and favorites', () async {
      await syncService.enqueue(
        type: 'create',
        nodeUuid: 'n-1',
        contentAst: AstBuilder.parseInline('Hello'),
        isPage: true,
      );
      await syncService.flush();
      await syncService.cache.addFavorite(
        'local-ws',
        'n-1',
        actorId: syncService.actorId,
      );

      await syncService.remapWorkspace(
        'local-ws',
        'server-ws',
        actorId: 'user-1',
      );

      final db = await database.database;
      final outbox = await db.query('relay_outbox');
      expect(outbox, hasLength(1));
      final envelope =
          jsonDecode(outbox.first['envelope_json'] as String) as Map<String, dynamic>;
      expect(envelope['workspaceId'], 'server-ws');
      expect(envelope['actorId'], 'user-1');

      final ops = await db.query('relay_operations');
      expect(ops, hasLength(1));
      expect(ops.first['workspace_id'], 'server-ws');
      expect(ops.first['actor_id'], 'user-1');

      final favorites = await db.query('user_favorite');
      expect(favorites, hasLength(1));
      expect(favorites.first['workspace_id'], 'server-ws');
      expect(favorites.first['actor_id'], 'user-1');
    });
  });

  group('LocalWorkspaceSeed', () {
    late AppDatabase database;
    late SyncV2Service syncService;

    setUp(() async {
      final ffiDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb);
      await database.initializeSchema();
      syncService = SyncV2Service(
        database: database,
        dio: Dio(),
        clientId: 'test-client',
        serverless: true,
      );
      await syncService.setWorkspaceId('local-ws');
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
    });

    test('seeds system classes and default pages, idempotently', () async {
      final seed = LocalWorkspaceSeed(syncService);

      // 21 system classes x 2 ops (class.create + node.updateContent) + 2
      // pages (Inbox + scratchpad), matching the server/web seed sequence.
      final emitted = await seed.ensureLocalWorkspace(displayName: 'Local user');
      expect(emitted, 44);

      final taskClass =
          await syncService.cache.getClassByUuid(SystemClassUuids.task);
      expect(taskClass?.name, 'task');

      final inbox = await syncService.cache.getByUuid(SystemPageUuids.inbox);
      expect(inbox, isNotNull);
      expect(inbox!.displayName, 'Inbox');
      expect(inbox.isPage, isTrue);

      final scratchpad =
          await syncService.cache.getByUuid(SystemPageUuids.scratchpad);
      expect(scratchpad?.displayName, 'Local user');

      final db = await database.database;
      // Seed ops stay in the outbox for a later server attach.
      expect(await db.query('relay_outbox'), hasLength(44));

      // Re-running emits nothing.
      expect(await seed.ensureLocalWorkspace(displayName: 'Local user'), 0);
      expect(await db.query('relay_outbox'), hasLength(44));
    });
  });
}
