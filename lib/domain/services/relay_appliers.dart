import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/constants/system.dart';
import '../../core/utils/ast_builder.dart';
import '../../core/utils/ast_stringifier.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_cache_repository.dart';
import '../models/relay/lww.dart';
import '../models/relay/operation_envelope.dart';
import '../models/relay/operation_payloads.dart';
import '../models/relay/store_errors.dart';

/// Applies v2 relay operation envelopes to the local derived state, porting
/// `v2/packages/store/src/appliers.ts` semantics:
///
///  - row-level LWW by (hlc_physical, hlc_logical, actor_id): higher HLC
///    wins, equal HLC breaks the tie on actor id (deterministic);
///  - the v2 scalar `name` lands in the node's title field, kept separate
///    from the content AST slot (Node.name);
///  - sibling order uses the lexicographic fractional allocator
///    (midpointBetween/nextChildPosition), stored in node_cache.position;
///  - class membership and collection membership are OR-Sets (add-wins per
///    pair, LWW per pair by (hlc, actor)), projected into node rows;
///  - class extends is m2m replace semantics with an applier-maintained
///    transitive closure; cycles fail loud with [CycleError];
///  - property values are LWW per (node, schema, idx) with tombstones;
///  - appliers fail loud with typed [StoreError]s and never swallow a write
///    silently. Envelope-id idempotency lives in the sync service
///    (relay_operations dedupe), mirroring applied_envelope in the v2 store.
class RelayAppliers {
  RelayAppliers(this._cache);

  final NodeCacheRepository _cache;

  LwwWinner _incoming(OperationEnvelope envelope) => (
    physical: envelope.hlc.physical,
    logical: envelope.hlc.logical,
    actor: envelope.actorId,
  );

  /// Applies [envelope], returning true when it changed derived state and
  /// false when it was dropped by a LWW guard or first-create-wins rule.
  Future<bool> apply(OperationEnvelope envelope) async {
    final payload = envelope.payload;
    // Class/property/collection operations identify their target via
    // `classId`, `propertySchemaId`, or `collectionId`, not `objectId`.
    final objectId =
        payload['objectId'] as String? ??
        payload['classId'] as String? ??
        payload['propertySchemaId'] as String? ??
        payload['collectionId'] as String? ??
        '';
    // Ops without a target (e.g. `plugin.op`) have no local derived
    // representation and are intentionally ignored.
    if (objectId.isEmpty) return false;

    // Known v2 ops validate their payload before touching state (the relay
    // would 422 them otherwise); unknown/legacy types fall to the ignore
    // list below.
    if (OperationPayloads.isKnownOpType(envelope.opType)) {
      try {
        OperationPayloads.validatePayload(envelope.opType, payload);
      } on FormatException catch (e) {
        throw EnvelopeValidationError(
          'invalid ${envelope.opType} payload: ${e.message}',
          envelope.opType,
        );
      }
    }

    switch (envelope.opType) {
      case 'object.create':
        return _applyCreate(envelope, objectId, payload);
      case 'object.update':
        return _applyUpdate(envelope, objectId, payload);
      case 'object.delete':
        return _applyDelete(envelope, objectId, payload);
      case 'object.move':
        return _applyMove(envelope, objectId, payload);
      case 'property.set':
        return _applyPropertySet(envelope, objectId, payload);
      case 'property.unset':
        return _applyPropertyUnset(envelope, objectId, payload);
      case 'class.create':
        await _applyClassCreate(envelope, payload);
        return true;
      case 'class.update':
        return _applyClassUpdate(envelope, payload);
      case 'class.delete':
        await _applyClassDelete(payload);
        return true;
      case 'class.setExtends':
        await _applyClassSetExtends(envelope, payload);
        return true;
      case 'propertySchema.create':
        await _applyPropertySchemaCreate(payload);
        return true;
      case 'propertySchema.update':
        return _applyPropertySchemaUpdate(payload);
      case 'propertySchema.delete':
        await _applyPropertySchemaDelete(payload);
        return true;
      case 'asset.attach':
      case 'asset.detach':
        // Asset metadata lives in the server-side asset tables; the app has
        // no local asset table (asset bytes are fetched over HTTP), so asset
        // bookkeeping ops are intentionally ignored — as are the remaining
        // activity/share/view/alias/plugin ops below.
        return false;
      case 'collection.member.add':
        return _applyCollectionMember(envelope, payload, present: true);
      case 'collection.member.remove':
        return _applyCollectionMember(envelope, payload, present: false);
      case 'activity.record':
      case 'activity.delete':
      case 'link.click':
      case 'share.public.create':
      case 'share.public.revoke':
      case 'nodeView.create':
      case 'nodeView.update':
      case 'nodeView.delete':
      case 'nodeView.reorder':
      case 'node.addAlias':
      case 'node.removeAlias':
      case 'plugin.op':
        return false;
      default:
        // No silent fallthrough: log op types this client does not know
        // (including v1-only ops dropped from the v2 M1 registry:
        // node.archive/restore, user.favorite.*, task.*, classPropertyEdge.*,
        // share.user.*).
        debugPrint(
          'RelayAppliers: ignoring unknown op type ${envelope.opType}',
        );
        return false;
    }
  }

