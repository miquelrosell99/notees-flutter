// ignore_for_file: use_null_aware_elements

import 'package:dio/dio.dart';

import '../models/node.dart';

class NodeView {
  NodeView({
    required this.uuid,
    required this.nodeUuid,
    required this.viewType,
    required this.name,
    this.queryAst,
  });

  final String uuid;
  final String nodeUuid;
  final String viewType;
  final String name;
  final Map<String, dynamic>? queryAst;

  factory NodeView.fromJson(Map<String, dynamic> json) => NodeView(
        uuid: json['uuid'] as String,
        nodeUuid: json['node_uuid'] as String,
        viewType: json['view_type'] as String,
        name: json['name'] as String,
        queryAst: json['query_ast'] as Map<String, dynamic>?,
      );
}

class NodeViewRepository {
  NodeViewRepository({required this.dio});

  final Dio dio;

  Future<List<NodeView>> fetchViews(String nodeUuid, {String? viewType, bool includeQueryAst = true}) async {
    final response = await dio.get<Map<String, dynamic>>(
      '/nodes/views',
      queryParameters: {
        'node_uuid': nodeUuid,
        if (viewType != null) 'view_type': viewType,
        'include_query_ast': includeQueryAst.toString(),
      },
    );
    final data = response.data;
    if (data == null) return [];
    final items = (data['views'] ?? data['items']) as List<dynamic>? ?? [];
    return items.map((e) => NodeView.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<NodeView?> fetchDefaultView(String nodeUuid, String viewType) async {
    final response = await dio.get<Map<String, dynamic>>(
      '/nodes/views/default/$nodeUuid/$viewType',
    );
    final data = response.data;
    if (data == null || data.isEmpty) return null;
    return NodeView.fromJson(data);
  }

  Future<NodeView> createView(
    String nodeUuid,
    String viewType,
    String name, {
    Map<String, dynamic>? queryAst,
  }) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/nodes/views',
      data: {
        'node_uuid': nodeUuid,
        'view_type': viewType,
        'name': name,
        if (queryAst != null) 'query_ast': queryAst,
      },
    );
    return NodeView.fromJson(response.data!);
  }

  Future<NodeView> updateQueryAst(String viewUuid, Map<String, dynamic> queryAst) async {
    final response = await dio.put<Map<String, dynamic>>(
      '/nodes/views/$viewUuid/query-ast',
      data: {'query_ast': queryAst},
    );
    return NodeView.fromJson(response.data!);
  }

  Future<List<Node>> executeView(String viewUuid, {Map<String, dynamic>? params}) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/nodes/views/$viewUuid/execute',
      data: params ?? {},
    );
    final data = response.data;
    if (data == null) return [];
    final items = (data['nodes'] ?? data['items']) as List<dynamic>? ?? [];
    return items.map((e) => Node.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> deleteView(String viewUuid) async {
    await dio.delete<Map<String, dynamic>>('/nodes/views/$viewUuid');
  }
}
