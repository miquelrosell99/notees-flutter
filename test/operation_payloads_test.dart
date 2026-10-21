import 'package:flutter_test/flutter_test.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';

/// Unit tests for the op payload factories and their strict validation
/// (the Dart port of `packages/protocol/src/op-types.ts`).
void main() {
  const objectId = '0192a000-0000-7000-8000-000000000010';
  const classId = '0192a000-0000-7000-8000-0000000000c5';

  group('factories emit registry-valid payloads', () {
    test('object.create carries the wire field names', () {
      final payload = OperationPayloads.objectCreate(
        objectId: objectId,
        isEmbedded: false,
        classIds: const [classId],
        tagIds: const ['0192a000-0000-7000-8000-0000000000aa'],
        contentAst: const [
          {'type': 'text', 'text': 'hi'},
        ],
        parentId: null,
      );

      expect(payload['objectId'], objectId);
      expect(payload['isEmbedded'], isFalse);
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
      expect(payload.containsKey('isEmbedded'), isFalse);
    });

    test('object.create emits the embedding flag when given', () {
      final payload = OperationPayloads.objectCreate(
        objectId: objectId,
        isEmbedded: true,
        parentId: classId,
      );
      expect(payload['isEmbedded'], isTrue);
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

    test('object.update carries the wire node fields set + clear; '
        'object.create rejects them outright', () {
      const asset = '0192a000-0000-7000-8000-00000000052b';
      // Presence writes; an explicit null reaches the wire as a clear.
      final set = OperationPayloads.objectUpdate(
        objectId: objectId,
        coverAssetId: asset,
        bannerAssetId: asset,
        aliasedNodeId: asset,
      );
      expect(set['coverAssetId'], asset);
      expect(set['bannerAssetId'], asset);
      expect(set['aliasedNodeId'], asset);
      final cleared = OperationPayloads.objectUpdate(
        objectId: objectId,
        aliasedNodeId: null,
      );
      expect(cleared.containsKey('aliasedNodeId'), isTrue);
      expect(cleared['aliasedNodeId'], isNull);
      // Omitted stays absent (absence = no write, distinct from a clear).
      final iconOnly = OperationPayloads.objectUpdate(
        objectId: objectId,
        icon: 'mdiStar',
      );
      expect(iconOnly.containsKey('coverAssetId'), isFalse);
      expect(iconOnly.containsKey('bannerAssetId'), isFalse);
      expect(iconOnly.containsKey('aliasedNodeId'), isFalse);
      // A non-uuid reference is rejected outright.
      expect(
        () => OperationPayloads.validatePayload('object.update', {
          'objectId': objectId,
          'coverAssetId': 'not-a-uuid',
        }),
        throwsFormatException,
      );
      // The fields are object.update-only: object.create rejects them like
      // any unknown key (the strict schema).
      for (final key in ['coverAssetId', 'bannerAssetId', 'aliasedNodeId']) {
        expect(
          () => OperationPayloads.validatePayload('object.create', {
            'objectId': objectId,
            key: asset,
          }),
          throwsFormatException,
        );
      }
    });

    test('propertySchema.create accepts the asset type and rejects a bogus '
        'one', () {
      final payload = OperationPayloads.propertySchemaCreate(
        propertySchemaId: classId,
        name: 'Attachment',
        type: 'asset',
        multi: true,
        scopeClassIds: const [classId],
      );
      expect(payload['type'], 'asset');
      expect(payload['scopeClassIds'], [classId]);
      expect(() => OperationPayloads.validatePayload(
          'propertySchema.create', payload), returnsNormally);
      expect(
        () => OperationPayloads.validatePayload('propertySchema.create', {
          'propertySchemaId': classId,
          'name': 'Bogus',
          'type': 'asset_payload',
        }),
        throwsFormatException,
      );
    });

    test('propertySchema.create: scopeClassIds is the sole locality '
        'authority — the retired `scope` enum is rejected like any '
        'retired key, an empty list is rejected, null/absent is global',
        () {
      // The retired enum key fails the strict schema (unknown-key reject)
      // for BOTH its legacy values — the parse-level pin.
      for (final legacy in ['global', 'class', 'object']) {
        expect(
          () => OperationPayloads.validatePayload('propertySchema.create', {
            'propertySchemaId': classId,
            'name': 'Legacy scope',
            'type': 'text',
            'scope': legacy,
          }),
          throwsFormatException,
          reason: 'retired scope enum value "$legacy" must fail loud',
        );
      }
      // Exactly one spelling of "global": the EMPTY list is rejected.
      expect(
        () => OperationPayloads.validatePayload('propertySchema.create', {
          'propertySchemaId': classId,
          'name': 'Empty scope',
          'type': 'text',
          'scopeClassIds': <String>[],
        }),
        throwsFormatException,
      );
      // Absent and explicit null both read global.
      for (final scope in [null, const [classId]]) {
        expect(
          () => OperationPayloads.validatePayload('propertySchema.create', {
            'propertySchemaId': classId,
            'name': 'Scoped',
            'type': 'text',
            'scopeClassIds': scope,
          }),
          returnsNormally,
        );
      }
      // Non-uuid entries fail the uuid-list gate.
      expect(
        () => OperationPayloads.validatePayload('propertySchema.create', {
          'propertySchemaId': classId,
          'name': 'Bad scope',
          'type': 'text',
          'scopeClassIds': const ['not-a-uuid'],
        }),
        throwsFormatException,
      );
    });

    test('propertySchema.create carries an optional nullable icon', () {
      final payload = OperationPayloads.propertySchemaCreate(
        propertySchemaId: classId,
        name: 'Genre',
        type: 'text',
        icon: 'mdiTagOutline',
      );
      expect(payload['icon'], 'mdiTagOutline');
      expect(() => OperationPayloads.validatePayload(
          'propertySchema.create', payload), returnsNormally);
      // Present null = no icon; overlong strings fail.
      expect(
        () => OperationPayloads.validatePayload('propertySchema.create', {
          'propertySchemaId': classId,
          'name': 'No icon',
          'type': 'text',
          'icon': null,
        }),
        returnsNormally,
      );
      expect(
        () => OperationPayloads.validatePayload('propertySchema.create', {
          'propertySchemaId': classId,
          'name': 'Long icon',
          'type': 'text',
          'icon': 'x' * 65,
        }),
        throwsFormatException,
      );
    });

    test('propertySchema.create accepts datetime and rejects the retired '
        'date/date_range types outright', () {
      final payload = OperationPayloads.propertySchemaCreate(
        propertySchemaId: classId,
        name: 'When',
        type: 'datetime',
        datePrecision: 'day',
      );
      expect(payload['type'], 'datetime');
      expect(() => OperationPayloads.validatePayload(
          'propertySchema.create', payload), returnsNormally);
      // The strict enum: the retired values are rejected outright (the
      // live log rewrites them to datetime before pre-batch clients mix).
      for (final retired in ['date', 'date_range']) {
        expect(
          () => OperationPayloads.validatePayload('propertySchema.create', {
            'propertySchemaId': classId,
            'name': 'Legacy',
            'type': retired,
          }),
          throwsFormatException,
          reason: 'retired type $retired must fail loud',
        );
      }
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

    test('trash.empty is a strict empty object: the factory emits {}, any '
        'key is rejected', () {
      final payload = OperationPayloads.trashEmpty();
      expect(payload, isEmpty);
      expect(() => OperationPayloads.validatePayload('trash.empty', payload),
          returnsNormally);
      expect(OperationPayloads.isKnownOpType('trash.empty'), isTrue);
      expect(
        () => OperationPayloads.validatePayload(
            'trash.empty', {'objectId': objectId}),
        throwsFormatException,
      );
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

    test('render contracts are PROPERTY-level (schema), not binding '
        '— option icon unchanged', () {
      // class.property.set carries ONLY the genuinely per-class mechanics
      // (sequence, active): the binding-level display experiment is gone,
      // readonly/hideWhenEmpty reject here like any retired key, and
      // `required`/`defaultValue` retired outright / moved to the schema
      // — the strict 4-key payload rejects them
      // exactly like the render contracts.
      for (final retired in [
        'display',
        'readonly',
        'hideWhenEmpty',
        'required',
        'defaultValue',
      ]) {
        expect(
          () => OperationPayloads.validatePayload('class.property.set', {
            'classId': classId,
            'propertySchemaId': objectId,
            retired: switch (retired) {
              'display' => 'bullet',
              'defaultValue' => 'high',
              _ => true,
            },
          }),
          throwsFormatException,
          reason: retired,
        );
      }
      // The surviving keys validate.
      expect(
        () => OperationPayloads.validatePayload('class.property.set', {
          'classId': classId,
          'propertySchemaId': objectId,
          'active': false,
        }),
        returnsNormally,
      );

      // propertySchema.create/update carry the render contracts —
      // nullable+optional (absent keeps, null clears; the builders omit
      // nulls, so explicit clears ride raw maps). `readonly` retired
      // outright: the strict validator rejects
      // it on both schema payloads.
      final created = OperationPayloads.propertySchemaCreate(
        propertySchemaId: classId,
        name: 'Status',
        type: 'select',
        display: 'bullet',
        hideWhenEmpty: false,
      );
      expect(created['display'], 'bullet');
      expect(
        () => OperationPayloads.validatePayload('propertySchema.create', {
          ...created,
          'readonly': true,
        }),
        throwsFormatException,
      );
      expect(
        () => OperationPayloads.validatePayload('propertySchema.create', created),
        returnsNormally,
      );
      for (final display in ['panel', 'bullet', 'inline']) {
        expect(
          () => OperationPayloads.validatePayload('propertySchema.create', {
            'propertySchemaId': classId,
            'name': 'Status',
            'type': 'select',
            'display': display,
          }),
          returnsNormally,
          reason: display,
        );
      }
      // An unknown display position is rejected outright (strict enum) on
      // both schema ops; the flags are bool-or-null.
      for (final opType in ['propertySchema.create', 'propertySchema.update']) {
        expect(
          () => OperationPayloads.validatePayload(opType, {
            'propertySchemaId': classId,
            if (opType == 'propertySchema.create') ...{
              'name': 'Status',
              'type': 'select',
            },
            'display': 'hover',
          }),
          throwsFormatException,
          reason: opType,
        );
        expect(
          () => OperationPayloads.validatePayload(opType, {
            'propertySchemaId': classId,
            if (opType == 'propertySchema.create') ...{'name': 'Status', 'type': 'select'},
            'hideWhenEmpty': 'yes',
          }),
          throwsFormatException,
          reason: opType,
        );
        // Explicit null clears validate (raw maps — the builders omit nulls).
        expect(
          () => OperationPayloads.validatePayload(opType, {
            'propertySchemaId': classId,
            if (opType == 'propertySchema.create') ...{'name': 'Status', 'type': 'select'},
            'display': null,
            'hideWhenEmpty': null,
          }),
          returnsNormally,
          reason: opType,
        );
        // `readonly` retired outright (derived
        // from the system list, not stored): it rejects on both schema
        // payloads like any retired key.
        expect(
          () => OperationPayloads.validatePayload(opType, {
            'propertySchemaId': classId,
            if (opType == 'propertySchema.create') ...{'name': 'Status', 'type': 'select'},
            'readonly': true,
          }),
          throwsFormatException,
          reason: opType,
        );
      }
      // `required` retired outright — it rejects
      // on the schema ops like any retired key. `defaultValue` MOVED here:
      // any JSON value validates, absent/null included.
      for (final opType in ['propertySchema.create', 'propertySchema.update']) {
        expect(
          () => OperationPayloads.validatePayload(opType, {
            'propertySchemaId': classId,
            if (opType == 'propertySchema.create') ...{'name': 'Status', 'type': 'select'},
            'required': true,
          }),
          throwsFormatException,
          reason: opType,
        );
      }
      for (final opType in ['propertySchema.create', 'propertySchema.update']) {
        expect(
          () => OperationPayloads.validatePayload(opType, {
            'propertySchemaId': classId,
            if (opType == 'propertySchema.create') ...{'name': 'Status', 'type': 'select'},
            'defaultValue': null,
          }),
          returnsNormally,
          reason: opType,
        );
      }

      // Option records accept the icon (max 64 chars, absent/null =
      // no icon) and stay NON-strict: unknown keys pass through so
      // icon-carrying options sync through older parsers.
      final createdWithIcon = OperationPayloads.propertySchemaCreate(
        propertySchemaId: classId,
        name: 'Status',
        type: 'select',
        options: const [
          {'id': 'a', 'label': 'Open', 'icon': 'mdiCheckCircle', 'color': 'green'},
          {'id': 'b', 'label': 'Shut', 'icon': null, 'future': 'key'},
        ],
      );
      expect(
        () => OperationPayloads.validatePayload('propertySchema.create', createdWithIcon),
        returnsNormally,
      );
      expect(
        () => OperationPayloads.validatePayload('propertySchema.create', {
          'propertySchemaId': classId,
          'name': 'Status',
          'type': 'select',
          'options': [
            {'id': 'a', 'label': 'Open', 'icon': 'x' * 65},
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => OperationPayloads.validatePayload('propertySchema.update', {
          'propertySchemaId': classId,
          'options': [
            {'id': 'a', 'label': 'Open', 'icon': 'mdiCircle'},
          ],
        }),
        returnsNormally,
      );
    });

    test('propertySchema.update carries icon/scopeClassIds/targetClassFilter/'
        'multi/validationRules — the keep/clear contract', () {
      // The builder's sentinel defaults: absent keeps (the key never rides).
      final untouched = OperationPayloads.propertySchemaUpdate(
        propertySchemaId: classId,
        name: 'x',
      );
      for (final key in [
        'icon',
        'scopeClassIds',
        'targetClassFilter',
        'multi',
        'validationRules',
        'defaultValue',
      ]) {
        expect(untouched.containsKey(key), isFalse, reason: key);
      }
      // Present values ride; explicit nulls ride as JSON clears.
      final updated = OperationPayloads.propertySchemaUpdate(
        propertySchemaId: classId,
        icon: null,
        scopeClassIds: null,
        targetClassFilter: const [classId],
        multi: true,
        validationRules: const {'min': 0, 'max': 10},
        defaultValue: 'fallback',
      );
      expect(updated, containsPair('icon', null));
      expect(updated, containsPair('scopeClassIds', null));
      expect(updated, containsPair('targetClassFilter', [classId]));
      expect(updated, containsPair('multi', true));
      expect(updated, containsPair('defaultValue', 'fallback'));
      expect(
        updated['validationRules'],
        {'min': 0, 'max': 10},
      );
      expect(
        () => OperationPayloads.validatePayload('propertySchema.update', updated),
        returnsNormally,
      );
      // The default's explicit-null clear rides too.
      expect(
        OperationPayloads.propertySchemaUpdate(
          propertySchemaId: classId,
          defaultValue: null,
        ),
        containsPair('defaultValue', null),
      );
      // At least one field: an all-absent update rejects (zod refine parity).
      expect(
        () => OperationPayloads.propertySchemaUpdate(propertySchemaId: classId),
        throwsArgumentError,
      );
    });

    test('validationRules parse gate: strict {min?, max?, pattern?} keys, '
        'numeric bounds, min <= max; compilability is NOT parse-level', () {
      // Well-formed shapes validate (each alone and combined).
      for (final rules in [
        {'min': 1},
        {'max': 5.5},
        {'min': 0, 'max': 10},
        {'pattern': '[a-z0-9-]+'},
        <String, dynamic>{},
      ]) {
        expect(
          () => OperationPayloads.validatePayload('propertySchema.update', {
            'propertySchemaId': classId,
            'validationRules': rules,
          }),
          returnsNormally,
          reason: '$rules',
        );
      }
      // min > max rejects at parse time.
      expect(
        () => OperationPayloads.validatePayload('propertySchema.update', {
          'propertySchemaId': classId,
          'validationRules': {'min': 10, 'max': 1},
        }),
        throwsFormatException,
      );
      // Strict keys, wrong types, and explicit nulls (zod .optional()
      // rejects null) all fail the shape gate.
      for (final rules in [
        {'minimum': 1},
        {'min': '1'},
        {'max': true},
        {'pattern': 3},
        {'min': null},
      ]) {
        expect(
          () => OperationPayloads.validatePayload('propertySchema.update', {
            'propertySchemaId': classId,
            'validationRules': rules,
          }),
          throwsFormatException,
          reason: '$rules',
        );
      }
      // A non-compilable pattern is a PARSE-LEVEL PASS — the applier fails
      // it at the rule write (R2), not the shape gate.
      expect(
        () => OperationPayloads.validatePayload('propertySchema.update', {
          'propertySchemaId': classId,
          'validationRules': {'pattern': '([a-z'},
        }),
        returnsNormally,
      );
      // Present-null clears the rules (the keep/clear contract).
      expect(
        () => OperationPayloads.validatePayload('propertySchema.update', {
          'propertySchemaId': classId,
          'validationRules': null,
        }),
        returnsNormally,
      );
    });

    test('object listStyle: the strict three-style enum, nullable on '
        'create and update', () {
      for (final style in ['numbered', 'alpha', 'roman']) {
        final created = OperationPayloads.objectCreate(
          objectId: objectId,
          listStyle: style,
        );
        expect(created['listStyle'], style);
        expect(
          () => OperationPayloads.validatePayload('object.create', created),
          returnsNormally,
          reason: style,
        );
        expect(
          () => OperationPayloads.validatePayload('object.update', {
            'objectId': objectId,
            'listStyle': style,
          }),
          returnsNormally,
          reason: style,
        );
      }
      // Absent and present-null both validate (null = the bullet default /
      // clear); a bogus style fails the enum.
      expect(
        () => OperationPayloads.validatePayload('object.create', {
          'objectId': objectId,
          'listStyle': null,
        }),
        returnsNormally,
      );
      expect(
        () => OperationPayloads.validatePayload('object.update', {
          'objectId': objectId,
          'listStyle': null,
        }),
        returnsNormally,
      );
      for (final opType in ['object.create', 'object.update']) {
        expect(
          () => OperationPayloads.validatePayload(opType, {
            'objectId': objectId,
            'listStyle': 'bullets',
          }),
          throwsFormatException,
          reason: opType,
        );
      }
      // object.update counts listStyle toward its at-least-one-field rule.
      final cleared = OperationPayloads.objectUpdate(
        objectId: objectId,
        listStyle: null,
      );
      expect(cleared, containsPair('listStyle', null));
      expect(
        () => OperationPayloads.validatePayload('object.update', cleared),
        returnsNormally,
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
            'isEmbedded': false,
          }),
          returnsNormally,
        );
        expect(
          () => OperationPayloads.validatePayload(opType, {
            'objectId': objectId,
            'isEmbedded': 'yes',
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