  // --- objects ----------------------------------------------------------------

  Future<bool> _applyCreate(
    OperationEnvelope envelope,
    String objectId,
    Map<String, dynamic> payload,
  ) async {
    final opType = envelope.opType;
    final parentId = payload['parentId'] as String?;
    final nodeType =
        payload['nodeType'] as String? ?? (parentId == null ? 'page' : 'block');
    final incoming = _incoming(envelope);

    // Placement CHECKs (bullet-proof schema): a block can never be
    // parentless; a class is always tree-external.
    if (nodeType == 'block' && parentId == null) {
      throw CheckConstraintError(
        '$opType: a block cannot be parentless (placement CHECK)',
        'node_parent',
        opType,
      );
    }
    if (nodeType == 'class' && parentId != null) {
      throw CheckConstraintError(
        '$opType: a class is tree-external and cannot have a parent',
        'node_parent',
        opType,
      );
    }
    if (parentId != null) {
      if (await _cache.getByUuid(parentId) == null) {
        throw NodeNotFoundError(
          '$opType: parent $parentId does not exist',
          opType,
        );
      }
      if (await _cache.isClassNode(parentId)) {
        throw MoveGuardError(
          '$opType: node $parentId is a class; classes are tree-external '
          'and cannot have children',
          opType,
        );
      }
    }

    // Seed OR-Set membership first: a re-issued create is the v2 membership
    // carrier (add-wins per pair), even when the node already exists.
    final classIds = _readStringList(payload['classIds']);
    for (final classId in classIds) {
      final stored = await _cache.classMemberWinner(objectId, classId);
      if (stored == null || compareLww(incoming, stored) >= 0) {
        await _cache.upsertClassMember(objectId, classId, true, incoming);
      }
    }

    // First create wins for the tree: re-issuing object.create on an
    // existing id must not move the node or revert later edits (the v1
    // dual-parent corruption class this op replaces).
    if (await _cache.getByUuid(objectId) != null) {
      if (classIds.isNotEmpty) await _cache.recomputeClassIds(objectId);
      return false;
    }

    final contentAst = payload['contentAst'];
    final name = switch (contentAst) {
      List<dynamic> list => AstBuilder.serialize(
        list.cast<Map<String, dynamic>>(),
      ),
      _ => '',
    };
    final title = payload['name'] as String?;
    final flags = _deriveFlags(classIds);
    final position = parentId == null
        ? null
        : nextChildPosition(await _cache.lastChildPosition(parentId));

    await _cache.upsert(
      Node(
        id: 0,
        uuid: objectId,
        name: name,
        displayName: title?.isNotEmpty == true ? title! : astToPlainText(name),
        parentUuid: parentId,
        position: position,
        sequence: double.tryParse(position ?? '') ?? 0.0,
        classesUuid: classIds,
        isPage: nodeType == 'page',
        isTask: flags.isTask,
        isDaily: flags.isDaily,
        isMonthly: flags.isMonthly,
        isYearly: flags.isYearly,
        isTable: flags.isTable,
        isAsset: flags.isAsset,
        isComment: flags.isComment,
        properties: const {},
        writeDate: envelope.timestamp,
        title: title,
        nodeType: nodeType,
        hlcPhysical: incoming.physical,
        hlcLogical: incoming.logical,
        actorId: incoming.actor,
      ),
    );
    if (nodeType == 'class') {
      // Declaration-first class creation: the class node doubles as the
      // registry row locally (classes render from class_cache).
      await _cache.upsertClass(
        uuid: objectId,
        name: title ?? astToPlainText(name),
        active: true,
      );
    }
    if (classIds.isNotEmpty) await _cache.recomputeClassIds(objectId);
    return true;
  }

