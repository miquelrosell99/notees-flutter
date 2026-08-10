import '../../core/constants/system.dart';
import '../../core/utils/ast_stringifier.dart';

class Node {
  Node({
    required this.id,
    required this.uuid,
    required this.name,
    required this.displayName,
    this.icon,
    this.color,
    this.parentId,
    this.parentUuid,
    this.pageId,
    this.pageUuid,
    this.sequence = 0.0,
    this.isPage = false,
    this.isTask = false,
    this.isDaily = false,
    this.isMonthly = false,
    this.isYearly = false,
    this.isTable = false,
    this.isAsset = false,
    this.isComment = false,
    this.isDeleted = false,
    this.isArchived = false,
    this.isPrivate = false,
    this.classes = const [],
    this.classesUuid = const [],
    this.tags = const [],
    this.tagsUuid = const [],
    this.properties = const {},
    this.children = const [],
    this.createDate,
    this.writeDate,
  });

  final int id;
  final String uuid;
  final String name;
  final String displayName;
  final String? icon;
  final String? color;
  final String? createDate;
  final String? writeDate;
  final int? parentId;
  final String? parentUuid;
  final int? pageId;
  final String? pageUuid;
  final double sequence;
  final bool isPage;
  final bool isTask;
  final bool isDaily;
  final bool isMonthly;
  final bool isYearly;
  final bool isTable;
  final bool isAsset;
  final bool isComment;
  final bool isDeleted;
  final bool isArchived;
  final bool isPrivate;
  final List<int> classes;
  final List<String> classesUuid;
  final List<int> tags;
  final List<String> tagsUuid;
  final Map<String, dynamic> properties;
  final List<Node> children;

  bool get isJournal => isDaily || isMonthly || isYearly;

  factory Node.fromJson(Map<String, dynamic> json) {
    final childrenJson = json['children'] as List<dynamic>?;
    final classesUuid = (json['classes_uuid'] as List<dynamic>?)?.cast<String>() ??
        (json['class_ids'] as List<dynamic>?)?.cast<String>() ??
        (json['class_uuids'] as List<dynamic>?)?.cast<String>() ??
        const [];
    final name = json['name'] as String? ?? '';

    // The backend uses both legacy mobile keys (is_daily/monthly/yearly) and
    // current server keys (is_day/month/year). Fall back to class UUIDs when
    // neither set of flags is present.
    final isDaily = (json['is_daily'] as bool? ?? false) ||
        (json['is_day'] as bool? ?? false) ||
        classesUuid.contains(SystemClassUuids.day);
    final isMonthly = (json['is_monthly'] as bool? ?? false) ||
        (json['is_month'] as bool? ?? false) ||
        classesUuid.contains(SystemClassUuids.month);
    final isYearly = (json['is_yearly'] as bool? ?? false) ||
        (json['is_year'] as bool? ?? false) ||
        classesUuid.contains(SystemClassUuids.year);

    // Some payloads use camelCase displayName; prefer display_name then fall
    // back to parsing the name AST/string.
    var displayName = (json['display_name'] as String?)?.trim() ??
        (json['displayName'] as String?)?.trim() ??
        '';
    if (displayName.isEmpty) {
      displayName = astToPlainText(name);
    }

    return Node(
      id: json['id'] as int? ?? 0,
      uuid: json['uuid'] as String,
      name: name,
      displayName: displayName,
      icon: json['icon'] as String?,
      color: json['color'] as String?,
      parentId: json['parent_id'] as int?,
      parentUuid: json['parent_uuid'] as String?,
      pageId: json['page_id'] as int?,
      pageUuid: json['page_uuid'] as String?,
      sequence: (json['sequence'] as num?)?.toDouble() ?? 0.0,
      isPage: json['is_page'] as bool? ?? false,
      isTask: json['is_task'] as bool? ?? false,
      isDaily: isDaily,
      isMonthly: isMonthly,
      isYearly: isYearly,
      isTable: json['is_table'] as bool? ?? false,
      isAsset: json['is_asset'] as bool? ?? false,
      isComment: json['is_comment'] as bool? ?? false,
      isDeleted: json['is_deleted'] as bool? ?? false,
      isArchived: json['is_archived'] as bool? ?? false,
      isPrivate: json['is_private'] as bool? ?? false,
      classes: (json['classes'] as List<dynamic>?)?.cast<int>() ?? const [],
      classesUuid: classesUuid,
      tags: (json['tags'] as List<dynamic>?)?.cast<int>() ?? const [],
      tagsUuid: (json['tags_uuid'] as List<dynamic>?)?.cast<String>() ??
          (json['tag_ids'] as List<dynamic>?)?.cast<String>() ??
          (json['tag_uuids'] as List<dynamic>?)?.cast<String>() ??
          const [],
      properties: (json['properties'] as Map<String, dynamic>?) ?? const {},
      children: childrenJson?.map((e) => Node.fromJson(e as Map<String, dynamic>)).toList() ?? const [],
      createDate: json['create_date'] as String?,
      writeDate: json['write_date'] as String?,
    );
  }

