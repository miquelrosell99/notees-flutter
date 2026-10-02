import 'package:dio/dio.dart';

class Workspace {
  Workspace({required this.uuid, required this.name, this.isActive = false});

  final String uuid;
  final String name;
  final bool isActive;

  // v2 server entries: {id, name|null, role, createdAt, envelopeCount, latestSeq}.
  factory Workspace.fromJson(Map<String, dynamic> json) => Workspace(
        uuid: json['id'] as String,
        name: json['name'] as String? ?? '',
        isActive: json['is_active'] as bool? ?? false,
      );
}

class WorkspaceRepository {
  WorkspaceRepository({required this.dio});

  final Dio dio;

  Future<List<Workspace>> listWorkspaces() async {
    // The v2 server answers { workspaces: [...] }.
    final response = await dio.get<Map<String, dynamic>>('/workspaces');
    final data = response.data;
    if (data == null) return [];
    final items = (data['workspaces'] as List<dynamic>?) ?? [];
    return items.map((e) => Workspace.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// The v2 server keeps no server-side active workspace — switching is
  /// persisted locally by the auth repository.
  Future<void> switchWorkspace(String uuid) async {}
}
