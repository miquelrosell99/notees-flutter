import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/system.dart';
import '../../core/utils/ast_builder.dart';
import '../../core/utils/date_uuid.dart';
import '../../core/utils/uuid7.dart';
import '../../domain/models/search_filters.dart';
import '../../domain/services/sync_v2_service.dart';
import './node_cache_repository.dart';
import '../models/breadcrumb_item.dart';
import '../models/linked_reference.dart';
import '../models/node.dart';
import '../models/page_content.dart';
import '../models/property.dart';

/// Sentinel distinguishing an omitted [NodeRepository.updateNode] `color`
/// argument from an explicit `null`: a color clear rides the wire
/// as `"color": null`, while an omitted argument writes nothing at all.
const Object _undefinedColor = Object();

class NodeRepository {
  NodeRepository({
    required this.dio,
    this.syncService,
  });

  final Dio dio;
  final SyncV2Service? syncService;

  NodeCacheRepository? get _cache => syncService?.cache;

  void _requireCache() {
    if (_cache == null) {
      throw StateError('Local cache not available');
    }
  }

  Future<List<Node>> fetchRecentPages({int limit = 10}) async {
    _requireCache();
    return _cache!.getRecentPages(limit: limit);
  }

  Future<List<Node>> fetchFavorites({int limit = 50}) async {
    _requireCache();
    final workspaceId = await syncService!.getWorkspaceId();
    if (workspaceId == null) return const [];
    return _cache!.getFavorites(
      workspaceId,
      limit: limit,
      actorId: syncService!.hasUserActor ? syncService!.actorId : null,
    );
  }

  Future<List<String>> fetchFavoriteUuids() async {
    _requireCache();
    final workspaceId = await syncService!.getWorkspaceId();
    if (workspaceId == null) return const [];
    return _cache!.getFavoriteUuids(
      workspaceId,
      actorId: syncService!.hasUserActor ? syncService!.actorId : null,
    );
  }

  Future<void> addFavorite(String nodeUuid) async {
    _requireCache();
    final workspaceId = await syncService!.getWorkspaceId();
    if (workspaceId != null) {
      await _cache!.addFavorite(workspaceId, nodeUuid, actorId: syncService!.actorId);
    }
    await syncService!.enqueue(
      type: 'add_favorite',
      nodeUuid: nodeUuid,
    );
    await syncService!.flush();
  }

  Future<void> removeFavorite(String nodeUuid) async {
    _requireCache();
    final workspaceId = await syncService!.getWorkspaceId();
    if (workspaceId != null) {
      await _cache!.removeFavorite(workspaceId, nodeUuid, actorId: syncService!.actorId);
    }
    await syncService!.enqueue(
      type: 'remove_favorite',
      nodeUuid: nodeUuid,
    );
    await syncService!.flush();
  }

  Future<void> reorderFavorites(int fromIndex, int toIndex) async {
    _requireCache();
    final workspaceId = await syncService!.getWorkspaceId();
    if (workspaceId == null) {
      return;
    }
    final uuids = await _cache!.getFavoriteUuids(
      workspaceId,
      actorId: syncService!.hasUserActor ? syncService!.actorId : null,
    );
    if (fromIndex < 0 ||
        fromIndex >= uuids.length ||
        toIndex < 0 ||
        toIndex >= uuids.length) {
      return;
    }
    final moved = uuids.removeAt(fromIndex);
    uuids.insert(toIndex, moved);
    await _cache!.reorderFavorites(workspaceId, uuids, actorId: syncService!.actorId);
    await syncService!.enqueue(
      type: 'reorder_favorites',
      nodeUuid: '',
      favoriteNodeUuids: uuids,
    );
    await syncService!.flush();
  }

  Future<List<Node>> fetchRootPages() async {
    _requireCache();
    return _cache!.getRootPages();
  }

  /// Nodes shared with the current actor; empty when no authenticated user
  /// is wired into sync.
  Future<List<Node>> fetchSharedWithMe({int limit = 50}) async {
    _requireCache();
    final workspaceId = await syncService!.getWorkspaceId();
    if (workspaceId == null || !syncService!.hasUserActor) return const [];
    return _cache!.getSharedWithMe(
      workspaceId,
      syncService!.actorId,
      limit: limit,
    );
  }

