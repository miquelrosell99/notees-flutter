/// Factory functions and validation for the operation payloads of the
/// Notees relay protocol v2.
///
/// This is the Dart port of `packages/protocol/src/op-types.ts` — the
/// op registry (18 op types). Factories return plain JSON maps for direct
/// storage in an [OperationEnvelope.payload]; every factory validates its
/// output through [validatePayload] before returning, so producers fail loud
/// at build time instead of earning a 422 `validation_failed` at relay
/// ingest. Payloads are strict (zod `.strict()` parity): unknown keys are
/// rejected.
///
/// Title-is-content (SCHEMA.md, 2026-10-01 lockstep): the protocol has no
/// object/class `name` field — a node's title IS its content. The builders
/// keep a [name] convenience that wraps the value in a single text token
/// (`[{type: 'text', text: name}]`) when no explicit `contentAst` is given
/// (web parity, `WorkspaceClient.createObject`); when both are given,
/// `contentAst` wins and `name` is dropped. The validators reject a `name`
/// key in object/class payloads like the relay does.
///
/// Color grammar (2026-10-03): `color` on object.update /
/// class.create / class.update is a preset token (`sky`) or `#RRGGBB` hex —
/// see [isColorValue]. `null` CLEARS (object.update gained null-clear here;
/// class.update documented it). The builders take [color] as an `Object?`
/// [_undefined]-defaulted sentinel so an explicit `null` reaches the wire as
/// `"color": null` while an omitted argument stays absent.
///
/// Property-wire batch (2026-10-04 lockstep, TS reference
/// shipped inert — the parsers land here; authoring stays disabled until
/// every client parses the new shapes):
///  - `workspace.feature.set {feature, enabled}` — the per-workspace
///    feature toggles; [feature] is the strict five-family enum
///    (tasks|events|meetings|sources|persons) and the
///    retired pre-reshape ids (journals|readItLater|library|people|
///    collections) are rejected outright;
///  - `property.set`/`property.unset` gain the optional PG5 `elementId`
///    (UUID) — the OR-Set add/remove carrier for multi-value slots;
///  - `class.property.set` gains the optional PC4 `active` soft-unbind flag
///    (omitted = keep the stored flag);
///  - `propertySchema.create`/`update` gain the SCHEMA.md "Datetime" fields
///    `datePrecision` (year|month|day) and `dateQualified` (PC6: values may
///    carry date-node qualifier refs in metadata startDate/endDate).
///
/// Node-fields + asset-type batch (2026-10-07 lockstep):
///  - `object.update` gains the optional nullable wire node fields
///    `coverAssetId` / `bannerAssetId` / `aliasedNodeId` (presence writes,
///    present-null clears; `object.create` carries none — the strict
///    validator rejects them there like any unknown key); `description`
///    (the page subtitle, max 512 chars) joins them 2026-10-09;
///  - the `propertySchema.create` type enum gains `"asset"` (an asset-node
///    reference whose class filter is implicit in the type).
library;

import 'colors.dart';

class OperationPayloads {
  OperationPayloads._();

  /// Sentinel marking an omitted optional argument (vs an explicit `null`).
  static const Object _undefined = Object();

  // --- registry ---------------------------------------------------------------

  /// The op registry (`KNOWN_OP_TYPES` in `op-types.ts`). Unknown op
  /// types are rejected at relay ingest with 422 `validation_failed`.
  static const List<String> knownOpTypes = [
    'object.create',
    'object.update',
    'object.delete',
    'object.restore',
    'object.move',
    'class.create',
    'class.update',
    'class.delete',
    'class.unassign',
    'class.reorder',
    'tag.unassign',
    'class.setExtends',
    'class.property.set',
    'class.property.unset',
    'propertySchema.create',
    'propertySchema.update',
    'propertySchema.delete',
    'property.set',
    'property.unset',
    'asset.attach',
    'asset.detach',
    'collection.member.add',
    'collection.member.remove',
    'workspace.feature.set',
  ];