  Future<bool> _applyUpdate(
    OperationEnvelope envelope,
    String objectId,
    Map<String, dynamic> payload,
  ) async {
    final opType = envelope.opType;
    final node = await _cache.getByUuid(objectId);
    if (node == null) {
      throw NodeNotFoundError('$opType: node $objectId does not exist', opType);
    }
    final hasDelta = payload['contentDeltaB64'] != null;
    final hasAst = payload['contentAst'] != null;
    if (hasDelta && !hasAst) {
      throw UnsupportedCarrierError(
        '$opType: contentDeltaB64 (canonical CRDT carrier) needs the Yjs '
        'port; reapply with the contentAst readable carrier',
        opType,
      );
    }

    final incoming = _incoming(envelope);
    final rowWinner = (
      physical: node.hlcPhysical,
      logical: node.hlcLogical,
      actor: node.actorId ?? '',
    );
    // Row-level last-write-wins: lower or equal (hlc, actor) writes drop.
    if (compareLww(incoming, rowWinner) <= 0) return false;

    final title = payload['name'] as String?;
    final contentAst = payload['contentAst'];
    // v2 `name` is the scalar title slot, never the content slot.
    final newTitle = title ?? node.title;
    String? newName = node.name;
    var newDisplay = node.displayName;
    if (contentAst is List<dynamic>) {
      newName = AstBuilder.serialize(contentAst.cast<Map<String, dynamic>>());
      newDisplay = newTitle?.isNotEmpty == true
          ? newTitle!
          : astToPlainText(newName);
    } else if (title != null) {
      newDisplay = title;
    }

    final newNodeType = payload['nodeType'] as String? ?? node.nodeType;
    await _cache.upsert(
      _copyWith(
        node,
        name: newName,
        displayName: newDisplay,
        title: newTitle,
        nodeType: newNodeType,
        // A nodeType flip is promotion/demotion: the is_page query flag
        // follows it.
        isPage: newNodeType == 'page',
        icon: payload['icon'] as String? ?? node.icon,
        color: payload['color'] as String? ?? node.color,
        writeDate: envelope.timestamp,
        hlcPhysical: incoming.physical,
        hlcLogical: incoming.logical,
        actorId: incoming.actor,
      ),
    );
    return true;
  }

  Future<bool> _applyDelete(
    OperationEnvelope envelope,
    String objectId,
    Map<String, dynamic> payload,
  ) async {
    final opType = envelope.opType;
    if (await _cache.getByUuid(objectId) == null) {
      throw NodeNotFoundError('$opType: node $objectId does not exist', opType);
    }
    final permanent = payload['permanent'] == true;
    if (!permanent) {
      // Soft delete: trash the whole subtree (v2 semantics — restore is
      // whole-tree). The trash/archive view reads is_archived.
      final ids = await _cache.subtreeUuids(objectId);
      for (final id in ids) {
        final node = await _cache.getByUuid(id);
        if (node != null) await _cache.upsert(node.copyWithIsArchived(true));
      }
      return true;
    }
    // Permanent delete: hard-delete the subtree and its derived rows.
    await _cache.hardDelete(objectId);
    return true;
  }

