/// Version vector for a single node: {client_id: seq}.
typedef VersionVector = Map<String, int>;

/// Base vector for a batch: {node_uuid: VersionVector}.
typedef BaseVector = Map<String, VersionVector>;

/// A single client operation sent to the sync server.
class OperationIntent {
  const OperationIntent({
    required this.type,
    required this.clientId,
    required this.seq,
    required this.nodeUuid,
    this.parentUuid,
    this.afterUuid,
    this.contentAst,
    this.name,
    this.classUuid,
    this.tagUuid,
    this.classUuids,
    this.tagUuids,
    this.isDeleted,
    this.properties,
    this.propertyUuid,
    this.propertyValue,
    this.isPage = false,
    this.isTask = false,
    this.isDaily = false,
    this.isMonthly = false,
    this.isYearly = false,
  });

  final String type;
  final String clientId;
  final int seq;
  final String nodeUuid;
  final String? parentUuid;
  final String? afterUuid;
  final List<Map<String, dynamic>>? contentAst;
  final String? name;
  final String? classUuid;
  final String? tagUuid;
  final List<String>? classUuids;
  final List<String>? tagUuids;
  final bool? isDeleted;
  final Map<String, dynamic>? properties;
  final String? propertyUuid;
  final dynamic propertyValue;
  final bool isPage;
  final bool isTask;
  final bool isDaily;
  final bool isMonthly;
  final bool isYearly;

  Map<String, dynamic> toJson() => {
        'type': type,
        'client_id': clientId,
        'seq': seq,
        'node_uuid': nodeUuid,
        if (parentUuid != null) 'parent_uuid': parentUuid,
        if (afterUuid != null) 'after_uuid': afterUuid,
        if (contentAst != null) 'content_ast': contentAst,
        if (name != null) 'name': name,
        if (classUuid != null) 'class_uuid': classUuid,
        if (tagUuid != null) 'tag_uuid': tagUuid,
        if (classUuids != null) 'class_uuids': classUuids,
        if (tagUuids != null) 'tag_uuids': tagUuids,
        if (isDeleted != null) 'is_deleted': isDeleted,
        if (properties != null) 'properties': properties,
        if (propertyUuid != null) 'property_uuid': propertyUuid,
        if (propertyValue != null) 'property_value': propertyValue,
        'is_page': isPage,
        'is_task': isTask,
        'is_daily': isDaily,
        'is_monthly': isMonthly,
        'is_yearly': isYearly,
      };

  factory OperationIntent.fromJson(Map<String, dynamic> json) => OperationIntent(
        type: json['type'] as String,
        clientId: json['client_id'] as String,
        seq: json['seq'] as int,
        nodeUuid: json['node_uuid'] as String,
        parentUuid: json['parent_uuid'] as String?,
        afterUuid: json['after_uuid'] as String?,
        contentAst: json['content_ast'] != null
            ? (json['content_ast'] as List<dynamic>)
                .cast<Map<String, dynamic>>()
            : null,
        name: json['name'] as String?,
        classUuid: json['class_uuid'] as String?,
        tagUuid: json['tag_uuid'] as String?,
        classUuids: json['class_uuids'] != null
            ? (json['class_uuids'] as List<dynamic>).cast<String>()
            : null,
        tagUuids: json['tag_uuids'] != null
            ? (json['tag_uuids'] as List<dynamic>).cast<String>()
            : null,
        isDeleted: json['is_deleted'] as bool?,
        properties: json['properties'] as Map<String, dynamic>?,
        propertyUuid: json['property_uuid'] as String?,
        propertyValue: json['property_value'],
        isPage: json['is_page'] as bool? ?? false,
        isTask: json['is_task'] as bool? ?? false,
        isDaily: json['is_daily'] as bool? ?? false,
        isMonthly: json['is_monthly'] as bool? ?? false,
        isYearly: json['is_yearly'] as bool? ?? false,
      );
}

/// Request body for POST /sync/batch.
class SyncBatchRequest {
  const SyncBatchRequest({
    required this.ops,
    required this.baseVector,
    this.workspaceUuid,
  });

  final List<OperationIntent> ops;
  final BaseVector baseVector;
  final String? workspaceUuid;

  Map<String, dynamic> toJson() => {
        'ops': ops.map((o) => o.toJson()).toList(),
        'base_vector': baseVector,
        if (workspaceUuid != null) 'workspace_uuid': workspaceUuid,
      };
}

/// Successful response from POST /sync/batch.
class SyncBatchResponse {
  const SyncBatchResponse({
    required this.applied,
    required this.newVectors,
  });

  final bool applied;
  final BaseVector newVectors;

  factory SyncBatchResponse.fromJson(Map<String, dynamic> json) =>
      SyncBatchResponse(
        applied: json['applied'] as bool,
        newVectors: (json['new_vectors'] as Map<String, dynamic>).map(
          (key, value) => MapEntry(
            key,
            (value as Map<String, dynamic>)
                .map((k, v) => MapEntry(k, v as int)),
          ),
        ),
      );
}

/// 409 conflict response from POST /sync/batch.
class SyncConflictResponse {
  const SyncConflictResponse({
    required this.staleNodes,
    required this.serverVectors,
    required this.conflictType,
  });

  final List<String> staleNodes;
  final BaseVector serverVectors;
  final String conflictType;

  factory SyncConflictResponse.fromJson(Map<String, dynamic> json) =>
      SyncConflictResponse(
        staleNodes: (json['stale_nodes'] as List<dynamic>).cast<String>(),
        serverVectors: (json['server_vectors'] as Map<String, dynamic>).map(
          (key, value) => MapEntry(
            key,
            (value as Map<String, dynamic>)
                .map((k, v) => MapEntry(k, v as int)),
          ),
        ),
        conflictType: json['conflict_type'] as String,
      );
}
