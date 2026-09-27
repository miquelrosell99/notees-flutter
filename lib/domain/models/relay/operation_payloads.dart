/// Factory functions and validation for the operation payloads of the
/// Notees relay protocol v2.
///
/// This is the Dart port of `v2/packages/protocol/src/op-types.ts` — the M1
/// op registry (16 op types). Factories return plain JSON maps for direct
/// storage in an [OperationEnvelope.payload]; every factory validates its
/// output through [validatePayload] before returning, so producers fail loud
/// at build time instead of earning a 422 `validation_failed` at relay
/// ingest. Payloads are strict (zod `.strict()` parity): unknown keys are
/// rejected.
class OperationPayloads {
  OperationPayloads._();

  // --- registry ---------------------------------------------------------------

  /// The v2 M1 op registry (`KNOWN_OP_TYPES` in `op-types.ts`). Unknown op
  /// types are rejected at relay ingest with 422 `validation_failed`.
  static const List<String> knownOpTypes = [
    'object.create',
    'object.update',
    'object.delete',
    'object.move',
    'class.create',
    'class.update',
    'class.delete',
    'class.setExtends',
    'class.property.set',
    'class.property.unset',
    'class.unassign',
    'propertySchema.create',
    'propertySchema.update',
    'propertySchema.delete',
    'property.set',
    'property.unset',
    'asset.attach',
    'asset.detach',
    'collection.member.add',
    'collection.member.remove',
  ];

  static bool isKnownOpType(String opType) => knownOpTypes.contains(opType);

  // --- objects ----------------------------------------------------------------

  static Map<String, dynamic> objectCreate({
    required String objectId,
    String? nodeType,
    List<String>? classIds,
    String? name,
    List<Map<String, dynamic>>? contentAst,
    String? parentId,
  }) =>
      _validated('object.create', {
        'objectId': objectId,
        'nodeType': ?nodeType,
        'classIds': classIds ?? <String>[],
        'name': ?name,
        'contentAst': ?contentAst,
        'parentId': ?parentId,
      });

  /// At least one field beyond `objectId` is required, and exactly one
  /// content carrier (`contentAst` or `contentDeltaB64`) may be set
  /// (`objectUpdatePayload.refine` in `op-types.ts`).
  static Map<String, dynamic> objectUpdate({
    required String objectId,
    String? nodeType,
    String? name,
    String? icon,
    String? color,
    String? contentDeltaB64,
    List<Map<String, dynamic>>? contentAst,
  }) {
    if (nodeType == null &&
        name == null &&
        icon == null &&
        color == null &&
        contentDeltaB64 == null &&
        contentAst == null) {
      throw ArgumentError('object.update requires at least one field');
    }
    if (contentDeltaB64 != null && contentAst != null) {
      throw ArgumentError(
        'object.update takes exactly one content carrier '
        '(contentAst or contentDeltaB64, not both)',
      );
    }
    return _validated('object.update', {
      'objectId': objectId,
      'nodeType': ?nodeType,
      'name': ?name,
      'icon': ?icon,
      'color': ?color,
      'contentDeltaB64': ?contentDeltaB64,
      'contentAst': ?contentAst,
    });
  }

  static Map<String, dynamic> objectDelete({
    required String objectId,
    bool permanent = false,
  }) =>
      _validated('object.delete', {
        'objectId': objectId,
        'permanent': permanent,
      });

  /// [parentId] null means workspace root and is legal only for pages; the
  /// store's placement CHECKs reject a parentless block. [afterId] places the
  /// node immediately after that sibling (omit to append at the end).
  static Map<String, dynamic> objectMove({
    required String objectId,
    required String? parentId,
    String? afterId,
  }) =>
      _validated('object.move', {
        'objectId': objectId,
        'parentId': parentId,
        'afterId': ?afterId,
      });

  // --- classes & properties ---------------------------------------------------

  static Map<String, dynamic> classCreate({
    required String classId,
    required String name,
    String? icon,
    String? color,
    String? description,
  }) =>
      _validated('class.create', {
        'classId': classId,
        'name': name,
        'icon': ?icon,
        'color': ?color,
        'description': ?description,
      });