  Future<bool> _applyMove(
    OperationEnvelope envelope,
    String objectId,
    Map<String, dynamic> payload,
  ) async {
    final opType = envelope.opType;
    final node = await _cache.getByUuid(objectId);
    if (node == null) {
      throw NodeNotFoundError('$opType: node $objectId does not exist', opType);
    }
    final parentId = payload['parentId'] as String?;
    final afterId = payload['afterId'] as String?;

    // Placement guards fail loud, mirroring object.create.
    if (parentId != null) {
      if (await _cache.getByUuid(parentId) == null) {
        throw NodeNotFoundError(
          '$opType: parent $parentId does not exist',
          opType,
        );
      }
      if (await _cache.isClassNode(parentId)) {
        throw MoveGuardError(
          '$opType: node $parentId is a class; classes are tree-external '
          'and cannot have children',
          opType,
        );
      }
      if ((await _cache.subtreeUuids(objectId)).contains(parentId)) {
        throw MoveGuardError(
          '$opType: cannot move node $objectId under $parentId, which is '
          'in its own subtree',
          opType,
        );
      }
    } else {
      // A block to workspace root is rejected by the placement CHECK (null
      // parent is legal only for pages). Legacy rows without node_type keep
      // their isPage-derived role.
      final isBlock =
          node.nodeType == 'block' || (node.nodeType == null && !node.isPage);
      if (isBlock) {
        throw CheckConstraintError(
          '$opType: a block cannot be parentless (placement CHECK)',
          'node_parent',
          opType,
        );
      }
    }

    final incoming = _incoming(envelope);
    final rowWinner = (
      physical: node.hlcPhysical,
      logical: node.hlcLogical,
      actor: node.actorId ?? '',
    );
    // Parent/position are row-level LWW: re-applying an older move after a
    // newer one drops whole.
    if (compareLww(incoming, rowWinner) <= 0) return false;

    final position = parentId == null
        ? null
        : await _allocateChildPosition(
            _cache,
            parentId: parentId,
            childId: objectId,
            afterId: afterId,
          );

    await _cache.upsert(
      _copyWith(
        node,
        parentUuid: parentId,
        position: position,
        sequence: double.tryParse(position ?? '') ?? node.sequence,
        writeDate: envelope.timestamp,
        hlcPhysical: incoming.physical,
        hlcLogical: incoming.logical,
        actorId: incoming.actor,
      ),
    );
    return true;
  }

  // --- properties ---------------------------------------------------------------

  Future<bool> _applyPropertySet(
    OperationEnvelope envelope,
    String objectId,
    Map<String, dynamic> payload,
  ) async {
    final schemaId = payload['propertySchemaId'] as String;
    final idx = (payload['idx'] as num?)?.toInt() ?? 0;
    final incoming = _incoming(envelope);

    // A tombstone with a winning (>=) (hlc, actor) blocks the write.
    final tombstone = await _cache.propertyTombstoneWinner(
      objectId,
      schemaId,
      idx,
    );
    if (tombstone != null && compareLww(incoming, tombstone) <= 0) {
      return false;
    }

    final existing = await _cache.propertyValueWinner(objectId, schemaId, idx);
    if (existing != null && compareLww(incoming, existing) <= 0) {
      return false;
    }

    final metadata = payload['metadata'];
    await _cache.upsertPropertyValue(
      objectId,
      schemaId,
      idx,
      jsonEncode(payload.containsKey('value') ? payload['value'] : null),
      metadata == null ? null : jsonEncode(metadata),
      incoming,
    );
    await _cache.projectNodeProperties(objectId);
    return true;
  }

  Future<bool> _applyPropertyUnset(
    OperationEnvelope envelope,
    String objectId,
    Map<String, dynamic> payload,
  ) async {
    final schemaId = payload['propertySchemaId'] as String;
    final idx = (payload['idx'] as num?)?.toInt() ?? 0;
    final incoming = _incoming(envelope);

    // Upsert the tombstone only when the incoming write wins the slot.
    final tombstone = await _cache.propertyTombstoneWinner(
      objectId,
      schemaId,
      idx,
    );
    if (tombstone == null || compareLww(incoming, tombstone) > 0) {
      await _cache.upsertPropertyTombstone(objectId, schemaId, idx, incoming);
    }

    final existing = await _cache.propertyValueWinner(objectId, schemaId, idx);
    if (existing != null && compareLww(incoming, existing) > 0) {
      await _cache.deletePropertyValue(objectId, schemaId, idx);
    }
    await _cache.projectNodeProperties(objectId);
    return true;
  }