  static bool isKnownOpType(String opType) => knownOpTypes.contains(opType);

  /// The per-workspace feature toggle ids (reshaped per owner
  /// directive 2026-10-04): the toggles ARE the five core class
  /// families — tasks=task, events=event, meetings=meeting, sources=source,
  /// persons=person. Feature ids are protocol vocabulary (not UUIDs); the
  /// retired pre-reshape ids (journals/readItLater/library/people/
  /// collections) are rejected outright by [validatePayload].
  static const workspaceFeatures = {
    'tasks',
    'events',
    'meetings',
    'sources',
    'persons',
  };

  // --- objects ----------------------------------------------------------------

  /// Title-is-content: [name] is a convenience for the node's initial text
  /// content (a single text token) and is dropped when [contentAst] is given
  /// (`WorkspaceClient.createObject` parity). [tagIds] seeds the tag
  /// membership OR-Set exactly like [classIds] seeds class membership.
  /// [afterId]/[beforeId] anchor the node next to that current sibling in
  /// the parent's fractional child order (see [objectMove]); omit both to
  /// append at the end.
  ///
  /// Render bit (Revision 11): [presentAsMain] is read only when the node
  /// has a parent — true renders it in the parent's main-children zone with
  /// document chrome, false inline with block chrome. Omit it and the
  /// applier defaults by placement: parentless ⇒ main (document chrome by
  /// the second cascade branch), parented ⇒ inline. Class declaration is
  /// the class.create op — object.create always makes a non-class node.
  static Map<String, dynamic> objectCreate({
    required String objectId,
    bool? presentAsMain,
    List<String>? classIds,
    List<String>? tagIds,
    String? name,
    List<Map<String, dynamic>>? contentAst,
    String? parentId,
    String? afterId,
    String? beforeId,
  }) {
    final effectiveContent =
        contentAst ??
        (name != null
            ? <Map<String, dynamic>>[
                {'type': 'text', 'text': name},
              ]
            : null);
    return _validated('object.create', {
      'objectId': objectId,
      'presentAsMain': ?presentAsMain,
      'classIds': classIds ?? <String>[],
      'tagIds': tagIds ?? <String>[],
      'contentAst': ?effectiveContent,
      'parentId': ?parentId,
      'afterId': ?afterId,
      'beforeId': ?beforeId,
    });
  }