  static Map<String, dynamic> classUpdate({
    required String classId,
    String? name,
    String? icon,
    String? color,
    String? description,
  }) {
    if (name == null && icon == null && color == null && description == null) {
      throw ArgumentError('class.update requires at least one field');
    }
    return _validated('class.update', {
      'classId': classId,
      'name': ?name,
      'icon': ?icon,
      'color': ?color,
      'description': ?description,
    });
  }

  static Map<String, dynamic> classDelete({required String classId}) =>
      _validated('class.delete', {'classId': classId});

  /// Replace semantics: [parentClassIds] IS the class's full parent set
  /// (an empty array detaches all parents). The store fails loud on cycles.
  static Map<String, dynamic> classSetExtends({
    required String classId,
    required List<String> parentClassIds,
  }) =>
      _validated('class.setExtends', {
        'classId': classId,
        'parentClassIds': parentClassIds,
      });

  /// [type] is the v2 property-schema enum (op-types.ts); [targetClassFilter]
  /// constrains node-typed (m2o/m2m) schemas to those classes.
  /// Binding upsert: a configuration row on `class_property` (sequence,
  /// flags, defaultValue). Row-level LWW by envelope HLC; omitted fields
  /// KEEP their existing values (partial patch, not a replace). A null
  /// parameter is indistinguishable from "leave unset" through typed Dart
  /// params, so clearing a flag means passing `false` (the v2 applier maps
  /// explicit null to false as well); send a raw map for JSON-null
  /// defaultValue.
  static Map<String, dynamic> classPropertySet({
    required String classId,
    required String propertySchemaId,
    int? sequence,
    bool? required,
    bool? readonly,
    bool? hideWhenEmpty,
    dynamic defaultValue,
  }) =>
      _validated('class.property.set', {
        'classId': classId,
        'propertySchemaId': propertySchemaId,
        'sequence': ?sequence,
        'required': ?required,
        'readonly': ?readonly,
        'hideWhenEmpty': ?hideWhenEmpty,
        'defaultValue': ?defaultValue,
      });

  /// Binding removal: deletes the `class_property` row. No tombstone — a
  /// config row, last write wins (SCHEMA.md).
  static Map<String, dynamic> classPropertyUnset({
    required String classId,
    required String propertySchemaId,
  }) =>
      _validated('class.property.unset', {
        'classId': classId,
        'propertySchemaId': propertySchemaId,
      });

  /// Class membership removal (SCHEMA.md "Class properties"): tombstones
  /// the OR-Set pair. Authored property values always survive; bound
  /// defaults simply stop being derived (nothing stored, nothing to clean).
  static Map<String, dynamic> classUnassign({
    required String objectId,
    required String classId,
  }) =>
      _validated('class.unassign', {
        'objectId': objectId,
        'classId': classId,
      });

  static Map<String, dynamic> propertySchemaCreate({
    required String propertySchemaId,
    required String name,
    required String type,
    bool? multi,
    String? scope,
    List<Map<String, dynamic>>? options,
    List<String>? targetClassFilter,
  }) =>
      _validated('propertySchema.create', {
        'propertySchemaId': propertySchemaId,
        'name': name,
        'type': type,
        'multi': ?multi,
        'scope': ?scope,
        'options': ?options,
        'targetClassFilter': ?targetClassFilter,
      });

  static Map<String, dynamic> propertySchemaUpdate({
    required String propertySchemaId,
    String? name,
    List<Map<String, dynamic>>? options,
  }) {
    if (name == null && options == null) {
      throw ArgumentError('propertySchema.update requires at least one field');
    }
    return _validated('propertySchema.update', {
      'propertySchemaId': propertySchemaId,
      'name': ?name,
      'options': ?options,
    });
  }

  static Map<String, dynamic> propertySchemaDelete({
    required String propertySchemaId,
  }) =>
      _validated('propertySchema.delete', {'propertySchemaId': propertySchemaId});

  /// [value] is schema-typed by the property schema; node-typed values carry
  /// `{"nodeId": ...}`. [metadata] holds per-value qualifiers (`since`, …).
  static Map<String, dynamic> propertySet({
    required String objectId,
    required String propertySchemaId,
    required dynamic value,
    int idx = 0,
    Map<String, dynamic>? metadata,
  }) =>
      _validated('property.set', {
        'objectId': objectId,
        'propertySchemaId': propertySchemaId,
        'value': value,
        'idx': idx,
        'metadata': ?metadata,
      });

