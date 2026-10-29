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
///    `is_embedded` (embedding flag for parented non-class nodes) replace
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
///    deliberately unchecked); a single-value schema takes idx 0 only; the
///    effective read model resolves bindings extends-aware (PG4: BFS
///    over class_extends, own binding at distance 0, shortest path then
///    earliest assignment HLC then class id — boundBy names the supplying
///    ancestor) and drops a stored default that no longer matches the
///    schema type;
///  - the binding row (class.property.set) carries ONLY the genuinely
///    per-class mechanic (active): `required` retired outright and
///    `defaultValue` MOVED to the property schema (one global default per property, the Logseq shape),
///    `sequence` retired outright (class panels
///    render alphabetically by property name, a read-time derivation);
///    PC2 validates the default against the payload type at create and the
///    stored type at update (a schema-less write stores unchecked);
///  - per-workspace feature toggles (workspace.feature.set) LWW by HLC on
///    (workspace, feature) derive the membership-preserving archival of the
///    five managed class families (F2 absent-row=ON, F3 keep-data; the
///    `journal` toggle is surfaces-only and derives no class bits; the
///    tasks enable authors the task family at the fixed seed ids on every
///    enable payload); an object.delete on a family base routes to the
///    toggle (the class-node delete routing);
///  - external-id mappings (external_ref.set / external_ref.delete,
///    2026-10-23 lockstep) LWW by envelope (hlc, actor) on the
///    (workspace, ref) key with a delete-side tombstone per ref (including
///    a delete of an unmapped ref), so a stale concurrent set delivered
///    after the winning delete is dropped on every replica; a node's hard
///    delete purges its live rows, soft-trash keeps them (SCHEMA.md
///    "External-id mappings");
///  - trash.empty (2026-10-14 lockstep) permanently deletes every node
///    carrying a non-permanent trash_root row through the same hard-delete
///    body as `object.delete {permanent: true}`; the root set is an
///    apply-time snapshot (restore-before-empty survives, log order
///    otherwise), a consumed or nodeless row is swept, never fatal;
///  - date-chain delete lock (2026-10-29 lockstep, SCHEMA.md "Datetime"): an
///    object.delete on a deterministic year/month/day journal node id fails
///    loud with [MoveGuardError] in BOTH arms — soft trash and permanent
///    purge — before the class routing and any row mutation; the journal
///    chain is permanent scaffolding (clear the day's content instead), and
///    the guard matches node ids only (parseDateNodeId is prefix-strict), so
///    the locked-system-class delete arm is untouched;
///  - class-level parentlessRole (2026-10-24 lockstep, SCHEMA.md "Node
///    structure"): `class.create`/`class.update` carry the
///    OPTIONAL NULLABLE `parentlessRole` ('page' | 'block'; absent/null =
///    'page', presence writes, present-null clears, the color contract).
///    The local store keeps class config in class_cache only, so the flag
///    lands as the registry column `parentless_role` (schema v38 — the TS
///    store's node+registry two-column port collapses to the registry:
///    classes have no node_cache row here, the icon/color precedent) and
///    the stored `is_page` bit becomes flag-aware: parentless nodes read
///    the EXTENDS-AWARE demote (own flag OR any ancestor's, one-way, via
///    class_cache × class_hierarchy) at create/move/update and on
///    membership recomputation, and a class flag write sweeps its members'
///    bits; the parent-page guard (_isPageRow) reads the same predicate, so
///    a standalone claim under a block-role parentless node fails loud (the
///    same MoveGuardError, no new error type);
///  - card.review (2026-10-28 memorization-cards lockstep, SCHEMA.md
///    "Memorization cards") is HISTORY-ONLY: one append-only row per graded
///    review in the derived card_review table — NO LWW gate, NO superseded
///    path, and the op never writes property values (the seeded card-family
///    properties stay the current schedule surface; the op is the review
///    journal). Validation is membership-only: the target must resolve to a
///    node row carrying the card system class (NodeNotFoundError /
///    MoveGuardError, the write-time-impossible law — never applied);
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
    // workspace_feature row): it routes by op type below, as does
    // `trash.empty` (its victims are the apply-time trash set, not a
    // payload objectId). `external_ref.*` keys its state by the payload's
    // `ref` (the set's nodeId is a mapping TARGET, not the op's addressed
    // object — a mapping may name a not-yet-synced node), so both ops
    // route by op type too; `card.review` addresses its card via the
    // payload's `cardId` (not `objectId`), and routes the same way.
    if (objectId.isEmpty &&
        envelope.opType != 'workspace.feature.set' &&
        envelope.opType != 'trash.empty' &&
        envelope.opType != 'external_ref.set' &&
        envelope.opType != 'external_ref.delete' &&
        envelope.opType != 'card.review') {
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
      case 'trash.empty':
        return _applyTrashEmpty(envelope);
      case 'property.set':
        return _applyPropertySet(envelope, objectId, payload);
      case 'property.unset':
        return _applyPropertyUnset(envelope, objectId, payload);
      case 'class.create':
        await _applyClassCreate(envelope, payload);
        return true;
      case 'class.update':
        return _applyClassUpdate(envelope, payload);
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
      case 'external_ref.set':
        return _applyExternalRefSet(envelope, payload);
      case 'external_ref.delete':
        return _applyExternalRefDelete(envelope, payload);
      case 'card.review':
        return _applyCardReview(envelope, payload);
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
      case 'class.delete':
        // `class.delete` is RETIRED from the op registry — class-node deletion routes through `object.delete`
        // (four applier-decided arms, SCHEMA.md "Workspace features"). A
        // retired op in a replayed log lands here and is ignored, exactly
        // like the other legacy ops below.
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


/// Content-asserted membership (the no-divergence law): every `class_link` token in a stored content stream IS a
/// classing of its node — the object appliers apply the OR-set add, so any
/// writer converges. Deep walk (tokens nest in quote/heading children).
List<String> _contentClassLinkIds(dynamic tokens) {
  final found = <String>[];
  final seen = <String>{};
  void walk(dynamic ts) {
    if (ts is! List) return;
    for (final token in ts) {
      if (token is! Map) continue;
      if (token['type'] == 'class_link') {
        final classId = token['classId'];
        if (classId is String && seen.add(classId)) found.add(classId);
      }
      walk(token['children']);
    }
  }

  walk(tokens);
  return found;
}

  Future<bool> _applyCreate(
    OperationEnvelope envelope,
    String objectId,
    Map<String, dynamic> payload,
  ) async {
    final opType = envelope.opType;
    final parentId = payload['parentId'] as String?;
    final afterId = payload['afterId'] as String?;
    final beforeId = payload['beforeId'] as String?;
    // Date-chain class lock (SCHEMA.md "Datetime", 2026-10-13 lockstep): a
    // date node's class set is FIXED to its precision's system class. The
    // re-issued object.create is the OR-Set add carrier (this client has no
    // class.assign op; class.assign rides the create, also on an existing
    // id), so the guard runs BEFORE the membership seeding and the
    // first-create-wins early return below.
    final isEmbeddedPre = payload.containsKey('isEmbedded')
        ? payload['isEmbedded'] == true
        : parentId != null;
    // Content-asserted membership: an inline block keeps the rich stream, so
    // its class_link tokens class the node; a document-chrome node's content
    // flattens below (text-only — nothing to assert).
    final linkClassIds = !isEmbeddedPre
        ? <String>[]
        : _contentClassLinkIds(payload['contentAst']);
    final lockedDateClass = dateChainClassId(objectId);
    if (lockedDateClass != null) {
      for (final classId in <String>[
        ..._readStringList(payload['classIds']),
        ...linkClassIds,
      ]) {
        if (classId != lockedDateClass) {
          throw MoveGuardError(
            '$opType: node $objectId is a date-chain node; it can only '
            'carry the $lockedDateClass system class',
            opType,
          );
        }
      }
    }
    // Embedding flag (Revision 12): the payload may carry isEmbedded; the
    // applier defaults it by placement — a parentless node is standalone
    // (document chrome by the second cascade branch; the flag is stored but
    // unread), a parented one starts embedded (its content belongs to the
    // parent's body — block chrome; the promotion boundary is the 1→0
    // toggle).
    final isEmbedded = payload.containsKey('isEmbedded')
        ? payload['isEmbedded'] == true
        : parentId != null;
    final incoming = _incoming(envelope);

    // Placement guard: the parent must exist — either as a node row or as a
    // class (classes are containers since spec I4: a class parent is legal
    // for non-class children, which is all object.create can make — class
    // declaration remains the class.create op, so the class-under-class
    // shape is unreachable here).
    if (parentId != null) {
      final parent = await _cache.getByUuid(parentId);
      if (parent == null && !await _cache.isClassNode(parentId)) {
        throw NodeNotFoundError(
          '$opType: parent $parentId does not exist',
          opType,
        );
      }
      // Parent-page condition (Revision 12): the
      // standalone role is only effective under a page parent — claiming it
      // under a class or an embedded block establishes an illegal parented
      // state and fails loud. (A parented default is embedded = true, so
      // isEmbedded == false here is always an explicit claim.)
      if (!isEmbedded && parent != null && !await _isPageRow(parent, _cache)) {
        throw MoveGuardError(
          '$opType: isEmbedded = false (standalone) requires the parent to '
          'render with document chrome (the parent is a class or an '
          'embedded block)',
          opType,
        );
      }
    }

    // Date-chain parenting lock (SCHEMA.md "Datetime", same rule as
    // object.move, with one birth-time exception): a date id may only be
    // created AT its deterministic chain parent (year → root, month → year,
    // day → month). Claiming any other parent is establishing an illegal
    // parented state and fails loud; a parentless create is the standalone
    // shape the client chain self-heal adopts, so it stays legal.
    if (parentId != null &&
        parseDateNodeId(objectId) != null &&
        parentId != dateChainParentId(objectId)) {
      throw MoveGuardError(
        '$opType: node $objectId is a date-chain node; it can only be '
        'created at its deterministic chain parent',
        opType,
      );
    }

    // Seed OR-Set membership first: a re-issued create is the membership
    // carrier (add-wins per pair), even when the node already exists. The
    // class add's comparator is >= on the actor tiebreak (an exact-HLC add
    // beats a class.unassign remove in either delivery order); the tag add's
    // is strictly-greater, matching the TS store's tagMemberUpsert gating.
    final classIds = _readStringList(payload['classIds']);
    for (final classId in <String>{...classIds, ...linkClassIds}) {
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
      if (classIds.isNotEmpty || linkClassIds.isNotEmpty) {
        await _cache.recomputeClassIds(objectId);
      }
      if (tagIds.isNotEmpty) await _cache.recomputeTagIds(objectId);
      return false;
    }

    // Content flatten invariant (Revision 11): a main-presenting node
    // carries text-only content; an inline block keeps the full rich token
    // stream (class rows never reach this op).
    final contentAst = payload['contentAst'];
    final flatAst = switch (contentAst) {
      List<dynamic> list => !isEmbedded
          ? stringifyContentAst(normalizeContentAst(list))
          : normalizeContentAst(list),
      _ => const <Map<String, dynamic>>[],
    };
    final name = AstBuilder.serialize(flatAst);
    final flags = _deriveFlags(classIds);
    // The parentlessRole demote (SCHEMA.md "Node
    // structure"): a parentless node renders with document chrome UNLESS
    // one of its classes effectively carries the block flag — the flag is
    // read ONLY in the parentless branch (the is_embedded symmetry: the
    // embedding flag decides only for parented nodes). The OR-Set seeding
    // above lands before this insert, so the flag read sees the create's
    // full class context (explicit classIds + content-asserted links).
    final effectiveClassIds = <String>{...classIds, ...linkClassIds};
    final isPage = parentId == null
        ? !(await _cache.classEffectivelyBlockFlagged(effectiveClassIds))
        : !isEmbedded;
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
        isPage: isPage,
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
        isEmbedded: isEmbedded,
        listStyle: payload['listStyle'] as String?,
        hlcPhysical: incoming.physical,
        hlcLogical: incoming.logical,
        actorId: incoming.actor,
      ),
    );
    if (classIds.isNotEmpty || linkClassIds.isNotEmpty) {
      await _cache.recomputeClassIds(objectId);
    }
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
      // Class-only rows (no node-cache row — classes live in class_cache):
      // the archival bit is their only object.update surface (the
      // classes-gallery disable gesture). The same refusals apply; the bit
      // mirrors to the registry projection.
      if (payload.containsKey('active') &&
          await _cache.classActiveState(objectId) != null) {
        _assertArchivalAllowed(opType, objectId, payload['active'] == true);
        await _cache.setClassActive(objectId, payload['active'] == true);
        return true;
      }
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

    // Promotion/demotion (Revision 12) is the isEmbedded toggle: the flag
    // joins the row-level LWW set; a true → false flip (promotion to the
    // Page role) stringifies the stored rich stream to text-only in the
    // same op (content flatten invariant), while a false → true demotion
    // leaves the (already flattened) content untouched — demotion never
    // un-flattens. On a class row the flag is inert (classes render
    // ClassView regardless); applying it harmlessly keeps the op uniform.
    // Promotion (the standalone claim) is gated by the parent-page
    // condition; demotion of a parented page is gated on its standalone
    // children being gone.
    var resultingIsEmbedded = node.isEmbedded ?? true;
    String? newName = node.name;
    var newDisplay = node.displayName;
    if (payload.containsKey('isEmbedded')) {
      // Date-chain embedding lock (SCHEMA.md "Datetime"): the journal
      // chain's role is platform-fixed — a date node renders with document
      // chrome and the embedding flag is not user-reachable state. BOTH
      // directions fail loud: a demote would nest the journal page as an
      // inline block in its chain parent's body, a promotion is a
      // standalone claim the UI never makes. The parent lock lives in
      // object.move, the class lock in the object.create / class guards —
      // this closes the last carrier.
      if (parseDateNodeId(objectId) != null) {
        throw MoveGuardError(
          '$opType: date-chain node $objectId has a platform-fixed journal '
          'role; isEmbedded is not writable on it',
          opType,
        );
      }
      final bit = payload['isEmbedded'] == true;
      if (!bit && node.parentUuid != null) {
        final parent = await _cache.getByUuid(node.parentUuid!);
        if (parent == null || !await _isPageRow(parent, _cache)) {
          throw MoveGuardError(
            '$opType: isEmbedded = false (standalone) requires the parent '
            'to render with document chrome (the parent is a class or an '
            'embedded block)',
            opType,
          );
        }
      }
      if (bit && node.isEmbedded == false && node.parentUuid != null) {
        final standaloneChild = await _cache.getChildren(node.uuid);
        if (standaloneChild.any((c) => c.isEmbedded == false)) {
          throw MoveGuardError(
            '$opType: cannot demote node $objectId while it carries '
            'standalone (isEmbedded = false) children (demote or move '
            'them first)',
            opType,
          );
        }
      }
      resultingIsEmbedded = bit;
      if (!bit && node.isEmbedded == true && node.name.isNotEmpty) {
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
    // Archival bit (the classes-gallery batch):
    // presence writes — `false` archives, `true` unarchives. A reversible
    // STATE, distinct from the trash table (deletion). Archival REFUSALS
    // fail loud: the locked system classes can never be archived, and
    // family bases are toggle-managed (the Features setting is their
    // single archive path) — unarchiving is harmless and stays legal.
    // Class rows mirror the bit to the registry projection below (the
    // feature-derivation pattern).
    if (payload.containsKey('active') && node.isClass) {
      _assertArchivalAllowed(opType, objectId, payload['active'] == true);
    }
    await _cache.upsert(
      _copyWith(
        node,
        name: newName,
        displayName: newDisplay,
        isEmbedded: resultingIsEmbedded,
        // The is_page query flag follows the role: a parentless node reads
        // the parentlessRole demote (its membership
        // changes re-derive through recomputeClassIds below, the isEmbedded
        // toggle just re-asserts the same branch), a parented node follows
        // the embedding flag (document chrome ⇔ the standalone claim);
        // class rows are tree-external and keep whatever they carried (they
        // live in class_cache locally).
        isPage: node.isClass
            ? node.isPage
            : node.parentUuid == null
                ? !(await _cache.classEffectivelyBlockFlagged(
                    node.classesUuid,
                  ))
                : !resultingIsEmbedded,
        // Archival: presence writes — `false` archives the row, `true`
        // unarchives it (the node row's archived flag is the projection of
        // `node.is_active` in the TS store).
        isArchived: payload.containsKey('active')
            ? payload['active'] != true
            : node.isArchived,
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
        description: payload.containsKey('description')
            ? payload['description'] as String?
            : node.description,
        // List style: presence writes, present-null clears back to the
        // bullet default (the color precedent).
        listStyle: payload.containsKey('listStyle')
            ? payload['listStyle'] as String?
            : node.listStyle,
        writeDate: envelope.timestamp,
        hlcPhysical: incoming.physical,
        hlcLogical: incoming.logical,
        actorId: incoming.actor,
      ),
    );
    // An archival flip on a class row mirrors to the registry projection
    // (`class_cache.active`, the pickers/class hubs read — the
    // feature-derivation pattern): the class node's bit is the authority,
    // the registry column its direct projection.
    if (payload.containsKey('active') && node.isClass) {
      await _cache.setClassActive(objectId, payload['active'] == true);
    }
    // Content-asserted membership: the class_link tokens about to be stored
    // class the node (any writer converges). Class rows flatten (never carry
    // links); date-chain nodes' class set is fixed — a foreign link there is
    // the same illegal state as a foreign classId on create.
    if (contentAst is List<dynamic>) {
      final asserted = node.isClass
          ? <String>[]
          : _contentClassLinkIds(contentAst);
      final lockedDateClass = dateChainClassId(objectId);
      if (lockedDateClass != null &&
          asserted.any((id) => id != lockedDateClass)) {
        throw MoveGuardError(
          '$opType: node $objectId is a date-chain node; it can only '
          'carry the $lockedDateClass system class',
          opType,
        );
      }
      for (final classId in asserted) {
        final stored = await _cache.classMemberWinner(objectId, classId);
        if (stored == null || compareLww(incoming, stored) >= 0) {
          await _cache.upsertClassMember(objectId, classId, true, incoming);
        }
      }
      if (asserted.isNotEmpty) await _cache.recomputeClassIds(objectId);
      await _cache.rebuildEdges(objectId, at: envelope.timestamp);
    }
    return true;
  }

  /// Archival refusals (the classes-gallery batch):
  /// the locked system classes can never be archived, and family bases are
  /// toggle-managed (the Features setting is their single archive path) —
  /// a direct archival write would diverge the class bit from the toggle
  /// until the next re-derivation. Both fail loud, never applied.
  /// Unarchiving stays legal: it heals, never diverges harmfully.
  void _assertArchivalAllowed(String opType, String objectId, bool unarchiving) {
    if (unarchiving) return;
    if (isLockedSystemClassId(objectId)) {
      throw LockedSystemClassError(
        '$opType: ${systemClassNameForId(objectId)} is a locked system '
        'class — it can never be archived (archival is gallery-toggleable '
        'for every OTHER system class)',
        opType,
      );
    }
    final managedFeature = featureForManagedClass(objectId);
    if (managedFeature != null) {
      throw MoveGuardError(
        '$opType: ${systemClassNameForId(objectId)} is a family base '
        'class — archival is toggle-managed (workspace.feature.set '
        '{feature: "$managedFeature", enabled: false}); direct archival '
        'writes are refused',
        opType,
      );
    }
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
    final permanent = payload['permanent'] == true;
    final nodeRow = await _cache.getByUuid(objectId);
    // "Node must exist" first (the TS reference's requireNode): a delete of
    // an id with neither a node row nor a class registry row fails loud
    // before any routing or trash/purge write.
    final deletedIsClass =
        nodeRow?.isClass ?? await _cache.classActiveState(objectId) != null;
    if (!deletedIsClass && nodeRow == null) {
      throw NodeNotFoundError('$opType: node $objectId does not exist', opType);
    }
    // Date-chain delete lock (SCHEMA.md "Datetime" — the fourth lock, beside
    // the parent/class/embedding locks): a date node is permanent journal
    // scaffolding under the permanent-address model — it realizes on first
    // write and can never leave the graph. Deleting one fails loud
    // REGARDLESS of `permanent` (the trash-bypass arm must throw before any
    // purge); clearing a day means deleting its CONTENT, never the day
    // node. The guard sits above the class routing: it matches node ids,
    // never class ids (parseDateNodeId is prefix-strict), so the
    // locked-system-class arm below is untouched.
    if (parseDateNodeId(objectId) != null) {
      throw MoveGuardError(
        '$opType: $objectId is a date-chain node — the journal chain is '
        'permanent platform scaffolding and can never be deleted (clear '
        "the day's content instead)",
        opType,
      );
    }
    // Class-node delete routing (the retired
    // class.delete op's routing, moved here; SCHEMA.md "Workspace
    // features"). Classes are nodes: one delete op, four applier-decided
    // outcomes, all a pure function of the class id so every replica takes
    // the same branch. MEMBERSHIP RIDES in every arm — `class_member_set`
    // rows are never touched by class removal (archive or trash); stripping
    // a class from nodes stays the explicit per-node `class.unassign`.
    if (deletedIsClass) {
      // Arm 1 — LOCKED system classes (the date chain + table, asset,
      // query, code, template, comment): platform structure, never
      // archivable or deletable. Fails loud, never applied — regardless
      // of `permanent`.
      if (isLockedSystemClassId(objectId)) {
        throw LockedSystemClassError(
          '$opType: ${systemClassNameForId(objectId)} is a locked system '
          'class — it can never be deleted',
          opType,
        );
      }
      // Arm 2 — a family BASE class (task, event, meeting, source, person):
      // routed to the toggle, applied as a feature-disable (the LWW row +
      // the family re-derivation — the Features setting stays the single
      // archive path for the families, and the whole extends family
      // archives with the base). The route decision rides the envelope's
      // HLC, so a racing toggle converges under either delivery order.
      final managedFeature = featureForManagedClass(objectId);
      if (managedFeature != null) {
        // The routed disable is an old-shape write: object.delete carries
        // no settings, so a winning route stores NULL (whole-row LWW).
        final wrote = await _lwwWriteFeatureRow(
          envelope,
          managedFeature,
          false,
          null,
        );
        if (wrote) {
          await _deriveFamilyClassBits(envelope.workspaceId, managedFeature);
        }
        return wrote;
      }
      // Arm 3 — any OTHER non-locked system class: re-wired to ARCHIVAL
      // (`active = false`), NOT trash (the gallery's disable gesture; the
      // system picks the most reversible interpretation — disable =
      // delete). No trash row: the class revives with
      // `object.update {active: true}`, not `object.restore` (archive is
      // not deletion). `permanent` is ignored on this arm — archival is
      // the only delete a system class admits.
      if (systemClassNameForId(objectId) != null) {
        await _archiveClassRow(objectId);
        return true;
      }
      // Arm 4 — a USER class: falls through to the plain trash path below
      // (soft delete with a trash row, restorable from the Trash hub — the
      // whole subtree rides, exactly like any node).
    }

    if (!permanent) {
      // Soft delete: trash the whole subtree (relay semantics — restore is
      // whole-tree). The trash/archive view reads is_archived; the
      // trash_root row (one per root, lockstep with the TS `trash` table)
      // is what lets object.restore tell "rode with the parent" apart from
      // "trashed independently". Membership RIDES — a class root's
      // class_member_set pairs are never tombstoned by the delete.
      final ids = await _cache.subtreeUuids(objectId);
      for (final id in ids) {
        final node = await _cache.getByUuid(id);
        if (node != null) await _cache.upsert(node.copyWithIsArchived(true));
      }
      if (deletedIsClass) {
        await _cache.deleteClass(objectId);
      }
      await _cache.recordTrashRoot(
        objectId,
        deletedAt: DateTime.now().toUtc().toIso8601String(),
      );
      return true;
    }
    // Permanent delete: hard-delete the subtree and its derived rows.
    // Membership RIDES even here: the pairs stand (the class pill renders
    // the dangling reference — SCHEMA.md "Content grammar").
    await _cache.hardDelete(objectId);
    if (deletedIsClass) {
      await _cache.deleteClass(objectId);
    }
    return true;
  }

  /// Arm-3 archival (a non-locked system class delete): the class registry
  /// row deactivates and a class node row, when one exists, archives with
  /// it. No trash row, no membership touches — restore is the archival
  /// write (`object.update {active: true}`), never `object.restore`.
  Future<void> _archiveClassRow(String classId) async {
    await _cache.deleteClass(classId);
    final node = await _cache.getByUuid(classId);
    if (node != null) {
      await _cache.upsert(node.copyWithIsArchived(true));
    }
  }

  /// Empties the trash (the trash.empty op, 2026-10-14 lockstep):
  /// permanently deletes every node carrying a non-permanent trash_root
  /// row. The root set is SNAPSHOT at apply time, ordered by node_id for
  /// determinism; each root goes through the SAME hard-delete body as
  /// `object.delete {permanent: true}` (NodeCacheRepository.hardDelete —
  /// this store's permanent delete purges trash_root rows instead of
  /// recording the TS reference's is_permanent = 1 tombstone, and the
  /// empty mirrors that established end state, tombstone bookkeeping
  /// included). A root consumed by an earlier iteration's subtree (an
  /// independently-trashed descendant inside another root's tree) has no
  /// node row left and is skipped; a stale non-permanent row with no node
  /// row (legacy dangling state) is swept instead of failing replay.
  /// Replay is idempotent: an empty trash table no-ops. Concurrency is
  /// plain log order, nothing special: an object.restore landing BEFORE
  /// the empty removes the node from the apply-time set (it survives);
  /// one landing AFTER is LWW against the delete.
  Future<bool> _applyTrashEmpty(OperationEnvelope envelope) async {
    final roots = await _cache.nonPermanentTrashRootIds();
    for (final root in roots) {
      final rootRow = await _cache.getByUuid(root);
      if (rootRow == null) {
        await _cache.consumeTrashRoot(root);
        continue;
      }
      await _cache.hardDelete(root);
      // Membership RIDES the empty too: a class root's pairs stand (the
      // dangling-reference state, SCHEMA.md "Content grammar").
      if (rootRow.isClass) {
        await _cache.deleteClass(root);
      }
    }
    return roots.isNotEmpty;
  }

  Future<bool> _applyRestore(
    OperationEnvelope envelope,
    String objectId,
    Map<String, dynamic> payload,
  ) async {
    final opType = envelope.opType;
    final root = await _cache.getByUuid(objectId);
    if (root == null) {
      // Class-only root (no node row — classes live in class_cache): the
      // plain-trash arm of the class-node delete routing recorded the
      // trash_root row. Restore reactivates the registry row, reactivates
      // any node children that rode the delete, and consumes the root.
      // (Arm-3 archival is NOT restored here — archive is not deletion; it
      // revives through `object.update {active: true}`.)
      if (await _cache.classActiveState(objectId) != null) {
        await _cache.setClassActive(objectId, true);
        final ids = await _cache.subtreeUuids(objectId);
        for (final id in ids) {
          final node = await _cache.getByUuid(id);
          if (node != null && node.isArchived) {
            await _cache.upsert(node.copyWithIsArchived(false));
          }
        }
        await _cache.consumeTrashRoot(objectId);
        return true;
      }
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
    // children, spec I4), a node may never move under itself or its own
    // descendant (parent_id cycle), and a DATE-CHAIN node may only move
    // under its deterministic chain parent (SCHEMA.md "Datetime" — the
    // parenting lock). A parentless non-class node is legal
    // too: it renders with document chrome by the second cascade branch
    // regardless of the stored embedding bit.
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
      // Parent-page condition (Revision 12): a
      // standalone node renders with document chrome only under a page
      // parent, so moving one under a class or an embedded block
      // establishes an illegal parented state and fails loud (moves never
      // write the flag — silently clearing it would rewrite render state
      // behind the user's back).
      if (node.isEmbedded == false) {
        final parent = await _cache.getByUuid(parentId);
        if (parent == null || !await _isPageRow(parent, _cache)) {
          throw MoveGuardError(
            '$opType: node $objectId is standalone (isEmbedded = false); '
            'it can only move under a parent that renders with document '
            'chrome',
            opType,
          );
        }
      }
    }

    // Treat-as-main on first parenting: a parentless node
    // with the bit still 1 renders as a page by the second cascade branch;
    // the first parenting acquires the standalone claim so it stays one
    // (the applier applies the claim below). Block-role parentless-class
    // members are excluded — they keep the bit and stay blocks.
    final claimsMain = parentId != null &&
        node.parentUuid == null &&
        !node.isClass &&
        node.isEmbedded == true &&
        !(await _cache.classEffectivelyBlockFlagged(node.classesUuid));
    if (claimsMain) {
      final parent = await _cache.getByUuid(parentId);
      if (parent == null || !await _isPageRow(parent, _cache)) {
        throw MoveGuardError(
          '$opType: node $objectId renders as a main page while '
          'parentless; parenting it requires a parent that renders with '
          'document chrome (parent $parentId is a class or an embedded '
          'block)',
          opType,
        );
      }
    }

    // Date-chain parenting lock (SCHEMA.md "Datetime", 2026-10-13 lockstep):
    // a date node may ONLY live under its deterministic chain parent
    // (year → root, month → year, day → month). The chain self-heal
    // re-issues exactly this move, so the chain-correct parent stays legal;
    // any other target — including parentless for month/day — is a
    // reparenting attempt and fails loud.
    if (parseDateNodeId(objectId) != null &&
        parentId != dateChainParentId(objectId)) {
      throw MoveGuardError(
        '$opType: node $objectId is a date-chain node; its parent is '
        'locked to the deterministic chain parent',
        opType,
      );
    }

    final incoming = _incoming(envelope);
    final rowWinner = (
      physical: node.hlcPhysical,
      logical: node.hlcLogical,
      actor: node.actorId ?? '',
    );
    // Parent/position are row-level LWW: re-applying an older move after a
    // newer one drops whole. A stale move also drops the treat-as-main
    // acquisition whole: the bit write rides this same row winner.
    if (compareLww(incoming, rowWinner) <= 0) return false;

    // Treat-as-main acquisition: the acquired standalone
    // claim — the bit goes 1 → 0 plus the content stringify, the same lossy
    // main-role boundary as the object.update promotion. Parented→parented
    // moves leave the bit alone.
    var resultingIsEmbedded = node.isEmbedded ?? true;
    var newName = node.name;
    var newDisplay = node.displayName;
    if (claimsMain && node.name.isNotEmpty) {
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
    if (claimsMain) resultingIsEmbedded = false;

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
        name: newName,
        displayName: newDisplay,
        isEmbedded: resultingIsEmbedded,
        parentUuid: parentId,
        position: position,
        sequence: double.tryParse(position ?? '') ?? node.sequence,
        // Document chrome ⇔ the landing is parentless (flag-aware — a
        // block-flagged parentless node stays Block-role, owner
        // 2026-10-24) or the resulting standalone claim is set; the
        // treat-as-main acquisition is the one move that writes the bit.
        isPage: parentId == null
            ? !(await _cache.classEffectivelyBlockFlagged(node.classesUuid))
            : !resultingIsEmbedded,
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
    // R3: the write fails loud when the target
    // node is INELIGIBLE for the schema — scopeClassIds set and the node's
    // class closure (its classes + extends ancestors) misses the list.
    // Schema-less writes (unknown schema id) stay unchecked, exactly like
    // the shape checks below. Narrowing a scope later never orphans
    // history: pre-existing authored rows survive in the log and the
    // effective read returns them tagged eligible=false — enforcement is
    // never retroactive.
    final schema = await _cache.propertySchemaValidationRow(schemaId);
    if (schema != null && schema.scopeClassIds != null) {
      final carried = await _cache.nodeClassIdsOf(objectId);
      final eligible = await _cache.classClosureIntersectsScope(
        carried ?? const <String>[],
        schema.scopeClassIds,
      );
      if (!eligible) {
        throw MoveGuardError(
          '$opType: node $objectId is not eligible for schema $schemaId '
          "(its classes — extends-aware — do not intersect the schema's "
          'scopeClassIds)',
          opType,
        );
      }
    }
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

  /// PC6 normalize-on-write (SCHEMA.md "Datetime"): for a dateQualified
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
    final opType = envelope.opType;
    final classId = payload['classId'] as String;
    // Date-chain class lock (SCHEMA.md "Datetime", 2026-10-13 lockstep): a
    // date node is a journal entry, never a class — declaring it one (fresh
    // or the conversion flip) would sever its identity.
    if (parseDateNodeId(classId) != null) {
      throw MoveGuardError(
        '$opType: node $classId is a date-chain node; it can never be '
        'declared a class',
        opType,
      );
    }
    final existing = await _cache.getClassByUuid(classId);
    // Registry `name` is a denormalized cache of the class node's title
    // text. Absent fields PRESERVE on re-declaration (the upsert used to
    // wipe icon/color with null — the TS COALESCE semantics); a conversion
    // (no contentAst) on a fresh row adopts the node's current title
    // (title-is-content: the node row is the authority). The parentlessRole
    // flag follows the same presence contract: a
    // re-issued flag-less class.create — the seed/ensure idempotent re-run —
    // PRESERVES the stored flag (TS `COALESCE(excluded.parentless_role,
    // class.parentless_role)` parity), present-null clears.
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
      // The archival bit is deliberately NOT passed: the re-declaration
      // conflict arm never touches `active`, so a re-issued class.create —
      // the seed/ensure idempotent re-run — must NOT revive an archived
      // class (the source-library
      // archived-by-default seed).
      description: await _cache.classDescription(classId),
      parentlessRole: payload.containsKey('parentlessRole')
          ? payload['parentlessRole'] as String?
          : await _cache.classParentlessRole(classId),
      createdAt: envelope.timestamp,
      updatedAt: envelope.timestamp,
    );

    // Conversion: class.create on an EXISTING node DECLARES that node a
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
          isEmbedded: false,
          isPage: false,
          parentUuid: null,
          position: null,
        ),
      );
    }
    // Hierarchy self-row: the closure queries match through it, so every
    // class needs (id, id) even before any setExtends runs.
    await _cache.insertClassHierarchySelfRow(classId);
    // The parentlessRole write may demote/promote existing parentless
    // members (the conversion path can declare a class over a node whose
    // members already carry it): re-derive their is_page bits. Absent-key
    // re-issues changed nothing, so only an explicit key triggers the
    // sweep.
    if (payload.containsKey('parentlessRole')) {
      await _cache.rederiveParentlessNodePageBits(classId);
    }
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
      // The parentlessRole flag: presence writes,
      // present-null clears (the color precedent). A flag flip re-derives
      // the is_page bits of every parentless member — the stored-bit
      // projection of a read-time derivation the TS store computes live.
      parentlessRole: payload.containsKey('parentlessRole')
          ? payload['parentlessRole'] as String?
          : await _cache.classParentlessRole(classId),
      updatedAt: envelope.timestamp,
    );
    if (payload.containsKey('parentlessRole')) {
      await _cache.rederiveParentlessNodePageBits(classId);
    }
    return true;
  }

  /// The class display name: the plain-text excerpt of the payload's
  /// contentAst (title-is-content), "" when no contentAst is set.
  String _classTitle(Map<String, dynamic> payload) {
    final contentAst = payload['contentAst'];
    if (contentAst is! List<dynamic>) return '';
    return contentSourceToExcerpt(contentAst);
  }

  /// Class-node delete routing — arm 2 lives in
  /// [_applyDelete]: a delete addressed at a family BASE class is routed to
  /// the toggle, applied as a feature-disable so the Features setting is the
  /// single archive path for the families and the whole extends family
  /// archives with the base. The route decision is a pure function of the
  /// class id (fixed vocabulary), so every replica takes the same branch;
  /// the LWW row gate keeps the derived state convergent under either
  /// delivery order.
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

    // System-extends lock (SCHEMA.md "Class properties"): a system class's extends mapping is seeded platform
    // structure — the feature-toggle cascade (systemClassAncestors) and
    // binding inheritance (the class_extends walk) both derive from it. The
    // payload's parent set must EQUAL the seeded set (compared as sets —
    // the seed/ensure re-issue convergence path); any deviation fails loud
    // and is never applied. System classes without seeded parents are
    // frozen to the empty set. User classes stay freely extensible,
    // including onto system bases.
    final seededParents = systemClassExtendsIds[classId];
    if (seededParents != null) {
      final next = parentClassIds.toSet();
      final seeded = seededParents.toSet();
      final same =
          next.length == seeded.length && next.every(seeded.contains);
      if (!same) {
        String fmt(Set<String> ids) => (ids.toList()..sort()).join(', ');
        throw SystemExtendsLockError(
          '$opType: system class $classId has a frozen extends mapping; '
          'payload parents [${fmt(next)}] deviate from the seeded '
          'set [${fmt(seeded)}]',
          opType,
        );
      }
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

    // R5: dead config is rejected — a binding on
    // a schema whose scope EXCLUDES the class is provably inert (the
    // effective read suppresses its default under R4), so the write fails
    // loud. The class's own extends closure counts: a class scoped to an
    // ANCESTOR of the binding class still binds (subclass instances are
    // eligible via the ancestor). Schema-less writes (unknown schema id)
    // stay unchecked.
    final schemaRow = await _cache.propertySchemaValidationRow(schemaId);
    if (schemaRow != null && schemaRow.scopeClassIds != null) {
      final binds = await _cache.classClosureIntersectsScope(
        [classId],
        schemaRow.scopeClassIds,
      );
      if (!binds) {
        throw MoveGuardError(
          '${envelope.opType}: schema $schemaId is scoped to classes that '
          'exclude $classId — the binding would be inert (scope is the '
          'sole locality authority)',
          envelope.opType,
        );
      }
    }

    // PC2 left the binding `defaultValue`
    // MOVED to the property schema (one global default per property) and
    // `required` retired outright — both reject at the strict payload gate
    // before this applier runs. `sequence` followed them with the owner
    // ruling 2026-10-21 (class panels render alphabetically by property
    // name — panel order no longer exists to configure). The row carries
    // active only.

    await _cache.upsertClassPropertyBinding(
      classId: classId,
      schemaId: schemaId,
      incoming: incoming,
      // PC4: the soft-unbind flag rides the row LWW (absent = keep).
      active: payload['active'] as bool?,
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
    // Date-chain class lock (SCHEMA.md "Datetime", 2026-10-13 lockstep): the
    // precision's system class IS the date node's identity — removing it is
    // illegal. Unassigning a FOREIGN class stays legal: it cleans up a
    // legacy violation rather than freezing one.
    final lockedDateClass = dateChainClassId(objectId);
    if (lockedDateClass != null && classId == lockedDateClass) {
      throw MoveGuardError(
        '$opType: node $objectId is a date-chain node; its $classId '
        'system class cannot be removed',
        opType,
      );
    }
    // Content-reference lock (the no-divergence law): the stored content
    // still carries an inline class_link to this class — unassigning would
    // strand a live reference. The removal gesture strips the links FIRST;
    // a raw class.unassign refuses rather than silently diverging.
    final nodeRow = await _cache.getByUuid(objectId);
    if (nodeRow != null && nodeRow.name.isNotEmpty) {
      try {
        final stored = jsonDecode(nodeRow.name);
        if (stored is List<dynamic> &&
            _contentClassLinkIds(normalizeContentAst(stored)).contains(classId)) {
          throw MoveGuardError(
            '$opType: node $objectId content references class $classId '
            'inline — remove the inline links first',
            opType,
          );
        }
      } on FormatException {
        // Not a JSON document (legacy plain text): no links to reference.
      }
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
    const opType = 'propertySchema.create';
    // PC2 (moved from the binding): the default is
    // typed per the schema's (payload) type — a wrong-typed default fails
    // loud here instead of deriving silently on every read. Node-typed
    // schemas (datetime/object/asset) accept only JSON null — a default that
    // links a node is meaningless. Absent = no default (NULL column).
    if (payload.containsKey('defaultValue') && payload['defaultValue'] != null) {
      final type = payload['type'] as String? ?? 'text';
      final defaultValue = payload['defaultValue'];
      if (!isValidDefaultForType(type, defaultValue)) {
        final expectation = switch (type) {
          'datetime' || 'object' || 'asset' =>
            'must be null — node-typed defaults are not supported',
          _ => 'must be typed $type',
        };
        throw PropertyValueShapeError(
          '$opType: defaultValue for $type schema $expectation '
          '— got ${jsonEncodeForMessage(defaultValue)}',
          opType,
        );
      }
    }
    await _cache.upsertPropertySchema(
      PropertySchemaRow(
        uuid: propertySchemaId,
        workspaceId: '', // Workspace is implicit to the local cache.
        name: payload['name'] as String? ?? '',
        type: payload['type'] as String? ?? 'text',
        multi: payload['multi'] == true,
        isSystem: false,
        // The schema's icon (absent/null = none) and the SOLE locality
        // authority: scopeClassIds absent/null =
        // global, a non-empty list = local to those classes +
        // extends-ancestors. The retired display-only `scope` enum is
        // rejected outright by the strict validator like any retired key.
        icon: payload['icon'] as String?,
        scopeClassIds: payload.containsKey('scopeClassIds')
            ? _readStringList(payload['scopeClassIds'])
            : null,
        options:
            (payload['options'] as List<dynamic>?)
                ?.cast<Map<String, dynamic>>() ??
            const [],
        classFilterUuids: _readStringList(payload['targetClassFilter']),
        // SCHEMA.md "Datetime" (PC6): the applier stores the columns raw; the
        // PC6 normalize-on-write consults dateQualified on property.set.
        datePrecision: payload['datePrecision'] as String?,
        dateQualified: payload['dateQualified'] as bool?,
        // SCHEMA.md "Number formats": display-only
        // formatting for number schemas.
        numberPad: payload['numberPad'] as int?,
        numberDecimals: payload['numberDecimals'] as int?,
        numberRounding: payload['numberRounding'] as String?,
        // Owner review 2026-10-05: the render contracts are
        // PROPERTY-level — the display position + hideWhenEmpty ride the
        // schema row (absent = the 'panel'/unset defaults). `readonly`
        // retired outright (derived from the
        // system property list, not stored).
        display: payload['display'] as String?,
        hideWhenEmpty: payload['hideWhenEmpty'] as bool? ?? false,
        // The ONE GLOBAL default: absent/null =
        // no default (NULL column); the strict payload gate already vetted
        // the JSON typing above.
        defaultValue: payload['defaultValue'],
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
    // R2: the update payload is a patch carrying
    // no type, so validationRules applicability is enforced HERE against
    // the schema's STORED type (min/max only on number schemas, pattern
    // only on text/url/email), and a non-compilable pattern fails at the
    // rule write — a stored pattern that throws at value-check time would
    // be an applier crash. A present-null clear skips both checks.
    if (payload.containsKey('validationRules') &&
        payload['validationRules'] != null) {
      final rules = validationRulesOfRaw(payload['validationRules']) ??
          const ValidationRules();
      assertValidationRulesApplicable(existing.type, rules, 'propertySchema.update');
      assertValidationPatternCompilable(rules, 'propertySchema.update');
    }
    // PC2 (the default is schema-level): the
    // keep/clear contract rides the same shape as the number formats
    // (absent keeps, present-null clears); the type-check runs against the
    // schema's STORED type, exactly like the validationRules applicability
    // above (a schema-less write — unknown id — stores unchecked).
    if (payload.containsKey('defaultValue') &&
        payload['defaultValue'] != null &&
        !isValidDefaultForType(existing.type, payload['defaultValue'])) {
      final type = existing.type;
      final expectation = switch (type) {
        'datetime' || 'object' || 'asset' =>
          'must be null — node-typed defaults are not supported',
        _ => 'must be typed $type',
      };
      throw PropertyValueShapeError(
        'propertySchema.update: defaultValue for $type schema $expectation '
        '— got ${jsonEncodeForMessage(payload['defaultValue'])}',
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
        // propertySchema.update carries name/options/datePrecision/
        // dateQualified/number formats/render contracts PLUS icon /
        // scopeClassIds / targetClassFilter / multi / validationRules (the
        // keep/clear contract — absent keeps the stored value, present-null
        // clears); everything else is preserved from the stored row.
        type: existing.type,
        // The multi column is NOT NULL — a present-null "clear" is the
        // single-value default (false), not a SQL NULL.
        multi: payload.containsKey('multi')
            ? payload['multi'] == true
            : existing.multi,
        isSystem: existing.isSystem,
        icon: payload.containsKey('icon')
            ? payload['icon'] as String?
            : existing.icon,
        scopeClassIds: payload.containsKey('scopeClassIds')
            ? (payload['scopeClassIds'] == null
                  ? null
                  : _readStringList(payload['scopeClassIds']))
            : existing.scopeClassIds,
        classFilterUuids: payload.containsKey('targetClassFilter')
            ? (payload['targetClassFilter'] == null
                  ? const <String>[]
                  : _readStringList(payload['targetClassFilter']))
            : existing.classFilterUuids,
        nodeUuid: existing.nodeUuid,
        iconVisibility: existing.iconVisibility,
        // R2 applicability + compilability are checked below before the
        // row write; the stored map is the payload's verbatim rules.
        validationRules: payload.containsKey('validationRules')
            ? (payload['validationRules'] == null
                  ? null
                  : (payload['validationRules'] as Map<String, dynamic>))
            : existing.validationRules,
        required: existing.required,
        // The ONE GLOBAL default: absent keeps the
        // stored value, an explicit null clears it (the keep/clear contract;
        // the PC2 type-check ran above against the stored type).
        defaultValue: payload.containsKey('defaultValue')
            ? payload['defaultValue']
            : existing.defaultValue,
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
        // clears; `required` retired outright and `defaultValue` lives
        // on this schema row — both left the binding under the owner
        // ruling 2026-10-20). `readonly` retired outright 2026-10-21
        // (derived, not stored).
        display: payload.containsKey('display')
            ? payload['display'] as String?
            : existing.display,
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
  // (F2). An object.delete addressed at a family base class is ROUTED here
  // (the class-node delete routing — the retired
  // class.delete op's rule, moved into the object.delete applier). The
  // `journal` toggle gates SURFACES only (the journal nav view, Today-page
  // management) — the date classes stay always-on and it derives no class
  // bits ([isFamilyFeature] is the guard).

  /// LWW-write one feature row. Returns true when the incoming envelope won
  /// (the row was written); false when a newer (hlc, actor) row already
  /// stood (the toggle is dropped, exactly like a stale property.set).
  /// [settings] rides the same comparator: the winning payload's record is
  /// stored as JSON text, and a winning payload WITHOUT settings stores
  /// NULL (absent — distinct from '{}'), which the read paths surface as
  /// null.
  Future<bool> _lwwWriteFeatureRow(
    OperationEnvelope envelope,
    WorkspaceFeature feature,
    bool enabled,
    Map<String, dynamic>? settings,
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
      settings: settings,
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
      final classId = systemClassUuids[name]!;
      await _cache.setClassActive(classId, enabled);
      // The class NODE flip is what pickers/search/class hubs filter on
      // (the node row's archived flag) — when a class node row exists (a
      // converted node) it archives with the registry projection.
      final node = await _cache.getByUuid(classId);
      if (node != null && node.isArchived == enabled) {
        await _cache.upsert(node.copyWithIsArchived(!enabled));
      }
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
          // The SIX SCHEMAS seed at GLOBAL scope (
          // the seed-scope audit — the whole family is reusable, Status
          // explicitly so): null scopeClassIds; the task-class BINDING
          // ROWS below are untouched (bindings are per-class config, zero
          // availability semantics — TS `ensureTaskFamilyRows` parity).
          scope: 'global',
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
      );
    }
  }

  Future<bool> _applyWorkspaceFeatureSet(
    OperationEnvelope envelope,
    Map<String, dynamic> payload,
  ) async {
    final feature = payload['feature'] as String;
    final enabled = payload['enabled'] == true;
    // Family toggles derive class archival bits; the journal toggle gates
    // SURFACES only (the date classes stay always-on) — no family, no
    // derivation, just the LWW row.
    final family = isFamilyFeature(feature) ? feature : null;
    final wrote = await _lwwWriteFeatureRow(
      envelope,
      feature,
      enabled,
      payload['settings'] as Map<String, dynamic>?,
    );
    if (wrote && family != null) {
      await _deriveFamilyClassBits(envelope.workspaceId, family);
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

  // --- external_ref.* ---------------------------------------------------------
  //
  // External-id mappings for importer/sync plugins (owner requirement
  // 2026-10-23): a durable per-workspace `externalId -> nodeId` map carried
  // by the log. LWW by envelope (hlc, actor) on the ref key: a re-set MOVES
  // the mapping, racing sets converge on the higher tuple under either
  // delivery order. The delete side keeps a tombstone per ref (the
  // property_value_tombstone precedent) — including a delete of an UNMAPPED
  // ref — so a stale set delivered after the winning delete is dropped on
  // every replica and wipe -> replay converges under any delivery order.
  // The applier maintains the invariant that at most one of {live row,
  // tombstone} exists per (workspace, ref): a winning set deletes the
  // tombstone, a winning delete deletes the live row. No referential
  // integrity (the property_value precedent — a mapping may name a node
  // another device has not synced yet); the object.delete hard path purges
  // a subtree's live rows (NodeCacheRepository.hardDelete), soft-trash
  // keeps them; ref tombstones survive their node's purge.

  /// LWW-write one live mapping; a stale write (full tuple <= the standing
  /// record, live or tombstone) leaves state untouched and is dropped,
  /// exactly like a stale property.set.
  Future<bool> _applyExternalRefSet(
    OperationEnvelope envelope,
    Map<String, dynamic> payload,
  ) async {
    final ref = payload['ref'] as String;
    final nodeId = payload['nodeId'] as String;
    final incoming = _incoming(envelope);
    final record = await _cache.externalRefRecord(envelope.workspaceId, ref);
    if (record != null && compareLww(incoming, record.winner) <= 0) {
      return false;
    }
    await _cache.upsertExternalRef(envelope.workspaceId, ref, nodeId, incoming);
    // The winning set supersedes any standing tombstone (the invariant).
    await _cache.deleteExternalRefTombstone(envelope.workspaceId, ref);
    return true;
  }

  /// The LWW delete side: the winning delete takes the live row down (when
  /// one stands) and records its causality — a delete of an UNMAPPED ref
  /// still lands the tombstone, which is what kills stale concurrent sets
  /// delivered later. A stale delete (full tuple <= the standing record)
  /// leaves the mapping intact.
  Future<bool> _applyExternalRefDelete(
    OperationEnvelope envelope,
    Map<String, dynamic> payload,
  ) async {
    final ref = payload['ref'] as String;
    final incoming = _incoming(envelope);
    final record = await _cache.externalRefRecord(envelope.workspaceId, ref);
    if (record != null && compareLww(incoming, record.winner) <= 0) {
      return false;
    }
    if (record != null && record.live) {
      await _cache.deleteExternalRef(envelope.workspaceId, ref);
    }
    await _cache.upsertExternalRefTombstone(
      envelope.workspaceId,
      ref,
      incoming,
    );
    return true;
  }

  // --- card.review ----------------------------------------------------------------
  //
  // Memorization-card review history (SCHEMA.md "Memorization cards",
  // 2026-10-28 memorization-cards lockstep): one append-only derived row per
  // graded review. HISTORY-ONLY — no LWW gate, no superseded path, and the
  // op never writes property values (the seeded card-family property schemas
  // stay the current schedule surface; the op is the review journal, the
  // card_review rows its derived read). Validation is membership-only: the
  // target must resolve to a node row carrying the card system class (fail
  // loud otherwise — the write-time-impossible law).

  /// Append one card_review row (the TS store's `applyCardReview` port).
  /// Every envelope lands — concurrent reviews from different actors are
  /// ALL history.
  Future<bool> _applyCardReview(
    OperationEnvelope envelope,
    Map<String, dynamic> payload,
  ) async {
    const opType = 'card.review';
    final cardId = payload['cardId'] as String;

    final node = await _cache.getByUuid(cardId);
    if (node == null) {
      throw NodeNotFoundError(
        '$opType: card $cardId does not exist',
        opType,
      );
    }
    final classIds = await _cache.nodeClassIdsOf(cardId);
    if (classIds == null || !classIds.contains(SystemClassUuids.card)) {
      throw MoveGuardError(
        '$opType: $cardId is not classed memorization card',
        opType,
      );
    }

    await _cache.insertCardReview(
      cardId: cardId,
      sessionId: payload['sessionId'] as String,
      grade: payload['grade'] as String,
      algorithm: payload['algorithm'] as String,
      stateBefore: payload['stateBefore'] as Map<String, dynamic>,
      stateAfter: payload['stateAfter'] as Map<String, dynamic>,
      reviewedAt: payload['reviewedAt'] as String,
      hlcPhysical: envelope.hlc.physical,
      hlcLogical: envelope.hlc.logical,
      actorId: envelope.actorId,
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

/// True when the node renders with document chrome under the recursive
/// parent-page rule (carried into Revision 12):
/// a class never does (ClassView); a parentless non-class node does —
/// UNLESS one of its classes effectively carries parentlessRole "block"
/// (the extends-aware one-way demote; the guard must see
/// the same role render sees, or a standalone claim could be stored under
/// a block-role parent — an impossible RENDERED state); a parented node
/// does exactly when it is NOT embedded (the standalone claim) AND its
/// parent also renders with document chrome. Cycles are impossible
/// (subtree moves are guarded); a missing parent row is a defensive "not
/// a page".
Future<bool> _isPageRow(Node node, NodeCacheRepository cache) async {
  if (node.isClass) return false;
  if (node.parentUuid == null) {
    return !(await cache.classEffectivelyBlockFlagged(node.classesUuid));
  }
  if (node.isEmbedded != false) return false;
  final parent = await cache.getByUuid(node.parentUuid!);
  if (parent == null) return false;
  return _isPageRow(parent, cache);
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
  bool? isEmbedded,
  String? icon,
  Object? color = _undefined,
  Object? coverAssetId = _undefined,
  Object? bannerAssetId = _undefined,
  Object? aliasedNodeId = _undefined,
  Object? description = _undefined,
  Object? listStyle = _undefined,
  Object? parentUuid = _undefined,
  Object? position = _undefined,
  double? sequence,
  String? writeDate,
  int? hlcPhysical,
  int? hlcLogical,
  String? actorId,
  bool? isPage,
  bool? isArchived,
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
  description: identical(description, _undefined)
      ? node.description
      : description as String?,
  listStyle: identical(listStyle, _undefined)
      ? node.listStyle
      : listStyle as String?,
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
  isArchived: isArchived ?? node.isArchived,
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
  isEmbedded: isEmbedded ?? node.isEmbedded,
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