  Future<List<Node>> searchNodes(String query, {int limit = 20}) async {
    _requireCache();
    return _cache!.searchNodes(query, limit: limit);
  }

  Future<Node> fetchNode(String uuid) async {
    _requireCache();
    var node = await _cache!.getByUuid(uuid);
    if (node == null) {
      // The node may have been created on another device. Pull the latest
      // relay operations and try again before giving up.
      try {
        await syncService?.pull();
      } catch (e) {
        debugPrint('[fetchNode] pull failed for $uuid: $e');
      }
      node = await _cache!.getByUuid(uuid);
    }
    if (node == null) throw StateError('Node not found in local cache: $uuid');
    return node;
  }

  Future<Node> fetchNodeByUuid(String uuid) async {
    _requireCache();
    var node = await _cache!.getByUuid(uuid);
    if (node == null) {
      try {
        await syncService?.pull();
      } catch (e) {
        debugPrint('[fetchNodeByUuid] pull failed for $uuid: $e');
      }
      node = await _cache!.getByUuid(uuid);
    }
    if (node == null) throw StateError('Node not found in local cache: $uuid');
    return node;
  }

  Future<List<Node>> fetchNodesByUuids(List<String> uuids) async {
    _requireCache();
    return _cache!.getByUuids(uuids);
  }

  /// Every live PAGE whose alias-terminal is [uuid] (the aliases listing
  /// behind the title-row affordance): the store's recursive
  /// `aliasNodeIdsOf` read, mapped to nodes and filtered to pages — the
  /// render-state restriction (a non-page carrier never acts as an alias,
  /// exactly like the web's rendersWithDocumentChrome filter).
  Future<List<Node>> fetchAliasNodesOf(String uuid) async {
    _requireCache();
    final ids = await _cache!.aliasNodeIdsOf(uuid);
    if (ids.isEmpty) return const [];
    final nodes = await _cache!.getByUuids(ids);
    return nodes.where((n) => n.isPage).toList();
  }

  /// The node-alias write: point [uuid]'s `aliasedNodeId` at [aliasedNodeId]
  /// (the main page) or clear it with `null` — a single object.update op
  /// through the sync service (applied locally, pushed on the next flush).
  Future<void> setAliasedNodeId(String uuid, String? aliasedNodeId) async {
    _requireCache();
    await syncService!.setAliasedNode(
      objectId: uuid,
      aliasedNodeId: aliasedNodeId,
    );
  }

  Future<List<BreadcrumbItem>> fetchBreadcrumbs(String uuid) async {
    _requireCache();
    final uuids = await _cache!.getBreadcrumbs(uuid);
    final nodes = await _cache!.getByUuids(uuids);
    return nodes
        .map((n) => BreadcrumbItem(
              uuid: n.uuid,
              name: n.name,
              displayName: n.displayName,
              icon: n.icon,
              isPage: n.isPage,
            ))
        .toList();
  }

  Future<PageContent> fetchPageContent(String uuid) async {
    _requireCache();
    try {
      return await _cache!.getPageContent(uuid);
    } on StateError {
      // Page may exist on the server but not in the local cache yet.
      try {
        await syncService?.pull();
      } catch (e) {
        debugPrint('[fetchPageContent] pull failed for $uuid: $e');
      }
      return _cache!.getPageContent(uuid);
    }
  }

  Future<PageContent> fetchInboxContent() async {
    return fetchPageContent(SystemPageUuids.inbox);
  }

  Future<Node> createQuickNote({
    required String name,
    String? icon,
    List<String> additionalTypes = const [],
  }) async {
    _requireCache();
    final nodeUuid = const Uuid().v7();
    final isTask = additionalTypes.contains('task');
    final classUuids = isTask ? [SystemClassUuids.task] : <String>[];
    await syncService!.enqueue(
      type: 'create',
      nodeUuid: nodeUuid,
      contentAst: AstBuilder.parseInline(name),
      isPage: !isTask,
      isTask: isTask,
      classUuids: classUuids,
    );
    await syncService!.flush();
    return Node(
      id: 0,
      uuid: nodeUuid,
      name: AstBuilder.serialize(AstBuilder.parseInline(name)),
      displayName: name,
      icon: icon,
      isPage: !isTask,
      isTask: isTask,
    );
  }

