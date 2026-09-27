import 'package:flutter/foundation.dart';

import '../../core/constants/system.dart';
import '../../core/utils/ast_builder.dart';
import '../../core/utils/ast_stringifier.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_cache_repository.dart';
import '../models/relay/hlc.dart';
import '../models/relay/operation_envelope.dart';

/// Applies v2 relay operation envelopes to the local [node_cache] derived
/// state (`op-types.ts` M1 registry).
///
/// Phase A scope: the wire field names are v2 (`objectId`, `nodeType`,
/// `contentAst`, `parentClassIds`, `propertySchemaId`, ...). Where v2 split
/// concepts the local cache still conflates, the v1 projection is kept and
/// marked — e.g. a v2 `object.update` `name` lands in the content slot it
/// shares with `contentAst` (the content-grammar rewrite separates them), and
/// the `contentDeltaB64` carrier (Yjs) is not applied locally yet.
class RelayAppliers {
  RelayAppliers(this._cache);

  final NodeCacheRepository _cache;

  Future<void> apply(OperationEnvelope envelope) async {
    final payload = envelope.payload;
    // Class/property/collection operations identify their target via
    // `classId`, `propertySchemaId`, or `collectionId`, not `objectId`.
    final objectId = payload['objectId'] as String? ??
        payload['classId'] as String? ??
        payload['propertySchemaId'] as String? ??
        payload['collectionId'] as String? ??
        '';
    // Ops without a target (e.g. `plugin.op`) have no local derived
    // representation and are intentionally ignored.
    if (objectId.isEmpty) return;

    switch (envelope.opType) {
      case 'object.create':
        await _applyCreate(objectId, payload);
      case 'object.update':
        await _applyUpdate(objectId, payload, envelope.hlc);
      case 'object.delete':
        await _applyDelete(objectId, payload);
      case 'object.move':
        await _applyMove(objectId, payload);
      case 'property.set':
        await _applyPropertySet(objectId, payload);
      case 'property.unset':
        await _applyPropertyUnset(objectId, payload);
      case 'class.create':
        await _applyClassCreate(payload);
      case 'class.update':
        await _applyClassUpdate(payload);
      case 'class.delete':
        await _applyClassDelete(payload);
      case 'class.setExtends':
        await _applyClassSetExtends(payload);
      case 'propertySchema.create':
        await _applyPropertySchemaCreate(payload);
      case 'propertySchema.update':
        await _applyPropertySchemaUpdate(payload);
      case 'propertySchema.delete':
        await _applyPropertySchemaDelete(payload);
      // Asset metadata lives in the server-side asset tables; the app has no
      // local asset table (asset bytes are fetched over HTTP), so asset
      // bookkeeping ops are intentionally ignored — as are collection
      // membership ops (no local membership table in Phase A; collections
      // are class-tagged nodes here).
      case 'asset.attach':
      case 'asset.detach':
      case 'collection.member.add':
      case 'collection.member.remove':
      // Activity log, link-click tracking, public share state, node views,
      // aliases and plugin-scoped ops have no local derived representation;
      // the corresponding UI reads them from the server on demand.
      // Intentionally ignored.
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
        break;
      default:
        // No silent fallthrough: log op types this client does not know
        // (including v1-only ops dropped from the v2 M1 registry:
        // node.archive/restore, user.favorite.*, task.*, classPropertyEdge.*,
        // share.user.*).
        debugPrint('RelayAppliers: ignoring unknown op type ${envelope.opType}');
    }
  }

