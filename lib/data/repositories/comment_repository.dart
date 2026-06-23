// ignore_for_file: use_null_aware_elements

import 'package:dio/dio.dart';

import '../models/node.dart';

class CommentRepository {
  CommentRepository({required this.dio});

  final Dio dio;

  Future<List<Node>> fetchComments(int nodeId, {int page = 1, int pageSize = 50}) async {
    final response = await dio.get<Map<String, dynamic>>(
      '/nodes/$nodeId/comments',
      queryParameters: {'page': page, 'page_size': pageSize},
    );
    final data = response.data;
    if (data == null) return [];
    final items = (data['items'] ?? data['nodes']) as List<dynamic>? ?? [];
    return items.map((e) => Node.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Node> createComment(
    int nodeId, {
    required String name,
    int? parentCommentId,
  }) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/nodes/$nodeId/comments',
      data: {
        'name': name,
        if (parentCommentId != null) 'parent_comment_id': parentCommentId,
      },
    );
    return Node.fromJson(response.data!);
  }

  Future<void> deleteComment(int nodeId, int commentId) async {
    await dio.delete<Map<String, dynamic>>('/nodes/$nodeId/comments/$commentId');
  }

  Future<int> fetchCommentCount(int nodeId) async {
    final response = await dio.get<Map<String, dynamic>>('/nodes/$nodeId/comment-count');
    return response.data?['count'] as int? ?? 0;
  }
}
