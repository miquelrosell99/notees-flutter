import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/constants/system.dart';
import '../../core/utils/ast_builder.dart';
import '../../core/utils/ast_stringifier.dart';
import '../../core/utils/node_display_name.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_cache_repository.dart';
import '../models/relay/lww.dart';
import '../models/relay/operation_envelope.dart';
import '../models/relay/operation_payloads.dart';
import '../models/relay/store_errors.dart';

/// Applies v2 relay operation envelopes to the local derived state, porting
/// `packages/store/src/appliers.ts` semantics:
///
///  - row-level LWW by (hlc_physical, hlc_logical, actor_id): higher HLC
///    wins, equal HLC breaks the tie on actor id (deterministic);
///  - title-is-content (2026-10-01 lockstep): the protocol has no node
///    `name` field — a node's title IS its content; the display name is the
///    content excerpt (date labels formatted), derived at apply time;
///  - render-state model (Revision 11, 2026-10-02): `is_class` (identity;
///    classes are always roots, containers of non-class children) +
///    `present_as_main` (render bit for parented non-class nodes) replace
///    the retired page/block/class enumeration — document-chrome nodes
///    (main-presenting, or any parentless non-class node) carry text-only
///    content, inline blocks keep the rich stream; promotion stringifies,
///    demotion never un-flattens; the retired `nodeType` payload key is
///    rejected outright by the strict validators (no replay-compat code);
///  - sibling order uses the lexicographic fractional allocator
///    (midpointBetween/nextChildPosition), stored in node_cache.position;
///  - class membership, tag membership and collection membership are
///    OR-Sets (add-wins per pair, LWW per pair by (hlc, actor)), projected
///    into node rows; user-defined class order rides class.reorder
///    (LWW-by-arrival) and the class list projects ordered members first;
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
      case 'object.restore':
        return _applyRestore(envelope, objectId, payload);
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
      case 'class.property.set':
        return _applyClassPropertySet(envelope, payload);
      case 'class.property.unset':
        await _applyClassPropertyUnset(payload);
        return true;
      case 'class.unassign':
        return _applyClassUnassign(envelope, payload);
      case 'class.reorder':
        return _applyClassReorder(payload);
      case 'tag.unassign':
        return _applyTagUnassign(envelope, payload);
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
    final afterId = payload['afterId'] as String?;
    final beforeId = payload['beforeId'] as String?;
    // Render bit (Revision 11): the payload may carry presentAsMain; the
    // applier defaults it by placement — a parentless node presents as main
    // (document chrome by the second cascade branch), a parented one starts
    // inline (block chrome; the "hide from body" gloss is the 0→1 toggle).
    final presentAsMain = payload.containsKey('presentAsMain')
        ? payload['presentAsMain'] == true
        : parentId == null;
    final incoming = _incoming(envelope);

    // Placement guard: the parent must exist — either as a node row or as a
    // class (classes are containers since spec I4: a class parent is legal
    // for non-class children, which is all object.create can make — class
    // declaration remains the class.create op, so the class-under-class
    // shape is unreachable here).
    if (parentId != null) {
      if (await _cache.getByUuid(parentId) == null &&
          !await _cache.isClassNode(parentId)) {
        throw NodeNotFoundError(
          '$opType: parent $parentId does not exist',
          opType,
        );
      }
    }

    // Seed OR-Set membership first: a re-issued create is the v2 membership
    // carrier (add-wins per pair), even when the node already exists. The
    // class add's comparator is >= on the actor tiebreak (an exact-HLC add
    // beats a class.unassign remove in either delivery order); the tag add's
    // is strictly-greater, matching the v2 store's tagMemberUpsert gating.
    final classIds = _readStringList(payload['classIds']);
    for (final classId in classIds) {
      final stored = await _cache.classMemberWinner(objectId, classId);
      if (stored == null || compareLww(incoming, stored) >= 0) {
        await _cache.upsertClassMember(objectId, classId, true, incoming);
      }
    }
    final tagIds = _readStringList(payload['tagIds']);
    for (final tagId in tagIds) {
      final stored = await _cache.tagMemberWinner(objectId, tagId);
      if (stored == null || compareLww(incoming, stored) > 0) {
        await _cache.upsertTagMember(objectId, tagId, true, incoming);
      }
    }

    // First create wins for the tree: re-issuing object.create on an
    // existing id must not move the node or revert later edits (the v1
    // dual-parent corruption class this op replaces).
    if (await _cache.getByUuid(objectId) != null) {
      if (classIds.isNotEmpty) await _cache.recomputeClassIds(objectId);
      if (tagIds.isNotEmpty) await _cache.recomputeTagIds(objectId);
      return false;
    }

    // Content flatten invariant (Revision 11): a main-presenting node
    // carries text-only content; an inline block keeps the full rich token
    // stream (class rows never reach this op).
    final contentAst = payload['contentAst'];
    final flatAst = switch (contentAst) {
      List<dynamic> list => presentAsMain
          ? stringifyContentAst(normalizeContentAst(list))
          : normalizeContentAst(list),
      _ => const <Map<String, dynamic>>[],
    };
    final name = AstBuilder.serialize(flatAst);
    final flags = _deriveFlags(classIds);
    final position = parentId == null
        ? null
        : await _allocateChildPosition(
            _cache,
            parentId: parentId,
            childId: objectId,
            afterId: afterId,
            beforeId: beforeId,
          );

    await _cache.upsert(
      Node(
        id: 0,
        uuid: objectId,
        name: name,
        displayName: deriveDisplayName(name),
        parentUuid: parentId,
        position: position,
        sequence: double.tryParse(position ?? '') ?? 0.0,
        classesUuid: classIds,
        tagsUuid: tagIds,
        isPage: presentAsMain,
        isTask: flags.isTask,
        isDaily: flags.isDaily,
        isMonthly: flags.isMonthly,
        isYearly: flags.isYearly,
        isTable: flags.isTable,
        isAsset: flags.isAsset,
        isComment: flags.isComment,
        properties: const {},
        writeDate: envelope.timestamp,
        isClass: false,
        presentAsMain: presentAsMain,
        hlcPhysical: incoming.physical,
        hlcLogical: incoming.logical,
        actorId: incoming.actor,
      ),
    );
    if (classIds.isNotEmpty) await _cache.recomputeClassIds(objectId);
    if (tagIds.isNotEmpty) await _cache.recomputeTagIds(objectId);
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

    // Promotion/demotion (Revision 11) is the presentAsMain toggle: the bit
    // joins the row-level LWW set; a false → true flip (promotion)
    // stringifies the stored rich stream to text-only in the same op
    // (content flatten invariant), while a true → false demotion leaves the
    // (already flattened) content untouched — demotion never un-flattens.
    // On a class row the bit is inert (classes render ClassView regardless);
    // applying it harmlessly keeps the op uniform.
    var resultingPresentAsMain = node.presentAsMain ?? false;
    String? newName = node.name;
    var newDisplay = node.displayName;
    if (payload.containsKey('presentAsMain')) {
      final bit = payload['presentAsMain'] == true;
      resultingPresentAsMain = bit;
      if (bit && node.presentAsMain != true && node.name.isNotEmpty) {
        try {
          final stored = jsonDecode(node.name);
          if (stored is List<dynamic>) {
            newName = AstBuilder.serialize(stringifyContentAst(
              normalizeContentAst(stored),
            ));
            newDisplay = deriveDisplayName(newName);
          }
        } on FormatException {
          // Not a JSON document (legacy plain text): already text-only.
        }
      }
    }
    final contentAst = payload['contentAst'];
    if (contentAst is List<dynamic>) {
      // Document-chrome content (class nodes and main-presenting nodes) is
      // text-only; inline blocks keep the rich tokens they were sent.
      final flatten = node.isClass || resultingPresentAsMain;
      final flatAst = flatten
          ? stringifyContentAst(normalizeContentAst(contentAst))
          : normalizeContentAst(contentAst);
      newName = AstBuilder.serialize(flatAst);
      newDisplay = deriveDisplayName(newName);
    }
    await _cache.upsert(
      _copyWith(
        node,
        name: newName,
        displayName: newDisplay,
        presentAsMain: resultingPresentAsMain,
        // The is_page query flag follows the bit (document chrome ⇔
        // parentless or main-presenting); class rows are tree-external and
        // keep whatever they carried (they live in class_cache locally).
        isPage: node.isClass ? node.isPage : resultingPresentAsMain,
        icon: payload['icon'] as String? ?? node.icon,
        color: payload['color'] as String? ?? node.color,
        writeDate: envelope.timestamp,
        hlcPhysical: incoming.physical,
        hlcLogical: incoming.logical,
        actorId: incoming.actor,
      ),
    );
    if (contentAst is List<dynamic>) {
      await _cache.rebuildEdges(objectId, at: envelope.timestamp);
    }
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
      // whole-tree). The trash/archive view reads is_archived; the
      // trash_root row (one per root, lockstep with the TS `trash` table)
      // is what lets object.restore tell "rode with the parent" apart from
      // "trashed independently".
      final ids = await _cache.subtreeUuids(objectId);
      for (final id in ids) {
        final node = await _cache.getByUuid(id);
        if (node != null) await _cache.upsert(node.copyWithIsArchived(true));
      }
      await _cache.recordTrashRoot(
        objectId,
        deletedAt: DateTime.now().toUtc().toIso8601String(),
      );
      return true;
    }
    // Permanent delete: hard-delete the subtree and its derived rows.
    await _cache.hardDelete(objectId);
    return true;
  }

  Future<bool> _applyRestore(
    OperationEnvelope envelope,
    String objectId,
    Map<String, dynamic> payload,
  ) async {
    final opType = envelope.opType;
    final root = await _cache.getByUuid(objectId);
    if (root == null) {
      throw NodeNotFoundError('$opType: node $objectId does not exist', opType);
    }
    // Corner: dangling parent (parent permanently deleted / legacy data) —
    // reparent to the workspace root; a present-but-inactive parent is left
    // alone (restoring the parent later heals the tree).
    final parentUuid = root.parentUuid;
    if (parentUuid != null && await _cache.getByUuid(parentUuid) == null) {
      await _cache.upsert(
        _copyWith(root, parentUuid: null, isPage: true),
      );
    }
    // Whole-tree: reactivate exactly the nodes that rode THIS trash event.
    // A descendant with its OWN trash_root row was trashed independently
    // (its subtree rode with it) and stays trashed.
    final ids = await _cache.subtreeUuids(objectId);
    final ownTrash = await _cache.trashRootIds(ids);
    final toReactivate = <String>[];
    for (final id in ids) {
      if (id != objectId && ownTrash.contains(id)) continue;
      var cursor = (await _cache.getByUuid(id))?.parentUuid;
      var ridesThisDelete = true;
      while (cursor != null) {
        if (cursor == objectId) break;
        if (ownTrash.contains(cursor)) {
          ridesThisDelete = false;
          break;
        }
        cursor = (await _cache.getByUuid(cursor))?.parentUuid;
      }
      if (ridesThisDelete) toReactivate.add(id);
    }
    for (final id in toReactivate) {
      final node = await _cache.getByUuid(id);
      if (node != null && node.isArchived) {
        await _cache.upsert(node.copyWithIsArchived(false));
      }
    }
    await _cache.consumeTrashRoot(objectId);
    return true;
  }

  Future<bool> _applyMove(
    OperationEnvelope envelope,
    String objectId,
    Map<String, dynamic> payload,
  ) async {
    final opType = envelope.opType;
    final node = await _cache.getByUuid(objectId);
    final parentId = payload['parentId'] as String?;
    final afterId = payload['afterId'] as String?;
    final beforeId = payload['beforeId'] as String?;

    if (node == null) {
      // Classes have no local node row (class_cache is their home). A class
      // can never gain a parent: classes are always roots — the guard
      // surfaces that friendly rather than as a missing-node error. Moving
      // a class to the root is a no-op (it has no row to update).
      if (parentId != null && await _cache.isClassNode(objectId)) {
        throw MoveGuardError(
          '$opType: node $objectId is a class; classes are always roots '
          'and cannot have a parent',
          opType,
        );
      }
      throw NodeNotFoundError('$opType: node $objectId does not exist', opType);
    }

    // Placement guards fail loud, mirroring object.create: the parent must
    // exist (a class parent is legal — classes are containers of non-class
    // children, spec I4), and a node may never move under itself or its own
    // descendant (parent_id cycle). A parentless non-class node is legal
    // too: it renders with document chrome by the second cascade branch
    // regardless of present_as_main.
    if (parentId != null) {
      if (await _cache.getByUuid(parentId) == null &&
          !await _cache.isClassNode(parentId)) {
        throw NodeNotFoundError(
          '$opType: parent $parentId does not exist',
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
      if (node.isClass) {
        throw MoveGuardError(
          '$opType: node $objectId is a class; classes are always roots '
          'and cannot have a parent',
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
    // newer one drops whole. Moves never write the render bit: the bit is
    // read only for parented non-class nodes, so a parentless landing
    // renders with document chrome by the second cascade branch regardless
    // of the stored bit.
    if (compareLww(incoming, rowWinner) <= 0) return false;

    final position = parentId == null
        ? null
        : await _allocateChildPosition(
            _cache,
            parentId: parentId,
            childId: objectId,
            afterId: afterId,
            beforeId: beforeId,
          );

    await _cache.upsert(
      _copyWith(
        node,
        parentUuid: parentId,
        position: position,
        sequence: double.tryParse(position ?? '') ?? node.sequence,
        // Document chrome ⇔ the landing is parentless or the stored bit is
        // set; moves never write the bit, so a parented landing follows it.
        isPage: parentId == null || node.presentAsMain == true,
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
      // Title-is-content: the registry name is a denormalized cache of the
      // class node's title text — the plain-text excerpt of contentAst.
      name: _classTitle(payload),
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
      name: payload.containsKey('contentAst')
          ? _classTitle(payload)
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

  /// The class display name: the plain-text excerpt of the payload's
  /// contentAst (title-is-content), "" when no contentAst is set.
  String _classTitle(Map<String, dynamic> payload) {
    final contentAst = payload['contentAst'];
    if (contentAst is! List<dynamic>) return '';
    return contentSourceToExcerpt(contentAst);
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

  Future<bool> _applyClassPropertySet(
    OperationEnvelope envelope,
    Map<String, dynamic> payload,
  ) async {
    final classId = payload['classId'] as String;
    final schemaId = payload['propertySchemaId'] as String;
    final incoming = _incoming(envelope);

    final existing = await _cache.classPropertyBindingWinner(classId, schemaId);
    if (existing != null && compareLww(incoming, existing) <= 0) {
      return false;
    }

    final hasDefault = payload.containsKey('defaultValue');
    await _cache.upsertClassPropertyBinding(
      classId: classId,
      schemaId: schemaId,
      incoming: incoming,
      sequence: (payload['sequence'] as num?)?.toInt(),
      required: payload['required'] as bool?,
      readonly: payload['readonly'] as bool?,
      hideWhenEmpty: payload['hideWhenEmpty'] as bool?,
      defaultValueJson: hasDefault
          ? jsonEncode(payload.containsKey('defaultValue')
              ? payload['defaultValue']
              : null)
          : null,
    );
    return true;
  }

  Future<void> _applyClassPropertyUnset(Map<String, dynamic> payload) async {
    await _cache.deleteClassPropertyBinding(
      payload['classId'] as String,
      payload['propertySchemaId'] as String,
    );
  }

  Future<bool> _applyClassUnassign(
    OperationEnvelope envelope,
    Map<String, dynamic> payload,
  ) async {
    final opType = envelope.opType;
    final objectId = payload['objectId'] as String;
    final classId = payload['classId'] as String;
    if (await _cache.getByUuid(objectId) == null) {
      throw NodeNotFoundError('$opType: node $objectId does not exist', opType);
    }
    // OR-Set remove: the membership pair is tombstoned, gated strictly
    // greater on (hlc, logical, actor) — an exact-HLC add wins the tie in
    // either delivery order (the re-issued object.create seed comparator
    // is >= on the actor tiebreak, the remove's is >).
    final incoming = _incoming(envelope);
    final stored = await _cache.classMemberWinner(objectId, classId);
    if (stored == null || compareLww(incoming, stored) > 0) {
      await _cache.upsertClassMember(objectId, classId, false, incoming);
    }
    // class_ids recompute from the present rows — bound defaults stop
    // deriving (nothing stored), authored values survive by design.
    await _cache.recomputeClassIds(objectId);
    return true;
  }

  /// Class ORDER (class.reorder): display-only user ordering, LWW-by-arrival
  /// — the write is unconditional and deterministic per op order, so
  /// convergent replicas agree. The class_ids projection merges: ordered
  /// members first, then unlisted members sorted by id (recomputeClassIds).
  Future<bool> _applyClassReorder(Map<String, dynamic> payload) async {
    final opType = 'class.reorder';
    final objectId = payload['objectId'] as String;
    final classIds = _readStringList(payload['classIds']);
    if (await _cache.getByUuid(objectId) == null) {
      throw NodeNotFoundError('$opType: node $objectId does not exist', opType);
    }
    await _cache.setClassOrder(objectId, classIds);
    await _cache.recomputeClassIds(objectId);
    return true;
  }

  /// Tag removal (tag.unassign): the OR-Set remove complement of the
  /// re-issued object.create add carrier — identical gating to
  /// [_applyClassUnassign] (strictly-greater on (hlc, actor)), own table.
  Future<bool> _applyTagUnassign(
    OperationEnvelope envelope,
    Map<String, dynamic> payload,
  ) async {
    final opType = 'tag.unassign';
    final objectId = payload['objectId'] as String;
    final tagId = payload['tagId'] as String;
    if (await _cache.getByUuid(objectId) == null) {
      throw NodeNotFoundError('$opType: node $objectId does not exist', opType);
    }
    final incoming = _incoming(envelope);
    final stored = await _cache.tagMemberWinner(objectId, tagId);
    if (stored == null || compareLww(incoming, stored) > 0) {
      await _cache.upsertTagMember(objectId, tagId, false, incoming);
    }
    await _cache.recomputeTagIds(objectId);
    return true;
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

  /// Fractional position for [childId] under [parentId], by anchor (port of
  /// `allocateChildPosition` in `appliers.ts`):
  /// - [afterId]: sibling midpoint between afterId's position and the next
  ///   sibling's, append-at-end when afterId is the last sibling;
  /// - [beforeId]: sibling midpoint between the previous sibling's position
  ///   and beforeId's — or, when beforeId is the first child, one slot below
  ///   it (midpoint against the empty string: the only way to place BEFORE
  ///   the current first sibling, which the afterId-only algebra cannot
  ///   express);
  /// - no usable anchor (absent, or not a current sibling): defensive plain
  ///   append.
  /// When both anchors are present [afterId] wins — but only when afterId is
  /// a current sibling: an afterId that is not a current sibling falls
  /// through to the beforeId branch (the TS reference never sends both).
  static Future<String> _allocateChildPosition(
    NodeCacheRepository cache, {
    required String parentId,
    required String childId,
    required String? afterId,
    String? beforeId,
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
    if (beforeId != null) {
      final before = await cache.childPosition(parentId, beforeId);
      if (before != null) {
        final prev = await cache.prevSiblingPosition(
          parentId,
          before,
          excludeChildUuid: childId,
        );
        return prev != null
            ? midpointBetween(prev, before)
            : midpointBetween('', before);
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

/// Sentinel distinguishing "argument not given" from an explicit null
/// (clearing `parentUuid`/`position` on a move to the workspace root).
const _undefined = Object();

/// Field-wise copy used by the v2 appliers (the local [Node] model predates
/// copyWith for these fields).
Node _copyWith(
  Node node, {
  String? name,
  String? displayName,
  bool? presentAsMain,
  String? icon,
  String? color,
  Object? parentUuid = _undefined,
  Object? position = _undefined,
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
  parentUuid: identical(parentUuid, _undefined)
      ? node.parentUuid
      : parentUuid as String?,
  pageId: node.pageId,
  pageUuid: node.pageUuid,
  sequence: sequence ?? node.sequence,
  position: identical(position, _undefined) ? node.position : position as String?,
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
  title: node.title,
  // Identity never changes on the update/move paths.
  isClass: node.isClass,
  presentAsMain: presentAsMain ?? node.presentAsMain,
  classOrder: node.classOrder,
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
