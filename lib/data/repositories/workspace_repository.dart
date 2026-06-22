import 'package:dio/dio.dart';

class Workspace {
  Workspace({required this.uuid, required this.name, this.isActive = false});

  final String uuid;
  final String name;
  final bool isActive;

  factory Workspace.fromJson(Map<String, dynamic> json) => Workspace(
        uuid: json['uuid'] as String,
        name: json['name'] as String,
        isActive: json['is_active'] as bool? ?? false,
      );
}

class WorkspaceRepository {
  WorkspaceRepository({required this.dio});

  final Dio dio;

  Future<List<Workspace>> listWorkspaces() async {
    final response = await dio.get<Map<String, dynamic>>('/workspaces');
    final data = response.data;
    if (data == null) return [];
    final items = (data['items'] as List<dynamic>?) ?? [];
    return items.map((e) => Workspace.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> switchWorkspace(String uuid) async {
    await dio.post('/workspaces/$uuid/switch');
  }
}
