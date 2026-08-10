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
import 'node_cache_repository.dart';
import '../models/breadcrumb_item.dart';
import '../models/linked_reference.dart';
import '../models/node.dart';
import '../models/page_content.dart';
import '../models/property.dart';

class NodeRepository {
  NodeRepository({
    required this.dio,
    this.syncService,
  });

  final Dio dio;
  final SyncV2Service? syncService;

  bool get _localMode => syncService != null;
  NodeCacheRepository? get _cache => syncService?.cache;

  Future<List<Node>> fetchRecentPages({int limit = 10}) async {
    if (_localMode) {
      return _cache!.getRecentPages(limit: limit);
    }
    final response = await dio.get<Map<String, dynamic>>('/nodes/recents', queryParameters: {'limit': limit});
    final data = response.data;
    if (data == null) return [];
    final items = data['nodes'] as List<dynamic>? ?? [];
    return items
        .map((e) => Node.fromJson(e as Map<String, dynamic>))
        .where((n) => !n.isJournal)
        .toList();
  }

  Future<List<Node>> fetchFavorites({int limit = 50}) async {
    if (_localMode) {
      final workspaceId = await syncService!.getWorkspaceId();
      if (workspaceId == null) return const [];
      return _cache!.getFavorites(workspaceId, limit: limit);
    }
    final response = await dio.get<Map<String, dynamic>>(
      '/nodes/favorites',
      queryParameters: {'page': 1, 'page_size': limit},
    );
    final data = response.data;
    if (data == null) return [];
    final items = (data['items'] ?? data['nodes']) as List<dynamic>? ?? [];
    return items.map((e) => Node.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<String>> fetchFavoriteUuids() async {
    if (_localMode) {
      final workspaceId = await syncService!.getWorkspaceId();
      if (workspaceId == null) return const [];
      return _cache!.getFavoriteUuids(workspaceId);
    }
    final response = await dio.get<Map<String, dynamic>>(
      '/nodes/favorites',
      queryParameters: {'page': 1, 'page_size': 500},
    );
    final data = response.data;
    if (data == null) return [];
    final items = (data['items'] ?? data['nodes']) as List<dynamic>? ?? [];
    return items.map((e) {
      final json = e as Map<String, dynamic>;
      return json['uuid'] as String? ?? '';
    }).where((uuid) => uuid.isNotEmpty).toList();
  }

  Future<void> addFavorite(String nodeUuid) async {
    if (syncService != null) {
      final workspaceId = await syncService!.getWorkspaceId();
      if (workspaceId != null) {
        await _cache!.addFavorite(workspaceId, nodeUuid);
      }
      await syncService!.enqueue(
        type: 'add_favorite',
        nodeUuid: nodeUuid,
      );
      await syncService!.flush();
      return;
    }
    await dio.post<Map<String, dynamic>>('/nodes/favorites/$nodeUuid');
  }

  Future<void> removeFavorite(String nodeUuid) async {
    if (syncService != null) {
      final workspaceId = await syncService!.getWorkspaceId();
      if (workspaceId != null) {
        await _cache!.removeFavorite(workspaceId, nodeUuid);
      }
      await syncService!.enqueue(
        type: 'remove_favorite',
        nodeUuid: nodeUuid,
      );
      await syncService!.flush();
      return;
    }
    await dio.delete<Map<String, dynamic>>('/nodes/favorites/$nodeUuid');
  }

  Future<void> reorderFavorites(int fromIndex, int toIndex) async {
    if (syncService != null) {
      final workspaceId = await syncService!.getWorkspaceId();
      if (workspaceId == null) {
        return;
      }
      final uuids = await _cache!.getFavoriteUuids(workspaceId);
      if (fromIndex < 0 ||
          fromIndex >= uuids.length ||
          toIndex < 0 ||
          toIndex >= uuids.length) {
        return;
      }
      final moved = uuids.removeAt(fromIndex);
      uuids.insert(toIndex, moved);
      await _cache!.reorderFavorites(workspaceId, uuids);
      await syncService!.enqueue(
        type: 'reorder_favorites',
        nodeUuid: '',
        favoriteNodeUuids: uuids,
      );
      await syncService!.flush();
      return;
    }
    await dio.put<Map<String, dynamic>>(
      '/nodes/favorites/reorder',
      data: {'from_index': fromIndex, 'to_index': toIndex},
    );
  }

  Future<List<Node>> fetchRootPages() async {
    if (_localMode) {
      return _cache!.getRootPages();
    }
    final response = await dio.get<Map<String, dynamic>>(
      '/nodes/',
      queryParameters: {'pages_only': 'true', 'root_only': 'true'},
    );
    final data = response.data;
    if (data == null) return [];
    final items = (data['items'] ?? data['nodes']) as List<dynamic>? ?? [];
    return items
        .map((e) => Node.fromJson(e as Map<String, dynamic>))
        .where((n) => !n.isJournal)
        .toList();
  }

  Future<List<Node>> searchNodes(String query, {int limit = 20}) async {
    if (_localMode) {
      return _cache!.searchNodes(query, limit: limit);
    }
    final response = await dio.get<Map<String, dynamic>>(
      '/nodes/search',
      queryParameters: {'q': query, 'limit': limit},
    );
    final data = response.data;
    if (data == null) return [];
    final items = data['nodes'] as List<dynamic>? ?? [];
    return items.map((e) => Node.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Node> fetchNode(String uuid) async {
    if (_localMode) {
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
    final response = await dio.get<Map<String, dynamic>>('/nodes/$uuid');
    return Node.fromJson(response.data!);
  }

  Future<Node> fetchNodeByUuid(String uuid) async {
    if (_localMode) {
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
    final response = await dio.get<Map<String, dynamic>>('/nodes/uuid/$uuid');
    return Node.fromJson(response.data!);
  }

  Future<List<BreadcrumbItem>> fetchBreadcrumbs(String uuid) async {
    if (_localMode) {
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
    final response = await dio.get<Map<String, dynamic>>('/nodes/$uuid/breadcrumbs');
    final data = response.data;
    if (data == null) return [];
    final items = data['breadcrumbs'] as List<dynamic>? ?? [];
    return items.map((e) => BreadcrumbItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<PageContent> fetchPageContent(String uuid) async {
    if (_localMode) {
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
    final response = await dio.get<Map<String, dynamic>>('/nodes/page/$uuid/content');
    return PageContent.fromJson(response.data!);
  }

  Future<PageContent> fetchInboxContent() async {
    return fetchPageContent(SystemPageUuids.inbox);
  }

  Future<Node> createQuickNote({
    required String name,
    String? icon,
    List<String> additionalTypes = const [],
  }) async {
    if (syncService != null) {
      final nodeUuid = const Uuid().v7();
      final isTask = additionalTypes.contains('task');
      final classUuids = isTask
          ? [SystemClassUuids.task]
          : [SystemClassUuids.page];
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

    final response = await dio.post<Map<String, dynamic>>(
      '/nodes/page',
      queryParameters: {
        'name': name,
        // ignore: use_null_aware_elements
        if (icon != null) 'icon': icon,
        if (additionalTypes.isNotEmpty) 'additional_types': additionalTypes,
      },
    );
    return Node.fromJson(response.data!);
  }

  Future<Node> createInboxBlock({
    required String name,
    bool isTask = false,
    String? color,
    String? parentUuid,
  }) async {
    final classUuids = isTask ? [SystemClassUuids.task] : <String>[];
    final targetParent = parentUuid ?? SystemPageUuids.inbox;

    if (syncService != null) {
      final nodeUuid = const Uuid().v7();
      final classUuids = isTask ? [SystemClassUuids.task] : <String>[];
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

    final response = await dio.post<Map<String, dynamic>>(
      '/nodes/',
      data: {
        'name': AstBuilder.serialize(AstBuilder.parseInline(name)),
        'parent_uuid': targetParent,
        'class_uuids': classUuids,
        'color': color,
      },
    );
    return Node.fromJson(response.data!);
  }

  Future<Node> createTask(String name) async {
    if (syncService != null) {
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
    return createQuickNote(name: name, additionalTypes: const ['task']);
  }

  Future<Node> getOrCreateDailyJournal(DateTime date) async {
    final formatted = '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';

    if (syncService != null) {
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

    final response = await dio.post<Map<String, dynamic>>(
      '/nodes/daily',
      queryParameters: {'date': formatted},
    );
    return Node.fromJson(response.data!);
  }

  Future<List<Node>> fetchTasks({bool includeComplete = false, int page = 1, int pageSize = 50}) async {
    if (_localMode) {
      return _cache!.getTasks(includeComplete: includeComplete);
    }
    final response = await dio.get<Map<String, dynamic>>(
      '/nodes/tasks',
      queryParameters: {
        'include_complete': includeComplete.toString(),
        'page': page,
        'page_size': pageSize,
      },
    );
    final data = response.data;
    if (data == null) return [];
    final items = (data['items'] ?? data['nodes']) as List<dynamic>? ?? [];
    return items.map((e) => Node.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<Node>> fetchClasses() async {
    if (_localMode) {
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
    final response = await dio.get<Map<String, dynamic>>('/nodes/classes');
    final data = response.data;
    if (data == null) return [];
    final items = data['nodes'] as List<dynamic>? ?? [];
    return items.map((e) => Node.fromJson(e as Map<String, dynamic>)).toList();
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
    if (_localMode) {
      return _cache!.getLinkedReferences(uuid);
    }
    final response = await dio.get<Map<String, dynamic>>(
      '/nodes/$uuid/linked-references',
      queryParameters: {'limit': limit},
    );
    final data = response.data;
    if (data == null) {
      return const LinkedReferencesResult(references: [], totalCount: 0);
    }
    final items = data['linked_references'] as List<dynamic>? ?? [];
    return LinkedReferencesResult(
      references: items.map((e) => LinkedReference.fromJson(e as Map<String, dynamic>)).toList(),
      totalCount: data['total_count'] as int? ?? items.length,
    );
  }

  Future<List<Node>> searchWithFilters(SearchFilters filters) async {
    if (_localMode) {
      return _cache!.searchWithFilters(filters);
    }
    final response = await dio.post<Map<String, dynamic>>(
      '/nodes/search',
      data: filters.toJson(),
    );
    final data = response.data;
    if (data == null) return [];
    final items = data['nodes'] as List<dynamic>? ?? [];
    return items.map((e) => Node.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Node> updateNode(
    String uuid, {
    String? name,
    String? icon,
    String? color,
    List<String>? classes,
    List<String>? tags,
  }) async {
    // Class/tag list changes are not yet modelled as v2 ops, so fall back to
    // the REST endpoint when they are present.
    final canUseSync = syncService != null && classes == null && tags == null;

    if (canUseSync) {
      if (name != null) {
        try {
          final ast = jsonDecode(name) as List<dynamic>;
          await syncService!.enqueue(
            type: 'update_content',
            nodeUuid: uuid,
            contentAst: ast.cast<Map<String, dynamic>>(),
          );
        } catch (_) {
          await syncService!.enqueue(
            type: 'update_node',
            nodeUuid: uuid,
            name: name,
          );
        }
      }

      if (icon != null) {
        await syncService!.enqueue(
          type: 'update_icon',
          nodeUuid: uuid,
          propertyValue: icon,
        );
      }
      if (color != null) {
        await syncService!.enqueue(
          type: 'update_color',
          nodeUuid: uuid,
          propertyValue: color,
        );
      }

      await syncService!.flush();
      // Return a best-effort local projection.
      return Node(
        id: 0,
        uuid: uuid,
        name: name ?? '',
        displayName: name ?? '',
        icon: icon,
        color: color,
      );
    }

    final response = await dio.put<Map<String, dynamic>>(
      '/nodes/$uuid',
      data: {
        'name': name,
        'icon': icon,
        'color': color,
        'class_uuids': classes,
        'tag_uuids': tags,
      },
    );
    return Node.fromJson(response.data!);
  }

  Future<List<Node>> batchUpdateNodes(List<Map<String, dynamic>> nodes) async {
    final response = await dio.put<Map<String, dynamic>>(
      '/nodes/batch',
      data: {'nodes': nodes},
    );
    final data = response.data;
    if (data == null) return [];
    final results = data['results'] as List<dynamic>? ?? [];
    return results
        .where((r) => r['success'] == true && r['node'] != null)
        .map((r) => Node.fromJson(r['node'] as Map<String, dynamic>))
        .toList();
  }

  Future<List<Node>> batchCreateNodes(List<Map<String, dynamic>> nodes) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/nodes/batch',
      data: {'nodes': nodes},
    );
    final data = response.data;
    if (data == null) return [];
    final results = data['results'] as List<dynamic>? ?? [];
    return results
        .where((r) => r['success'] == true && r['node'] != null)
        .map((r) => Node.fromJson(r['node'] as Map<String, dynamic>))
        .toList();
  }

  Future<void> archiveNode(String uuid) async {
    if (syncService != null) {
      final node = await _cache?.getByUuid(uuid);
      if (node != null) {
        await _cache!.upsert(node.copyWithIsArchived(true));
      }
      await syncService!.enqueue(
        type: 'archive',
        nodeUuid: uuid,
      );
      await syncService!.flush();
      return;
    }
    await dio.post<Map<String, dynamic>>('/nodes/$uuid/archive');
  }

  Future<void> unarchiveNode(String uuid) async {
    if (syncService != null) {
      final node = await _cache?.getByUuid(uuid);
      if (node != null) {
        await _cache!.upsert(node.copyWithIsArchived(false));
      }
      await syncService!.enqueue(
        type: 'restore',
        nodeUuid: uuid,
      );
      await syncService!.flush();
      return;
    }
    await dio.post<Map<String, dynamic>>('/nodes/$uuid/unarchive');
  }

  Future<List<Node>> fetchArchived({int page = 1, int pageSize = 50}) async {
    if (_localMode) {
      return _cache!.getArchived();
    }
    final response = await dio.get<Map<String, dynamic>>(
      '/nodes/archived',
      queryParameters: {'page': page, 'page_size': pageSize},
    );
    final data = response.data;
    if (data == null) return [];
    final items = (data['items'] ?? data['nodes']) as List<dynamic>? ?? [];
    return items.map((e) => Node.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> moveNode({
    required String nodeUuid,
    String? parentUuid,
    int? position,
  }) async {
    if (syncService != null) {
      await syncService!.enqueue(
        type: 'move',
        nodeUuid: nodeUuid,
        parentUuid: parentUuid,
        newIndex: position,
      );
      await syncService!.flush();
      return;
    }
    await dio.put<Map<String, dynamic>>(
      '/nodes/$nodeUuid/move',
      data: {
        'parent_uuid': parentUuid,
        'position': position,
      },
    );
  }

  Future<void> deleteNode(String uuid) async {
    if (syncService != null) {
      await syncService!.enqueue(type: 'delete', nodeUuid: uuid);
      await syncService!.flush();
      return;
    }
    await dio.delete('/nodes/$uuid');
  }

  // === Trash ===

  Future<List<Node>> fetchTrash({int page = 1, int pageSize = 50}) async {
    if (_localMode) {
      return _cache!.getArchived();
    }
    final response = await dio.get<Map<String, dynamic>>(
      '/nodes/trash',
      queryParameters: {'page': page, 'page_size': pageSize},
    );
    final data = response.data;
    if (data == null) return [];
    final items = (data['items'] ?? data['nodes']) as List<dynamic>? ?? [];
    return items.map((e) => Node.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> restoreNode(String uuid) async {
    if (syncService != null) {
      await syncService!.enqueue(type: 'restore', nodeUuid: uuid);
      await syncService!.flush();
      return;
    }
    await dio.post<Map<String, dynamic>>('/nodes/$uuid/restore');
  }

  Future<void> emptyTrash() async {
    await dio.post<Map<String, dynamic>>('/nodes/trash/empty');
  }

  Future<void> permanentlyDeleteNode(String uuid) async {
    await dio.delete('/nodes/$uuid/permanent');
  }

  // === Tags ===

  Future<void> addTag(String nodeUuid, String tagUuid) async {
    if (syncService != null) {
      await syncService!.enqueue(
        type: 'add_tag',
        nodeUuid: nodeUuid,
        tagUuid: tagUuid,
      );
      await syncService!.flush();
      return;
    }
    await dio.post<Map<String, dynamic>>(
      '/nodes/$nodeUuid/tag-links',
      data: {'target_node_uuid': tagUuid},
    );
  }

  Future<void> removeTag(String nodeUuid, String tagUuid) async {
    if (syncService != null) {
      await syncService!.enqueue(
        type: 'remove_tag',
        nodeUuid: nodeUuid,
        tagUuid: tagUuid,
      );
      await syncService!.flush();
      return;
    }
    await dio.delete<Map<String, dynamic>>('/nodes/$nodeUuid/tag-links/$tagUuid');
  }

  // === Properties ===

  Future<List<Property>> fetchAvailableProperties(String nodeUuid) async {
    if (_localMode) {
      return _cache!.getAvailableProperties(nodeUuid);
    }
    final response = await dio.get<Map<String, dynamic>>(
      '/properties/available',
      queryParameters: {'context_node_uuid': nodeUuid},
    );
    final data = response.data;
    if (data == null) return [];
    final items = data['properties'] as List<dynamic>? ?? [];
    return items.map((e) => Property.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<NodePropertyValue>> fetchNodeProperties(String nodeUuid) async {
    if (_localMode) {
      return _cache!.getNodeProperties(nodeUuid);
    }
    final response = await dio.get<Map<String, dynamic>>('/nodes/$nodeUuid/properties');
    final data = response.data;
    if (data == null) return [];
    final items = data['properties'] as List<dynamic>? ?? [];
    return items.map((e) => NodePropertyValue.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Fetches the properties a class applies to its nodes, including the
  /// class-level `hidden`, `required` and `default_value` attributes.
  Future<List<ClassProperty>> fetchClassProperties(String classNodeUuid, {bool includeInherited = true}) async {
    if (_localMode) {
      // Class-level property metadata is not rebuilt locally yet.
      return const [];
    }
    final response = await dio.get<Map<String, dynamic>>(
      '/properties/classes/$classNodeUuid/properties',
      queryParameters: {'include_inherited': includeInherited},
    );
    final data = response.data;
    if (data == null) return [];
    final items = data['class_properties'] as List<dynamic>? ?? [];
    return items.map((e) => ClassProperty.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> setNodeProperty(String nodeUuid, String propertyUuid, dynamic value) async {
    if (syncService != null) {
      await syncService!.enqueue(
        type: 'set_property',
        nodeUuid: nodeUuid,
        propertyUuid: propertyUuid,
        propertyValue: value,
      );
      await syncService!.flush();
      return;
    }

    final response = await dio.post<Map<String, dynamic>>(
      '/nodes/$nodeUuid/properties',
      data: {'property_uuid': propertyUuid, 'value': value},
    );
    debugPrint(
      '[setNodeProperty] $propertyUuid=$value -> '
      '${response.data?['properties']?[propertyUuid]}',
    );
  }

  Future<String?> getMostRecentTaskCompletionId(String taskUuid) async {
    if (_localMode) {
      return _cache!.getMostRecentTaskCompletionId(taskUuid);
    }
    // Server mode does not maintain a local completion table; callers should
    // track completion ids themselves when using the REST API.
    return null;
  }

  Future<void> recordTaskCompletion(String taskUuid, {String status = 'done'}) async {
    if (syncService != null) {
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
      return;
    }

    await dio.post<Map<String, dynamic>>(
      '/nodes/tasks/$taskUuid/complete',
      data: {'status': status},
    );
  }

  Future<void> deleteTaskCompletion(String taskUuid, String completionId) async {
    if (syncService != null) {
      await _cache!.deleteTaskCompletion(taskUuid, completionId);
      await syncService!.enqueue(
        type: 'task_delete_completion',
        nodeUuid: taskUuid,
        completionId: completionId,
      );
      await syncService!.flush();
      return;
    }

    await dio.delete<Map<String, dynamic>>(
      '/nodes/tasks/$taskUuid/completions/$completionId',
    );
  }
}