  Future<void> _applyCreate(String objectId, Map<String, dynamic> payload) async {
    // Mirrors the server applier's first-create-wins for the tree: a create
    // for an existing node does not move the node or revert later edits.
    // Re-issued creates ARE the v2 OR-Set membership carrier though
    // (add-wins, op-types.ts): seed any new classIds into the existing node.
    final existing = await _cache.getByUuid(objectId);
    if (existing != null) {
      final classIds = _readStringList(payload['classIds']);
      final merged = <String>{...existing.classesUuid, ...classIds}.toList();
      if (classIds.isNotEmpty && merged.length != existing.classesUuid.length) {
        final flags = _deriveFlags(merged);
        await _cache.upsert(
          Node(
            id: existing.id,
            uuid: existing.uuid,
            name: existing.name,
            displayName: existing.displayName,
            icon: existing.icon,
            color: existing.color,
            parentId: existing.parentId,
            parentUuid: existing.parentUuid,
            pageId: existing.pageId,
            pageUuid: existing.pageUuid,
            sequence: existing.sequence,
            isPage: existing.isPage,
            isTask: flags.isTask,
            isDaily: flags.isDaily,
            isMonthly: flags.isMonthly,
            isYearly: flags.isYearly,
            isTable: flags.isTable,
            isAsset: flags.isAsset,
            isComment: flags.isComment,
            isDeleted: existing.isDeleted,
            isArchived: existing.isArchived,
            isPrivate: existing.isPrivate,
            classes: existing.classes,
            classesUuid: merged,
            tags: existing.tags,
            tagsUuid: existing.tagsUuid,
            properties: existing.properties,
            children: existing.children,
            createDate: existing.createDate,
            writeDate: existing.writeDate,
          ),
        );
      }
      return;
    }

    // v2 carries `name` (scalar) and `contentAst` (token array) as separate
    // slots; the local cache stores one `name` string (the serialized AST or
    // legacy plain text), so content wins when both arrive and the scalar
    // name fills the display name.
    final contentAst = payload['contentAst'];
    final explicitName = payload['name'] as String?;
    final name = switch (contentAst) {
      List<dynamic> list => AstBuilder.serialize(list.cast<Map<String, dynamic>>()),
      _ => explicitName ?? '',
    };
    final displayName = explicitName ?? astToPlainText(name);
    final classIds = _readStringList(payload['classIds']);
    final parentId = payload['parentId'] as String?;
    // Placement defaults by context when the payload omits nodeType
    // (op-types.ts: workspace root → page, child → block).
    final nodeType = payload['nodeType'] as String? ??
        (parentId == null ? 'page' : 'block');
    final flags = _deriveFlags(classIds);

    final node = Node(
      id: 0,
      uuid: objectId,
      name: name,
      displayName: displayName,
      parentUuid: parentId,
      classesUuid: classIds,
      isDeleted: false,
      properties: const {},
      isPage: nodeType == 'page',
      isTask: flags.isTask,
      isDaily: flags.isDaily,
      isMonthly: flags.isMonthly,
      isYearly: flags.isYearly,
      isTable: flags.isTable,
      isAsset: flags.isAsset,
      isComment: flags.isComment,
    );
    await _cache.upsert(node);
  }

  Future<void> _applyUpdate(
    String objectId,
    Map<String, dynamic> payload,
    Hlc hlc,
  ) async {
    final node = await _loadOrCreate(objectId);
    var updated = node;

    // name/icon/color are direct LWW upserts.
    final name = payload['name'] as String?;
    if (name != null) {
      // The local cache conflates name and content in one column (see
      // _applyCreate); a v2 name update lands in that shared slot as the
      // inline AST of the title, matching the v1 update_node behavior.
      final inline = AstBuilder.serialize(AstBuilder.parseInline(name));
      updated = _copyWith(updated, name: inline, displayName: name);
    }
    final icon = payload['icon'] as String?;
    if (icon != null) {
      updated = _copyWith(updated, icon: icon);
    }
    final color = payload['color'] as String?;
    if (color != null) {
      updated = _copyWith(updated, color: color);
    }

    // contentAst is guarded by last-write-wins HLC: the server skips update
    // ops whose HLC is not newer than the stored one; mirror that locally so
    // stale pages from catch-up or re-applied envelopes do not clobber newer
    // content. contentDeltaB64 (the Yjs carrier) is not applied locally yet.
    final contentAst = payload['contentAst'];
    if (contentAst is List<dynamic>) {
      final lastApplied = await _cache.getContentHlc(objectId);
      if (lastApplied == null || hlc.compareTo(lastApplied) > 0) {
        final serialized =
            AstBuilder.serialize(contentAst.cast<Map<String, dynamic>>());
        updated = _copyWith(
          updated,
          name: serialized,
          displayName: astToPlainText(serialized),
        );
        await _cache.upsert(updated);
        await _cache.setContentHlc(objectId, hlc);
        return;
      }
    }
    if (updated != node) {
      await _cache.upsert(updated);
    }
  }