  Future<Node> createInboxBlock({
    required String name,
    bool isTask = false,
    String? color,
    String? parentUuid,
  }) async {
    _requireCache();
    final classUuids = isTask ? [SystemClassUuids.task] : <String>[];
    final targetParent = parentUuid ?? SystemPageUuids.inbox;
    final nodeUuid = const Uuid().v7();
    await syncService!.enqueue(
      type: 'create',
      nodeUuid: nodeUuid,
      contentAst: AstBuilder.parseInline(name),
      parentUuid: targetParent,
      isPage: false,
      isTask: isTask,
      classUuids: classUuids,
      properties: color != null ? {'color': color} : null,
    );
    await syncService!.flush();
    return Node(
      id: 0,
      uuid: nodeUuid,
      name: AstBuilder.serialize(AstBuilder.parseInline(name)),
      displayName: name,
      isPage: false,
      isTask: isTask,
      color: color,
    );
  }

  Future<Node> createTask(String name) async {
    _requireCache();
    final nodeUuid = const Uuid().v7();
    await syncService!.enqueue(
      type: 'create',
      nodeUuid: nodeUuid,
      contentAst: AstBuilder.parseInline(name),
      isTask: true,
      classUuids: [SystemClassUuids.task],
    );
    await syncService!.flush();
    return Node(
      id: 0,
      uuid: nodeUuid,
      name: AstBuilder.serialize(AstBuilder.parseInline(name)),
      displayName: name,
      isTask: true,
    );
  }

  Future<Node> getOrCreateDailyJournal(DateTime date) async {
    _requireCache();
    final formatted = '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';

    final nodeUuid = dateToDayUuid(date);
    final cached = await syncService!.getCachedNode(nodeUuid);
    if (cached != null) return cached;
    await syncService!.enqueue(
      type: 'create',
      nodeUuid: nodeUuid,
      contentAst: AstBuilder.parseInline(formatted),
      isDaily: true,
      classUuids: [SystemClassUuids.day],
    );
    await syncService!.flush();
    return Node(
      id: 0,
      uuid: nodeUuid,
      name: AstBuilder.serialize(AstBuilder.parseInline(formatted)),
      displayName: formatted,
      isDaily: true,
    );
  }

  Future<List<Node>> fetchTasks({bool includeComplete = false, int page = 1, int pageSize = 50}) async {
    _requireCache();
    return _cache!.getTasks(includeComplete: includeComplete);
  }

  Future<List<Node>> fetchClasses() async {
    _requireCache();
    // If the class cache is empty (e.g. after a fresh install or schema
    // migration), pull from the server first so the snapshot can populate it.
    if (await _cache!.classCacheCount() == 0) {
      try {
        await syncService!.pull();
      } catch (e) {
        debugPrint('[fetchClasses] pull failed: $e');
      }
    }
    return _cache!.getClasses();
  }

  Future<Node?> findClassByUuid(String uuid) async {
    final classes = await fetchClasses();
    for (final c in classes) {
      if (c.uuid == uuid) return c;
    }
    return null;
  }

  /// Fetches nodes that link to the given node (backlinks with context).
  Future<LinkedReferencesResult> fetchLinkedReferences(String uuid, {int limit = 50}) async {
    _requireCache();
    return _cache!.getLinkedReferences(uuid);
  }

  Future<List<Node>> searchWithFilters(SearchFilters filters) async {
    _requireCache();
    return _cache!.searchWithFilters(filters);
  }