  // --- classes ------------------------------------------------------------------

  Future<void> _applyClassCreate(
    OperationEnvelope envelope,
    Map<String, dynamic> payload,
  ) async {
    final classId = payload['classId'] as String;
    await _cache.upsertClass(
      uuid: classId,
      name: payload['name'] as String?,
      icon: payload['icon'] as String?,
      color: payload['color'] as String?,
      description: payload['description'] as String?,
      active: true,
      createdAt: envelope.timestamp,
      updatedAt: envelope.timestamp,
    );
  }

  Future<bool> _applyClassUpdate(
    OperationEnvelope envelope,
    Map<String, dynamic> payload,
  ) async {
    final classId = payload['classId'] as String;
    final existing = await _cache.getClassByUuid(classId);
    if (existing == null) {
      throw NodeNotFoundError(
        '${envelope.opType}: class $classId does not exist',
        envelope.opType,
      );
    }
    await _cache.upsertClass(
      uuid: classId,
      name: payload.containsKey('name')
          ? payload['name'] as String?
          : existing.name,
      icon: payload.containsKey('icon')
          ? payload['icon'] as String?
          : existing.icon,
      color: payload.containsKey('color')
          ? payload['color'] as String?
          : existing.color,
      description: payload['description'] as String?,
      updatedAt: envelope.timestamp,
    );
    return true;
  }

  Future<void> _applyClassDelete(Map<String, dynamic> payload) async {
    final classId = payload['classId'] as String;
    await _cache.deleteClass(classId);
  }

  Future<void> _applyClassSetExtends(
    OperationEnvelope envelope,
    Map<String, dynamic> payload,
  ) async {
    final opType = envelope.opType;
    final classId = payload['classId'] as String;
    final parentClassIds = _readStringList(payload['parentClassIds']);
    if (await _cache.getClassByUuid(classId) == null) {
      throw NodeNotFoundError('$opType: class $classId does not exist', opType);
    }

    // Cycle gate, checked against the pre-write closure (so multi-hop cycles
    // across several parents are covered too). All checks run before any
    // write: a thrown apply leaves the closure and edges exactly as they
    // were, and the envelope id is not consumed.
    for (final parentClassId in parentClassIds) {
      if (await _cache.getClassByUuid(parentClassId) == null) {
        throw NodeNotFoundError(
          '$opType: parent class $parentClassId does not exist',
          opType,
        );
      }
      if (parentClassId == classId) {
        throw CycleError(
          '$opType: class $classId cannot extend itself',
          opType,
        );
      }
      // A cycle forms when the class is already an ancestor of one of its
      // new parents.
      if (await _cache.hierarchyContains(parentClassId, classId)) {
        throw CycleError(
          '$opType: class $classId is already an ancestor of $parentClassId; '
          'extends would cycle',
          opType,
        );
      }
    }

    // Replace semantics: the payload array IS the class's full parent set —
    // drop every previous edge, insert the new ones, rebuild the closure.
    await _cache.replaceClassExtends(classId, parentClassIds);
    await _cache.setClassExtends(classId, parentClassIds);
    await _cache.rebuildClassHierarchy();
  }

  // --- property schemas -----------------------------------------------------------

  Future<void> _applyPropertySchemaCreate(Map<String, dynamic> payload) async {
    final propertySchemaId = payload['propertySchemaId'] as String;
    await _cache.upsertPropertySchema(
      PropertySchemaRow(
        uuid: propertySchemaId,
        workspaceId: '', // Workspace is implicit to the local cache.
        name: payload['name'] as String? ?? '',
        type: payload['type'] as String? ?? 'text',
        multi: payload['multi'] == true,
        isSystem: false,
        scope: payload['scope'] as String? ?? 'global',
        options:
            (payload['options'] as List<dynamic>?)
                ?.cast<Map<String, dynamic>>() ??
            const [],
        classFilterUuids: _readStringList(payload['targetClassFilter']),
      ),
    );
  }

