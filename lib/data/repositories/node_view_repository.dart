// ignore_for_file: use_null_aware_elements

import 'package:dio/dio.dart';

import '../models/node.dart';

class NodeView {
  NodeView({
    required this.id,
    required this.nodeId,
    required this.viewType,
    required this.name,
    this.queryAst,
  });

  final int id;
  final int nodeId;
  final String viewType;
  final String name;
  final Map<String, dynamic>? queryAst;

  factory NodeView.fromJson(Map<String, dynamic> json) => NodeView(
        id: json['id'] as int,
        nodeId: json['node_id'] as int,
        viewType: json['view_type'] as String,
        name: json['name'] as String,
        queryAst: json['query_ast'] as Map<String, dynamic>?,
      );
}

class NodeViewRepository {
  NodeViewRepository({required this.dio});

  final Dio dio;

  Future<List<NodeView>> fetchViews(int nodeId, {String? viewType, bool includeQueryAst = true}) async {
    final response = await dio.get<Map<String, dynamic>>(
      '/nodes/views',
      queryParameters: {
        'node_id': nodeId,
        if (viewType != null) 'view_type': viewType,
        'include_query_ast': includeQueryAst.toString(),
      },
    );
    final data = response.data;
    if (data == null) return [];
    final items = (data['views'] ?? data['items']) as List<dynamic>? ?? [];
    return items.map((e) => NodeView.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<NodeView?> fetchDefaultView(int nodeId, String viewType) async {
    final response = await dio.get<Map<String, dynamic>>(
      '/nodes/views/default/$nodeId/$viewType',
    );
    final data = response.data;
    if (data == null || data.isEmpty) return null;
    return NodeView.fromJson(data);
  }

  Future<NodeView> createView(
    int nodeId,
    String viewType,
    String name, {
    Map<String, dynamic>? queryAst,
  }) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/nodes/views',
      data: {
        'node_id': nodeId,
        'view_type': viewType,
        'name': name,
        if (queryAst != null) 'query_ast': queryAst,
      },
    );
    return NodeView.fromJson(response.data!);
  }

  Future<NodeView> updateQueryAst(int viewId, Map<String, dynamic> queryAst) async {
    final response = await dio.put<Map<String, dynamic>>(
      '/nodes/views/$viewId/query-ast',
      data: {'query_ast': queryAst},
    );
    return NodeView.fromJson(response.data!);
  }

  Future<List<Node>> executeView(int viewId, {Map<String, dynamic>? params}) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/nodes/views/$viewId/execute',
      data: params ?? {},
    );
    final data = response.data;
    if (data == null) return [];
    final items = (data['nodes'] ?? data['items']) as List<dynamic>? ?? [];
    return items.map((e) => Node.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> deleteView(int viewId) async {
    await dio.delete<Map<String, dynamic>>('/nodes/views/$viewId');
  }
}
