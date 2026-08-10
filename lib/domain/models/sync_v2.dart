/// A single client operation sent to the sync server.
class OperationIntent {
  const OperationIntent({
    required this.type,
    required this.clientId,
    required this.seq,
    required this.nodeUuid,
    this.parentUuid,
    this.afterUuid,
    this.newIndex,
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
    this.completionId,
    this.completionStatus,
    this.completedAt,
    this.scheduledDate,
    this.deadlineDate,
    this.isPage = false,
    this.isTask = false,
    this.isDaily = false,
    this.isMonthly = false,
    this.isYearly = false,
    this.favoriteNodeUuids,
  });

  final String type;
  final String clientId;
  final int seq;
  final String nodeUuid;
  final String? parentUuid;
  final String? afterUuid;
  final int? newIndex;
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
  final String? completionId;
  final String? completionStatus;
  final String? completedAt;
  final String? scheduledDate;
  final String? deadlineDate;
  final bool isPage;
  final bool isTask;
  final bool isDaily;
  final bool isMonthly;
  final bool isYearly;
  final List<String>? favoriteNodeUuids;

  Map<String, dynamic> toJson() => {
        'type': type,
        'client_id': clientId,
        'seq': seq,
        'node_uuid': nodeUuid,
        if (parentUuid != null) 'parent_uuid': parentUuid,
        if (afterUuid != null) 'after_uuid': afterUuid,
        if (newIndex != null) 'new_index': newIndex,
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
        if (completionId != null) 'completion_id': completionId,
        if (completionStatus != null) 'completion_status': completionStatus,
        if (completedAt != null) 'completed_at': completedAt,
        if (scheduledDate != null) 'scheduled_date': scheduledDate,
        if (deadlineDate != null) 'deadline_date': deadlineDate,
        'is_page': isPage,
        'is_task': isTask,
        'is_daily': isDaily,
        'is_monthly': isMonthly,
        'is_yearly': isYearly,
        if (favoriteNodeUuids != null) 'favorite_node_uuids': favoriteNodeUuids,
      };

  factory OperationIntent.fromJson(Map<String, dynamic> json) => OperationIntent(
        type: json['type'] as String,
        clientId: json['client_id'] as String,
        seq: json['seq'] as int,
        nodeUuid: json['node_uuid'] as String,
        parentUuid: json['parent_uuid'] as String?,
        afterUuid: json['after_uuid'] as String?,
        newIndex: json['new_index'] as int?,
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
        completionId: json['completion_id'] as String?,
        completionStatus: json['completion_status'] as String?,
        completedAt: json['completed_at'] as String?,
        scheduledDate: json['scheduled_date'] as String?,
        deadlineDate: json['deadline_date'] as String?,
        isPage: json['is_page'] as bool? ?? false,
        isTask: json['is_task'] as bool? ?? false,
        isDaily: json['is_daily'] as bool? ?? false,
        isMonthly: json['is_monthly'] as bool? ?? false,
        isYearly: json['is_yearly'] as bool? ?? false,
        favoriteNodeUuids: json['favorite_node_uuids'] != null
            ? (json['favorite_node_uuids'] as List<dynamic>).cast<String>()
            : null,
      );
}
