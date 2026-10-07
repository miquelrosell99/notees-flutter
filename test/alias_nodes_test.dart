import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/models/node.dart';
import 'package:notees/data/repositories/node_repository.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/domain/models/relay/store_errors.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:notees/features/editor/widgets/alias_target_guard.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The node-alias UI read/write seam (SCHEMA.md "Node aliases"): the
/// service's `setAliasedNode` write (one object.update, presence writes /
/// present-null clears, applied locally) and the repository's
/// `fetchAliasNodesOf` listing (the store's recursive read, filtered to
/// pages) — plus the client-side pick guard.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const a = '0192a000-0000-7000-8000-0000000000b1';
  const b = '0192a000-0000-7000-8000-0000000000b2';

  Node page(String uuid, {String? aliasedNodeId}) => Node(
        id: 0,
        uuid: uuid,
        name: '[{"type":"text","text":"$uuid"}]',
        displayName: uuid,
        isPage: true,
        aliasedNodeId: aliasedNodeId,
      );

  group('aliasTargetError (the pick guard)', () {
    test('an ordinary page is writable', () {
      expect(aliasTargetError(page(b), carrierUuid: a), isNull);
    });

    test('a non-page target is rejected', () {
      final block = Node(
        id: 0,
        uuid: b,
        name: 'x',
        displayName: 'x',
        isPage: false,
      );
      expect(aliasTargetError(block, carrierUuid: a),
          'The aliased node must be a page.');
    });

    test('a self-alias is rejected', () {
      expect(aliasTargetError(page(a), carrierUuid: a),
          'A page cannot alias itself.');
    });

    test('a page that already is an alias is rejected', () {
      expect(aliasTargetError(page(b, aliasedNodeId: a), carrierUuid: a),
          'That page is already an alias.');
    });
  });

  group('setAliasedNode + fetchAliasNodesOf', () {
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
        clientId: '40000000-0000-4000-8000-000000000001',
        serverless: true,
      );
      await syncService.setWorkspaceId('10000000-0000-4000-8000-000000000001');

      for (final entry in [(a, 'Alias page'), (b, 'Main page')]) {
        await syncService.emitLocal(
          opType: 'object.create',
          payload: OperationPayloads.objectCreate(
            objectId: entry.$1,
            presentAsMain: true,
            contentAst: [
              {'type': 'text', 'text': entry.$2},
            ],
          ),
          affectedNodeIds: [entry.$1],
        );
      }
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
    });

    test('the write lands through object.update and the listing reads it',
        () async {
      final repo = NodeRepository(dio: Dio(), syncService: syncService);

      expect(await repo.fetchAliasNodesOf(b), isEmpty);

      // THE backward write: A's `aliasedNodeId` becomes B.
      await repo.setAliasedNodeId(a, b);
      expect((await syncService.cache.getByUuid(a))!.aliasedNodeId, b);
      final aliases = await repo.fetchAliasNodesOf(b);
      expect(aliases.map((n) => n.uuid), [a]);
      expect(aliases.single.displayName, 'Alias page');

      // A clear (present-null) unlinks; the listing empties.
      await repo.setAliasedNodeId(a, null);
      expect((await syncService.cache.getByUuid(a))!.aliasedNodeId, isNull);
      expect(await repo.fetchAliasNodesOf(b), isEmpty);
    });

    test('a cyclic write fails loud and lands nothing', () async {
      final repo = NodeRepository(dio: Dio(), syncService: syncService);
      await repo.setAliasedNodeId(a, b);
      // B → A would close A → B → A: the applier rejects it, the column
      // stays null and the listing is unchanged.
      expect(() => repo.setAliasedNodeId(b, a), throwsA(isA<CycleError>()));
      expect((await syncService.cache.getByUuid(b))!.aliasedNodeId, isNull);
      expect(await repo.fetchAliasNodesOf(b), hasLength(1));
    });
  });
}
