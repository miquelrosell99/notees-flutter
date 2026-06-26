import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../../core/utils/ast_builder.dart';
import '../../domain/models/search_filters.dart';
import '../../domain/services/sync_v2_service.dart';
import '../models/breadcrumb_item.dart';
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

  Future<List<Node>> fetchRecentPages({int limit = 10}) async {
    final response = await dio.get<Map<String, dynamic>>('/nodes/recents', queryParameters: {'limit': limit});
    final data = response.data;
    if (data == null) return [];
    final items = data['nodes'] as List<dynamic>? ?? [];
    return items.map((e) => Node.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<Node>> fetchFavorites({int limit = 50}) async {
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
    await dio.post<Map<String, dynamic>>('/nodes/favorites/$nodeUuid');
  }

  Future<void> removeFavorite(String nodeUuid) async {
    await dio.delete<Map<String, dynamic>>('/nodes/favorites/$nodeUuid');
  }

  Future<void> reorderFavorites(int fromIndex, int toIndex) async {
    await dio.put<Map<String, dynamic>>(
      '/nodes/favorites/reorder',
      data: {'from_index': fromIndex, 'to_index': toIndex},
    );
  }

  Future<List<Node>> fetchRootPages() async {
    final response = await dio.get<Map<String, dynamic>>(
      '/nodes/',
      queryParameters: {'pages_only': 'true', 'root_only': 'true'},
    );
    final data = response.data;
    if (data == null) return [];
    final items = (data['items'] ?? data['nodes']) as List<dynamic>? ?? [];
    return items.map((e) => Node.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<Node>> searchNodes(String query, {int limit = 20}) async {
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
    final response = await dio.get<Map<String, dynamic>>('/nodes/$uuid');
    return Node.fromJson(response.data!);
  }

  Future<Node> fetchNodeByUuid(String uuid) async {
    final response = await dio.get<Map<String, dynamic>>('/nodes/uuid/$uuid');
    return Node.fromJson(response.data!);
  }

  Future<List<BreadcrumbItem>> fetchBreadcrumbs(String uuid) async {
    final response = await dio.get<Map<String, dynamic>>('/nodes/$uuid/breadcrumbs');
    final data = response.data;
    if (data == null) return [];
    final items = data['breadcrumbs'] as List<dynamic>? ?? [];
    return items.map((e) => BreadcrumbItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<PageContent> fetchPageContent(String uuid) async {
    final response = await dio.get<Map<String, dynamic>>('/nodes/page/$uuid/content');
    return PageContent.fromJson(response.data!);
  }

  Future<Node> createQuickNote({
    required String name,
    String? icon,
    List<String> additionalTypes = const [],
  }) async {
    if (syncService != null) {
      final nodeUuid = const Uuid().v7();
      final isTask = additionalTypes.contains('task');
      await syncService!.enqueue(
        type: 'create',
        nodeUuid: nodeUuid,
        contentAst: AstBuilder.parseInline(name),
        isPage: true,
        isTask: isTask,
      );
      await syncService!.flush();
      return Node(
        id: 0,
        uuid: nodeUuid,
        name: AstBuilder.serialize(AstBuilder.parseInline(name)),
        displayName: name,
        icon: icon,
        isPage: true,
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

  Future<Node> createTask(String name) async {
    return createQuickNote(name: name, additionalTypes: const ['task']);
  }

  Future<Node> getOrCreateDailyJournal(DateTime date) async {
    final formatted = '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    final response = await dio.post<Map<String, dynamic>>(
      '/nodes/daily',
      queryParameters: {'date': formatted},
    );
    return Node.fromJson(response.data!);
  }

  Future<List<Node>> fetchTasks({bool includeComplete = false, int page = 1, int pageSize = 50}) async {
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

  Future<List<Node>> searchWithFilters(SearchFilters filters) async {
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

      final properties = <String, dynamic>{};
      if (icon != null) properties['icon'] = icon;
      if (color != null) properties['color'] = color;
      if (properties.isNotEmpty) {
        await syncService!.enqueue(
          type: 'update_node',
          nodeUuid: uuid,
          properties: properties,
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
    final response = await dio.get<Map<String, dynamic>>('/nodes/$nodeUuid/properties');
    final data = response.data;
    if (data == null) return [];
    final items = data['properties'] as List<dynamic>? ?? [];
    return items.map((e) => NodePropertyValue.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> setNodeProperty(String nodeUuid, String propertyUuid, dynamic value) async {
    await dio.post<Map<String, dynamic>>(
      '/nodes/$nodeUuid/properties',
      data: {'property_uuid': propertyUuid, 'value': value},
    );
  }
}
