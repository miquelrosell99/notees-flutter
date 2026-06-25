// ignore_for_file: use_null_aware_elements

import 'dart:io';

import 'package:dio/dio.dart';

class Asset {
  Asset({
    required this.uuid,
    required this.nodeUuid,
    required this.filename,
    required this.contentType,
    required this.category,
    required this.sizeBytes,
    required this.url,
  });

  final String uuid;
  final String nodeUuid;
  final String filename;
  final String contentType;
  final String category;
  final int sizeBytes;
  final String url;

  factory Asset.fromJson(Map<String, dynamic> json) => Asset(
        uuid: json['uuid'] as String,
        nodeUuid: json['node_uuid'] as String? ?? json['node_id'].toString(),
        filename: json['filename'] as String,
        contentType: json['content_type'] as String,
        category: json['category'] as String,
        sizeBytes: json['size_bytes'] as int,
        url: json['url'] as String,
      );
}

class AssetRepository {
  AssetRepository({required this.dio});

  final Dio dio;

  Future<Asset> uploadFile(
    File file, {
    String? parentUuid,
    String? existingNodeUuid,
    String? content,
  }) async {
    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(file.path),
      if (parentUuid != null) 'parent_uuid': parentUuid,
      if (existingNodeUuid != null) 'existing_node_uuid': existingNodeUuid,
      if (content != null) 'content': content,
    });
    final response = await dio.post<Map<String, dynamic>>(
      '/assets/upload',
      data: formData,
    );
    return Asset.fromJson(response.data!);
  }

  Future<List<Asset>> fetchAssets({int page = 1, int pageSize = 50}) async {
    final response = await dio.get<Map<String, dynamic>>(
      '/assets/',
      queryParameters: {'page': page, 'page_size': pageSize},
    );
    final data = response.data;
    if (data == null) return [];
    final items = (data['assets'] ?? data['items']) as List<dynamic>? ?? [];
    return items.map((e) => Asset.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Asset> fetchAssetInfo(String uuid) async {
    final response = await dio.get<Map<String, dynamic>>('/assets/$uuid/info');
    return Asset.fromJson(response.data!);
  }

  String assetUrl(String uuid) => '/assets/$uuid';

  Future<void> deleteAsset(String uuid) async {
    await dio.delete('/assets/$uuid');
  }
}