  static Map<String, dynamic> propertyUnset({
    required String objectId,
    required String propertySchemaId,
    int idx = 0,
  }) =>
      _validated('property.unset', {
        'objectId': objectId,
        'propertySchemaId': propertySchemaId,
        'idx': idx,
      });

  // --- assets & collections ---------------------------------------------------

  static Map<String, dynamic> assetAttach({
    required String objectId,
    required String assetId,
    required String hash,
    required String mimeType,
    required int size,
    required String originalName,
  }) =>
      _validated('asset.attach', {
        'objectId': objectId,
        'assetId': assetId,
        'hash': hash,
        'mimeType': mimeType,
        'size': size,
        'originalName': originalName,
      });

  static Map<String, dynamic> assetDetach({
    required String objectId,
    required String assetId,
  }) =>
      _validated('asset.detach', {
        'objectId': objectId,
        'assetId': assetId,
      });

  static Map<String, dynamic> collectionMemberAdd({
    required String collectionId,
    required String objectId,
  }) =>
      _validated('collection.member.add', {
        'collectionId': collectionId,
        'objectId': objectId,
      });

  static Map<String, dynamic> collectionMemberRemove({
    required String collectionId,
    required String objectId,
  }) =>
      _validated('collection.member.remove', {
        'collectionId': collectionId,
        'objectId': objectId,
      });

  // --- validation (port of op-types.ts zod schemas) ----------------------------

  static const _nodeTypes = {'page', 'block', 'class'};
  static const _propertySchemaTypes = {
    'text',
    'number',
    'boolean',
    'date',
    'date_range',
    'url',
    'email',
    'select',
    'multi_select',
    'object',
    'image',
  };
  static const _propertySchemaScopes = {'global', 'class', 'object'};

  static final _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static Map<String, dynamic> _validated(
    String opType,
    Map<String, dynamic> payload,
  ) {
    validatePayload(opType, payload);
    return payload;
  }