  /// Returns a copy of this node with [dueDate] added/updated in the task
  /// deadline system property. Used by the UI to reflect local edits before the
  /// server round-trip completes.
  Node copyWithDueDate(DateTime dueDate) {
    final formatted =
        '${dueDate.year.toString().padLeft(4, '0')}-${dueDate.month.toString().padLeft(2, '0')}-${dueDate.day.toString().padLeft(2, '0')}';
    final updatedProperties = Map<String, dynamic>.from(properties);
    updatedProperties[SystemPropertyUuids.taskDeadline] = formatted;
    return Node(
      id: id,
      uuid: uuid,
      name: name,
      displayName: displayName,
      icon: icon,
      color: color,
      parentId: parentId,
      parentUuid: parentUuid,
      pageId: pageId,
      pageUuid: pageUuid,
      sequence: sequence,
      isPage: isPage,
      isTask: isTask,
      isDaily: isDaily,
      isMonthly: isMonthly,
      isYearly: isYearly,
      isTable: isTable,
      isAsset: isAsset,
      isComment: isComment,
      isDeleted: isDeleted,
      isPrivate: isPrivate,
      classes: classes,
      classesUuid: classesUuid,
      tags: tags,
      tagsUuid: tagsUuid,
      properties: updatedProperties,
      children: children,
      createDate: createDate,
      writeDate: writeDate,
    );
  }

  /// Returns a copy of this node with [isArchived] updated.
  Node copyWithIsArchived(bool isArchived) {
    return Node(
      id: id,
      uuid: uuid,
      name: name,
      displayName: displayName,
      icon: icon,
      color: color,
      parentId: parentId,
      parentUuid: parentUuid,
      pageId: pageId,
      pageUuid: pageUuid,
      sequence: sequence,
      isPage: isPage,
      isTask: isTask,
      isDaily: isDaily,
      isMonthly: isMonthly,
      isYearly: isYearly,
      isTable: isTable,
      isAsset: isAsset,
      isComment: isComment,
      isDeleted: isDeleted,
      isArchived: isArchived,
      isPrivate: isPrivate,
      classes: classes,
      classesUuid: classesUuid,
      tags: tags,
      tagsUuid: tagsUuid,
      properties: properties,
      children: children,
      createDate: createDate,
      writeDate: writeDate,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'uuid': uuid,
        'name': name,
        'display_name': displayName,
        'icon': icon,
        'color': color,
        'parent_id': parentId,
        'parent_uuid': parentUuid,
        'page_id': pageId,
        'page_uuid': pageUuid,
        'sequence': sequence,
        'is_page': isPage,
        'is_task': isTask,
        'is_daily': isDaily,
        'is_monthly': isMonthly,
        'is_yearly': isYearly,
        'is_table': isTable,
        'is_asset': isAsset,
        'is_comment': isComment,
        'is_deleted': isDeleted,
        'is_archived': isArchived,
        'is_private': isPrivate,
        'classes': classes,
        'classes_uuid': classesUuid,
        'tags': tags,
        'tags_uuid': tagsUuid,
        'properties': properties,
        'children': children.map((e) => e.toJson()).toList(),
        'create_date': createDate,
        'write_date': writeDate,
      };
}
