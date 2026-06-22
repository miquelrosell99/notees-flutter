import 'package:dio/dio.dart';

import '../../domain/models/search_filters.dart';
import '../models/node.dart';

class NodeRepository {
  NodeRepository({required this.dio});

  final Dio dio;

  Future<List<Node>> fetchRecentPages({int limit = 10}) async {
    final response = await dio.get<Map<String, dynamic>>('/nodes/recents', queryParameters: {'limit': limit});
    final data = response.data;
    if (data == null) return [];
    final items = data['nodes'] as List<dynamic>? ?? [];
    return items.map((e) => Node.fromJson(e as Map<String, dynamic>)).toList();
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

  Future<Node> fetchNode(int id) async {
    final response = await dio.get<Map<String, dynamic>>('/nodes/$id');
    return Node.fromJson(response.data!);
  }

  Future<Node> fetchPageContent(int id) async {
    final response = await dio.get<Map<String, dynamic>>('/nodes/page/$id/content');
    return Node.fromJson(response.data!);
  }

  Future<Node> createQuickNote({
    required String name,
    String? icon,
    List<String> additionalTypes = const [],
  }) async {
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
}
