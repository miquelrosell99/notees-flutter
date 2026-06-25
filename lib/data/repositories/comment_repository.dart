// ignore_for_file: use_null_aware_elements

import 'package:dio/dio.dart';

import '../models/node.dart';

class CommentRepository {
  CommentRepository({required this.dio});

  final Dio dio;

  Future<List<Node>> fetchComments(String nodeUuid, {int page = 1, int pageSize = 50}) async {
    final response = await dio.get<Map<String, dynamic>>(
      '/nodes/$nodeUuid/comments',
      queryParameters: {'page': page, 'page_size': pageSize},
    );
    final data = response.data;
    if (data == null) return [];
    final items = (data['items'] ?? data['nodes']) as List<dynamic>? ?? [];
    return items.map((e) => Node.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Node> createComment(
    String nodeUuid, {
    required String name,
    String? parentCommentUuid,
  }) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/nodes/$nodeUuid/comments',
      data: {
        'name': name,
        if (parentCommentUuid != null) 'parent_comment_uuid': parentCommentUuid,
      },
    );
    return Node.fromJson(response.data!);
  }

  Future<void> deleteComment(String nodeUuid, String commentUuid) async {
    await dio.delete<Map<String, dynamic>>('/nodes/$nodeUuid/comments/$commentUuid');
  }

  Future<int> fetchCommentCount(String nodeUuid) async {
    final response = await dio.get<Map<String, dynamic>>('/nodes/$nodeUuid/comment-count');
    return response.data?['count'] as int? ?? 0;
  }
}