  /// Color ([color]) is tri-state: omit it to leave the node's
  /// color untouched, pass a preset token or `#RRGGBB` hex to set it, or
  /// pass an explicit `null` to CLEAR it — the queued `update_color` op
  /// serializes the clear as `"color": null` on the wire, and the outbox
  /// JSON preserves the key through an offline round-trip.
  Future<Node> updateNode(
    String uuid, {
    String? name,
    String? icon,
    Object? color = _undefinedColor,
    List<String>? classes,
    List<String>? tags,
  }) async {
    _requireCache();
    final service = syncService!;

    if (name != null) {
      try {
        final ast = jsonDecode(name) as List<dynamic>;
        await service.enqueue(
          type: 'update_content',
          nodeUuid: uuid,
          contentAst: ast.cast<Map<String, dynamic>>(),
        );
      } catch (_) {
        await service.enqueue(
          type: 'update_node',
          nodeUuid: uuid,
          name: name,
        );
      }
    }

    if (icon != null) {
      await service.enqueue(
        type: 'update_icon',
        nodeUuid: uuid,
        propertyValue: icon,
      );
    }
    // "Absent" is represented by the caller omitting [color] (the sentinel):
    // no op is enqueued and the wire sees no color write. Anything else —
    // token, hex, or an explicit null clear — rides a queued update_color
    // op; the payload builder turns a null propertyValue into an explicit
    // `"color": null`.
    if (!identical(color, _undefinedColor)) {
      await service.enqueue(
        type: 'update_color',
        nodeUuid: uuid,
        propertyValue: color as String?,
      );
    }

    final cached = await _cache!.getByUuid(uuid);
    final currentClasses = cached?.classesUuid ?? const [];
    final currentTags = cached?.tagsUuid ?? const [];

    if (classes != null) {
      final currentSet = currentClasses.toSet();
      final nextSet = classes.toSet();
      for (final added in nextSet.difference(currentSet)) {
        await service.enqueue(
          type: 'add_class',
          nodeUuid: uuid,
          classUuid: added,
        );
      }
      for (final removed in currentSet.difference(nextSet)) {
        await service.enqueue(
          type: 'remove_class',
          nodeUuid: uuid,
          classUuid: removed,
        );
      }
    }

    if (tags != null) {
      final currentSet = currentTags.toSet();
      final nextSet = tags.toSet();
      for (final added in nextSet.difference(currentSet)) {
        await service.enqueue(
          type: 'add_tag',
          nodeUuid: uuid,
          tagUuid: added,
        );
      }
      for (final removed in currentSet.difference(nextSet)) {
        await service.enqueue(
          type: 'remove_tag',
          nodeUuid: uuid,
          tagUuid: removed,
        );
      }
    }

    await service.flush();
    // Return a best-effort local projection.
    return Node(
      id: 0,
      uuid: uuid,
      name: name ?? '',
      displayName: name ?? '',
      icon: icon,
      color: identical(color, _undefinedColor) ? null : color as String?,
    );
  }

  Future<void> archiveNode(String uuid) async {
    _requireCache();
    final node = await _cache?.getByUuid(uuid);
    if (node != null) {
      await _cache!.upsert(node.copyWithIsArchived(true));
    }
    await syncService!.enqueue(
      type: 'archive',
      nodeUuid: uuid,
    );
    await syncService!.flush();
  }

  Future<void> unarchiveNode(String uuid) async {
    _requireCache();
    final node = await _cache?.getByUuid(uuid);
    if (node != null) {
      await _cache!.upsert(node.copyWithIsArchived(false));
    }
    await syncService!.enqueue(
      type: 'restore',
      nodeUuid: uuid,
    );
    await syncService!.flush();
  }

  Future<List<Node>> fetchArchived({int page = 1, int pageSize = 50}) async {
    _requireCache();
    return _cache!.getArchived();
  }

  Future<void> moveNode({
    required String nodeUuid,
    String? parentUuid,
    int? position,
  }) async {
    _requireCache();
    await syncService!.enqueue(
      type: 'move',
      nodeUuid: nodeUuid,
      parentUuid: parentUuid,
      newIndex: position,
    );
    await syncService!.flush();
  }

  Future<void> deleteNode(String uuid) async {
    _requireCache();
    await syncService!.enqueue(type: 'delete', nodeUuid: uuid);
    await syncService!.flush();
  }

  // === Trash ===

  /// Trashed (restorable) nodes.
  ///
  /// Matches the web's Trash view: "trash" is the archived node set
  /// (`active = 0`). `node.delete` / `node.permanentDelete` are hard deletes
  /// on the server with no recoverable remainder, so archived nodes are the
  /// only entries that can be restored.
  Future<List<Node>> fetchTrash({int page = 1, int pageSize = 50}) async {
    _requireCache();
    return _cache!.getArchived();
  }

  Future<void> restoreNode(String uuid) async {
    _requireCache();
    await syncService!.enqueue(type: 'restore', nodeUuid: uuid);
    await syncService!.flush();
  }

  // === Tags ===

  Future<void> addTag(String nodeUuid, String tagUuid) async {
    _requireCache();
    await syncService!.enqueue(
      type: 'add_tag',
      nodeUuid: nodeUuid,
      tagUuid: tagUuid,
    );
    await syncService!.flush();
  }

