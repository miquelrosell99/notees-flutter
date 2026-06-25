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
  final List<int> classes;
  final List<String> classesUuid;
  final List<int> tags;
  final List<String> tagsUuid;
  final Map<String, dynamic> properties;
  final List<Node> children;

  bool get isJournal => isDaily || isMonthly || isYearly;

  factory Node.fromJson(Map<String, dynamic> json) {
    final childrenJson = json['children'] as List<dynamic>?;
    return Node(
      id: json['id'] as int,
      uuid: json['uuid'] as String,
      name: json['name'] as String,
      displayName: json['display_name'] as String? ?? astToPlainText(json['name'] as String?),
      icon: json['icon'] as String?,
      color: json['color'] as String?,
      parentId: json['parent_id'] as int?,
      parentUuid: json['parent_uuid'] as String?,
      pageId: json['page_id'] as int?,
      pageUuid: json['page_uuid'] as String?,
      sequence: (json['sequence'] as num?)?.toDouble() ?? 0.0,
      isPage: json['is_page'] as bool? ?? false,
      isTask: json['is_task'] as bool? ?? false,
      isDaily: json['is_daily'] as bool? ?? false,
      isMonthly: json['is_monthly'] as bool? ?? false,
      isYearly: json['is_yearly'] as bool? ?? false,
      isTable: json['is_table'] as bool? ?? false,
      isAsset: json['is_asset'] as bool? ?? false,
      isComment: json['is_comment'] as bool? ?? false,
      classes: (json['classes'] as List<dynamic>?)?.cast<int>() ?? const [],
      classesUuid: (json['classes_uuid'] as List<dynamic>?)?.cast<String>() ?? const [],
      tags: (json['tags'] as List<dynamic>?)?.cast<int>() ?? const [],
      tagsUuid: (json['tags_uuid'] as List<dynamic>?)?.cast<String>() ?? const [],
      properties: (json['properties'] as Map<String, dynamic>?) ?? const {},
      children: childrenJson?.map((e) => Node.fromJson(e as Map<String, dynamic>)).toList() ?? const [],
      createDate: json['create_date'] as String?,
      writeDate: json['write_date'] as String?,
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
