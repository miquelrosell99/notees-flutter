// ignore_for_file: use_null_aware_elements

import 'package:dio/dio.dart';

import '../models/node.dart';

class TemplateRepository {
  TemplateRepository({required this.dio});

  final Dio dio;

  Future<List<Node>> fetchTemplates({int page = 1, int pageSize = 50}) async {
    final response = await dio.get<Map<String, dynamic>>(
      '/nodes/templates',
      queryParameters: {'page': page, 'page_size': pageSize},
    );
    final data = response.data;
    if (data == null) return [];
    final items = (data['items'] ?? data['nodes']) as List<dynamic>? ?? [];
    return items.map((e) => Node.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<String>> fetchTemplateVariables(int nodeId) async {
    final response = await dio.get<Map<String, dynamic>>('/nodes/$nodeId/template-variables');
    final data = response.data;
    if (data == null) return [];
    final items = data['variables'] as List<dynamic>? ?? [];
    return items.cast<String>();
  }

  Future<Node> instantiateTemplate(
    int nodeId, {
    int? parentId,
    String? name,
    Map<String, String> variables = const {},
    Map<String, String> dynamicContext = const {},
    bool asBlocks = false,
    int? afterId,
  }) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/nodes/$nodeId/instantiate',
      data: {
        if (parentId != null) 'parent_id': parentId,
        if (name != null) 'name': name,
        'variables': variables,
        'dynamic_context': dynamicContext,
        'as_blocks': asBlocks,
        if (afterId != null) 'after_id': afterId,
      },
    );
    final data = response.data!;
    final nodeJson = data['node'] as Map<String, dynamic>?;
    if (nodeJson != null) {
      return Node.fromJson(nodeJson);
    }
    final blocks = data['blocks'] as List<dynamic>?;
    if (blocks != null && blocks.isNotEmpty) {
      return Node.fromJson(blocks.first as Map<String, dynamic>);
    }
    throw Exception('Template instantiation returned no node');
  }
}
