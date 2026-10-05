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
        presentAsMain: true,
        classIds: const [classId],
        tagIds: const ['0192a000-0000-7000-8000-0000000000aa'],
        contentAst: const [
          {'type': 'text', 'text': 'hi'},
        ],
        parentId: null,
      );

      expect(payload['objectId'], objectId);
      expect(payload['presentAsMain'], isTrue);
      expect(payload['classIds'], [classId]);
      expect(payload['tagIds'], ['0192a000-0000-7000-8000-0000000000aa']);
      expect(payload['contentAst'], hasLength(1));
      expect(payload['parentId'], isNull);
      expect(payload.containsKey('name'), isFalse);
      expect(() => OperationPayloads.validatePayload('object.create', payload),
          returnsNormally);
    });

    test('object.create defaults classIds and tagIds to empty', () {
      final payload = OperationPayloads.objectCreate(objectId: objectId);
      expect(payload['classIds'], isEmpty);
      expect(payload['tagIds'], isEmpty);
      expect(payload.containsKey('presentAsMain'), isFalse);
    });

    test('object.create emits the render bit when given', () {
      final payload = OperationPayloads.objectCreate(
        objectId: objectId,
        presentAsMain: false,
        parentId: classId,
      );
      expect(payload['presentAsMain'], isFalse);
      expect(() => OperationPayloads.validatePayload('object.create', payload),
          returnsNormally);
    });

    test('object.create name convenience converts to a single text token', () {
      final payload =
          OperationPayloads.objectCreate(objectId: objectId, name: 'A page');
      expect(payload['contentAst'], [
        {'type': 'text', 'text': 'A page'},
      ]);
      expect(payload.containsKey('name'), isFalse);
      expect(() => OperationPayloads.validatePayload('object.create', payload),
          returnsNormally);
    });

    test('object.create contentAst wins over the name convenience', () {
      final payload = OperationPayloads.objectCreate(
        objectId: objectId,
        name: 'dropped',
        contentAst: const [
          {'type': 'text', 'text': 'kept'},
        ],
      );
      expect(payload['contentAst'], [
        {'type': 'text', 'text': 'kept'},
      ]);
      expect(payload.containsKey('name'), isFalse);
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

    test('class.create name convenience converts to contentAst', () {
      final payload = OperationPayloads.classCreate(
        classId: classId,
        name: 'Genre',
      );
      expect(payload['contentAst'], [
        {'type': 'text', 'text': 'Genre'},
      ]);
      expect(payload.containsKey('name'), isFalse);
      expect(() => OperationPayloads.validatePayload('class.create', payload),
          returnsNormally);
    });

    test('class.update accepts contentAst and keeps other fields', () {
      final payload = OperationPayloads.classUpdate(
        classId: classId,
        contentAst: const [
          {'type': 'text', 'text': 'Renamed class'},
        ],
        color: '#5B7D5B',
      );
      expect(payload['contentAst'], hasLength(1));
      expect(payload['color'], '#5B7D5B');
      expect(() => OperationPayloads.validatePayload('class.update', payload),
          returnsNormally);
    });

    test('class.reorder carries objectId and the full ordered classIds', () {
      final payload = OperationPayloads.classReorder(
        objectId: objectId,
        classIds: const [classId, '0192a000-0000-7000-8000-0000000000b1'],
      );
      expect(payload['objectId'], objectId);
      expect(payload['classIds'], hasLength(2));
      expect(payload.containsKey('tagIds'), isFalse);
      expect(() => OperationPayloads.validatePayload('class.reorder', payload),
          returnsNormally);
      expect(OperationPayloads.isKnownOpType('class.reorder'), isTrue);
    });

    test('tag.unassign carries objectId and tagId', () {
      final payload = OperationPayloads.tagUnassign(
        objectId: objectId,
        tagId: classId,
      );
      expect(payload, {'objectId': objectId, 'tagId': classId});
      expect(() => OperationPayloads.validatePayload('tag.unassign', payload),
          returnsNormally);
      expect(OperationPayloads.isKnownOpType('tag.unassign'), isTrue);
    });

    test('object.delete defaults permanent to false', () {
      final payload = OperationPayloads.objectDelete(objectId: objectId);
      expect(payload['permanent'], isFalse);
    });

    test('object.move keeps a null parentId (workspace root; parentless '
        'non-class nodes render with document chrome)', () {
      final payload =
          OperationPayloads.objectMove(objectId: objectId, parentId: null);
      expect(payload['parentId'], isNull);
      expect(payload.containsKey('afterId'), isFalse);
      expect(payload.containsKey('beforeId'), isFalse);
    });

    test('object.move carries the sibling placement anchors', () {
      final payload = OperationPayloads.objectMove(
        objectId: objectId,
        parentId: classId,
        afterId: '0192a000-0000-7000-8000-0000000000b1',
        beforeId: '0192a000-0000-7000-8000-0000000000b2',
      );
      expect(payload['afterId'], '0192a000-0000-7000-8000-0000000000b1');
      expect(payload['beforeId'], '0192a000-0000-7000-8000-0000000000b2');
      expect(() => OperationPayloads.validatePayload('object.move', payload),
          returnsNormally);
    });

    test('object.create carries the sibling placement anchors', () {
      final payload = OperationPayloads.objectCreate(
        objectId: objectId,
        parentId: classId,
        afterId: '0192a000-0000-7000-8000-0000000000b1',
        beforeId: '0192a000-0000-7000-8000-0000000000b2',
      );
      expect(payload['afterId'], '0192a000-0000-7000-8000-0000000000b1');
      expect(payload['beforeId'], '0192a000-0000-7000-8000-0000000000b2');
      expect(() => OperationPayloads.validatePayload('object.create', payload),
          returnsNormally);

      final plain =
          OperationPayloads.objectCreate(objectId: objectId, parentId: classId);
      expect(plain.containsKey('afterId'), isFalse);
      expect(plain.containsKey('beforeId'), isFalse);
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

    test('number formats: create accepts, validates ranges/enum; update keep/clear', () {
      final created = OperationPayloads.propertySchemaCreate(
        propertySchemaId: classId,
        name: 'Dex number',
        type: 'number',
        numberPad: 4,
        numberDecimals: 1,
        numberRounding: 'floor',
      );
      expect(
        () => OperationPayloads.validatePayload('propertySchema.create', created),
        returnsNormally,
      );
      expect(created['numberPad'], 4);
      expect(created['numberDecimals'], 1);
      expect(created['numberRounding'], 'floor');

      // Range and enum enforcement mirror the TS reference.
      expect(
        () => OperationPayloads.validatePayload('propertySchema.create', {
          'propertySchemaId': classId,
          'name': 'x',
          'type': 'number',
          'numberPad': 0,
        }),
        throwsFormatException,
      );
      expect(
        () => OperationPayloads.validatePayload('propertySchema.create', {
          'propertySchemaId': classId,
          'name': 'x',
          'type': 'number',
          'numberDecimals': 11,
        }),
        throwsFormatException,
      );
      expect(
        () => OperationPayloads.validatePayload('propertySchema.create', {
          'propertySchemaId': classId,
          'name': 'x',
          'type': 'number',
          'numberRounding': 'sideways',
        }),
        throwsFormatException,
      );

      // update carries the fields; an explicit null clear validates too.
      final updated = OperationPayloads.propertySchemaUpdate(
        propertySchemaId: classId,
        numberDecimals: 2,
      );
      expect(updated['numberDecimals'], 2);
      expect(
        () => OperationPayloads.validatePayload('propertySchema.update', {
          'propertySchemaId': classId,
          'numberPad': null,
        }),
        returnsNormally,
      );
      // Unknown keys stay rejected (strict validator).
      expect(
        () => OperationPayloads.validatePayload('propertySchema.create', {
          'propertySchemaId': classId,
          'name': 'x',
          'type': 'number',
          'numberPadded': 4,
        }),
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

    test('object payloads reject the retired name key (title-is-content)',
        () {
      expect(
        () => OperationPayloads.validatePayload('object.create', {
          'objectId': objectId,
          'name': 'A page',
        }),
        throwsFormatException,
      );
      expect(
        () => OperationPayloads.validatePayload('object.update', {
          'objectId': objectId,
          'name': 'A page',
        }),
        throwsFormatException,
      );
    });

    test('object payloads reject the retired nodeType key outright '
        '(Revision 11, no legacy replay)', () {
      // The page/block/class enumeration is gone: the render state is
      // is_class + present_as_main, and the old key fails strict validation
      // on BOTH object ops.
      expect(
        () => OperationPayloads.validatePayload('object.create', {
          'objectId': objectId,
          'nodeType': 'page',
        }),
        throwsFormatException,
      );
      expect(
        () => OperationPayloads.validatePayload('object.update', {
          'objectId': objectId,
          'nodeType': 'block',
        }),
        throwsFormatException,
      );
      // presentAsMain validates as a plain bool on both ops.
      for (final opType in ['object.create', 'object.update']) {
        expect(
          () => OperationPayloads.validatePayload(opType, {
            'objectId': objectId,
            'presentAsMain': true,
          }),
          returnsNormally,
        );
        expect(
          () => OperationPayloads.validatePayload(opType, {
            'objectId': objectId,
            'presentAsMain': 'yes',
          }),
          throwsFormatException,
        );
      }
    });

    test('class payloads reject name and accept contentAst', () {
      expect(
        () => OperationPayloads.validatePayload('class.create', {
          'classId': classId,
          'name': 'Genre',
        }),
        throwsFormatException,
      );
      expect(
        () => OperationPayloads.validatePayload('class.update', {
          'classId': classId,
          'name': 'Genre',
        }),
        throwsFormatException,
      );
      expect(
        () => OperationPayloads.validatePayload('class.create', {
          'classId': classId,
          'contentAst': [
            {'type': 'text', 'text': 'Genre'},
          ],
        }),
        returnsNormally,
      );
    });

    test('class.reorder rejects non-uuid class lists', () {
      expect(
        () => OperationPayloads.validatePayload('class.reorder', {
          'objectId': objectId,
          'classIds': ['nope'],
        }),
        throwsFormatException,
      );
    });

    test('sibling anchor fields are accepted on both payloads (uuid-checked)',
        () {
      for (final opType in ['object.create', 'object.move']) {
        expect(
          () => OperationPayloads.validatePayload(opType, {
            'objectId': objectId,
            'parentId': classId,
            'afterId': '0192a000-0000-7000-8000-0000000000b1',
            'beforeId': '0192a000-0000-7000-8000-0000000000b2',
          }),
          returnsNormally,
        );
        expect(
          () => OperationPayloads.validatePayload(opType, {
            'objectId': objectId,
            'parentId': classId,
            'beforeId': 'not-a-uuid',
          }),
          throwsFormatException,
        );
        expect(
          () => OperationPayloads.validatePayload(opType, {
            'objectId': objectId,
            'parentId': classId,
            'afterId': 'not-a-uuid',
          }),
          throwsFormatException,
        );
      }
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