  Future<void> removeTag(String nodeUuid, String tagUuid) async {
    _requireCache();
    await syncService!.enqueue(
      type: 'remove_tag',
      nodeUuid: nodeUuid,
      tagUuid: tagUuid,
    );
    await syncService!.flush();
  }

  // === Properties ===

  Future<List<Property>> fetchAvailableProperties(String nodeUuid) async {
    _requireCache();
    return _cache!.getAvailableProperties(nodeUuid);
  }

  Future<List<NodePropertyValue>> fetchNodeProperties(String nodeUuid) async {
    _requireCache();
    // If property schemas have not been synced yet (e.g. after a fresh install
    // or schema migration), pull first so property names resolve correctly.
    if (await _cache!.propertySchemaCacheCount() == 0) {
      try {
        await syncService?.pull();
      } catch (e) {
        debugPrint('[fetchNodeProperties] pull failed for $nodeUuid: $e');
      }
    }
    return _cache!.getNodeProperties(nodeUuid);
  }

  /// Fetches the properties a class applies to its nodes, including the
  /// class-level `hidden`, `required` and `default_value` attributes.
  Future<List<ClassProperty>> fetchClassProperties(String classNodeUuid, {bool includeInherited = true}) async {
    _requireCache();
    return _cache!.getClassProperties(classNodeUuid);
  }

  Future<void> setNodeProperty(String nodeUuid, String propertyUuid, dynamic value) async {
    _requireCache();
    await syncService!.enqueue(
      type: 'set_property',
      nodeUuid: nodeUuid,
      propertyUuid: propertyUuid,
      propertyValue: value,
    );
    await syncService!.flush();
  }

  /// The effective (schema, idx) rows for [nodeUuid] — the source
  /// of the block-bullet value button (display bullet/inline select,
  /// multi_select and boolean rows).
  Future<List<EffectiveProperty>> fetchEffectiveProperties(String nodeUuid) async {
    _requireCache();
    return _cache!.getEffectiveProperties(nodeUuid);
  }

  /// One cached property-schema row by UUID (the select options ride
  /// the icon + color verbatim).
  Future<PropertySchemaRow?> fetchPropertySchemaRow(String uuid) async {
    _requireCache();
    return _cache!.getPropertySchemaRow(uuid);
  }

  Future<String?> getMostRecentTaskCompletionId(String taskUuid) async {
    _requireCache();
    return _cache!.getMostRecentTaskCompletionId(taskUuid);
  }

  Future<int> getTaskCompletionCount(String taskUuid) async {
    _requireCache();
    return _cache!.getTaskCompletionCount(taskUuid);
  }

  Future<Map<String, dynamic>?> getTaskRecurrence(String taskUuid) async {
    _requireCache();
    return _cache!.getTaskRecurrence(taskUuid);
  }

  Future<void> recordTaskCompletion(String taskUuid, {String status = 'done'}) async {
    _requireCache();
    final completionId = Uuid7.generate();
    final completedAt = DateTime.now().toUtc().toIso8601String();
    String? scheduledDate;
    String? deadlineDate;

    final node = await _cache?.getByUuid(taskUuid);
    if (node != null) {
      scheduledDate = node.properties[SystemPropertyUuids.taskScheduled] as String?;
      deadlineDate = node.properties[SystemPropertyUuids.taskDeadline] as String?;
    }

    await _cache!.recordTaskCompletion(
      taskUuid,
      completionId,
      completedAt: completedAt,
      scheduledDate: scheduledDate,
      deadlineDate: deadlineDate,
      status: status,
    );
    await syncService!.enqueue(
      type: 'task_record_completion',
      nodeUuid: taskUuid,
      completionId: completionId,
      completionStatus: status,
      completedAt: completedAt,
      scheduledDate: scheduledDate,
      deadlineDate: deadlineDate,
    );
    await syncService!.flush();
  }

  Future<void> deleteTaskCompletion(String taskUuid, String completionId) async {
    _requireCache();
    await _cache!.deleteTaskCompletion(taskUuid, completionId);
    await syncService!.enqueue(
      type: 'task_delete_completion',
      nodeUuid: taskUuid,
      completionId: completionId,
    );
    await syncService!.flush();
  }
}
