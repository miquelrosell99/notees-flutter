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

    test('object.create defaults the render bit by placement context', () async {
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

      final root = await cache.getByUuid(rootUuid);
      expect(root!.isPage, isTrue);
      expect(root.presentAsMain, isTrue);
      final child = await cache.getByUuid(childUuid);
      expect(child!.isPage, isFalse);
      expect(child.presentAsMain, isFalse);
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

    test('promoting an inline block to main flattens its rich content '
        '(presentAsMain toggle)', () async {
      const pageUuid = '00000000-0000-0000-0000-000000000105';
      const blockUuid = '00000000-0000-0000-0000-000000000106';

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000f1',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: pageUuid,
        ),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000f2',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: blockUuid,
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
          presentAsMain: true,
        ),
        physical: 3,
      ));

      final node = await cache.getByUuid(blockUuid);
      expect(node!.presentAsMain, isTrue);
      expect(node.isPage, isTrue);
      // The rich stream flattened to a single text-only token (main-
      // presenting nodes carry text-only content) and the display name
      // re-derived from it.
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
        ),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000e9',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: nodeUuid,
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

    test('class.update without description keeps the stored one (TS '
        '`p.description !== undefined` parity)', () async {
      const classUuid = '00000000-0000-0000-0000-000000000303';

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000f1',
        opType: 'class.create',
        payload: OperationPayloads.classCreate(
          classId: classUuid,
          name: 'Genre',
          color: 'pink',
          description: 'A way to shelve books',
        ),
      ));
      Future<String?> storedDescription() async {
        final db = await database.database;
        final rows = await db.rawQuery(
          'SELECT description FROM class_cache WHERE uuid = ?',
          [classUuid],
        );
        return rows.single['description'] as String?;
      }

      expect(await storedDescription(), 'A way to shelve books');

      // A color-only patch (here: an explicit null clear) must not clobber
      // the description — the old unconditional write reset it to NULL.
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000f2',
        opType: 'class.update',
        payload: OperationPayloads.classUpdate(classId: classUuid, color: null),
        physical: 2,
      ));
      expect((await cache.getClassByUuid(classUuid))!.color, isNull);
      expect(await storedDescription(), 'A way to shelve books');

      // A present description still replaces the stored one.
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000f3',
        opType: 'class.update',
        payload: OperationPayloads.classUpdate(
          classId: classUuid,
          description: 'Renamed shelf',
        ),
        physical: 3,
      ));
      expect(await storedDescription(), 'Renamed shelf');
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

    test('object.restore reactivates the subtree and consumes the trash row',
        () async {
      const pageUuid = '00000000-0000-0000-0000-000000000210';
      const childUuid = '00000000-0000-0000-0000-000000000211';
      const grandchildUuid = '00000000-0000-0000-0000-000000000212';
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000210',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(objectId: pageUuid),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000211',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: childUuid,
          parentId: pageUuid,
        ),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000212',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: grandchildUuid,
          parentId: childUuid,
        ),
      ));

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000213',
        opType: 'object.delete',
        payload: OperationPayloads.objectDelete(objectId: pageUuid),
        physical: 2,
      ));
      expect((await cache.getByUuid(grandchildUuid))!.isArchived, isTrue);

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000214',
        opType: 'object.restore',
        payload: OperationPayloads.objectRestore(objectId: pageUuid),
        physical: 3,
      ));
      expect((await cache.getByUuid(pageUuid))!.isArchived, isFalse);
      expect((await cache.getByUuid(childUuid))!.isArchived, isFalse);
      expect((await cache.getByUuid(grandchildUuid))!.isArchived, isFalse);
      expect(await cache.trashRootIds([pageUuid]), isEmpty);
    });

    test('object.restore keeps an independently trashed descendant trashed',
        () async {
      const pageUuid = '00000000-0000-0000-0000-000000000220';
      const childUuid = '00000000-0000-0000-0000-000000000221';
      const siblingUuid = '00000000-0000-0000-0000-000000000222';
      for (final (uuid, idSuffix, parent) in [
        (pageUuid, '20', null),
        (childUuid, '21', pageUuid),
        (siblingUuid, '22', pageUuid),
      ]) {
        await appliers.apply(envelope(
          id: '0192a000-0000-7000-8000-0000000002$idSuffix',
          opType: 'object.create',
          payload: OperationPayloads.objectCreate(
            objectId: uuid,
            parentId: parent,
          ),
        ));
      }
      // The child is trashed on its own first; the parent follows.
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000230',
        opType: 'object.delete',
        payload: OperationPayloads.objectDelete(objectId: childUuid),
        physical: 2,
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000231',
        opType: 'object.delete',
        payload: OperationPayloads.objectDelete(objectId: pageUuid),
        physical: 3,
      ));

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000232',
        opType: 'object.restore',
        payload: OperationPayloads.objectRestore(objectId: pageUuid),
        physical: 4,
      ));
      expect((await cache.getByUuid(pageUuid))!.isArchived, isFalse);
      expect((await cache.getByUuid(siblingUuid))!.isArchived, isFalse);
      expect((await cache.getByUuid(childUuid))!.isArchived, isTrue);
      // Its own trash row survives — a later child restore still works.
      expect(await cache.trashRootIds([childUuid]), isNotEmpty);
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000233',
        opType: 'object.restore',
        payload: OperationPayloads.objectRestore(objectId: childUuid),
        physical: 5,
      ));
      expect((await cache.getByUuid(childUuid))!.isArchived, isFalse);
    });

    test('object.restore reparents to the root when the parent row is gone',
        () async {
      const pageUuid = '00000000-0000-0000-0000-000000000240';
      const childUuid = '00000000-0000-0000-0000-000000000241';
      const grandchildUuid = '00000000-0000-0000-0000-000000000242';
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000240',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(objectId: pageUuid),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000241',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: childUuid,
          parentId: pageUuid,
        ),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000242',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: grandchildUuid,
          parentId: childUuid,
        ),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000243',
        opType: 'object.delete',
        payload: OperationPayloads.objectDelete(objectId: grandchildUuid),
        physical: 2,
      ));
      // Legacy corner: the parent's row disappears after the trash while the
      // trashed node survives with a dangling parent_uuid.
      await cache.deleteByUuid(childUuid);

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000244',
        opType: 'object.restore',
        payload: OperationPayloads.objectRestore(objectId: grandchildUuid),
        physical: 3,
      ));
      final restored = await cache.getByUuid(grandchildUuid);
      expect(restored, isNotNull);
      expect(restored!.isArchived, isFalse);
      expect(restored.parentUuid, isNull);
    });

    test('object.restore on a permanently deleted node throws NodeNotFoundError',
        () async {
      const doomedUuid = '00000000-0000-0000-0000-000000000250';
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000250',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(objectId: doomedUuid),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000251',
        opType: 'object.delete',
        payload: OperationPayloads.objectDelete(
          objectId: doomedUuid,
          permanent: true,
        ),
        physical: 2,
      ));
      expect(
        () => appliers.apply(envelope(
          id: '0192a000-0000-7000-8000-000000000252',
          opType: 'object.restore',
          payload: OperationPayloads.objectRestore(objectId: doomedUuid),
          physical: 3,
        )),
        throwsA(isA<NodeNotFoundError>()),
      );
    });

    test('number formats round-trip; update keeps absent and clears explicit null', () async {
      const schemaUuid = '00000000-0000-0000-0000-0000000004f1';
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000004f1',
        opType: 'propertySchema.create',
        payload: OperationPayloads.propertySchemaCreate(
          propertySchemaId: schemaUuid,
          name: 'Dex number',
          type: 'number',
          numberPad: 4,
          numberDecimals: 1,
          numberRounding: 'floor',
        ),
      ));
      var row = await cache.getPropertySchemaRow(schemaUuid);
      expect(row, isNotNull);
      expect(row!.numberPad, 4);
      expect(row.numberDecimals, 1);
      expect(row.numberRounding, 'floor');

      // Absent keeps (the builder omits nulls — name-only update).
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000004f2',
        opType: 'propertySchema.update',
        payload: OperationPayloads.propertySchemaUpdate(
          propertySchemaId: schemaUuid,
          name: 'Dex #',
        ),
        physical: 2,
      ));
      row = await cache.getPropertySchemaRow(schemaUuid);
      expect(row!.numberPad, 4);
      expect(row.numberDecimals, 1);
      expect(row.numberRounding, 'floor');

      // Explicit null clears (raw payload — the builders omit nulls).
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000004f3',
        opType: 'propertySchema.update',
        payload: {
          'propertySchemaId': schemaUuid,
          'numberDecimals': null,
          'numberRounding': null,
        },
        physical: 3,
      ));
      row = await cache.getPropertySchemaRow(schemaUuid);
      expect(row!.numberPad, 4);
      expect(row.numberDecimals, isNull);
      expect(row.numberRounding, isNull);
    });

    test('§34.90: schema-side render contracts round-trip; update keep/clear',
        () async {
      const schemaUuid = '00000000-0000-0000-0000-0000000004e1';
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000004e1',
        opType: 'propertySchema.create',
        payload: OperationPayloads.propertySchemaCreate(
          propertySchemaId: schemaUuid,
          name: 'Status',
          type: 'select',
          display: 'bullet',
          readonly: true,
          hideWhenEmpty: true,
        ),
      ));
      var row = await cache.getPropertySchemaRow(schemaUuid);
      expect(row!.display, 'bullet');
      expect(row.readonly, isTrue);
      expect(row.hideWhenEmpty, isTrue);

      // Absent keeps (the builders omit nulls — name-only update).
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000004e2',
        opType: 'propertySchema.update',
        payload: OperationPayloads.propertySchemaUpdate(
          propertySchemaId: schemaUuid,
          name: 'Stage',
        ),
        physical: 2,
      ));
      row = await cache.getPropertySchemaRow(schemaUuid);
      expect(row!.display, 'bullet');
      expect(row.readonly, isTrue);
      expect(row.hideWhenEmpty, isTrue);

      // Present values replace; explicit null clears (raw maps — the
      // builders omit nulls, mirroring the number formats keep/clear).
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000004e3',
        opType: 'propertySchema.update',
        payload: {
          'propertySchemaId': schemaUuid,
          'display': 'inline',
          'readonly': null,
          'hideWhenEmpty': null,
        },
        physical: 3,
      ));
      row = await cache.getPropertySchemaRow(schemaUuid);
      expect(row!.display, 'inline');
      expect(row.readonly, isFalse); // null clear lands on the NOT NULL 0
      expect(row.hideWhenEmpty, isFalse);
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

    test('§34.89: option icon rides verbatim through create and the '
        'wholesale options update', () async {
      const schemaUuid = '00000000-0000-0000-0000-0000000004a1';
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000004a1',
        opType: 'propertySchema.create',
        payload: OperationPayloads.propertySchemaCreate(
          propertySchemaId: schemaUuid,
          name: 'Status',
          type: 'select',
          options: const [
            {'id': 'a', 'label': 'Open', 'icon': 'mdiCheckCircle', 'color': 'green'},
            {'id': 'b', 'label': 'Shut'},
          ],
        ),
      ));
      var row = await cache.getPropertySchemaRow(schemaUuid);
      expect(row!.options.first, {
        'id': 'a',
        'label': 'Open',
        'icon': 'mdiCheckCircle',
        'color': 'green',
      });

      // propertySchema.update carries a WHOLESALE options replace — the
      // icons/colors ride verbatim into the stored JSON.
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000004a2',
        opType: 'propertySchema.update',
        payload: OperationPayloads.propertySchemaUpdate(
          propertySchemaId: schemaUuid,
          options: const [
            {'id': 'a', 'label': 'Open', 'icon': 'mdiEyeCircleOutline', 'color': 'blue'},
            {'id': 'c', 'label': 'New', 'icon': 'mdiCircle'},
          ],
        ),
        physical: 2,
      ));
      row = await cache.getPropertySchemaRow(schemaUuid);
      expect(row!.options, [
        {'id': 'a', 'label': 'Open', 'icon': 'mdiEyeCircleOutline', 'color': 'blue'},
        {'id': 'c', 'label': 'New', 'icon': 'mdiCircle'},
      ]);
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
        ),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-0000000000f8',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: nodeUuid,
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
        ),
      ));
      for (final (uuid, suffix) in [(blockA, '102'), (blockB, '103'), (blockC, '104')]) {
        await appliers.apply(envelope(
          id: '0192a000-0000-7000-8000-000000000$suffix',
          opType: 'object.create',
          payload: OperationPayloads.objectCreate(
            objectId: uuid,
            // Parented child that renders in the main-children zone.
            presentAsMain: true,
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
      // The beforeId core: one slot below the first child ('`' < 'a') — the
      // midpoint-against-empty branch the afterId-only algebra cannot
      // express.
      expect(RelayAppliers.midpointBetween('', 'a'), '`');
      expect('`'.compareTo('a'), lessThan(0));
    });

    /// Seeds a page with three blocks at fractional positions 'a', 'aa',
    /// 'aaa' — the allocator matrix's base state (midpoints between them:
    /// 'a`' between x and y, 'aa`' between y and z).
    Future<void> seedPageWithBlocks(
      String pageUuid,
      String blockX,
      String blockY,
      String blockZ,
    ) async {
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000181',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: pageUuid,
        ),
      ));
      for (final (uuid, suffix)
          in [(blockX, '182'), (blockY, '183'), (blockZ, '184')]) {
        await appliers.apply(envelope(
          id: '0192a000-0000-7000-8000-000000000$suffix',
          opType: 'object.create',
          payload: OperationPayloads.objectCreate(
            objectId: uuid,
            // Parented child that renders in the main-children zone.
            presentAsMain: true,
            parentId: pageUuid,
          ),
        ));
      }
    }

    test('beforeId places the node immediately before the anchor (midpoint)',
        () async {
      const pageUuid = '00000000-0000-0000-0000-000000000811';
      const blockX = '00000000-0000-0000-0000-000000000812';
      const blockY = '00000000-0000-0000-0000-000000000813';
      const blockZ = '00000000-0000-0000-0000-000000000814';
      await seedPageWithBlocks(pageUuid, blockX, blockY, blockZ);

      // z jumps the queue to sit right before y: midpoint between x ('a')
      // and y ('aa').
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000185',
        opType: 'object.move',
        payload: OperationPayloads.objectMove(
          objectId: blockZ,
          parentId: pageUuid,
          beforeId: blockY,
        ),
        physical: 5,
      ));
      final z = await cache.getByUuid(blockZ);
      expect(z!.position, 'a`');
      final order = (await cache.getChildren(pageUuid)).map((n) => n.uuid);
      expect(order, [blockX, blockZ, blockY]);
    });

    test('beforeId against the first child yields a position below it',
        () async {
      const pageUuid = '00000000-0000-0000-0000-000000000821';
      const blockX = '00000000-0000-0000-0000-000000000822';
      const blockY = '00000000-0000-0000-0000-000000000823';
      const blockZ = '00000000-0000-0000-0000-000000000824';
      await seedPageWithBlocks(pageUuid, blockX, blockY, blockZ);

      // No previous sibling: midpoint against the empty string — the only
      // slot before the first child.
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000185',
        opType: 'object.move',
        payload: OperationPayloads.objectMove(
          objectId: blockZ,
          parentId: pageUuid,
          beforeId: blockX,
        ),
        physical: 5,
      ));
      final z = await cache.getByUuid(blockZ);
      expect(z!.position, '`');
      expect(z.position!.compareTo('a'), lessThan(0));
      final order = (await cache.getChildren(pageUuid)).map((n) => n.uuid);
      expect(order, [blockZ, blockX, blockY]);
    });

    test('unknown beforeId falls back to a plain append (defensive)',
        () async {
      const pageUuid = '00000000-0000-0000-0000-000000000831';
      const otherPage = '00000000-0000-0000-0000-000000000832';
      const blockX = '00000000-0000-0000-0000-000000000833';
      const blockY = '00000000-0000-0000-0000-000000000834';
      const blockZ = '00000000-0000-0000-0000-000000000835';
      await seedPageWithBlocks(pageUuid, blockX, blockY, blockZ);
      // otherPage is a root page, never a child of pageUuid.
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000185',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: otherPage,
        ),
      ));

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000186',
        opType: 'object.move',
        payload: OperationPayloads.objectMove(
          objectId: blockY,
          parentId: pageUuid,
          beforeId: otherPage,
        ),
        physical: 5,
      ));
      final y = await cache.getByUuid(blockY);
      expect(y!.position, 'aaaa');
      final order = (await cache.getChildren(pageUuid)).map((n) => n.uuid);
      expect(order, [blockX, blockZ, blockY]);
    });

    test('afterId wins when both anchors are present', () async {
      const pageUuid = '00000000-0000-0000-0000-000000000841';
      const blockX = '00000000-0000-0000-0000-000000000842';
      const blockY = '00000000-0000-0000-0000-000000000843';
      const blockZ = '00000000-0000-0000-0000-000000000844';
      await seedPageWithBlocks(pageUuid, blockX, blockY, blockZ);

      // afterId is looked up first: append-after-z wins over before-y.
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000185',
        opType: 'object.move',
        payload: OperationPayloads.objectMove(
          objectId: blockX,
          parentId: pageUuid,
          afterId: blockZ,
          beforeId: blockY,
        ),
        physical: 5,
      ));
      final x = await cache.getByUuid(blockX);
      expect(x!.position, 'aaaa');
      final order = (await cache.getChildren(pageUuid)).map((n) => n.uuid);
      expect(order, [blockY, blockZ, blockX]);
    });

    test('an unknown afterId falls through to a valid beforeId', () async {
      const pageUuid = '00000000-0000-0000-0000-000000000851';
      const otherPage = '00000000-0000-0000-0000-000000000852';
      const blockX = '00000000-0000-0000-0000-000000000853';
      const blockY = '00000000-0000-0000-0000-000000000854';
      const blockZ = '00000000-0000-0000-0000-000000000855';
      await seedPageWithBlocks(pageUuid, blockX, blockY, blockZ);
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000185',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: otherPage,
        ),
      ));

      // afterId is not a current sibling, so the afterId branch yields
      // nothing and the beforeId branch places y before x.
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000186',
        opType: 'object.move',
        payload: OperationPayloads.objectMove(
          objectId: blockY,
          parentId: pageUuid,
          afterId: otherPage,
          beforeId: blockX,
        ),
        physical: 5,
      ));
      final y = await cache.getByUuid(blockY);
      expect(y!.position, '`');
      final order = (await cache.getChildren(pageUuid)).map((n) => n.uuid);
      expect(order, [blockY, blockX, blockZ]);
    });

    test('object.create honors beforeId for its initial placement', () async {
      const pageUuid = '00000000-0000-0000-0000-000000000861';
      const blockX = '00000000-0000-0000-0000-000000000862';
      const blockY = '00000000-0000-0000-0000-000000000863';
      const blockZ = '00000000-0000-0000-0000-000000000864';
      const blockW = '00000000-0000-0000-0000-000000000865';
      await seedPageWithBlocks(pageUuid, blockX, blockY, blockZ);

      // Create placement anchors next to a current sibling: w lands
      // immediately before x — one slot below the first child.
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000185',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: blockW,
          parentId: pageUuid,
          beforeId: blockX,
        ),
      ));
      final w = await cache.getByUuid(blockW);
      expect(w!.position, '`');
      final order = (await cache.getChildren(pageUuid)).map((n) => n.uuid);
      expect(order, [blockW, blockX, blockY, blockZ]);
    });

    test('demoting a main child to inline never un-flattens its content',
        () async {
      const pageUuid = '00000000-0000-0000-0000-000000000871';
      const childUuid = '00000000-0000-0000-0000-000000000872';

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000191',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(objectId: pageUuid),
      ));
      // A parented create with the bit set: a main child (document chrome
      // when zoomed), content flattened at create.
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000192',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: childUuid,
          presentAsMain: true,
          parentId: pageUuid,
          contentAst: const [
            {'type': 'text', 'text': 'Notes: '},
            {
              'type': 'mention',
              'targetNodeId': '00000000-0000-0000-0000-000000000199',
              'text': 'ref',
            },
          ],
        ),
        physical: 2,
      ));
      expect((await cache.getByUuid(childUuid))!.isPage, isTrue);

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000193',
        opType: 'object.update',
        payload: OperationPayloads.objectUpdate(
          objectId: childUuid,
          presentAsMain: false,
        ),
        physical: 3,
      ));

      final node = await cache.getByUuid(childUuid);
      expect(node!.presentAsMain, isFalse);
      expect(node.isPage, isFalse);
      // Demotion does NOT un-flatten: the stored text-only content survives.
      expect(jsonDecode(node.name), [
        {'type': 'text', 'text': 'Notes: ref'},
      ]);
    });

    test('class parents are legal: a non-class child of a class (spec I4)',
        () async {
      const classUuid = '00000000-0000-0000-0000-000000000881';
      const childUuid = '00000000-0000-0000-0000-000000000882';

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000194',
        opType: 'class.create',
        payload: OperationPayloads.classCreate(
          classId: classUuid,
          name: 'Projects',
        ),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000195',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: childUuid,
          parentId: classUuid,
          contentAst: AstBuilder.parseInline('Child of a class'),
        ),
        physical: 2,
      ));

      final child = await cache.getByUuid(childUuid);
      expect(child, isNotNull);
      expect(child!.parentUuid, classUuid);
      expect(child.isClass, isFalse);
      // Parented ⇒ inline by default (class children are ordinary body
      // blocks unless the bit says main).
      expect(child.presentAsMain, isFalse);
    });

    test('moving a class under any parent fails loud (classes are always '
        'roots)', () async {
      const classUuid = '00000000-0000-0000-0000-000000000883';
      const pageUuid = '00000000-0000-0000-0000-000000000884';

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000196',
        opType: 'class.create',
        payload: OperationPayloads.classCreate(
          classId: classUuid,
          name: 'Pinned',
        ),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000197',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(objectId: pageUuid),
        physical: 2,
      ));

      // Classes have no local node row (class_cache is their home) — the
      // guard must still surface as a typed MoveGuardError, not a
      // missing-node error.
      expect(
        () async => appliers.apply(envelope(
          id: '0192a000-0000-7000-8000-000000000198',
          opType: 'object.move',
          payload: OperationPayloads.objectMove(
            objectId: classUuid,
            parentId: pageUuid,
          ),
          physical: 3,
        )),
        throwsA(isA<MoveGuardError>()),
      );
    });

    test('moving an inline block to the workspace root is legal (parentless '
        '⇒ document chrome)', () async {
      const pageUuid = '00000000-0000-0000-0000-000000000885';
      const blockUuid = '00000000-0000-0000-0000-000000000886';

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000199',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(objectId: pageUuid),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-00000000019a',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: blockUuid,
          parentId: pageUuid,
          contentAst: AstBuilder.parseInline('Floating'),
        ),
        physical: 2,
      ));
      expect((await cache.getByUuid(blockUuid))!.isPage, isFalse);

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-00000000019b',
        opType: 'object.move',
        payload: OperationPayloads.objectMove(
          objectId: blockUuid,
          parentId: null,
        ),
        physical: 3,
      ));

      final node = await cache.getByUuid(blockUuid);
      expect(node!.parentUuid, isNull);
      // The move never writes the render bit; the parentless landing
      // renders with document chrome by the second cascade branch.
      expect(node.isPage, isTrue);
      expect(node.presentAsMain, isFalse);
      // Moving under a parent again keeps the stored bit (inline).
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-00000000019c',
        opType: 'object.move',
        payload: OperationPayloads.objectMove(
          objectId: blockUuid,
          parentId: pageUuid,
        ),
        physical: 4,
      ));
      final back = await cache.getByUuid(blockUuid);
      expect(back!.parentUuid, pageUuid);
      expect(back.presentAsMain, isFalse);
      expect(back.isPage, isFalse);
    });

    test('a main child and an inline child partition a parent by the one '
        'render bit', () async {
      const pageUuid = '00000000-0000-0000-0000-000000000887';
      const mainChild = '00000000-0000-0000-0000-000000000888';
      const inlineChild = '00000000-0000-0000-0000-000000000889';

      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-00000000019d',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(objectId: pageUuid),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-00000000019e',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: mainChild,
          presentAsMain: true,
          parentId: pageUuid,
          contentAst: AstBuilder.parseInline('Main zone'),
        ),
        physical: 2,
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-00000000019f',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: inlineChild,
          parentId: pageUuid,
          contentAst: AstBuilder.parseInline('Body'),
        ),
        physical: 3,
      ));

      final children = await cache.getChildren(pageUuid);
      expect(children.map((n) => n.uuid).toList(), [mainChild, inlineChild]);
      final main = children.firstWhere((n) => n.uuid == mainChild);
      final inline = children.firstWhere((n) => n.uuid == inlineChild);
      expect(main.presentAsMain, isTrue);
      expect(main.isPage, isTrue);
      expect(inline.presentAsMain, isFalse);
      expect(inline.isPage, isFalse);
    });

    test('the retired nodeType payload key is rejected outright (strict '
        'validator, no legacy replay)', () async {
      const nodeUuid = '00000000-0000-0000-0000-00000000088a';

      // Direct validator surface.
      expect(
        () => OperationPayloads.validatePayload('object.create', {
          'objectId': nodeUuid,
          'nodeType': 'page',
        }),
        throwsFormatException,
      );
      expect(
        () => OperationPayloads.validatePayload('object.update', {
          'objectId': nodeUuid,
          'nodeType': 'block',
        }),
        throwsFormatException,
      );

      // Applier surface: an envelope carrying the retired key fails loud
      // before touching state.
      expect(
        () async => appliers.apply(envelope(
          id: '0192a000-0000-7000-8000-0000000001a1',
          opType: 'object.create',
          payload: {
            'objectId': nodeUuid,
            'nodeType': 'page',
            'classIds': <String>[],
          },
        )),
        throwsA(isA<EnvelopeValidationError>()),
      );
      expect(await cache.getByUuid(nodeUuid), isNull);
    });
  });
}