  Future<void> _applyDelete(String objectId, Map<String, dynamic> payload) async {
    final permanent = payload['permanent'] == true;
    if (!permanent) {
      // v2 tombstone (soft delete): the recoverable path, which the app's
      // trash/archive view reads (is_archived).
      final node = await _loadOrCreate(objectId);
      await _cache.upsert(node.copyWithIsArchived(true));
      return;
    }
    // Hard delete, matching the v1 node.delete behavior: remove the node row
    // plus its property values, favorites, task completions/recurrence, and
    // search index rows.
    await _cache.hardDelete(objectId);
  }

  Future<void> _applyMove(String objectId, Map<String, dynamic> payload) async {
    final node = await _loadOrCreate(objectId);
    final parentId = payload['parentId'] as String?;
    final afterId = payload['afterId'] as String?;
    var sequence = node.sequence;
    if (afterId != null) {
      // Sibling midpoint placement: land immediately after `afterId` in the
      // parent's child order (the server's fractional allocator uses the
      // same rule over its position strings).
      final siblings = parentId == null
          ? (await _cache.getRootPages())
              .where((n) => n.uuid != objectId)
              .toList()
          : (await _cache.getChildren(parentId))
              .where((n) => n.uuid != objectId)
              .toList();
      final afterIndex = siblings.indexWhere((n) => n.uuid == afterId);
      if (afterIndex >= 0) {
        final afterSequence = siblings[afterIndex].sequence;
        if (afterIndex + 1 < siblings.length) {
          final nextSequence = siblings[afterIndex + 1].sequence;
          sequence = afterSequence + (nextSequence - afterSequence) / 2;
        } else {
          sequence = afterSequence + 1;
        }
      }
    }
    await _cache.upsert(_copyWith(node, parentUuid: parentId, sequence: sequence));
  }

  Future<void> _applyPropertySet(
    String objectId,
    Map<String, dynamic> payload,
  ) async {
    final node = await _loadOrCreate(objectId);
    final propertySchemaId = payload['propertySchemaId'] as String?;
    if (propertySchemaId == null) return;
    // The local properties map is keyed by schema id and models single-value
    // slots; v2 multi-value (idx) properties land in Phase B with the
    // property read model.
    final updatedProperties = Map<String, dynamic>.from(node.properties);
    updatedProperties[propertySchemaId] = payload['value'];
    await _cache.upsert(node.copyWithProperties(updatedProperties));
  }

  Future<void> _applyPropertyUnset(
    String objectId,
    Map<String, dynamic> payload,
  ) async {
    final node = await _loadOrCreate(objectId);
    final propertySchemaId = payload['propertySchemaId'] as String?;
    if (propertySchemaId == null) return;
    final updatedProperties = Map<String, dynamic>.from(node.properties);
    updatedProperties.remove(propertySchemaId);
    await _cache.upsert(node.copyWithProperties(updatedProperties));
  }

  Future<void> _applyClassCreate(Map<String, dynamic> payload) async {
    final classId = payload['classId'] as String?;
    if (classId == null) return;
    await _cache.upsertClass(
      uuid: classId,
      name: payload['name'] as String? ?? '',
      icon: payload['icon'] as String?,
      color: payload['color'] as String?,
      description: payload['description'] as String?,
      active: true,
    );
  }

  Future<void> _applyClassUpdate(Map<String, dynamic> payload) async {
    final classId = payload['classId'] as String?;
    if (classId == null) return;
    final existing = await _cache.getClassByUuid(classId);
    await _cache.upsertClass(
      uuid: classId,
      name: payload.containsKey('name')
          ? payload['name'] as String?
          : existing?.name,
      icon: payload.containsKey('icon')
          ? payload['icon'] as String?
          : existing?.icon,
      color: payload.containsKey('color')
          ? payload['color'] as String?
          : existing?.color,
      description: payload['description'] as String?,
    );
  }

