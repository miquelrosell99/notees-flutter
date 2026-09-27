import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/constants/system.dart';
import 'package:notees/core/utils/ast_builder.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/domain/services/relay_appliers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('RelayAppliers (v2 registry) against SQLite', () {
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
      final db = AppDatabase.fromDatabase(ffiDb);
      await db.initializeSchema();
      cache = NodeCacheRepository(db);
      appliers = RelayAppliers(cache);
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

    test('applies object.update name and icon/color upserts', () async {
      const nodeUuid = '00000000-0000-0000-0000-000000000104';

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000e6',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: nodeUuid,
          nodeType: 'page',
        ),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000e7',
        opType: 'object.update',
        payload: OperationPayloads.objectUpdate(
          objectId: nodeUuid,
          name: 'Renamed',
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
      expect(node!.displayName, 'Renamed');
      expect(node.icon, 'folder');
      expect(node.color, '#5B7D5B');
    });

    test('applies property.set and property.unset by propertySchemaId',
        () async {
      const nodeUuid = '00000000-0000-0000-0000-000000000102';

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000e9',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: nodeUuid,
          nodeType: 'block',
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
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000f8',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: nodeUuid,
          nodeType: 'block',
          classIds: [SystemClassUuids.task],
          contentAst: AstBuilder.parseInline('Doomed'),
        ),
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

      // Place B immediately after A inside the page: with A at sequence 0
      // and no further siblings, B lands at sequence 1.
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
      expect(c.sequence, 1.0);
      final order = (await cache.getChildren(pageUuid)).map((n) => n.uuid);
      expect(order, [blockA, blockB]);
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
  });
}
