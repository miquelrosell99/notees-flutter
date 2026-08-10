import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/constants/system.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:notees/core/utils/ast_builder.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/domain/services/relay_appliers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('RelayAppliers against SQLite', () {
    late NodeCacheRepository cache;
    late RelayAppliers appliers;

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

    test('applies node.create with class flags', () async {
      final nodeUuid = '00000000-0000-0000-0000-000000000101';
      final content = AstBuilder.parseInline('Daily journal');
      final envelope = OperationEnvelope(
        id: 'e1',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 1, logical: 0),
        affectedNodeIds: [nodeUuid],
        opType: 'node.create',
        payload: OperationPayloads.nodeCreate(
          nodeId: nodeUuid,
          kind: 'page',
          classIds: [SystemClassUuids.day],
          initialContent: content,
        ),
        timestamp: '2026-08-09T12:00:00.000Z',
      );

      await appliers.apply(envelope);
      final node = await cache.getByUuid(nodeUuid);

      expect(node, isNotNull);
      expect(node!.uuid, nodeUuid);
      expect(node.displayName, 'Daily journal');
      expect(node.classesUuid, [SystemClassUuids.day]);
      expect(node.isDaily, isTrue);
      expect(node.isTask, isFalse);
    });

    test('applies property.set on existing node', () async {
      final nodeUuid = '00000000-0000-0000-0000-000000000102';
      final createEnvelope = OperationEnvelope(
        id: 'e1',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 1, logical: 0),
        affectedNodeIds: [nodeUuid],
        opType: 'node.create',
        payload: OperationPayloads.nodeCreate(
          nodeId: nodeUuid,
          kind: 'block',
          classIds: [SystemClassUuids.task],
        ),
      );
      final propertyEnvelope = OperationEnvelope(
        id: 'e2',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 2, logical: 0),
        affectedNodeIds: [nodeUuid],
        opType: 'property.set',
        payload: OperationPayloads.propertySet(
          propertyValueId: 'pv-1',
          nodeId: nodeUuid,
          schemaId: SystemPropertyUuids.taskDeadline,
          value: '2026-08-10',
        ),
      );

      await appliers.apply(createEnvelope);
      await appliers.apply(propertyEnvelope);
      final node = await cache.getByUuid(nodeUuid);

      expect(node, isNotNull);
      expect(node!.properties[SystemPropertyUuids.taskDeadline], '2026-08-10');
    });

    test('applies class.assign and recomputes flags', () async {
      final nodeUuid = '00000000-0000-0000-0000-000000000103';
      final createEnvelope = OperationEnvelope(
        id: 'e1',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 1, logical: 0),
        affectedNodeIds: [nodeUuid],
        opType: 'node.create',
        payload: OperationPayloads.nodeCreate(
          nodeId: nodeUuid,
          kind: 'block',
        ),
      );
      final assignEnvelope = OperationEnvelope(
        id: 'e2',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 2, logical: 0),
        affectedNodeIds: [nodeUuid],
        opType: 'class.assign',
        payload: OperationPayloads.classAssign(
          nodeId: nodeUuid,
          classId: SystemClassUuids.task,
        ),
      );

      await appliers.apply(createEnvelope);
      await appliers.apply(assignEnvelope);
      final node = await cache.getByUuid(nodeUuid);

      expect(node, isNotNull);
      expect(node!.classesUuid, contains(SystemClassUuids.task));
      expect(node.isTask, isTrue);
    });

    test('applies class.create, update, setExtends and delete', () async {
      final classUuid = '00000000-0000-0000-0000-000000000301';
      final parentUuid = '00000000-0000-0000-0000-000000000302';

      final createEnvelope = OperationEnvelope(
        id: 'e1',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 1, logical: 0),
        affectedNodeIds: [classUuid],
        opType: 'class.create',
        payload: OperationPayloads.classCreate(
          classId: classUuid,
          name: 'Project',
          color: '#5B7D5B',
        ),
      );
      final setExtendsEnvelope = OperationEnvelope(
        id: 'e2',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 2, logical: 0),
        affectedNodeIds: [classUuid],
        opType: 'class.setExtends',
        payload: OperationPayloads.classSetExtends(
          classId: classUuid,
          extendsClassIds: [parentUuid],
        ),
      );
      final updateEnvelope = OperationEnvelope(
        id: 'e3',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 3, logical: 0),
        affectedNodeIds: [classUuid],
        opType: 'class.update',
        payload: OperationPayloads.classUpdate(
          classId: classUuid,
          icon: 'folder',
        ),
      );

      await appliers.apply(createEnvelope);
      var cls = await cache.getClassByUuid(classUuid);
      expect(cls, isNotNull);
      expect(cls!.displayName, 'Project');
      expect(cls.color, '#5B7D5B');

      await appliers.apply(setExtendsEnvelope);
      cls = await cache.getClassByUuid(classUuid);
      // Extends are stored separately; the cached class row still exposes name/color.
      expect(cls, isNotNull);

      await appliers.apply(updateEnvelope);
      cls = await cache.getClassByUuid(classUuid);
      expect(cls!.icon, 'folder');

      final deleteEnvelope = OperationEnvelope(
        id: 'e4',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 4, logical: 0),
        affectedNodeIds: [classUuid],
        opType: 'class.delete',
        payload: OperationPayloads.classDelete(classId: classUuid),
      );
      await appliers.apply(deleteEnvelope);
      cls = await cache.getClassByUuid(classUuid);
      expect(cls, isNull);
    });

    test('applies node.archive and node.restore to isArchived flag', () async {
      final nodeUuid = '00000000-0000-0000-0000-000000000104';
      final createEnvelope = OperationEnvelope(
        id: 'e1',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 1, logical: 0),
        affectedNodeIds: [nodeUuid],
        opType: 'node.create',
        payload: OperationPayloads.nodeCreate(
          nodeId: nodeUuid,
          kind: 'page',
        ),
      );
      final archiveEnvelope = OperationEnvelope(
        id: 'e2',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 2, logical: 0),
        affectedNodeIds: [nodeUuid],
        opType: 'node.archive',
        payload: OperationPayloads.nodeArchive(nodeId: nodeUuid),
      );
      final restoreEnvelope = OperationEnvelope(
        id: 'e3',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 3, logical: 0),
        affectedNodeIds: [nodeUuid],
        opType: 'node.restore',
        payload: OperationPayloads.nodeRestore(nodeId: nodeUuid),
      );

      await appliers.apply(createEnvelope);
      await appliers.apply(archiveEnvelope);
      var node = await cache.getByUuid(nodeUuid);
      expect(node, isNotNull);
      expect(node!.isArchived, isTrue);

      await appliers.apply(restoreEnvelope);
      node = await cache.getByUuid(nodeUuid);
      expect(node, isNotNull);
      expect(node!.isArchived, isFalse);
    });

    test('applies task.recordCompletion and task.deleteCompletion', () async {
      final nodeUuid = '00000000-0000-0000-0000-000000000105';
      final completionId = '00000000-0000-0000-0000-000000000201';
      final createEnvelope = OperationEnvelope(
        id: 'e1',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 1, logical: 0),
        affectedNodeIds: [nodeUuid],
        opType: 'node.create',
        payload: OperationPayloads.nodeCreate(
          nodeId: nodeUuid,
          kind: 'block',
          classIds: [SystemClassUuids.task],
        ),
      );
      final recordEnvelope = OperationEnvelope(
        id: 'e2',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 2, logical: 0),
        affectedNodeIds: [nodeUuid],
        opType: 'task.recordCompletion',
        payload: OperationPayloads.taskRecordCompletion(
          nodeId: nodeUuid,
          completionId: completionId,
          completedAt: '2026-08-09T12:00:00.000Z',
          scheduledDate: '2026-08-09',
          deadlineDate: '2026-08-10',
          status: 'done',
        ),
      );
      final deleteEnvelope = OperationEnvelope(
        id: 'e3',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 3, logical: 0),
        affectedNodeIds: [nodeUuid],
        opType: 'task.deleteCompletion',
        payload: OperationPayloads.taskDeleteCompletion(
          nodeId: nodeUuid,
          completionId: completionId,
        ),
      );

      await appliers.apply(createEnvelope);
      await appliers.apply(recordEnvelope);

      var mostRecentId = await cache.getMostRecentTaskCompletionId(nodeUuid);
      expect(mostRecentId, completionId);

      await appliers.apply(deleteEnvelope);

      mostRecentId = await cache.getMostRecentTaskCompletionId(nodeUuid);
      expect(mostRecentId, isNull);
    });

    test('applies propertySchema.create/update/delete', () async {
      final schemaUuid = '00000000-0000-0000-0000-000000000401';
      final createEnvelope = OperationEnvelope(
        id: 'e1',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 1, logical: 0),
        affectedNodeIds: [schemaUuid],
        opType: 'propertySchema.create',
        payload: OperationPayloads.propertySchemaCreate(
          schemaId: schemaUuid,
          name: 'Priority',
          type: 'selection',
          options: [
            {'id': 0, 'name': 'Low'},
            {'id': 1, 'name': 'High'},
          ],
        ),
      );

      await appliers.apply(createEnvelope);
      var property = await cache.getPropertySchema(schemaUuid);
      expect(property, isNotNull);
      expect(property!.name, 'Priority');
      expect(property.type, 'selection');
      expect(property.options.length, 2);

      final updateEnvelope = OperationEnvelope(
        id: 'e2',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 2, logical: 0),
        affectedNodeIds: [schemaUuid],
        opType: 'propertySchema.update',
        payload: OperationPayloads.propertySchemaUpdate(
          schemaId: schemaUuid,
          name: 'Importance',
        ),
      );
      await appliers.apply(updateEnvelope);
      property = await cache.getPropertySchema(schemaUuid);
      expect(property!.name, 'Importance');

      final deleteEnvelope = OperationEnvelope(
        id: 'e3',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 3, logical: 0),
        affectedNodeIds: [schemaUuid],
        opType: 'propertySchema.delete',
        payload: OperationPayloads.propertySchemaDelete(schemaId: schemaUuid),
      );
      await appliers.apply(deleteEnvelope);
      property = await cache.getPropertySchema(schemaUuid);
      expect(property, isNull);
    });

    test('applies classPropertyEdge.create/update/delete/reorder', () async {
      final classUuid = '00000000-0000-0000-0000-000000000501';
      final schemaUuid = '00000000-0000-0000-0000-000000000502';

      await cache.upsertClass(
        uuid: classUuid,
        name: 'Project',
      );
      await appliers.apply(OperationEnvelope(
        id: 'e1',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 1, logical: 0),
        affectedNodeIds: [schemaUuid],
        opType: 'propertySchema.create',
        payload: OperationPayloads.propertySchemaCreate(
          schemaId: schemaUuid,
          name: 'Owner',
          type: 'text',
        ),
      ));

      final createEdgeEnvelope = OperationEnvelope(
        id: 'e2',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 2, logical: 0),
        affectedNodeIds: [classUuid, schemaUuid],
        opType: 'classPropertyEdge.create',
        payload: OperationPayloads.classPropertyEdgeCreate(
          classId: classUuid,
          propertySchemaId: schemaUuid,
          sequence: 0,
          required: true,
        ),
      );
      await appliers.apply(createEdgeEnvelope);
      var classProperties = await cache.getClassProperties(classUuid);
      expect(classProperties.length, 1);
      expect(classProperties.first.propertyName, 'Owner');
      expect(classProperties.first.required, isTrue);

      final updateEdgeEnvelope = OperationEnvelope(
        id: 'e3',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 3, logical: 0),
        affectedNodeIds: [classUuid, schemaUuid],
        opType: 'classPropertyEdge.update',
        payload: OperationPayloads.classPropertyEdgeUpdate(
          classId: classUuid,
          propertySchemaId: schemaUuid,
          required: false,
        ),
      );
      await appliers.apply(updateEdgeEnvelope);
      classProperties = await cache.getClassProperties(classUuid);
      expect(classProperties.first.required, isFalse);

      final reorderEnvelope = OperationEnvelope(
        id: 'e4',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 4, logical: 0),
        affectedNodeIds: [classUuid, schemaUuid],
        opType: 'classPropertyEdge.reorder',
        payload: OperationPayloads.classPropertyEdgeReorder(
          classId: classUuid,
          orderedPropertySchemaIds: [schemaUuid],
        ),
      );
      await appliers.apply(reorderEnvelope);
      classProperties = await cache.getClassProperties(classUuid);
      expect(classProperties.first.sequence, 0);

      final deleteEdgeEnvelope = OperationEnvelope(
        id: 'e5',
        workspaceId: 'ws',
        actorId: 'a',
        hlc: Hlc(physical: 5, logical: 0),
        affectedNodeIds: [classUuid, schemaUuid],
        opType: 'classPropertyEdge.delete',
        payload: OperationPayloads.classPropertyEdgeDelete(
          classId: classUuid,
          propertySchemaId: schemaUuid,
        ),
      );
      await appliers.apply(deleteEdgeEnvelope);
      classProperties = await cache.getClassProperties(classUuid);
      expect(classProperties, isEmpty);
    });
  });
}
