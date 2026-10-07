import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/constants/system.dart';
import '../../core/utils/ast_builder.dart';
import '../../core/utils/ast_stringifier.dart';
import '../../core/utils/date_uuid.dart';
import '../../core/utils/node_display_name.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_cache_repository.dart';
import '../models/relay/lww.dart';
import '../models/relay/operation_envelope.dart';
import '../models/relay/operation_payloads.dart';
import '../models/relay/property_value_shapes.dart';
import '../models/relay/store_errors.dart';
import '../models/relay/workspace_features.dart';

/// Applies relay operation envelopes to the local derived state, porting
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
///  - property values: single-value slots stay LWW at the deterministic
///    positional element; multi-value slots are an OR-Set of PG5 elements
///    (per-element row id, add-wins tombstones; the membership comparator
///    is HLC-only so on equal HLC the add wins regardless of actor);
///    dateQualified schemas normalize the reserved metadata qualifier keys
///    to date-node refs on write (PC6); unsetting a node-backed text value
///    trashes the unreferenced carrier block;
///  - PG6 apply-time value validation: a property.set against a
///    known schema row validates one-shape-per-type (legacy bare-uuid refs
///    and numeric strings normalize to the canonical encoding), the
///    datePrecision ceiling, the targetClassFilter via the extends-aware
///    walk, and node-target existence — failing loud (image values stay
///    deliberately unchecked); a single-value schema takes idx 0 only; a
///    class.property.set defaultValue must be typed per the schema (PC2);
///    the effective read model resolves bindings extends-aware (PG4: BFS
///    over class_extends, own binding at distance 0, shortest path then
///    earliest assignment HLC then class id — boundBy names the supplying
///    ancestor) and drops a stored default that no longer matches the
///    schema type;
///  - per-workspace feature toggles (workspace.feature.set) LWW by HLC on
///    (workspace, feature) derive the membership-preserving archival of the
///    five managed class families (F2 absent-row=ON, F3 keep-data, F4
///    class.delete-on-a-base routes to the toggle; the tasks enable authors
///    the task family at the fixed seed ids on every enable payload);
///  - appliers fail loud with typed [StoreError]s and never swallow a write
///    silently. Envelope-id idempotency lives in the sync service
///    (relay_operations dedupe), mirroring applied_envelope in the TS store.
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
    // representation and are intentionally ignored. `workspace.feature.set`
    // is the one target-less op WITH a derived representation (the
    // workspace_feature row): it routes by op type below.
    if (objectId.isEmpty && envelope.opType != 'workspace.feature.set') {
      return false;
    }

    // Known ops validate their payload before touching state (the relay
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
        return _applyClassDelete(envelope, payload);
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
      case 'workspace.feature.set':
        return _applyWorkspaceFeatureSet(envelope, payload);
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
        // (including legacy ops dropped from the op registry:
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

    // Seed OR-Set membership first: a re-issued create is the membership
    // carrier (add-wins per pair), even when the node already exists. The
    // class add's comparator is >= on the actor tiebreak (an exact-HLC add
    // beats a class.unassign remove in either delivery order); the tag add's
    // is strictly-greater, matching the TS store's tagMemberUpsert gating.
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
    // existing id must not move the node or revert later edits (the legacy
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
      // Class content stays text-only; every other node keeps the rich token
      // stream it was sent. A page's own content may carry inline tokens
      // (mentions, external links) — the header title edits it with the
      // full block editor — while display-name derivation still flattens to
      // text for labels (title-is-content). Create-as-main and the promotion
      // stringify above remain the lossy boundaries.
      final flatten = node.isClass;
      final flatAst = flatten
          ? stringifyContentAst(normalizeContentAst(contentAst))
          : normalizeContentAst(contentAst);
      newName = AstBuilder.serialize(flatAst);
      newDisplay = deriveDisplayName(newName);
    }

    // Wire node fields (the icon/color precedent, 2026-10-07 lockstep):
    // presence writes, present-null clears — exactly like `color` above.
    // Cover/banner map without validating (asset existence is a read/
    // client-layer concern); the alias target DOES validate — see
    // _assertAliasAcyclic below (the extends-DAG precedent: structural
    // invariants are write-time impossible). Clearing (null) cannot create
    // a cycle and skips the check.
    if (payload.containsKey('aliasedNodeId')) {
      final target = payload['aliasedNodeId'] as String?;
      if (target != null) {
        await _assertAliasAcyclic(objectId, target, opType);
      }
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
        // Color is presence-based (TS `if (p.color !== undefined)`): a
        // present null CLEARS the stored color instead of keeping it.
        color: payload.containsKey('color')
            ? payload['color'] as String?
            : node.color,
        coverAssetId: payload.containsKey('coverAssetId')
            ? payload['coverAssetId'] as String?
            : node.coverAssetId,
        bannerAssetId: payload.containsKey('bannerAssetId')
            ? payload['bannerAssetId'] as String?
            : node.bannerAssetId,
        aliasedNodeId: payload.containsKey('aliasedNodeId')
            ? payload['aliasedNodeId'] as String?
            : node.aliasedNodeId,
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

  /// M12 write-time alias-cycle validation (the extends-DAG precedent):
  /// `object.update {aliasedNodeId: T}` on node N must not close an alias
  /// cycle. The would-be chain is N → T → T's target → … — walk it from T;
  /// a revisit of any visited node (including N itself — the 1-edge
  /// self-alias) means the write would create a cycle, so it fails loud and
  /// is NEVER applied. Chains without a cycle terminate (finite graph); the
  /// visited set makes the walk exact.
  Future<void> _assertAliasAcyclic(
    String nodeId,
    String targetId,
    String opType,
  ) async {
    final visited = {nodeId};
    var current = targetId;
    for (;;) {
      if (visited.contains(current)) {
        throw CycleError(
          '$opType: aliasing $nodeId → $targetId would close an alias '
          'cycle at $current',
          opType,
        );
      }
      visited.add(current);
      final next = await _cache.aliasedNodeIdOf(current);
      if (next == null) return;
      current = next;
    }
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
      // Soft delete: trash the whole subtree (relay semantics — restore is
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
  //
  // PG5: multi-value slots are an OR-Set of elements. A
  // payload `elementId` is an element ADD (the property_value row id IS the
  // element id); a payload WITHOUT it is the legacy positional carrier at
  // the deterministic `node:schema:idx` element — replayed stored logs and
  // old clients keep applying unchanged. PC6: dateQualified schemas
  // normalize the reserved metadata qualifier keys (startDate/endDate) to
  // date-node refs on write. PB2: unsetting a node-backed TEXT
  // value trashes the now-unreferenced carrier block under three guards
  // (child-of-owner, active non-class, unreferenced) — derived-state parity
  // with the TS reference on wipe+replay.

  Future<bool> _applyPropertySet(
    OperationEnvelope envelope,
    String objectId,
    Map<String, dynamic> payload,
  ) async {
    final opType = envelope.opType;
    final schemaId = payload['propertySchemaId'] as String;
    final idx = (payload['idx'] as num?)?.toInt() ?? 0;
    final elementId = payload['elementId'] as String?;

    // PB2/PG6: one-shape-per-type + schema-linked integrity
    // at the write path. The schema row (when known — property.set has no
    // schema FK) types the slot: shape/scalar mismatch, a date ref finer
    // than the schema's precision, a target outside the class filter, and a
    // ref to a nonexistent node all fail loud; a legacy bare-uuid reference
    // or a numeric string normalizes to the canonical encoding. The
    // NORMALIZED value is what gets stored.
    final schema = await _cache.propertySchemaValidationRow(schemaId);
    final payloadValue = payload.containsKey('value') ? payload['value'] : null;
    final value = schema != null
        ? await _cache.assertPropertyValueForSchema(
            schema,
            payloadValue,
            opType,
          )
        : payloadValue;
    // PC6 normalize-on-write: a well-formed YYYY-MM-DD string in the
    // reserved qualifier keys rewrites to the deterministic day-node ref —
    // ONLY on dateQualified schemas, only those two keys, pure value
    // rewriting (no graph side effects, no existence assertion).
    final metadata = _normalizeQualifierMetadata(schema, payload);
    // PG6 cardinality: a single-value schema takes idx 0 only. Higher
    // slots would write rows no reader derives (the read model reads slot
    // 0 for a single-value schema's editor), so the write is rejected, not
    // parked.
    if (schema != null && !schema.multi && idx > 0) {
      throw PropertyValueShapeError(
        '$opType: schema $schemaId is single-value — idx must be 0, got $idx',
        opType,
      );
    }

    var dropped = false;
    final encoded = jsonEncode(value);
    if (elementId != null) {
      dropped = await _applyElementAdd(
        envelope,
        objectId: objectId,
        schemaId: schemaId,
        elementId: elementId,
        idx: idx,
        encoded: encoded,
        encodedMetadata: metadata != null ? jsonEncode(metadata) : null,
      );
    } else {
      dropped = await _applyPositionalSet(
        envelope,
        objectId: objectId,
        schemaId: schemaId,
        idx: idx,
        encoded: encoded,
        encodedMetadata: metadata != null ? jsonEncode(metadata) : null,
      );
    }

    await _cache.projectNodeProperties(objectId);
    return !dropped;
  }

  /// PG5 OR-Set element ADD: the row id IS the element id, so adds of
  /// distinct elements never conflict and a re-issued add revives the
  /// element unless a strictly-newer (HLC) tombstone stands — add-wins: on
  /// equal HLC the add proceeds regardless of actor. The value/metadata/idx
  /// overwrite per element uses the full (hlc, actor) tuple, exactly like
  /// the pre-PG5 slot LWW.
  Future<bool> _applyElementAdd(
    OperationEnvelope envelope, {
    required String objectId,
    required String schemaId,
    required String elementId,
    required int idx,
    required String encoded,
    required String? encodedMetadata,
  }) async {
    final incoming = _incoming(envelope);
    final tombstone = await _cache.propertyElementTombstoneWinner(elementId);
    if (tombstone != null &&
        (tombstone.physical > incoming.physical ||
            (tombstone.physical == incoming.physical &&
                tombstone.logical > incoming.logical))) {
      return true; // a strictly-newer remove wins — the add is dropped.
    }

    final existing = await _cache.propertyValueRowById(elementId);
    if (existing == null) {
      await _cache.upsertPropertyValueById(
        id: elementId,
        nodeUuid: objectId,
        schemaId: schemaId,
        idx: idx,
        valueJson: encoded,
        metadataJson: encodedMetadata,
        incoming: incoming,
      );
      return false;
    }
    final rowWinner = (
      physical: (existing['hlc_physical'] as num?)?.toInt() ?? 0,
      logical: (existing['hlc_logical'] as num?)?.toInt() ?? 0,
      actor: existing['actor_id'] as String? ?? '',
    );
    if (compareLww(incoming, rowWinner) > 0) {
      await _cache.upsertPropertyValueById(
        id: elementId,
        nodeUuid: objectId,
        schemaId: schemaId,
        idx: idx,
        valueJson: encoded,
        metadataJson: encodedMetadata,
        incoming: incoming,
      );
      return false;
    }
    // A stale re-add (full tuple <= the live row) leaves the row untouched.
    return true;
  }

  /// The pre-PG5 positional path (payload WITHOUT elementId): unchanged
  /// slot LWW, keyed by the deterministic positional row id — concurrent
  /// element adds may share the idx, but a positional write addresses ONLY
  /// its own deterministic element.
  Future<bool> _applyPositionalSet(
    OperationEnvelope envelope, {
    required String objectId,
    required String schemaId,
    required int idx,
    required String encoded,
    required String? encodedMetadata,
  }) async {
    final incoming = _incoming(envelope);

    // A tombstone with a winning (>=) (hlc, actor) blocks the write.
    final tombstone = await _cache.propertyTombstoneWinner(
      objectId,
      schemaId,
      idx,
    );
    if (tombstone != null && compareLww(incoming, tombstone) <= 0) {
      return true;
    }

    final rowId = NodeCacheRepository.positionalPropertyValueId(
      objectId,
      schemaId,
      idx,
    );
    final existing = await _cache.propertyValueRowById(rowId);
    if (existing != null) {
      final rowWinner = (
        physical: (existing['hlc_physical'] as num?)?.toInt() ?? 0,
        logical: (existing['hlc_logical'] as num?)?.toInt() ?? 0,
        actor: existing['actor_id'] as String? ?? '',
      );
      if (compareLww(incoming, rowWinner) <= 0) return true;
    }

    await _cache.upsertPropertyValue(
      objectId,
      schemaId,
      idx,
      encoded,
      encodedMetadata,
      incoming,
    );
    return false;
  }

  Future<bool> _applyPropertyUnset(
    OperationEnvelope envelope,
    String objectId,
    Map<String, dynamic> payload,
  ) async {
    final schemaId = payload['propertySchemaId'] as String;
    final idx = (payload['idx'] as num?)?.toInt() ?? 0;
    final elementId = payload['elementId'] as String?;

    if (elementId != null) {
      await _applyElementRemove(
        envelope,
        objectId: objectId,
        schemaId: schemaId,
        elementId: elementId,
      );
    } else {
      await _applyPositionalUnset(
        envelope,
        objectId: objectId,
        schemaId: schemaId,
        idx: idx,
      );
    }
    await _cache.projectNodeProperties(objectId);
    return true;
  }

  /// PG5 OR-Set element REMOVE: records the remove's causality on the
  /// element tombstone (callers gate the strictly-greater upsert — on an
  /// exact tie the earlier add sticks, add-wins) and deletes the live row
  /// when the remove's HLC is strictly newer than the row's (equal HLC
  /// keeps the row — the add wins ties). An unset addressed at an element
  /// that exists under a DIFFERENT (node, schema) is malformed: ignored,
  /// like a stale write (deterministic on every replica).
  Future<void> _applyElementRemove(
    OperationEnvelope envelope, {
    required String objectId,
    required String schemaId,
    required String elementId,
  }) async {
    final incoming = _incoming(envelope);
    final existing = await _cache.propertyValueRowById(elementId);
    if (existing != null &&
        (existing['node_uuid'] != objectId ||
            existing['property_schema_id'] != schemaId)) {
      return; // malformed addressing — deterministic no-op.
    }

    final tombstone = await _cache.propertyElementTombstoneWinner(elementId);
    if (tombstone == null || compareLww(incoming, tombstone) > 0) {
      await _cache.upsertPropertyElementTombstone(
        elementId: elementId,
        nodeUuid: objectId,
        schemaId: schemaId,
        incoming: incoming,
      );
    }

    if (existing == null) return;
    final removeWinsByHlc =
        incoming.physical >
            ((existing['hlc_physical'] as num?)?.toInt() ?? 0) ||
        (incoming.physical ==
                ((existing['hlc_physical'] as num?)?.toInt() ?? 0) &&
            incoming.logical >
                ((existing['hlc_logical'] as num?)?.toInt() ?? 0));
    if (!removeWinsByHlc) return; // add-wins ties: the live row stays.
    await _cache.deletePropertyValueById(elementId);
    // Unsetting a node-backed text value deletes the carrier block
    // under the same guards as the positional path.
    await _trashTextCarrierIfOrphaned(
      objectId,
      schemaId,
      existing['value'] as String,
      envelope.timestamp,
    );
  }

  /// The pre-PG5 positional remove (payload WITHOUT elementId): the slot
  /// tombstone upserts when the incoming write wins, and the deterministic
  /// composite row dies only when the remove outranks it — newer element
  /// adds at that idx are different elements and survive.
  Future<void> _applyPositionalUnset(
    OperationEnvelope envelope, {
    required String objectId,
    required String schemaId,
    required int idx,
  }) async {
    final incoming = _incoming(envelope);

    final tombstone = await _cache.propertyTombstoneWinner(
      objectId,
      schemaId,
      idx,
    );
    if (tombstone == null || compareLww(incoming, tombstone) > 0) {
      await _cache.upsertPropertyTombstone(objectId, schemaId, idx, incoming);
    }

    final rowId = NodeCacheRepository.positionalPropertyValueId(
      objectId,
      schemaId,
      idx,
    );
    final existing = await _cache.propertyValueRowById(rowId);
    if (existing == null) return;
    final rowWinner = (
      physical: (existing['hlc_physical'] as num?)?.toInt() ?? 0,
      logical: (existing['hlc_logical'] as num?)?.toInt() ?? 0,
      actor: existing['actor_id'] as String? ?? '',
    );
    if (compareLww(incoming, rowWinner) <= 0) return;
    await _cache.deletePropertyValueById(rowId);
    // SCHEMA.md "Node-backed text properties": unsetting a
    // node-backed text value deletes the carrier block — trash + retention,
    // consistent with node deletion (three guards below).
    await _trashTextCarrierIfOrphaned(
      objectId,
      schemaId,
      existing['value'] as String,
      envelope.timestamp,
    );
  }

  /// The carrier-deletion half of property.unset (PB2). The value
  /// row is already deleted; [removedValueRaw] is its stored JSON. Trashes
  /// the now-unreferenced carrier inside the same apply. Guards: the removed
  /// value references a node (canonical {nodeId} or legacy bare uuid), no
  /// other live property_value row still references it, and the carrier is
  /// an active non-class CHILD of the owner. Scalar text values (citekey
  /// style) carry no carrier.
  Future<void> _trashTextCarrierIfOrphaned(
    String objectId,
    String schemaId,
    String removedValueRaw,
    String timestamp,
  ) async {
    if (await _cache.propertySchemaTypeOf(schemaId) != 'text') return;
    String? target;
    try {
      final decoded = jsonDecode(removedValueRaw);
      target = _nodeRefOfValue(decoded);
    } on FormatException {
      return;
    }
    if (target == null) return;
    // Exclusive reference: no other live row (any owner or slot) points at
    // the carrier — both the {nodeId} and the legacy bare-uuid shapes.
    if (await _cache.propertyValueReferencesTarget(target)) return;
    final carrier = await _cache.getByUuid(target);
    if (carrier == null ||
        carrier.parentUuid != objectId ||
        carrier.isClass ||
        carrier.isArchived) {
      return;
    }
    final ids = await _cache.subtreeUuids(target);
    for (final id in ids) {
      final node = await _cache.getByUuid(id);
      if (node != null && !node.isArchived) {
        await _cache.upsert(node.copyWithIsArchived(true));
      }
    }
    await _cache.recordTrashRoot(target, deletedAt: timestamp);
  }

  /// The node id a stored value references, when it is reference-shaped:
  /// either the canonical `{ "nodeId": … }` or a legacy bare uuid. Scalar
  /// strings that are not uuid-shaped return null (they are text).
  static String? _nodeRefOfValue(dynamic value) {
    if (value is Map<String, dynamic> && value['nodeId'] is String) {
      final id = value['nodeId'] as String;
      return id.isEmpty ? null : id;
    }
    if (value is String && _uuidLike.hasMatch(value)) return value;
    return null;
  }

  static final _uuidLike = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  /// PC6 normalize-on-write (SCHEMA.md "Dates"): for a dateQualified
  /// schema, a well-formed `YYYY-MM-DD` string in the reserved qualifier
  /// keys (startDate/endDate) rewrites to the deterministic day-node ref
  /// `{"nodeId": <day chain node>}` — pure value rewriting, no graph side
  /// effects; the ref joins the year/month/day chain whenever the chain
  /// exists and stays existence-lenient until then. Non-date strings, refs,
  /// other metadata keys, non-qualified schemas, and unknown schemas all
  /// ride through untouched. Returns the metadata to store (null when the
  /// payload carried none).
  Map<String, dynamic>? _normalizeQualifierMetadata(
    PropertySchemaValidationRow? schema,
    Map<String, dynamic> payload,
  ) {
    final metadata = payload['metadata'];
    if (metadata is! Map<String, dynamic>) return null;
    if (schema?.dateQualified != true) return metadata;
    var changed = false;
    final normalized = Map<String, dynamic>.from(metadata);
    for (final key in const ['startDate', 'endDate']) {
      final value = normalized[key];
      if (value is! String) continue;
      final day = dayUuidFromIsoDate(value);
      if (day == null) continue; // not a well-formed ISO date — as authored.
      normalized[key] = {'nodeId': day};
      changed = true;
    }
    return changed ? normalized : metadata;
  }

  // --- classes ------------------------------------------------------------------

  Future<void> _applyClassCreate(
    OperationEnvelope envelope,
    Map<String, dynamic> payload,
  ) async {
    final classId = payload['classId'] as String;
    final existing = await _cache.getClassByUuid(classId);
    // Registry `name` is a denormalized cache of the class node's title
    // text. Absent fields PRESERVE on re-declaration (the upsert used to
    // wipe icon/color with null — the TS COALESCE semantics); a conversion
    // (no contentAst) on a fresh row adopts the node's current title
    // (title-is-content: the node row is the authority).
    String? adoptedTitle;
    if (!payload.containsKey('contentAst')) {
      final node = await _cache.getByUuid(classId);
      if (node != null) adoptedTitle = node.displayName;
    }
    await _cache.upsertClass(
      uuid: classId,
      name: payload.containsKey('contentAst')
          ? _classTitle(payload)
          : (existing?.name ?? adoptedTitle ?? ''),
      icon: payload.containsKey('icon')
          ? payload['icon'] as String?
          : existing?.icon,
      color: payload.containsKey('color')
          ? payload['color'] as String?
          : existing?.color,
      // class.create never writes description: a fresh row starts
      // description-less and a re-declaration keeps the stored one (TS
      // parity — the payload schema accepts the key, the applier drops it).
      description: await _cache.classDescription(classId),
      active: true,
      createdAt: envelope.timestamp,
      updatedAt: envelope.timestamp,
    );

    // Conversion (owner ruling retiring the seeded `class` class,
    // 2026-10-07): class.create on an EXISTING node DECLARES that node a
    // class — the flip is the whole capability: is_class = 1, classes are
    // roots (the parent edge + its fractional position drop), the render
    // bit clears. The node's title/icon/color stay (conversion carries no
    // content unless sent). Membership and the node's own children are
    // untouched (classes are containers). Applied unconditionally:
    // declaration is structural, not a row-field race (the extends-DAG
    // precedent).
    final node = await _cache.getByUuid(classId);
    if (node != null && !node.isClass) {
      await _cache.upsert(
        _copyWith(
          node,
          isClass: true,
          presentAsMain: false,
          isPage: false,
          parentUuid: null,
          position: null,
        ),
      );
    }
    // Hierarchy self-row: the closure queries match through it, so every
    // class needs (id, id) even before any setExtends runs.
    await _cache.insertClassHierarchySelfRow(classId);
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
      // Presence-based like the TS applier (`if (p.description !==
      // undefined)`): a class.update without description must not clobber
      // the stored one (upsertClass is replace-semantics, so an absent key
      // has to fall back to the existing row explicitly).
      description: payload.containsKey('description')
          ? payload['description'] as String?
          : await _cache.classDescription(classId),
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

  /// F4: a delete addressed at a family BASE class is
  /// routed to the toggle — applied as a feature-disable so the Features
  /// setting is the single archive path for the families and the lossy
  /// plain delete (membership tombstoning) never runs on them. The five
  /// bases route (task, event, meeting, source, person — the TS domain test
  /// pins the meeting mapping); non-base family children (book, birthday, …)
  /// keep plain delete semantics. The route decision is a pure function of
  /// the class id (fixed vocabulary), so every replica takes the same
  /// branch; the LWW row gate keeps the derived state convergent under
  /// either delivery order.
  Future<bool> _applyClassDelete(
    OperationEnvelope envelope,
    Map<String, dynamic> payload,
  ) async {
    final classId = payload['classId'] as String;
    final managedFeature = featureForManagedClass(classId);
    if (managedFeature != null) {
      final wrote = await _lwwWriteFeatureRow(
        envelope,
        managedFeature,
        false,
      );
      if (wrote) {
        await _deriveFamilyClassBits(envelope.workspaceId, managedFeature);
      }
      return wrote;
    }
    await _cache.deleteClass(classId);
    return true;
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

    // PC2: defaultValue is typed per the schema type — a
    // wrong-typed default fails loud here instead of deriving silently on
    // every read. Omitted defaultValue (patch keeps the stored one) skips
    // the check; a stored default that drifts out of match (schema
    // delete+recreate with a different type) is dropped defensively at the
    // effective read instead.
    if (payload.containsKey('defaultValue')) {
      final opType = envelope.opType;
      final schemaType = await _cache.propertySchemaTypeOf(schemaId);
      final defaultValue = payload['defaultValue'];
      if (schemaType != null && !isValidDefaultForType(schemaType, defaultValue)) {
        final expectation = switch (schemaType) {
          'date' || 'date_range' || 'object' || 'asset' =>
            'must be null — node-typed defaults are not supported',
          _ => 'must be typed $schemaType',
        };
        throw PropertyValueShapeError(
          '$opType: defaultValue for $schemaType schema $expectation '
          '— got ${jsonEncodeForMessage(defaultValue)}',
          opType,
        );
      }
    }

    final hasDefault = payload.containsKey('defaultValue');
    await _cache.upsertClassPropertyBinding(
      classId: classId,
      schemaId: schemaId,
      incoming: incoming,
      sequence: (payload['sequence'] as num?)?.toInt(),
      // The binding carries ONLY the per-class mechanics — required
      // (the owner's exception) rides the row LWW; readonly/hideWhenEmpty/
      // display are PROPERTY-level (propertySchema.create/update).
      required: payload['required'] as bool?,
      // PC4: the soft-unbind flag rides the row LWW (absent = keep).
      active: payload['active'] as bool?,
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
        // SCHEMA.md "Dates" (PC6): the applier stores the columns raw; the
        // PC6 normalize-on-write consults dateQualified on property.set.
        datePrecision: payload['datePrecision'] as String?,
        dateQualified: payload['dateQualified'] as bool?,
        // SCHEMA.md "Number formats": display-only
        // formatting for number schemas.
        numberPad: payload['numberPad'] as int?,
        numberDecimals: payload['numberDecimals'] as int?,
        numberRounding: payload['numberRounding'] as String?,
        // Owner review 2026-10-05: the render contracts are
        // PROPERTY-level — the display position + readonly/hideWhenEmpty
        // ride the schema row (absent = the 'panel'/unset defaults).
        display: payload['display'] as String?,
        readonly: payload['readonly'] as bool? ?? false,
        hideWhenEmpty: payload['hideWhenEmpty'] as bool? ?? false,
      ),
    );
  }

  Future<bool> _applyPropertySchemaUpdate(Map<String, dynamic> payload) async {
    final propertySchemaId = payload['propertySchemaId'] as String;
    final existing = await _cache.getPropertySchemaRow(propertySchemaId);
    if (existing == null) {
      // TS parity (appliers.ts applyPropertySchemaUpdate): a plain UPDATE
      // silently affects no rows when the schema doesn't exist yet — replay
      // orders that deliver the update before the create converge instead of
      // throwing (the class-property-active fixture replays both orders).
      return false;
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
        // propertySchema.update carries name/options/datePrecision/
        // dateQualified/number formats/render contracts; everything
        // else is preserved from the stored row.
        type: existing.type,
        multi: existing.multi,
        isSystem: existing.isSystem,
        scope: existing.scope,
        nodeUuid: existing.nodeUuid,
        iconVisibility: existing.iconVisibility,
        validationRules: existing.validationRules,
        required: existing.required,
        defaultValue: existing.defaultValue,
        classFilterUuids: existing.classFilterUuids,
        computed: existing.computed,
        datePrecision: payload.containsKey('datePrecision')
            ? payload['datePrecision'] as String?
            : existing.datePrecision,
        dateQualified: payload.containsKey('dateQualified')
            ? payload['dateQualified'] as bool?
            : existing.dateQualified,
        // Number formats: absent keeps, explicit null clears
        // (containsKey distinguishes the two).
        numberPad: payload.containsKey('numberPad')
            ? payload['numberPad'] as int?
            : existing.numberPad,
        numberDecimals: payload.containsKey('numberDecimals')
            ? payload['numberDecimals'] as int?
            : existing.numberDecimals,
        numberRounding: payload.containsKey('numberRounding')
            ? payload['numberRounding'] as String?
            : existing.numberRounding,
        // render contracts (PROPERTY-level): the same keep/clear
        // contract as the number formats (absent keeps, present null
        // clears; `required` is NOT here — it stays on the class binding).
        display: payload.containsKey('display')
            ? payload['display'] as String?
            : existing.display,
        readonly: payload.containsKey('readonly')
            ? (payload['readonly'] as bool?) ?? false
            : existing.readonly,
        hideWhenEmpty: payload.containsKey('hideWhenEmpty')
            ? (payload['hideWhenEmpty'] as bool?) ?? false
            : existing.hideWhenEmpty,
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

  // --- workspace.feature.* ----------------------------------------------------
  //
  // Per-workspace feature toggles: LWW by (workspaceId, feature) on the
  // envelope (hlc, actor) — the winning row lands in `workspace_feature`
  // and the applier derives the membership-preserving archival of the
  // feature's managed system classes from it. Toggle-off is
  // hide-surfaces-keep-data (F3): the class registry `active` bit flips,
  // class membership rows are NEVER touched. An absent row means ENABLED
  // (F2). A class.delete on a managed base routes here (F4 — see
  // [_applyClassDelete]).

  /// LWW-write one feature row. Returns true when the incoming envelope won
  /// (the row was written); false when a newer (hlc, actor) row already
  /// stood (the toggle is dropped, exactly like a stale property.set).
  Future<bool> _lwwWriteFeatureRow(
    OperationEnvelope envelope,
    WorkspaceFeature feature,
    bool enabled,
  ) async {
    final existing = await _cache.workspaceFeatureWinner(
      envelope.workspaceId,
      feature,
    );
    final incoming = _incoming(envelope);
    if (existing != null && compareLww(incoming, existing) <= 0) {
      return false;
    }
    await _cache.upsertWorkspaceFeature(
      envelope.workspaceId,
      feature,
      enabled,
      incoming,
    );
    return true;
  }

  /// Re-derive the archival bits for one family's full class set (base +
  /// extends-children) from the CURRENT feature rows. Each class's bit is
  /// the AND of its gating features (own feature when it is a family base,
  /// plus every managed ancestor's — gatingFeaturesForClass): re-enabling
  /// EVENTS must not un-archive a MEETINGS-off meeting, so a blind
  /// family-wide flip is wrong under the cascade; per-class re-derivation
  /// is idempotent, membership-preserving, and convergent (pure active-bit
  /// projection — no causality/timestamp writes).
  Future<void> _deriveFamilyClassBits(
    String workspaceId,
    WorkspaceFeature feature,
  ) async {
    for (final name in familyClassNames(feature)) {
      var enabled = true;
      for (final gating in gatingFeaturesForClass(name)) {
        if (!await _cache.featureEnabledNow(workspaceId, gating)) {
          enabled = false;
          break;
        }
      }
      await _cache.setClassActive(systemClassUuids[name]!, enabled);
    }
  }

  /// The `tasks` enable path: author the task class +
  /// the six property schemas + their bindings at the fixed seed ids.
  /// Purely additive (INSERT-or-ignore everywhere) so a client-authored
  /// family (random option ids) or a server-seeded one is never clobbered —
  /// first writer wins, convergent on the single global log. The rows are
  /// inserted ACTIVE; the caller normalizes the archival bit afterwards.
  Future<void> _ensureTaskFamilyRows(OperationEnvelope envelope) async {
    const classId = SystemClassUuids.task;
    await _cache.insertClassIfAbsent(
      uuid: classId,
      name: 'Task',
      icon: systemClassIcons['task'],
    );
    for (final entry in taskFamilySeed) {
      await _cache.insertPropertySchemaIfAbsent(
        PropertySchemaRow(
          uuid: entry.schemaId,
          workspaceId: '', // Workspace is implicit to the local cache.
          name: entry.name,
          type: entry.type,
          multi: false,
          isSystem: true,
          scope: 'class',
          // The designed status options carry the circle-family MDI
          // glyphs + color tokens (owner-mandated set); priority and
          // the date schemas stay plain {id, label}.
          options: [
            for (final option in entry.options)
              {
                'id': option['id'],
                'label': option['label'],
                if (option['icon'] != null) 'icon': option['icon'],
                if (option['color'] != null) 'color': option['color'],
              },
          ],
          // Owner review 2026-10-05: the display position is
          // PROPERTY-level — the Status schema defaults to 'bullet' (its
          // value rides the block bullet as an icon button); the rest stay
          // in the properties panel (null).
          display: entry.display,
          createdAt: envelope.timestamp,
          updatedAt: envelope.timestamp,
        ),
      );
      await _cache.insertClassPropertyBindingIfAbsent(
        classId: classId,
        schemaId: entry.schemaId,
        sequence: entry.sequence,
      );
    }
  }

  Future<bool> _applyWorkspaceFeatureSet(
    OperationEnvelope envelope,
    Map<String, dynamic> payload,
  ) async {
    final feature = payload['feature'] as String;
    final enabled = payload['enabled'] == true;
    final wrote = await _lwwWriteFeatureRow(envelope, feature, enabled);
    if (wrote) {
      await _deriveFamilyClassBits(envelope.workspaceId, feature);
    }
    // The ensure rides every enable PAYLOAD (not only the LWW winner):
    // both delivery orders of a racing toggle pair must author the
    // identical row set — the family re-derivation below normalizes the
    // archival bits to the CURRENT row state on every path.
    if (enabled && feature == 'tasks') {
      await _ensureTaskFamilyRows(envelope);
      await _deriveFamilyClassBits(envelope.workspaceId, feature);
    }
    return wrote;
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
/// (clearing `parentUuid`/`position` on a move to the workspace root, and
/// clearing `color` on object.update — present-null semantics).
const _undefined = Object();

/// Field-wise copy used by the appliers (the local [Node] model predates
/// copyWith for these fields).
Node _copyWith(
  Node node, {
  String? name,
  String? displayName,
  bool? presentAsMain,
  String? icon,
  Object? color = _undefined,
  Object? coverAssetId = _undefined,
  Object? bannerAssetId = _undefined,
  Object? aliasedNodeId = _undefined,
  Object? parentUuid = _undefined,
  Object? position = _undefined,
  double? sequence,
  String? writeDate,
  int? hlcPhysical,
  int? hlcLogical,
  String? actorId,
  bool? isPage,
  // Identity only changes on the class.create conversion path (a node
  // declared a class); update/move never flip it.
  bool? isClass,
}) => Node(
  id: node.id,
  uuid: node.uuid,
  name: name ?? node.name,
  displayName: displayName ?? node.displayName,
  icon: icon ?? node.icon,
  color: identical(color, _undefined) ? node.color : color as String?,
  coverAssetId: identical(coverAssetId, _undefined)
      ? node.coverAssetId
      : coverAssetId as String?,
  bannerAssetId: identical(bannerAssetId, _undefined)
      ? node.bannerAssetId
      : bannerAssetId as String?,
  aliasedNodeId: identical(aliasedNodeId, _undefined)
      ? node.aliasedNodeId
      : aliasedNodeId as String?,
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
  isClass: isClass ?? node.isClass,
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