  /// Validates [payload] against the v2 schema for [opType], throwing
  /// [FormatException] on any deviation. Strict: unknown keys are rejected
  /// (zod `.strict()` parity), so a renamed wire field fails here instead of
  /// drifting silently. This is the client-side half of the relay's 422
  /// `validation_failed` gate.
  static void validatePayload(String opType, Map<String, dynamic> payload) {
    switch (opType) {
      case 'object.create':
        _strict(payload, {
          'objectId',
          'nodeType',
          'classIds',
          'name',
          'contentAst',
          'parentId',
        });
        _uuid(payload, 'objectId');
        _enum(payload, 'nodeType', _nodeTypes, required: false);
        _uuidList(payload, 'classIds', required: false);
        _string(payload, 'name', max: 1024, required: false);
        _list(payload, 'contentAst', required: false);
        _uuid(payload, 'parentId', required: false, nullable: true);
      case 'object.update':
        _strict(payload, {
          'objectId',
          'nodeType',
          'name',
          'icon',
          'color',
          'contentDeltaB64',
          'contentAst',
        });
        _uuid(payload, 'objectId');
        _enum(payload, 'nodeType', _nodeTypes, required: false);
        _string(payload, 'name', max: 1024, required: false);
        _string(payload, 'icon', max: 64, required: false);
        _string(payload, 'color', max: 32, required: false);
        _string(payload, 'contentDeltaB64', required: false);
        _list(payload, 'contentAst', required: false);
        if (payload.length == 1) {
          throw FormatException('object.update requires at least one field');
        }
        if (payload.containsKey('contentDeltaB64') &&
            payload.containsKey('contentAst')) {
          throw FormatException(
            'object.update takes exactly one content carrier per update',
          );
        }
      case 'object.delete':
        _strict(payload, {'objectId', 'permanent'});
        _uuid(payload, 'objectId');
        _bool(payload, 'permanent', required: false);
      case 'object.move':
        _strict(payload, {'objectId', 'parentId', 'afterId'});
        _uuid(payload, 'objectId');
        _uuid(payload, 'parentId', nullable: true);
        _uuid(payload, 'afterId', required: false);
      case 'class.create':
        _strict(payload, {'classId', 'name', 'icon', 'color', 'description'});
        _uuid(payload, 'classId');
        _string(payload, 'name', min: 1, max: 256);
        _string(payload, 'icon', max: 64, required: false);
        _string(payload, 'color', max: 32, required: false);
        _string(payload, 'description', max: 4096, required: false);
      case 'class.update':
        _strict(payload, {'classId', 'name', 'icon', 'color', 'description'});
        _uuid(payload, 'classId');
        _string(payload, 'name', min: 1, max: 256, required: false);
        _string(payload, 'icon', max: 64, required: false);
        _string(payload, 'color', max: 32, required: false);
        _string(payload, 'description', max: 4096, required: false);
      case 'class.delete':
        _strict(payload, {'classId'});
        _uuid(payload, 'classId');
      case 'class.setExtends':
        _strict(payload, {'classId', 'parentClassIds'});
        _uuid(payload, 'classId');
        _uuidList(payload, 'parentClassIds');
      case 'class.property.set':
        _strict(payload, {
          'classId',
          'propertySchemaId',
          'sequence',
          'required',
          'readonly',
          'hideWhenEmpty',
          'defaultValue',
        });
        _uuid(payload, 'classId');
        _uuid(payload, 'propertySchemaId');
        _int(payload, 'sequence', required: false);
        _boolNullable(payload, 'required', required: false);
        _boolNullable(payload, 'readonly', required: false);
        _boolNullable(payload, 'hideWhenEmpty', required: false);
      case 'class.property.unset':
        _strict(payload, {'classId', 'propertySchemaId'});
        _uuid(payload, 'classId');
        _uuid(payload, 'propertySchemaId');
      case 'class.unassign':
        _strict(payload, {'objectId', 'classId'});
        _uuid(payload, 'objectId');
        _uuid(payload, 'classId');
      case 'propertySchema.create':
        _strict(payload, {
          'propertySchemaId',
          'name',
          'type',
          'multi',
          'scope',
          'options',
          'targetClassFilter',
        });
        _uuid(payload, 'propertySchemaId');
        _string(payload, 'name', min: 1, max: 256);
        _enum(payload, 'type', _propertySchemaTypes);
        _bool(payload, 'multi', required: false);
        _enum(payload, 'scope', _propertySchemaScopes, required: false);
        _options(payload, required: false);
        _uuidList(payload, 'targetClassFilter', required: false);
      case 'propertySchema.update':
        _strict(payload, {'propertySchemaId', 'name', 'options'});
        _uuid(payload, 'propertySchemaId');
        _string(payload, 'name', min: 1, max: 256, required: false);
        _options(payload, required: false);
      case 'propertySchema.delete':
        _strict(payload, {'propertySchemaId'});
        _uuid(payload, 'propertySchemaId');
      case 'property.set':
        _strict(payload, {
          'objectId',
          'propertySchemaId',
          'value',
          'idx',
          'metadata',
        });
        _uuid(payload, 'objectId');
        _uuid(payload, 'propertySchemaId');
        if (!payload.containsKey('value')) {
          throw FormatException('property.set is missing value');
        }
        _int(payload, 'idx', min: 0, required: false);
        _record(payload, 'metadata', required: false);
      case 'property.unset':
        _strict(payload, {'objectId', 'propertySchemaId', 'idx'});
        _uuid(payload, 'objectId');
        _uuid(payload, 'propertySchemaId');
        _int(payload, 'idx', min: 0, required: false);
      case 'asset.attach':
        _strict(payload, {
          'objectId',
          'assetId',
          'hash',
          'mimeType',
          'size',
          'originalName',
        });
        _uuid(payload, 'objectId');
        _uuid(payload, 'assetId');
        _string(payload, 'hash', min: 64, max: 64);
        _string(payload, 'mimeType', min: 1);
        _int(payload, 'size', min: 0);
        _string(payload, 'originalName', min: 1, max: 1024);
      case 'asset.detach':
        _strict(payload, {'objectId', 'assetId'});
        _uuid(payload, 'objectId');
        _uuid(payload, 'assetId');
      case 'collection.member.add':
      case 'collection.member.remove':
        _strict(payload, {'collectionId', 'objectId'});
        _uuid(payload, 'collectionId');
        _uuid(payload, 'objectId');
      default:
        throw FormatException('Unknown op type: $opType');
    }
  }