  /// At least one field beyond `objectId` is required, and exactly one
  /// content carrier (`contentAst` or `contentDeltaB64`) may be set
  /// (`objectUpdatePayload.refine` in `op-types.ts`). There is no `name`
  /// field (title-is-content): a rename is a `contentAst` replacement.
  ///
  /// Render-bit toggle (Revision 11): promotion/demotion flips are
  /// [presentAsMain] true/false — identity is preserved, and promotion
  /// (false → true) stringifies the content in the same op.
  ///
  /// Color: [color] is a preset token or `#RRGGBB` hex; pass `null`
  /// explicitly to CLEAR the node's color (the wire carries `"color": null`).
  ///
  /// Wire node fields (the icon/color precedent, 2026-10-07 lockstep):
  /// [coverAssetId] (an asset node for the page cover), [bannerAssetId]
  /// (an asset node for the page banner), [aliasedNodeId] (the main page
  /// a node alias points at) and [description] (the page subtitle in the
  /// core page chrome, the Capacities header precedent, plain text max 512
  /// chars) are `object.update`-only — `object.create` carries none.
  /// Presence writes, an explicit `null` CLEARS; the applier maps them
  /// without validating the references, except the alias target: an update
  /// that would close an alias cycle fails loud and is never applied.
  /// Reference integrity beyond that is a read/client-layer concern.
  static Map<String, dynamic> objectUpdate({
    required String objectId,
    bool? presentAsMain,
    String? icon,
    Object? color = _undefined,
    Object? coverAssetId = _undefined,
    Object? bannerAssetId = _undefined,
    Object? aliasedNodeId = _undefined,
    Object? description = _undefined,
    String? contentDeltaB64,
    List<Map<String, dynamic>>? contentAst,
  }) {
    if (presentAsMain == null &&
        icon == null &&
        identical(color, _undefined) &&
        identical(coverAssetId, _undefined) &&
        identical(bannerAssetId, _undefined) &&
        identical(aliasedNodeId, _undefined) &&
        identical(description, _undefined) &&
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
      'presentAsMain': ?presentAsMain,
      'icon': ?icon,
      if (!identical(color, _undefined)) 'color': color,
      if (!identical(coverAssetId, _undefined))
        'coverAssetId': coverAssetId,
      if (!identical(bannerAssetId, _undefined))
        'bannerAssetId': bannerAssetId,
      if (!identical(aliasedNodeId, _undefined))
        'aliasedNodeId': aliasedNodeId,
      if (!identical(description, _undefined)) 'description': description,
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

  static Map<String, dynamic> objectRestore({
    required String objectId,
  }) =>
      _validated('object.restore', {
        'objectId': objectId,
      });

  /// [parentId] null means workspace root and is legal for any non-class
  /// node (a parentless node renders with document chrome by the second
  /// cascade branch; classes are always roots and cannot be moved under a
  /// parent). [afterId] places the node immediately after that sibling,
  /// [beforeId] immediately before it
  /// (the first-child placement fractional midpoints cannot otherwise
  /// express); omit both to append at the end. At most one anchor is
  /// meaningful: when both are present [afterId] wins — but an [afterId]
  /// that is not a current sibling falls through to the [beforeId] branch,
  /// and an anchor that is not a current sibling falls back to a defensive
  /// plain append (mirrors afterId).
  static Map<String, dynamic> objectMove({
    required String objectId,
    required String? parentId,
    String? afterId,
    String? beforeId,
  }) =>
      _validated('object.move', {
        'objectId': objectId,
        'parentId': parentId,
        'afterId': ?afterId,
        'beforeId': ?beforeId,
      });

  // --- classes & properties ---------------------------------------------------

  /// Title-is-content: the class's title text rides `contentAst` (text-only
  /// content, like pages). [name] is a convenience wrapped into a single
  /// text token (`WorkspaceClient.createClass` parity). Color:
  /// [color] is a preset token or `#RRGGBB` hex (omit for no color).
  static Map<String, dynamic> classCreate({
    required String classId,
    String? name,
    List<Map<String, dynamic>>? contentAst,
    String? icon,
    String? color,
    String? description,
  }) {
    final effectiveContent =
        contentAst ??
        (name != null
            ? <Map<String, dynamic>>[
                {'type': 'text', 'text': name},
              ]
            : null);
    return _validated('class.create', {
      'classId': classId,
      'contentAst': ?effectiveContent,
      'icon': ?icon,
      'color': ?color,
      'description': ?description,
    });
  }

  /// Title-text replacement (text-only content), same contract as
  /// [classCreate]. Color: [color] is a preset token or `#RRGGBB`
  /// hex; pass `null` explicitly to CLEAR the class's color (the wire
  /// carries `"color": null` — the schema now accepts what the catalog
  /// always documented).
  static Map<String, dynamic> classUpdate({
    required String classId,
    String? name,
    List<Map<String, dynamic>>? contentAst,
    String? icon,
    Object? color = _undefined,
    String? description,
  }) {
    if (name == null &&
        contentAst == null &&
        icon == null &&
        identical(color, _undefined) &&
        description == null) {
      throw ArgumentError('class.update requires at least one field');
    }
    final effectiveContent =
        contentAst ??
        (name != null
            ? <Map<String, dynamic>>[
                {'type': 'text', 'text': name},
              ]
            : null);
    return _validated('class.update', {
      'classId': classId,
      'contentAst': ?effectiveContent,
      'icon': ?icon,
      if (!identical(color, _undefined)) 'color': color,
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

  /// [type] is the property-schema enum (op-types.ts); [targetClassFilter]
  /// constrains node-typed (m2o/m2m) schemas to those classes.
  /// Binding upsert: a configuration row on `class_property` (sequence,
  /// required, defaultValue, active). Row-level LWW by envelope HLC; omitted
  /// fields KEEP their existing values (partial patch, not a replace). A null
  /// parameter is indistinguishable from "leave unset" through typed Dart
  /// params, so clearing a flag means passing `false` (the applier maps
  /// explicit null to false as well); send a raw map for JSON-null
  /// defaultValue.
  ///
  /// Owner review 2026-10-05: the row carries ONLY the genuinely
  /// per-class mechanics — the render contracts (readonly/hideWhenEmpty/
  /// display) are PROPERTY-level and live on the property schema
  /// (`propertySchema.create/update`); this strict payload rejects them like
  /// any retired key. `required` is the owner's deliberate exception: a
  /// property may be mandatory for one class, optional for another.
  static Map<String, dynamic> classPropertySet({
    required String classId,
    required String propertySchemaId,
    int? sequence,
    bool? required,
    bool? active,
    dynamic defaultValue,
  }) =>
      _validated('class.property.set', {
        'classId': classId,
        'propertySchemaId': propertySchemaId,
        'sequence': ?sequence,
        'required': ?required,
        'active': ?active,
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

  /// Class ORDER (display-only, 2026-10-01): the membership OR-Set projects
  /// class_ids sorted by id; user-defined order rides this dedicated op as an
  /// LWW-by-arrival array. The effective class_ids = ordered members first,
  /// then any unlisted members sorted by id (the store's recomputeClassIds).
  static Map<String, dynamic> classReorder({
    required String objectId,
    required List<String> classIds,
  }) =>
      _validated('class.reorder', {
        'objectId': objectId,
        'classIds': classIds,
      });

  /// Tag removal (tag.unassign): the OR-Set remove complement of the
  /// re-issued object.create add carrier — identical gating to
  /// [classUnassign], own table (`tag_member_set`).
  static Map<String, dynamic> tagUnassign({
    required String objectId,
    required String tagId,
  }) =>
      _validated('tag.unassign', {
        'objectId': objectId,
        'tagId': tagId,
      });

  /// [type] is the property-schema enum (op-types.ts); [targetClassFilter]
  /// constrains node-typed (m2o/m2m) schemas to those classes.
  /// [datePrecision] (year|month|day) caps the granularity a datetime value
  /// may claim (SCHEMA.md "Datetime"; NULL = day at the read model) and
  /// [dateQualified] (PC6) allows datetime and node-typed values to carry
  /// date qualifiers (metadata startDate/endDate as date-node refs).
  ///
  /// Owner review 2026-10-05: the render contracts are
  /// PROPERTY-level — [display] ('panel' | 'bullet' | 'inline'; where a
  /// select/multi_select/boolean value renders on a block row; NULL/'panel'
  /// = the properties section only) and [readonly] / [hideWhenEmpty] (a
  /// property is readonly / hidden-when-empty everywhere it appears, whatever
  /// class binds it — or none). Nullable+optional like the number formats:
  /// the builders omit nulls, so an explicit null clear rides a raw map.
  static Map<String, dynamic> propertySchemaCreate({
    required String propertySchemaId,
    required String name,
    required String type,
    bool? multi,
    String? scope,
    List<Map<String, dynamic>>? options,
    List<String>? targetClassFilter,
    String? datePrecision,
    bool? dateQualified,
    int? numberPad,
    int? numberDecimals,
    String? numberRounding,
    String? display,
    bool? readonly,
    bool? hideWhenEmpty,
  }) =>
      _validated('propertySchema.create', {
        'propertySchemaId': propertySchemaId,
        'name': name,
        'type': type,
        'multi': ?multi,
        'scope': ?scope,
        'options': ?options,
        'targetClassFilter': ?targetClassFilter,
        'datePrecision': ?datePrecision,
        'dateQualified': ?dateQualified,
        'numberPad': ?numberPad,
        'numberDecimals': ?numberDecimals,
        'numberRounding': ?numberRounding,
        'display': ?display,
        'readonly': ?readonly,
        'hideWhenEmpty': ?hideWhenEmpty,
      });

  static Map<String, dynamic> propertySchemaUpdate({
    required String propertySchemaId,
    String? name,
    List<Map<String, dynamic>>? options,
    String? datePrecision,
    bool? dateQualified,
    int? numberPad,
    int? numberDecimals,
    String? numberRounding,
    String? display,
    bool? readonly,
    bool? hideWhenEmpty,
  }) {
    if (name == null &&
        options == null &&
        datePrecision == null &&
        dateQualified == null &&
        numberPad == null &&
        numberDecimals == null &&
        numberRounding == null &&
        display == null &&
        readonly == null &&
        hideWhenEmpty == null) {
      throw ArgumentError('propertySchema.update requires at least one field');
    }
    return _validated('propertySchema.update', {
      'propertySchemaId': propertySchemaId,
      'name': ?name,
      'options': ?options,
      'datePrecision': ?datePrecision,
      'dateQualified': ?dateQualified,
      'numberPad': ?numberPad,
      'numberDecimals': ?numberDecimals,
      'numberRounding': ?numberRounding,
      'display': ?display,
      'readonly': ?readonly,
      'hideWhenEmpty': ?hideWhenEmpty,
    });
  }

  static Map<String, dynamic> propertySchemaDelete({
    required String propertySchemaId,
  }) =>
      _validated('propertySchema.delete', {'propertySchemaId': propertySchemaId});

  /// [value] is schema-typed by the property schema; node-typed values carry
  /// `{"nodeId": ...}`. [metadata] holds per-value qualifiers (`since`, …;
  /// on dateQualified schemas the reserved startDate/endDate canonicalize to
  /// date-node refs — PC6 normalizes legacy ISO strings on write).
  ///
  /// PG5 element identity: a [elementId] (writer-minted UUIDv7) makes the
  /// write an OR-Set element ADD — the property_value row id IS the element
  /// id, adds of distinct elements never conflict, and removal addresses the
  /// element (`propertyUnset` with the same [elementId]). Absent = the
  /// legacy positional carrier at [idx] (the deterministic
  /// `node:schema:idx` element).
  static Map<String, dynamic> propertySet({
    required String objectId,
    required String propertySchemaId,
    required dynamic value,
    String? elementId,
    int idx = 0,
    Map<String, dynamic>? metadata,
  }) =>
      _validated('property.set', {
        'objectId': objectId,
        'propertySchemaId': propertySchemaId,
        'value': value,
        'elementId': ?elementId,
        'idx': idx,
        'metadata': ?metadata,
      });

  /// Removes a property value: by [elementId] (PG5 OR-Set remove of that
  /// element — add-wins tombstone) or, absent it, the legacy positional
  /// remove of the slot's deterministic element at [idx].
  static Map<String, dynamic> propertyUnset({
    required String objectId,
    required String propertySchemaId,
    String? elementId,
    int idx = 0,
  }) =>
      _validated('property.unset', {
        'objectId': objectId,
        'propertySchemaId': propertySchemaId,
        'elementId': ?elementId,
        'idx': idx,
      });

  // --- workspace features ----------------------------------------------------

  /// Per-workspace feature toggle: LWW by HLC on
  /// (workspace, feature); an absent derived row reads ENABLED. [feature] is
  /// the strict five-family enum ([workspaceFeatures]); the retired
  /// pre-reshape ids fail loud. Applying the toggle derives the
  /// membership-preserving archival of the family's managed system classes
  /// (hide surfaces, keep data); a class.delete on a family base routes here
  /// (F4). LOCKSTEP-PENDING authoring: the builder exists for tests and the
  /// future Features settings surface, but no app surface emits the op until
  /// every client parses it.
  static Map<String, dynamic> workspaceFeatureSet({
    required String feature,
    required bool enabled,
  }) =>
      _validated('workspace.feature.set', {
        'feature': feature,
        'enabled': enabled,
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

  static const _propertySchemaTypes = {
    'text',
    'number',
    'boolean',
    // The unified date property type (2026-10-09): the retired `date` and
    // `date_range` types rewrite to `datetime` in live logs; the strict
    // schema rejects the retired values outright. A value is a point
    // `{nodeId, time?}` or a range `{start: slot|null, end: slot|null}`
    // (slot = `{nodeId, time?}`) anchored to the year/month/day node
    // chain — see SCHEMA.md "Datetime".
    'datetime',
    'url',
    'email',
    'select',
    'multi_select',
    'object',
    'image',
    // An asset reference — a node-typed value ({ nodeId }) whose target must
    // carry the asset class; the filter is IMPLICIT in the type (an explicit
    // targetClassFilter is redundant on an asset schema).
    'asset',
  };
  static const _propertySchemaScopes = {'global', 'class', 'object'};

  /// SCHEMA.md "Datetime" precision enum (the finest granularity a datetime
  /// value may claim; NULL/absent = day at the read model).
  static const _datePrecisions = {'year', 'month', 'day'};
  static const _numberRoundings = {'round', 'floor', 'ceil', 'truncate'};

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

  /// Validates [payload] against the schema for [opType], throwing
  /// [FormatException] on any deviation. Strict: unknown keys are rejected
  /// (zod `.strict()` parity), so a renamed wire field fails here instead of
  /// drifting silently. This is the client-side half of the relay's 422
  /// `validation_failed` gate.
  static void validatePayload(String opType, Map<String, dynamic> payload) {
    switch (opType) {
      case 'object.create':
        _strict(payload, {
          'objectId',
          'presentAsMain',
          'classIds',
          'tagIds',
          'contentAst',
          'parentId',
          'afterId',
          'beforeId',
        });
        _uuid(payload, 'objectId');
        _bool(payload, 'presentAsMain', required: false);
        _uuidList(payload, 'classIds', required: false);
        _uuidList(payload, 'tagIds', required: false);
        _list(payload, 'contentAst', required: false);
        _uuid(payload, 'parentId', required: false, nullable: true);
        _uuid(payload, 'afterId', required: false);
        _uuid(payload, 'beforeId', required: false);
      case 'object.update':
        _strict(payload, {
          'objectId',
          'presentAsMain',
          'icon',
          'color',
          'coverAssetId',
          'bannerAssetId',
          'aliasedNodeId',
          'description',
          'contentDeltaB64',
          'contentAst',
        });
        _uuid(payload, 'objectId');
        _bool(payload, 'presentAsMain', required: false);
        _string(payload, 'icon', max: 64, required: false);
        _color(payload, 'color');
        // Wire node fields: nullable uuids (absence = no write, present
        // null = clear — the `_uuid` helper accepts a present null and
        // validates the shape only when a string rides).
        _uuid(payload, 'coverAssetId', required: false);
        _uuid(payload, 'bannerAssetId', required: false);
        _uuid(payload, 'aliasedNodeId', required: false);
        // The page subtitle: plain text, max 512 (presence writes,
        // present-null clears like the other wire node fields).
        _string(payload, 'description', max: 512, required: false);
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
      case 'object.restore':
        _strict(payload, {'objectId'});
        _uuid(payload, 'objectId');
      case 'object.move':
        _strict(payload, {'objectId', 'parentId', 'afterId', 'beforeId'});
        _uuid(payload, 'objectId');
        _uuid(payload, 'parentId', nullable: true);
        _uuid(payload, 'afterId', required: false);
        _uuid(payload, 'beforeId', required: false);
      case 'class.create':
        _strict(payload, {'classId', 'contentAst', 'icon', 'color', 'description'});
        _uuid(payload, 'classId');
        _list(payload, 'contentAst', required: false);
        _string(payload, 'icon', max: 64, required: false);
        _color(payload, 'color');
        _string(payload, 'description', max: 4096, required: false);
      case 'class.update':
        _strict(payload, {'classId', 'contentAst', 'icon', 'color', 'description'});
        _uuid(payload, 'classId');
        _list(payload, 'contentAst', required: false);
        _string(payload, 'icon', max: 64, required: false);
        _color(payload, 'color');
        _string(payload, 'description', max: 4096, required: false);
      case 'class.delete':
        _strict(payload, {'classId'});
        _uuid(payload, 'classId');
      case 'class.setExtends':
        _strict(payload, {'classId', 'parentClassIds'});
        _uuid(payload, 'classId');
        _uuidList(payload, 'parentClassIds');
      case 'class.property.set':
        // The binding carries ONLY the per-class mechanics
        // (sequence, required, defaultValue, active) — the render contracts
        // (readonly/hideWhenEmpty/display) are PROPERTY-level
        // (propertySchema.create/update) and reject here like retired keys.
        _strict(payload, {
          'classId',
          'propertySchemaId',
          'sequence',
          'required',
          'defaultValue',
          'active',
        });
        _uuid(payload, 'classId');
        _uuid(payload, 'propertySchemaId');
        _int(payload, 'sequence', required: false);
        _boolNullable(payload, 'required', required: false);
        _bool(payload, 'active', required: false);
      case 'class.property.unset':
        _strict(payload, {'classId', 'propertySchemaId'});
        _uuid(payload, 'classId');
        _uuid(payload, 'propertySchemaId');
      case 'class.unassign':
        _strict(payload, {'objectId', 'classId'});
        _uuid(payload, 'objectId');
        _uuid(payload, 'classId');
      case 'class.reorder':
        _strict(payload, {'objectId', 'classIds'});
        _uuid(payload, 'objectId');
        _uuidList(payload, 'classIds');
      case 'tag.unassign':
        _strict(payload, {'objectId', 'tagId'});
        _uuid(payload, 'objectId');
        _uuid(payload, 'tagId');
      case 'propertySchema.create':
        _strict(payload, {
          'propertySchemaId',
          'name',
          'type',
          'multi',
          'scope',
          'options',
          'targetClassFilter',
          'datePrecision',
          'dateQualified',
          'numberPad',
          'numberDecimals',
          'numberRounding',
          'display',
          'readonly',
          'hideWhenEmpty',
        });
        _uuid(payload, 'propertySchemaId');
        _string(payload, 'name', min: 1, max: 256);
        _enum(payload, 'type', _propertySchemaTypes);
        _bool(payload, 'multi', required: false);
        _enum(payload, 'scope', _propertySchemaScopes, required: false);
        _options(payload, required: false);
        _uuidList(payload, 'targetClassFilter', required: false);
        _enum(payload, 'datePrecision', _datePrecisions, required: false);
        _bool(payload, 'dateQualified', required: false);
        // SCHEMA.md "Number formats": display-only
        // formatting for number schemas (values stay exact in the log).
        _int(payload, 'numberPad', min: 1, max: 20, required: false);
        _int(payload, 'numberDecimals', min: 0, max: 10, required: false);
        _enum(payload, 'numberRounding', _numberRoundings, required: false);
        // The PROPERTY-level render contracts — nullable+optional
        // (absent keeps, null clears; stored NULL = 'panel' / unset).
        // `required` is deliberately NOT here: it stays on the class binding.
        _enum(payload, 'display', {'panel', 'bullet', 'inline'}, required: false);
        _boolNullable(payload, 'readonly', required: false);
        _boolNullable(payload, 'hideWhenEmpty', required: false);
      case 'propertySchema.update':
        _strict(payload, {
          'propertySchemaId',
          'name',
          'options',
          'datePrecision',
          'dateQualified',
          'numberPad',
          'numberDecimals',
          'numberRounding',
          'display',
          'readonly',
          'hideWhenEmpty',
        });
        _uuid(payload, 'propertySchemaId');
        _string(payload, 'name', min: 1, max: 256, required: false);
        _options(payload, required: false);
        _enum(payload, 'datePrecision', _datePrecisions, required: false);
        _bool(payload, 'dateQualified', required: false);
        _int(payload, 'numberPad', min: 1, max: 20, required: false);
        _int(payload, 'numberDecimals', min: 0, max: 10, required: false);
        _enum(payload, 'numberRounding', _numberRoundings, required: false);
        // render contracts — the same keep/clear contract as the
        // number formats (absent keeps, present null clears).
        _enum(payload, 'display', {'panel', 'bullet', 'inline'}, required: false);
        _boolNullable(payload, 'readonly', required: false);
        _boolNullable(payload, 'hideWhenEmpty', required: false);
      case 'propertySchema.delete':
        _strict(payload, {'propertySchemaId'});
        _uuid(payload, 'propertySchemaId');
      case 'property.set':
        _strict(payload, {
          'objectId',
          'propertySchemaId',
          'value',
          'elementId',
          'idx',
          'metadata',
        });
        _uuid(payload, 'objectId');
        _uuid(payload, 'propertySchemaId');
        if (!payload.containsKey('value')) {
          throw FormatException('property.set is missing value');
        }
        _uuid(payload, 'elementId', required: false);
        _int(payload, 'idx', min: 0, required: false);
        _record(payload, 'metadata', required: false);
      case 'property.unset':
        _strict(payload, {
          'objectId',
          'propertySchemaId',
          'elementId',
          'idx',
        });
        _uuid(payload, 'objectId');
        _uuid(payload, 'propertySchemaId');
        _uuid(payload, 'elementId', required: false);
        _int(payload, 'idx', min: 0, required: false);
      case 'workspace.feature.set':
        // The strict five-family enum; the retired
        // pre-reshape ids (journals/readItLater/library/people/collections)
        // are rejected outright like any unknown value.
        _strict(payload, {'feature', 'enabled'});
        _enum(payload, 'feature', workspaceFeatures);
        _bool(payload, 'enabled');
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

  /// Color grammar: a preset token or `#RRGGBB` hex ([isColorValue]);
  /// a present `null` CLEARS (object.update / class.update). The retired
  /// `var(--color-preset-*)` encoding and any other garbage fail loud here.
  static void _color(Map<String, dynamic> payload, String key) {
    if (!payload.containsKey(key)) return;
    final value = payload[key];
    if (value == null) return;
    if (!isColorValue(value)) {
      throw FormatException('Field $key must be a preset token or #RRGGBB hex');
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
    int? max,
  }) {
    final value = payload[key];
    if (value == null) {
      if (required) {
        throw FormatException('Missing required int field: $key');
      }
      return;
    }
    if (value is! int || value < min || (max != null && value > max)) {
      throw FormatException(
        'Field $key must be an int >= $min${max != null ? ' and <= $max' : ''}',
      );
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
      // An option may carry an OPTIONAL MDI icon name (the same
      // camelCase shape as node/class icons, max 64 chars; absent/null = no
      // icon). The record itself stays NON-strict — unknown keys pass through
      // so icon-carrying options sync through older parsers (which
      // strip the icon instead of rejecting the envelope).
      final icon = item['icon'];
      if (icon != null && (icon is! String || icon.length > 64)) {
        throw FormatException(
          'Field options[].icon must be a string of length <= 64',
        );
      }
    }
  }
}
