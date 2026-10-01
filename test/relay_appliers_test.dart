import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/constants/system.dart';
import 'package:notees/core/utils/ast_builder.dart';
import 'package:notees/core/utils/ast_stringifier.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/domain/models/relay/store_errors.dart';
import 'package:notees/domain/services/relay_appliers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('RelayAppliers (v2 registry) against SQLite', () {
    late AppDatabase database;
    late NodeCacheRepository cache;
    late RelayAppliers appliers;

    const deviceId = 'test-device';

    OperationEnvelope envelope({
      required String id,
      required String opType,
      required Map<String, dynamic> payload,
      int physical = 1,
      String actorId = '0192a000-0000-7000-8000-000000000002',
    }) =>
        OperationEnvelope(
          id: id,
          workspaceId: '0192a000-0000-7000-8000-000000000001',
          actorId: actorId,
          deviceId: deviceId,
          client: 'flutter',
          hlc: Hlc(physical: physical, logical: 0),
          affectedNodeIds: [
            payload['objectId'] ?? payload['classId'] ?? '',
          ],
          opType: opType,
          payload: payload,
          timestamp: '2026-09-24T12:00:00.000Z',
        );

    setUp(() async {
      final ffiDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb);
      await database.initializeSchema();
      cache = NodeCacheRepository(database);
      appliers = RelayAppliers(cache);
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
    });

    test('applies object.create with class flags', () async {
      const nodeUuid = '00000000-0000-0000-0000-000000000101';
      final content = AstBuilder.parseInline('Daily journal');
      final env = envelope(
        id: '0192a000-0000-7000-8000-0000000000e1',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: nodeUuid,
          nodeType: 'page',
          classIds: [SystemClassUuids.day],
          contentAst: content,
        ),
      );

      await appliers.apply(env);
      final node = await cache.getByUuid(nodeUuid);

      expect(node, isNotNull);
      expect(node!.uuid, nodeUuid);
      expect(node.displayName, 'Daily journal');
      expect(node.classesUuid, [SystemClassUuids.day]);
      expect(node.isDaily, isTrue);
      expect(node.isTask, isFalse);
      expect(node.isPage, isTrue);
    });

    test('object.create without nodeType defaults by placement context', () async {
      const rootUuid = '00000000-0000-0000-0000-000000000110';
      const childUuid = '00000000-0000-0000-0000-000000000111';

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000e2',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(objectId: rootUuid),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000e3',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: childUuid,
          parentId: rootUuid,
        ),
      ));

      expect((await cache.getByUuid(rootUuid))!.isPage, isTrue);
      final child = await cache.getByUuid(childUuid);
      expect(child!.isPage, isFalse);
      expect(child.parentUuid, rootUuid);
    });

    test('a re-issued object.create seeds class membership (OR-Set carrier)',
        () async {
      const nodeUuid = '00000000-0000-0000-0000-000000000103';

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000e4',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(objectId: nodeUuid),
      ));
      // Re-create with a classId: membership is added, the tree untouched.
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000e5',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: nodeUuid,
          classIds: [SystemClassUuids.task],
        ),
      ));

      final node = await cache.getByUuid(nodeUuid);
      expect(node!.classesUuid, contains(SystemClassUuids.task));
      expect(node.isTask, isTrue);
    });

    test('applies object.update contentAst and icon/color upserts', () async {
      const nodeUuid = '00000000-0000-0000-0000-000000000104';

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000e6',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: nodeUuid,
          nodeType: 'page',
          contentAst: AstBuilder.parseInline('Original'),
        ),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000e7',
        opType: 'object.update',
        payload: OperationPayloads.objectUpdate(
          objectId: nodeUuid,
          // Title-is-content: a rename is a contentAst replacement.
          contentAst: AstBuilder.parseInline('Renamed'),
        ),
        physical: 2,
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000e8',
        opType: 'object.update',
        payload: OperationPayloads.objectUpdate(
          objectId: nodeUuid,
          icon: 'folder',
          color: '#5B7D5B',
        ),
        physical: 3,
      ));

      final node = await cache.getByUuid(nodeUuid);
      // The rename landed in the content slot; the display name derives
      // from it. There is no scalar name slot on the v2 wire.
      expect(node!.displayName, 'Renamed');
      expect(AstBuilder.toPlainText(contentTokensFromSource(node.name)),
          'Renamed');
      expect(node.title, isNull);
      expect(node.icon, 'folder');
      expect(node.color, '#5B7D5B');
    });

    test('promoting a block to a page flattens its rich content (title-is-'
        'content)', () async {
      const pageUuid = '00000000-0000-0000-0000-000000000105';
      const blockUuid = '00000000-0000-0000-0000-000000000106';

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000f1',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: pageUuid,
          nodeType: 'page',
        ),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000f2',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: blockUuid,
          nodeType: 'block',
          parentId: pageUuid,
          contentAst: const [
            {'type': 'text', 'text': 'Todo: '},
            {
              'type': 'mention',
              'targetNodeId': '00000000-0000-0000-0000-000000000199',
              'text': 'shopping',
            },
          ],
        ),
        physical: 2,
      ));

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000f3',
        opType: 'object.update',
        payload: OperationPayloads.objectUpdate(
          objectId: blockUuid,
          nodeType: 'page',
        ),
        physical: 3,
      ));

      final node = await cache.getByUuid(blockUuid);
      expect(node!.nodeType, 'page');
      expect(node.isPage, isTrue);
      // The rich stream flattened to a single text-only token (pages carry
      // text-only content) and the display name re-derived from it.
      expect(jsonDecode(node.name), [
        {'type': 'text', 'text': 'Todo: shopping'},
      ]);
      expect(node.displayName, 'Todo: shopping');
    });

    test('applies property.set and property.unset by propertySchemaId',
        () async {
      const nodeUuid = '00000000-0000-0000-0000-000000000102';
      const pageUuid = '00000000-0000-0000-0000-000000000199';

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000e0',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: pageUuid,
          nodeType: 'page',
        ),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000e9',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: nodeUuid,
          nodeType: 'block',
          parentId: pageUuid,
          classIds: [SystemClassUuids.task],
        ),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000ea',
        opType: 'property.set',
        payload: OperationPayloads.propertySet(
          objectId: nodeUuid,
          propertySchemaId: SystemPropertyUuids.taskDeadline,
          value: '2026-08-10',
        ),
        physical: 2,
      ));

      var node = await cache.getByUuid(nodeUuid);
      expect(node!.properties[SystemPropertyUuids.taskDeadline], '2026-08-10');

      // The derived property_value table is the LWW authority.
      final db = await database.database;
      final rows = await db.rawQuery(
        'SELECT value, idx FROM property_value WHERE node_uuid = ? AND property_schema_id = ?',
        [nodeUuid, SystemPropertyUuids.taskDeadline],
      );
      expect(rows, hasLength(1));
      expect(jsonDecode(rows.single['value'] as String), '2026-08-10');

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000eb',
        opType: 'property.unset',
        payload: OperationPayloads.propertyUnset(
          objectId: nodeUuid,
          propertySchemaId: SystemPropertyUuids.taskDeadline,
        ),
        physical: 3,
      ));
      node = await cache.getByUuid(nodeUuid);
      expect(node!.properties[SystemPropertyUuids.taskDeadline], isNull);
      expect(
        await db.rawQuery(
          'SELECT COUNT(*) AS c FROM property_value WHERE node_uuid = ?',
          [nodeUuid],
        ).then((r) => r.single['c']),
        0,
      );
      // The tombstone survives (and blocks stale re-set below).
      final tombstones = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM property_value_tombstone WHERE node_uuid = ?',
        [nodeUuid],
      );
      expect(tombstones.single['c'], 1);

      // A stale re-set (older HLC than the tombstone) is dropped.
      final reverted = await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000ec',
        opType: 'property.set',
        payload: OperationPayloads.propertySet(
          objectId: nodeUuid,
          propertySchemaId: SystemPropertyUuids.taskDeadline,
          value: '2026-01-01',
        ),
        physical: 2,
      ));
      expect(reverted, isFalse);
      expect(
        (await cache.getByUuid(nodeUuid))!
            .properties[SystemPropertyUuids.taskDeadline],
        isNull,
      );
    });

    test('applies class.create, update, setExtends and delete', () async {
      const classUuid = '00000000-0000-0000-0000-000000000301';
      const parentUuid = '00000000-0000-0000-0000-000000000302';

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000ec',
        opType: 'class.create',
        payload: OperationPayloads.classCreate(
          classId: classUuid,
          name: 'Project',
          color: '#5B7D5B',
        ),
      ));
      var cls = await cache.getClassByUuid(classUuid);
      expect(cls, isNotNull);
      expect(cls!.displayName, 'Project');
      expect(cls.color, '#5B7D5B');

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000ecp',
        opType: 'class.create',
        payload: OperationPayloads.classCreate(
          classId: parentUuid,
          name: 'Parent',
        ),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000ed',
        opType: 'class.setExtends',
        payload: OperationPayloads.classSetExtends(
          classId: classUuid,
          parentClassIds: [parentUuid],
        ),
        physical: 2,
      ));
      // Extends are stored separately; the cached class row exposes name/color.
      cls = await cache.getClassByUuid(classUuid);
      expect(cls, isNotNull);

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000ee',
        opType: 'class.update',
        payload: OperationPayloads.classUpdate(
          classId: classUuid,
          icon: 'folder',
        ),
        physical: 3,
      ));
      cls = await cache.getClassByUuid(classUuid);
      expect(cls!.icon, 'folder');

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000ef',
        opType: 'class.delete',
        payload: OperationPayloads.classDelete(classId: classUuid),
        physical: 4,
      ));
      cls = await cache.getClassByUuid(classUuid);
      expect(cls, isNull);
    });

    test('object.delete permanent:false archives, permanent:true hard-deletes',
        () async {
      const archivedUuid = '00000000-0000-0000-0000-000000000105';
      const doomedUuid = '00000000-0000-0000-0000-000000000106';

      const pageUuid = '00000000-0000-0000-0000-00000000019a';
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000f0',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: pageUuid,
          nodeType: 'page',
        ),
      ));
      for (final (uuid, idSuffix) in [
        (archivedUuid, 'f1'),
        (doomedUuid, 'f2'),
      ]) {
        await appliers.apply(envelope(
          id: '0192a000-0000-7000-8000-000000000$idSuffix',
          opType: 'object.create',
          payload: OperationPayloads.objectCreate(
            objectId: uuid,
            nodeType: 'page',
            parentId: pageUuid,
          ),
        ));
      }

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000f3',
        opType: 'object.delete',
        payload: OperationPayloads.objectDelete(
          objectId: archivedUuid,
          permanent: false,
        ),
        physical: 2,
      ));
      var node = await cache.getByUuid(archivedUuid);
      expect(node, isNotNull);
      expect(node!.isArchived, isTrue);

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000f4',
        opType: 'object.delete',
        payload: OperationPayloads.objectDelete(
          objectId: doomedUuid,
          permanent: true,
        ),
        physical: 2,
      ));
      node = await cache.getByUuid(doomedUuid);
      expect(node, isNull);
    });

    test('applies propertySchema.create/update/delete', () async {
      const schemaUuid = '00000000-0000-0000-0000-000000000401';

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000f5',
        opType: 'propertySchema.create',
        payload: OperationPayloads.propertySchemaCreate(
          propertySchemaId: schemaUuid,
          name: 'Priority',
          type: 'select',
          options: const [
            {'id': 'a', 'label': 'Low'},
            {'id': 'b', 'label': 'High'},
          ],
        ),
      ));
      var property = await cache.getPropertySchema(schemaUuid);
      expect(property, isNotNull);
      expect(property!.name, 'Priority');
      expect(property.type, 'select');
      expect(property.options.length, 2);

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000f6',
        opType: 'propertySchema.update',
        payload: OperationPayloads.propertySchemaUpdate(
          propertySchemaId: schemaUuid,
          name: 'Importance',
        ),
        physical: 2,
      ));
      property = await cache.getPropertySchema(schemaUuid);
      expect(property!.name, 'Importance');
      // v2 update carries only name/options; everything else is preserved.
      expect(property.type, 'select');
      expect(property.options.length, 2);

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000f7',
        opType: 'propertySchema.delete',
        payload: OperationPayloads.propertySchemaDelete(
          propertySchemaId: schemaUuid,
        ),
        physical: 3,
      ));
      property = await cache.getPropertySchema(schemaUuid);
      expect(property, isNull);
    });

    test('object.delete permanent:true removes the node and its derived rows',
        () async {
      const nodeUuid = '00000000-0000-0000-0000-000000000701';
      const pageUuid = '00000000-0000-0000-0000-00000000019b';
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000f0',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: pageUuid,
          nodeType: 'page',
        ),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000f8',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: nodeUuid,
          nodeType: 'block',
          parentId: pageUuid,
          classIds: [SystemClassUuids.task],
          contentAst: AstBuilder.parseInline('Doomed'),
        ),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000f9b',
        opType: 'property.set',
        payload: OperationPayloads.propertySet(
          objectId: nodeUuid,
          propertySchemaId: SystemPropertyUuids.taskDeadline,
          value: '2026-08-10',
        ),
        physical: 2,
      ));
      await cache.applyFavoriteAdd(
        '0192a000-0000-7000-8000-000000000001',
        '0192a000-0000-7000-8000-000000000002',
        nodeUuid,
      );
      await cache.recordTaskCompletion(
        nodeUuid,
        '00000000-0000-0000-0000-000000000201',
        completedAt: '2026-08-09T12:00:00.000Z',
      );
      await cache.applyTaskSetRecurrence(
        nodeUuid,
        recurrenceId: 'r-1',
        rule: const {'freq': 'daily'},
      );
      expect(await cache.getByUuid(nodeUuid), isNotNull);

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000f9',
        opType: 'object.delete',
        payload: OperationPayloads.objectDelete(
          objectId: nodeUuid,
          permanent: true,
        ),
        physical: 2,
      ));

      expect(await cache.getByUuid(nodeUuid), isNull);
      expect(
        await cache.getFavoriteUuids(
          '0192a000-0000-7000-8000-000000000001',
          actorId: '0192a000-0000-7000-8000-000000000002',
        ),
        isEmpty,
      );
      expect(await cache.getMostRecentTaskCompletionId(nodeUuid), isNull);
      expect(await cache.getTaskRecurrence(nodeUuid), isNull);
    });

    test('applies object.move reparenting and afterId sibling placement',
        () async {
      const pageUuid = '00000000-0000-0000-0000-000000000801';
      const blockA = '00000000-0000-0000-0000-000000000802';
      const blockB = '00000000-0000-0000-0000-000000000803';
      const blockC = '00000000-0000-0000-0000-000000000804';

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000101',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: pageUuid,
          nodeType: 'page',
        ),
      ));
      for (final (uuid, suffix) in [(blockA, '102'), (blockB, '103'), (blockC, '104')]) {
        await appliers.apply(envelope(
          id: '0192a000-0000-7000-8000-000000000$suffix',
          opType: 'object.create',
          payload: OperationPayloads.objectCreate(
            objectId: uuid,
            parentId: pageUuid,
          ),
        ));
      }

      // Reparent C under A (append: no afterId).
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000105',
        opType: 'object.move',
        payload: OperationPayloads.objectMove(
          objectId: blockC,
          parentId: blockA,
        ),
        physical: 2,
      ));
      var c = await cache.getByUuid(blockC);
      expect(c!.parentUuid, blockA);
      expect(c.position, 'a');

      // Place B immediately after A inside the page: sibling midpoint after
      // A's 'a' with no further sibling appends 'aa'.
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000106',
        opType: 'object.move',
        payload: OperationPayloads.objectMove(
          objectId: blockB,
          parentId: pageUuid,
          afterId: blockA,
        ),
        physical: 3,
      ));
      c = await cache.getByUuid(blockB);
      expect(c!.parentUuid, pageUuid);
      expect(c.position, 'aa');
      final order = (await cache.getChildren(pageUuid)).map((n) => n.uuid);
      expect(order, [blockA, blockB]);
      final aChildren =
          (await cache.getChildren(blockA)).map((n) => n.uuid);
      expect(aChildren, [blockC]);
    });

    test('skips stale object.update content (last-write-wins HLC)', () async {
      const nodeUuid = '00000000-0000-0000-0000-000000000707';

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000111',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: nodeUuid,
          nodeType: 'page',
        ),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000112',
        opType: 'object.update',
        payload: OperationPayloads.objectUpdate(
          objectId: nodeUuid,
          contentAst: AstBuilder.parseInline('Newer'),
        ),
        physical: 10,
      ));
      expect((await cache.getByUuid(nodeUuid))!.displayName, 'Newer');

      // An older HLC must not clobber the newer content.
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000113',
        opType: 'object.update',
        payload: OperationPayloads.objectUpdate(
          objectId: nodeUuid,
          contentAst: AstBuilder.parseInline('Older'),
        ),
        physical: 5,
      ));
      expect((await cache.getByUuid(nodeUuid))!.displayName, 'Newer');

      // A newer HLC still applies.
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000114',
        opType: 'object.update',
        payload: OperationPayloads.objectUpdate(
          objectId: nodeUuid,
          contentAst: AstBuilder.parseInline('Newest'),
        ),
        physical: 11,
      ));
      expect((await cache.getByUuid(nodeUuid))!.displayName, 'Newest');
    });

    test('object.create ignores an existing node (first-create-wins parity)',
        () async {
      const nodeUuid = '00000000-0000-0000-0000-000000000710';
      OperationEnvelope createEnvelope(String id) => envelope(
            id: id,
            opType: 'object.create',
            payload: OperationPayloads.objectCreate(
              objectId: nodeUuid,
              nodeType: 'page',
              contentAst: AstBuilder.parseInline('Original'),
            ),
          );

      await appliers.apply(createEnvelope(
          '0192a000-0000-7000-8000-000000000115'));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000116',
        opType: 'object.update',
        payload: OperationPayloads.objectUpdate(
          objectId: nodeUuid,
          contentAst: AstBuilder.parseInline('Renamed'),
        ),
        physical: 2,
      ));
      expect((await cache.getByUuid(nodeUuid))!.displayName, 'Renamed');

      // A re-applied create (e.g. a pull echo of an op already applied at
      // flush time) must not revert the rename.
      await appliers.apply(createEnvelope(
          '0192a000-0000-7000-8000-000000000115'));
      expect((await cache.getByUuid(nodeUuid))!.displayName, 'Renamed');
    });

    test('ignores asset/collection/activity ops and legacy v1 ops without failing',
        () async {
      const nodeUuid = '00000000-0000-0000-0000-000000000709';
      final cases = <(String, Map<String, dynamic>)>[
        ('asset.attach', {
          'objectId': nodeUuid,
          'assetId': '00000000-0000-0000-0000-000000000801',
          'hash': 'a' * 64,
          'mimeType': 'image/png',
          'size': 1,
          'originalName': 'a.png',
        }),
        ('asset.detach', {
          'objectId': nodeUuid,
          'assetId': '00000000-0000-0000-0000-000000000801',
        }),
        ('collection.member.add', {
          'collectionId': '00000000-0000-0000-0000-000000000802',
          'objectId': nodeUuid,
        }),
        ('activity.record', {'objectId': nodeUuid}),
        ('link.click', {'objectId': nodeUuid}),
        ('share.public.create', {'objectId': nodeUuid}),
        ('nodeView.create', {'objectId': nodeUuid}),
        ('node.addAlias', {'objectId': nodeUuid}),
        // Legacy v1 ops dropped from the v2 M1 registry: no local apply.
        ('node.archive', {'nodeId': nodeUuid}),
        ('task.recordCompletion', {'nodeId': nodeUuid}),
        ('user.favorite.add', {'nodeId': nodeUuid}),
        // plugin.op carries no target id and is dropped before the switch.
        ('plugin.op', {'pluginId': 'p', 'opType': 'x', 'data': <String, dynamic>{}}),
      ];
      for (var i = 0; i < cases.length; i++) {
        await appliers.apply(envelope(
          id: '0192a000-0000-7000-8000-0000000001${(20 + i).toString().padLeft(2, '0')}',
          opType: cases[i].$1,
          payload: cases[i].$2,
        ));
      }
      // Nothing was written for the unknown node.
      expect(await cache.getByUuid(nodeUuid), isNull);
    });

    test('object.update with only contentDeltaB64 fails loud (Yjs pending)',
        () async {
      const nodeUuid = '00000000-0000-0000-0000-00000000080a';
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000201',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: nodeUuid,
          nodeType: 'page',
        ),
      ));
      expect(
        () async => appliers.apply(envelope(
          id: '0192a000-0000-7000-8000-000000000202',
          opType: 'object.update',
          payload: {
            'objectId': nodeUuid,
            'contentDeltaB64': 'AAAA',
          },
          physical: 2,
        )),
        throwsA(isA<UnsupportedCarrierError>()),
      );
    });

    test('object.delete/move on a missing node throws NodeNotFoundError',
        () async {
      expect(
        () async => appliers.apply(envelope(
          id: '0192a000-0000-7000-8000-000000000203',
          opType: 'object.delete',
          payload: OperationPayloads.objectDelete(
            objectId: '00000000-0000-0000-0000-0000000008ff',
          ),
        )),
        throwsA(isA<NodeNotFoundError>()),
      );
    });

    test('class.setExtends cycle throws and leaves state unchanged', () async {
      const root = '00000000-0000-0000-0000-0000000008c1';
      const leaf = '00000000-0000-0000-0000-0000000008c2';
      for (final (id, classId, name) in [
        ('204', root, 'Root'),
        ('205', leaf, 'Leaf'),
      ]) {
        await appliers.apply(envelope(
          id: '0192a000-0000-7000-8000-0000000002$id',
          opType: 'class.create',
          payload: OperationPayloads.classCreate(classId: classId, name: name),
        ));
      }
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000206',
        opType: 'class.setExtends',
        payload: OperationPayloads.classSetExtends(
          classId: leaf,
          parentClassIds: [root],
        ),
        physical: 2,
      ));
      expect(
        () async => appliers.apply(envelope(
          id: '0192a000-0000-7000-8000-000000000207',
          opType: 'class.setExtends',
          payload: OperationPayloads.classSetExtends(
            classId: root,
            parentClassIds: [leaf],
          ),
          physical: 3,
        )),
        throwsA(isA<CycleError>()),
      );
      final db = await database.database;
      final edges =
          await db.rawQuery('SELECT COUNT(*) AS c FROM class_extends');
      expect(edges.single['c'], 1);
      final rootClosure = await db.rawQuery(
        'SELECT ancestor_id FROM class_hierarchy WHERE class_id = ? ORDER BY ancestor_id',
        [root],
      );
      expect(rootClosure.map((r) => r['ancestor_id']).toList(), [root]);
    });

    test('collection membership is an add-wins OR-Set', () async {
      const collectionId = '00000000-0000-0000-0000-0000000008d1';
      const objectId = '00000000-0000-0000-0000-0000000008d2';
      final add = await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000208',
        opType: 'collection.member.add',
        payload: OperationPayloads.collectionMemberAdd(
          collectionId: collectionId,
          objectId: objectId,
        ),
        physical: 2,
      ));
      expect(add, isTrue);
      // Equal-(hlc, actor) remove loses to the add (add-wins).
      final remove = await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000209',
        opType: 'collection.member.remove',
        payload: OperationPayloads.collectionMemberRemove(
          collectionId: collectionId,
          objectId: objectId,
        ),
        physical: 2,
      ));
      expect(remove, isFalse);
      final db = await database.database;
      final rows = await db.rawQuery(
        'SELECT present FROM collection_member WHERE collection_id = ? AND object_id = ?',
        [collectionId, objectId],
      );
      expect(rows.single['present'], 1);
    });

    test('fractional allocator midpoint matrix (store.ts port)', () {
      expect(RelayAppliers.nextChildPosition(null), 'a');
      expect(RelayAppliers.nextChildPosition('a'), 'aa');
      expect(RelayAppliers.nextChildPosition('aa'), 'aaa');
      expect(RelayAppliers.midpointBetween('a', 'c'), 'b');
      // Adjacent chars descend, then the empty/empty core takes the average
      // of the boundary chars (0x60..0x7b) -> 'm'.
      expect(RelayAppliers.midpointBetween('a', 'b'), 'am');
      expect(RelayAppliers.midpointBetween('a', 'z'), 'm');
      // Same expectations as the monorepo store tests ('a`' is the
      // lexicographic midpoint between 'a' and 'aa').
      expect(RelayAppliers.midpointBetween('a', 'aa'), 'a`');
      expect(RelayAppliers.midpointBetween('aa', 'aaa'), 'aa`');
      expect(RelayAppliers.midpointBetween('a', 'aaa'), 'a`');
    });
  });
}