  Future<void> _applyClassDelete(Map<String, dynamic> payload) async {
    final classId = payload['classId'] as String?;
    if (classId == null) return;
    await _cache.deleteClass(classId);
  }

  Future<void> _applyClassSetExtends(Map<String, dynamic> payload) async {
    final classId = payload['classId'] as String?;
    if (classId == null) return;
    // Replace semantics: parentClassIds IS the class's full parent set.
    final parentClassIds = _readStringList(payload['parentClassIds']);
    await _cache.setClassExtends(classId, parentClassIds);
  }

  Future<void> _applyPropertySchemaCreate(Map<String, dynamic> payload) async {
    final propertySchemaId = payload['propertySchemaId'] as String?;
    if (propertySchemaId == null) return;
    await _cache.upsertPropertySchema(
      PropertySchemaRow(
        uuid: propertySchemaId,
        workspaceId: '', // Workspace is implicit to the local cache.
        name: payload['name'] as String? ?? '',
        type: payload['type'] as String? ?? 'text',
        multi: payload['multi'] == true,
        isSystem: false,
        scope: payload['scope'] as String? ?? 'global',
        options: (payload['options'] as List<dynamic>?)
                ?.cast<Map<String, dynamic>>() ??
            const [],
        classFilterUuids: _readStringList(payload['targetClassFilter']),
      ),
    );
  }

  Future<void> _applyPropertySchemaUpdate(Map<String, dynamic> payload) async {
    final propertySchemaId = payload['propertySchemaId'] as String?;
    if (propertySchemaId == null) return;
    // Read the raw row: absent keys must preserve the stored values rather
    // than reset them.
    final existing = await _cache.getPropertySchemaRow(propertySchemaId);
    if (existing == null) return;
    await _cache.upsertPropertySchema(
      PropertySchemaRow(
        uuid: propertySchemaId,
        workspaceId: existing.workspaceId,
        name: payload.containsKey('name')
            ? (payload['name'] as String?) ?? existing.name
            : existing.name,
        options: payload.containsKey('options')
            ? (payload['options'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? const []
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
  }

  Future<void> _applyPropertySchemaDelete(Map<String, dynamic> payload) async {
    final propertySchemaId = payload['propertySchemaId'] as String?;
    if (propertySchemaId == null) return;
    await _cache.deletePropertySchema(propertySchemaId);
  }

  Future<Node> _loadOrCreate(String objectId) async {
    final existing = await _cache.getByUuid(objectId);
    if (existing != null) return existing;
    return Node(
      id: 0,
      uuid: objectId,
      name: '',
      displayName: '',
      classesUuid: const [],
      properties: const {},
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
  String? icon,
  String? color,
  String? parentUuid,
  double? sequence,
}) =>
    Node(
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
      isPage: node.isPage,
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
      writeDate: node.writeDate,
    );

extension _NodeCopyWith on Node {
  Node copyWithProperties(Map<String, dynamic> value) => Node(
        id: id,
        uuid: uuid,
        name: name,
        displayName: displayName,
        icon: icon,
        color: color,
        parentId: parentId,
        parentUuid: parentUuid,
        pageId: pageId,
        pageUuid: pageUuid,
        sequence: sequence,
        isPage: isPage,
        isTask: isTask,
        isDaily: isDaily,
        isMonthly: isMonthly,
        isYearly: isYearly,
        isTable: isTable,
        isAsset: isAsset,
        isComment: isComment,
        isDeleted: isDeleted,
        isArchived: isArchived,
        isPrivate: isPrivate,
        classes: classes,
        classesUuid: classesUuid,
        tags: tags,
        tagsUuid: tagsUuid,
        properties: value,
        children: children,
        createDate: createDate,
        writeDate: writeDate,
      );
}

({
  bool isTask,
  bool isDaily,
  bool isMonthly,
  bool isYearly,
  bool isTable,
  bool isAsset,
  bool isComment,
}) _deriveFlags(List<String> classIds) {
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
