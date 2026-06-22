class Node {
  Node({
    required this.id,
    required this.uuid,
    required this.name,
    this.icon,
    this.color,
    this.parentId,
    this.pageId,
    this.sequence = 0.0,
    this.isPage = false,
    this.isTask = false,
    this.isDaily = false,
    this.isMonthly = false,
    this.isYearly = false,
    this.classes = const [],
    this.tags = const [],
    this.properties = const {},
    this.children = const [],
  });

  final int id;
  final String uuid;
  final String name;
  final String? icon;
  final String? color;
  final int? parentId;
  final int? pageId;
  final double sequence;
  final bool isPage;
  final bool isTask;
  final bool isDaily;
  final bool isMonthly;
  final bool isYearly;
  final List<int> classes;
  final List<int> tags;
  final Map<String, dynamic> properties;
  final List<Node> children;

  bool get isJournal => isDaily || isMonthly || isYearly;

  factory Node.fromJson(Map<String, dynamic> json) {
    final childrenJson = json['children'] as List<dynamic>?;
    return Node(
      id: json['id'] as int,
      uuid: json['uuid'] as String,
      name: json['name'] as String,
      icon: json['icon'] as String?,
      color: json['color'] as String?,
      parentId: json['parent_id'] as int?,
      pageId: json['page_id'] as int?,
      sequence: (json['sequence'] as num?)?.toDouble() ?? 0.0,
      isPage: json['is_page'] as bool? ?? false,
      isTask: json['is_task'] as bool? ?? false,
      isDaily: json['is_daily'] as bool? ?? false,
      isMonthly: json['is_monthly'] as bool? ?? false,
      isYearly: json['is_yearly'] as bool? ?? false,
      classes: (json['classes'] as List<dynamic>?)?.cast<int>() ?? const [],
      tags: (json['tags'] as List<dynamic>?)?.cast<int>() ?? const [],
      properties: (json['properties'] as Map<String, dynamic>?) ?? const {},
      children: childrenJson?.map((e) => Node.fromJson(e as Map<String, dynamic>)).toList() ?? const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'uuid': uuid,
        'name': name,
        'icon': icon,
        'color': color,
        'parent_id': parentId,
        'page_id': pageId,
        'sequence': sequence,
        'is_page': isPage,
        'is_task': isTask,
        'is_daily': isDaily,
        'is_monthly': isMonthly,
        'is_yearly': isYearly,
        'classes': classes,
        'tags': tags,
        'properties': properties,
        'children': children.map((e) => e.toJson()).toList(),
      };
}
