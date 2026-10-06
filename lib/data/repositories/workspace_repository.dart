import 'package:dio/dio.dart';

/// One of the account's workspaces (the server's membership view).
class Workspace {
  Workspace({
    required this.uuid,
    this.name,
    this.role,
    this.createdAt,
    this.envelopeCount = 0,
    this.latestSeq = 0,
  });

  final String uuid;
  final String? name;
  final String? role;
  final DateTime? createdAt;
  final int envelopeCount;
  final int latestSeq;

  /// The server stores name|null; an unnamed workspace displays as
  /// "Workspace" (the web client's fallback label).
  String get displayName =>
      (name == null || name!.isEmpty) ? 'Workspace' : name!;

  /// Owner-only affordances (rename, delete) key off the membership role;
  /// the server 403s non-owners on those routes.
  bool get isOwner => role == 'owner';

  // Server entries: {id, name|null, role, createdAt, envelopeCount, latestSeq}.
  factory Workspace.fromJson(Map<String, dynamic> json) => Workspace(
        uuid: json['id'] as String,
        name: json['name'] as String?,
        role: json['role'] as String?,
        createdAt: json['createdAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
        envelopeCount: (json['envelopeCount'] as num?)?.toInt() ?? 0,
        latestSeq: (json['latestSeq'] as num?)?.toInt() ?? 0,
      );
}

class WorkspaceRepository {
  WorkspaceRepository({required this.dio});

  final Dio dio;

  Future<List<Workspace>> listWorkspaces() async {
    // The server answers { workspaces: [...] }.
    final response = await dio.get<Map<String, dynamic>>('/workspaces');
    final data = response.data;
    if (data == null) return [];
    final items = (data['workspaces'] as List<dynamic>?) ?? [];
    return items.map((e) => Workspace.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Creates a workspace; the creator becomes its owner. [name] is optional —
  /// the server accepts an unnamed workspace (the web client's create flow
  /// sends `{}` when the field is empty).
  Future<Workspace> createWorkspace({String? name}) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/workspaces',
      data: name == null ? const <String, dynamic>{} : {'name': name},
    );
    return Workspace.fromJson(response.data!);
  }

  /// Renames a workspace (PATCH /workspaces/:id; owner-only via membership —
  /// non-owners get a 403, non-members a 404).
  Future<Workspace> renameWorkspace(String uuid, String name) async {
    final response = await dio.patch<Map<String, dynamic>>(
      '/workspaces/$uuid',
      data: {'name': name},
    );
    return Workspace.fromJson(response.data!);
  }
}