  Future<bool> _applyPropertySchemaUpdate(Map<String, dynamic> payload) async {
    final propertySchemaId = payload['propertySchemaId'] as String;
    final existing = await _cache.getPropertySchemaRow(propertySchemaId);
    if (existing == null) {
      throw NodeNotFoundError(
        'propertySchema.update: schema $propertySchemaId does not exist',
        'propertySchema.update',
      );
    }
    await _cache.upsertPropertySchema(
      PropertySchemaRow(
        uuid: propertySchemaId,
        workspaceId: existing.workspaceId,
        name: payload.containsKey('name')
            ? (payload['name'] as String?) ?? existing.name
            : existing.name,
        options: payload.containsKey('options')
            ? (payload['options'] as List<dynamic>?)
                      ?.cast<Map<String, dynamic>>() ??
                  const []
            : existing.options,
        // v2 propertySchema.update only carries name/options; everything
        // else is preserved from the stored row.
        type: existing.type,
        multi: existing.multi,
        isSystem: existing.isSystem,
        scope: existing.scope,
        nodeUuid: existing.nodeUuid,
        iconVisibility: existing.iconVisibility,
        validationRules: existing.validationRules,
        required: existing.required,
        readonly: existing.readonly,
        hideWhenEmpty: existing.hideWhenEmpty,
        defaultValue: existing.defaultValue,
        classFilterUuids: existing.classFilterUuids,
        computed: existing.computed,
      ),
    );
    return true;
  }

  Future<void> _applyPropertySchemaDelete(Map<String, dynamic> payload) async {
    final propertySchemaId = payload['propertySchemaId'] as String;
    await _cache.deletePropertySchema(propertySchemaId);
  }

  // --- collections ------------------------------------------------------------------

  Future<bool> _applyCollectionMember(
    OperationEnvelope envelope,
    Map<String, dynamic> payload, {
    required bool present,
  }) async {
    final collectionId = payload['collectionId'] as String;
    final objectId = payload['objectId'] as String;
    final incoming = _incoming(envelope);
    final stored = await _cache.collectionMemberWinner(collectionId, objectId);
    // OR-Set add-wins: an add with an equal (hlc, actor) to a remove still
    // wins, so the add comparator is >= while the remove comparator is >.
    final wins =
        stored == null ||
        (present
            ? compareLww(incoming, stored) >= 0
            : compareLww(incoming, stored) > 0);
    if (!wins) return false;
    await _cache.upsertCollectionMember(
      collectionId,
      objectId,
      present,
      incoming,
    );
    return true;
  }

  // --- fractional position allocator (port of appliers.ts) ---------------------------

  /// Append position: lexicographic fractional string after [last].
  static String nextChildPosition(String? last) =>
      last != null ? '${last}a' : 'a';

  /// Lexicographic midpoint of two fractional position strings: the shortest
  /// string strictly greater than [lo] and strictly less than [hi]
  /// (precondition lo < hi, ASCII). Boundary chars use '`' (one below 'a')
  /// as the floor and '{' (one above 'z') as the ceil, so distinct positions
  /// always have room. Deterministic — no random suffix — so wipe -> replay
  /// converges to byte-identical state.
  static String midpointBetween(String lo, String hi) {
    var i = 0;
    while (i < lo.length &&
        i < hi.length &&
        lo.codeUnitAt(i) == hi.codeUnitAt(i)) {
      i++;
    }
    final prefix = lo.substring(0, i);
    final loRest = lo.substring(i);
    final hiRest = hi.substring(i);
    final loCode = loRest.isNotEmpty ? loRest.codeUnitAt(0) : 0x60;
    final hiCode = hiRest.isNotEmpty ? hiRest.codeUnitAt(0) : 0x7b;
    if (loCode + 1 < hiCode) {
      return prefix + String.fromCharCode((loCode + 1 + hiCode - 1) ~/ 2);
    }
    if (loRest.isEmpty) {
      // lo is a prefix of hi and hi continues at the lowest digit: squeeze
      // one char below hi's next digit.
      return prefix + String.fromCharCode(hiCode - 1);
    }
    // Adjacent boundary chars: keep lo's digit (which is < hi's) and descend.
    return prefix +
        loRest[0] +
        midpointBetween(loRest.substring(1), hiRest.substring(1));
  }