  static void _strict(Map<String, dynamic> payload, Set<String> allowed) {
    for (final key in payload.keys) {
      if (!allowed.contains(key)) {
        throw FormatException('Unknown payload key: $key');
      }
    }
  }

  static void _uuid(
    Map<String, dynamic> payload,
    String key, {
    bool required = true,
    bool nullable = false,
  }) {
    final value = payload[key];
    if (value == null) {
      if (required && !nullable) {
        throw FormatException('Missing required uuid field: $key');
      }
      return;
    }
    if (value is! String || !_uuidPattern.hasMatch(value)) {
      throw FormatException('Field $key must be a uuid string');
    }
  }

  static void _uuidList(Map<String, dynamic> payload, String key,
      {bool required = true}) {
    final value = payload[key];
    if (value == null) {
      if (required) {
        throw FormatException('Missing required uuid list field: $key');
      }
      return;
    }
    if (value is! List<dynamic>) {
      throw FormatException('Field $key must be a list of uuids');
    }
    for (final item in value) {
      if (item is! String || !_uuidPattern.hasMatch(item)) {
        throw FormatException('Field $key must be a list of uuids');
      }
    }
  }

  static void _string(
    Map<String, dynamic> payload,
    String key, {
    bool required = true,
    int min = 0,
    int max = 1 << 31,
  }) {
    final value = payload[key];
    if (value == null) {
      if (required) {
        throw FormatException('Missing required string field: $key');
      }
      return;
    }
    if (value is! String || value.length < min || value.length > max) {
      throw FormatException(
        'Field $key must be a string of length $min..$max',
      );
    }
  }

  static void _enum(
    Map<String, dynamic> payload,
    String key,
    Set<String> allowed, {
    bool required = true,
  }) {
    final value = payload[key];
    if (value == null) {
      if (required) {
        throw FormatException('Missing required enum field: $key');
      }
      return;
    }
    if (value is! String || !allowed.contains(value)) {
      throw FormatException('Field $key must be one of ${allowed.join('|')}');
    }
  }

  static void _bool(Map<String, dynamic> payload, String key,
      {bool required = true}) {
    final value = payload[key];
    if (value == null) {
      if (required) {
        throw FormatException('Missing required bool field: $key');
      }
      return;
    }
    if (value is! bool) {
      throw FormatException('Field $key must be a bool');
    }
  }

  static void _int(
    Map<String, dynamic> payload,
    String key, {
    bool required = true,
    int min = 0,
  }) {
    final value = payload[key];
    if (value == null) {
      if (required) {
        throw FormatException('Missing required int field: $key');
      }
      return;
    }
    if (value is! int || value < min) {
      throw FormatException('Field $key must be an int >= $min');
    }
  }

  static void _boolNullable(Map<String, dynamic> payload, String key,
      {bool required = true}) {
    final value = payload[key];
    if (value == null) {
      if (required) {
        throw FormatException('Missing required bool field: $key');
      }
      return;
    }
    if (value is! bool) {
      throw FormatException('Field $key must be a bool or null');
    }
  }

  static void _list(Map<String, dynamic> payload, String key,
      {bool required = true}) {
    final value = payload[key];
    if (value == null) {
      if (required) {
        throw FormatException('Missing required list field: $key');
      }
      return;
    }
    if (value is! List<dynamic>) {
      throw FormatException('Field $key must be a list');
    }
  }

  static void _record(Map<String, dynamic> payload, String key,
      {bool required = true}) {
    final value = payload[key];
    if (value == null) {
      if (required) {
        throw FormatException('Missing required record field: $key');
      }
      return;
    }
    if (value is! Map<String, dynamic>) {
      throw FormatException('Field $key must be an object');
    }
  }

  static void _options(Map<String, dynamic> payload, {bool required = true}) {
    final value = payload['options'];
    if (value == null) {
      if (required) {
        throw FormatException('Missing required options field');
      }
      return;
    }
    if (value is! List<dynamic>) {
      throw FormatException('Field options must be a list of {id, label}');
    }
    for (final item in value) {
      if (item is! Map<String, dynamic> ||
          item['id'] == null ||
          item['label'] is! String) {
        throw FormatException('Field options must be a list of {id, label}');
      }
    }
  }
}
