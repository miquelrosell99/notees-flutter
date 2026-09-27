import 'package:flutter_test/flutter_test.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';

/// Unit tests for the v2 op payload factories and their strict validation
/// (the Dart port of `v2/packages/protocol/src/op-types.ts`).
void main() {
  const objectId = '0192a000-0000-7000-8000-000000000010';
  const classId = '0192a000-0000-7000-8000-0000000000c5';

  group('factories emit registry-valid payloads', () {
    test('object.create carries v2 field names', () {
      final payload = OperationPayloads.objectCreate(
        objectId: objectId,
        nodeType: 'page',
        classIds: const [classId],
        name: 'A page',
        contentAst: const [
          {'type': 'text', 'text': 'hi'},
        ],
        parentId: null,
      );

      expect(payload['objectId'], objectId);
      expect(payload['nodeType'], 'page');
      expect(payload['classIds'], [classId]);
      expect(payload['name'], 'A page');
      expect(payload['contentAst'], hasLength(1));
      expect(payload['parentId'], isNull);
      expect(() => OperationPayloads.validatePayload('object.create', payload),
          returnsNormally);
    });

    test('object.create defaults classIds to empty', () {
      final payload = OperationPayloads.objectCreate(objectId: objectId);
      expect(payload['classIds'], isEmpty);
      expect(payload.containsKey('nodeType'), isFalse);
    });

    test('object.update requires at least one field', () {
      expect(() => OperationPayloads.objectUpdate(objectId: objectId),
          throwsArgumentError);
      expect(
        () => OperationPayloads.validatePayload(
            'object.update', {'objectId': objectId}),
        throwsFormatException,
      );
    });

    test('object.update rejects two content carriers', () {
      expect(
        () => OperationPayloads.objectUpdate(
          objectId: objectId,
          contentAst: const [
            {'type': 'text', 'text': 'x'},
          ],
          contentDeltaB64: 'AAAA',
        ),
        throwsArgumentError,
      );
    });

    test('object.delete defaults permanent to false', () {
      final payload = OperationPayloads.objectDelete(objectId: objectId);
      expect(payload['permanent'], isFalse);
    });

    test('object.move keeps a null parentId (workspace root, pages only)', () {
      final payload =
          OperationPayloads.objectMove(objectId: objectId, parentId: null);
      expect(payload['parentId'], isNull);
      expect(payload.containsKey('afterId'), isFalse);
    });

    test('class.setExtends carries parentClassIds (replace semantics)', () {
      final payload = OperationPayloads.classSetExtends(
        classId: classId,
        parentClassIds: const [objectId],
      );
      expect(payload['parentClassIds'], [objectId]);
      expect(payload.containsKey('extendsClassIds'), isFalse);
    });

    test('property.set carries objectId/propertySchemaId/idx/metadata', () {
      final payload = OperationPayloads.propertySet(
        objectId: objectId,
        propertySchemaId: classId,
        value: const {'nodeId': objectId},
        metadata: const {'since': '1962'},
      );
      expect(payload['objectId'], objectId);
      expect(payload['propertySchemaId'], classId);
      expect(payload['idx'], 0);
      expect(payload['metadata'], {'since': '1962'});
      expect(payload.containsKey('propertyValueId'), isFalse);
      expect(payload.containsKey('nodeId'), isFalse);
    });

    test('propertySchema.create validates the type enum', () {
      final payload = OperationPayloads.propertySchemaCreate(
        propertySchemaId: classId,
        name: 'Status',
        type: 'select',
        options: const [
          {'id': 'a', 'label': 'Open'},
        ],
      );
      expect(() =>
          OperationPayloads.validatePayload('propertySchema.create', payload),
          returnsNormally);
      expect(
        () => OperationPayloads.propertySchemaCreate(
          propertySchemaId: classId,
          name: 'Status',
          type: 'selection',
        ),
        throwsFormatException,
      );
    });

    test('asset.attach enforces the 64-char hash', () {
      expect(
        () => OperationPayloads.assetAttach(
          objectId: objectId,
          assetId: classId,
          hash: 'abc',
          mimeType: 'image/png',
          size: 3,
          originalName: 'a.png',
        ),
        throwsFormatException,
      );
    });

    test('collection membership ops carry collectionId/objectId', () {
      final payload = OperationPayloads.collectionMemberAdd(
        collectionId: classId,
        objectId: objectId,
      );
      expect(() => OperationPayloads.validatePayload(
          'collection.member.add', payload), returnsNormally);
    });
  });

  group('strict validation (zod .strict() parity)', () {
    test('unknown payload keys are rejected', () {
      expect(
        () => OperationPayloads.validatePayload('object.delete', {
          'objectId': objectId,
          'permanent': true,
          'nodeId': objectId,
        }),
        throwsFormatException,
      );
    });

    test('snake_case payload keys are rejected', () {
      expect(
        () => OperationPayloads.validatePayload('property.set', {
          'object_id': objectId,
          'property_schema_id': classId,
          'value': 1,
        }),
        throwsFormatException,
      );
    });

    test('non-uuid ids are rejected', () {
      expect(
        () => OperationPayloads.validatePayload('object.delete', {
          'objectId': 'not-a-uuid',
          'permanent': true,
        }),
        throwsFormatException,
      );
    });

    test('negative idx is rejected', () {
      expect(
        () => OperationPayloads.validatePayload('property.set', {
          'objectId': objectId,
          'propertySchemaId': classId,
          'value': 1,
          'idx': -1,
        }),
        throwsFormatException,
      );
    });

    test('unknown op type is rejected', () {
      expect(
        () => OperationPayloads.validatePayload('node.archive', {
          'nodeId': objectId,
        }),
        throwsFormatException,
      );
      expect(OperationPayloads.isKnownOpType('node.archive'), isFalse);
      expect(OperationPayloads.isKnownOpType('object.create'), isTrue);
    });
  });
}