  /// Fractional position for [childId] under [parentId], placed immediately
  /// after the sibling [afterId]: sibling midpoint, append-at-end when
  /// [afterId] is the last sibling, and a defensive plain append when
  /// [afterId] is not a current sibling.
  static Future<String> _allocateChildPosition(
    NodeCacheRepository cache, {
    required String parentId,
    required String childId,
    required String? afterId,
  }) async {
    if (afterId != null) {
      final after = await cache.childPosition(parentId, afterId);
      if (after != null) {
        final next = await cache.nextSiblingPosition(
          parentId,
          after,
          excludeChildUuid: childId,
        );
        return next != null
            ? midpointBetween(after, next)
            : nextChildPosition(
                await cache.lastChildPosition(
                  parentId,
                  excludeChildUuid: childId,
                ),
              );
      }
    }
    return nextChildPosition(
      await cache.lastChildPosition(parentId, excludeChildUuid: childId),
    );
  }

  List<String> _readStringList(dynamic value) {
    if (value is List<dynamic>) {
      return value.cast<String>();
    }
    return const [];
  }
}

/// Field-wise copy used by the v2 appliers (the local [Node] model predates
/// copyWith for these fields).
Node _copyWith(
  Node node, {
  String? name,
  String? displayName,
  String? title,
  String? nodeType,
  String? icon,
  String? color,
  String? parentUuid,
  String? position,
  double? sequence,
  String? writeDate,
  int? hlcPhysical,
  int? hlcLogical,
  String? actorId,
  bool? isPage,
}) => Node(
  id: node.id,
  uuid: node.uuid,
  name: name ?? node.name,
  displayName: displayName ?? node.displayName,
  icon: icon ?? node.icon,
  color: color ?? node.color,
  parentId: node.parentId,
  parentUuid: parentUuid ?? node.parentUuid,
  pageId: node.pageId,
  pageUuid: node.pageUuid,
  sequence: sequence ?? node.sequence,
  position: position ?? node.position,
  isPage: isPage ?? node.isPage,
  isTask: node.isTask,
  isDaily: node.isDaily,
  isMonthly: node.isMonthly,
  isYearly: node.isYearly,
  isTable: node.isTable,
  isAsset: node.isAsset,
  isComment: node.isComment,
  isDeleted: node.isDeleted,
  isArchived: node.isArchived,
  isPrivate: node.isPrivate,
  classes: node.classes,
  classesUuid: node.classesUuid,
  tags: node.tags,
  tagsUuid: node.tagsUuid,
  properties: node.properties,
  children: node.children,
  createDate: node.createDate,
  writeDate: writeDate ?? node.writeDate,
  extendsUuid: node.extendsUuid,
  title: title ?? node.title,
  nodeType: nodeType ?? node.nodeType,
  hlcPhysical: hlcPhysical ?? node.hlcPhysical,
  hlcLogical: hlcLogical ?? node.hlcLogical,
  actorId: actorId ?? node.actorId,
);

({
  bool isTask,
  bool isDaily,
  bool isMonthly,
  bool isYearly,
  bool isTable,
  bool isAsset,
  bool isComment,
})
_deriveFlags(List<String> classIds) {
  return (
    isTask: classIds.contains(SystemClassUuids.task),
    isDaily: classIds.contains(SystemClassUuids.day),
    isMonthly: classIds.contains(SystemClassUuids.month),
    isYearly: classIds.contains(SystemClassUuids.year),
    isTable: classIds.contains(SystemClassUuids.table),
    isAsset: classIds.contains(SystemClassUuids.asset),
    isComment: classIds.contains(SystemClassUuids.comment),
  );
}
