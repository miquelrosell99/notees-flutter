/// v1 timestamp-based sync request (used by the mobile pull path).
class SyncRequest {
  const SyncRequest({
    this.lastSync,
    this.clientNodes = const [],
    this.workspaceUuid,
  });

  final DateTime? lastSync;
  final List<ClientNodeState> clientNodes;
  final String? workspaceUuid;

  Map<String, dynamic> toJson() => {
        if (lastSync != null) 'last_sync': lastSync!.toIso8601String(),
        'client_nodes': clientNodes.map((n) => n.toJson()).toList(),
        if (workspaceUuid != null) 'workspace_uuid': workspaceUuid,
      };
}

class ClientNodeState {
  const ClientNodeState({
    required this.uuid,
    required this.version,
    this.name,
    this.parentId,
    this.sequence,
    this.isDeleted = false,
  });

  final String uuid;
  final int version;
  final String? name;
  final String? parentId;
  final double? sequence;
  final bool isDeleted;

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'version': version,
        if (name != null) 'name': name,
        if (parentId != null) 'parent_id': parentId,
        if (sequence != null) 'sequence': sequence,
        'is_deleted': isDeleted,
      };
}

class ServerNodeState {
  const ServerNodeState({
    required this.uuid,
    required this.version,
    this.name,
    this.parentId,
    this.sequence,
    this.isDeleted = false,
    this.writeDate,
  });

  final String uuid;
  final int version;
  final String? name;
  final String? parentId;
  final double? sequence;
  final bool isDeleted;
  final String? writeDate;

  factory ServerNodeState.fromJson(Map<String, dynamic> json) => ServerNodeState(
        uuid: json['uuid'] as String,
        version: json['version'] as int,
        name: json['name'] as String?,
        parentId: json['parent_id'] as String?,
        sequence: (json['sequence'] as num?)?.toDouble(),
        isDeleted: json['is_deleted'] as bool? ?? false,
        writeDate: json['write_date'] as String?,
      );
}

class SyncResponse {
  const SyncResponse({
    required this.serverTime,
    this.serverNodes = const [],
    this.deletedNodeUuids = const [],
    this.conflicts = const [],
  });

  final String serverTime;
  final List<ServerNodeState> serverNodes;
  final List<String> deletedNodeUuids;
  final List<dynamic> conflicts;

  factory SyncResponse.fromJson(Map<String, dynamic> json) => SyncResponse(
        serverTime: json['server_time'] as String,
        serverNodes: ((json['server_nodes'] as List<dynamic>?) ?? [])
            .map((e) => ServerNodeState.fromJson(e as Map<String, dynamic>))
            .toList(),
        deletedNodeUuids: ((json['deleted_node_uuids'] as List<dynamic>?) ?? [])
            .cast<String>(),
        conflicts: (json['conflicts'] as List<dynamic>?) ?? const [],
      );
}
