// ignore_for_file: use_null_aware_elements

import 'package:dio/dio.dart';

class Share {
  Share({
    required this.shareUuid,
    required this.nodeId,
    required this.createdAt,
    this.expiryDate,
    this.url,
    this.nodeName,
    this.nodeUuid,
  });

  final String shareUuid;
  final int nodeId;
  final String createdAt;
  final String? expiryDate;
  final String? url;
  final String? nodeName;
  final String? nodeUuid;

  factory Share.fromJson(Map<String, dynamic> json) => Share(
        shareUuid: json['share_uuid'] as String,
        nodeId: json['node_id'] as int,
        createdAt: json['created_at'] as String,
        expiryDate: json['expiry_date'] as String?,
        url: json['url'] as String?,
        nodeName: json['node_name'] as String?,
        nodeUuid: json['node_uuid'] as String?,
      );
}

class ShareRepository {
  ShareRepository({required this.dio});

  final Dio dio;

  Future<List<Share>> fetchShares() async {
    final response = await dio.get<Map<String, dynamic>>('/shares');
    final data = response.data;
    if (data == null) return [];
    final items = (data['shares'] ?? data['items']) as List<dynamic>? ?? [];
    return items.map((e) => Share.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Share> createShare(
    int nodeId, {
    String? expiryDate,
    String? password,
  }) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/nodes/$nodeId/shares',
      data: {
        if (expiryDate != null) 'expiry_date': expiryDate,
        if (password != null) 'password': password,
      },
    );
    return Share.fromJson(response.data!);
  }

  Future<List<Share>> fetchNodeShares(int nodeId) async {
    final response = await dio.get<Map<String, dynamic>>('/nodes/$nodeId/shares');
    final data = response.data;
    if (data == null) return [];
    final items = (data['shares'] ?? data['items']) as List<dynamic>? ?? [];
    return items.map((e) => Share.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> revokeShare(String shareUuid) async {
    await dio.delete<Map<String, dynamic>>('/shares/$shareUuid');
  }
}
