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
    this.extendsUuid = const [],
    this.title,
    this.position,
    this.isClass = false,
    this.presentAsMain,
    this.classOrder = const [],
    this.hlcPhysical = 0,
    this.hlcLogical = 0,
    this.actorId,
    this.coverAssetId,
    this.bannerAssetId,
    this.aliasedNodeId,
    this.description,
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

  /// For class-definition nodes: UUIDs of classes this class extends.
  final List<String> extendsUuid;

  /// Legacy scalar title slot, kept only so pre-title-is-content rows
  /// still render. The relay protocol has no object `name` field (title-is-
  /// content, 2026-10-01): appliers never set this from relay payloads; the
  /// display name derives from the content AST stored in [name].
  final String? title;

  /// Lexicographic fractional sibling position (the `node_child_order`
  /// equivalent); null for legacy rows that only have [sequence].
  final String? position;

  /// Revision-11 render-state model: [isClass] is the ONLY identity marker
  /// — classes are always roots (`CHECK (is_class = 0 OR parent_id IS NULL)`)
  /// and may have non-class children. A class renders from class_cache; the
  /// editor never sees class rows in node_cache.
  final bool isClass;

  /// Render bit, read only by the third cascade branch: `is_class` → Class
  /// view; parentless → document chrome (bit unread); else the bit → the
  /// parent's main-children zone + document chrome when zoomed (true), or
  /// inline body + block chrome (false). Null only for legacy rows that
  /// predate the v20 column.
  final bool? presentAsMain;

  /// User-defined class ORDER (class.reorder, LWW-by-arrival); the effective
  /// classes_uuid = ordered members first, then unlisted members sorted by
  /// id (store schema v7 `node.class_order` parity).
  final List<String> classOrder;

  /// Row-LWW winner for object.update/object.move: an incoming write whose
  /// (hlc, actor) does not beat these values is dropped.
  final int hlcPhysical;
  final int hlcLogical;
  final String? actorId;

  /// Wire node fields (the icon/color precedent, 2026-10-07 lockstep):
  /// an asset node for the page cover, an asset node for the page banner,
  /// and the main page this node aliases at (many-to-one FROM the alias).
  /// [description] (2026-10-09 lockstep) is the page subtitle in the core
  /// page chrome (the Capacities header precedent, plain text max 512).
  /// `object.update` only — `object.create` carries none. Derived columns
  /// (`cover_asset_id` / `banner_asset_id` / `aliased_node_id` /
  /// `description`) project them for SQL reads; the payload JSON is the
  /// read authority.
  final String? coverAssetId;
  final String? bannerAssetId;
  final String? aliasedNodeId;
  final String? description;

  bool get isJournal => isDaily || isMonthly || isYearly;

  factory Node.fromJson(Map<String, dynamic> json) {
    final childrenJson = json['children'] as List<dynamic>?;
    final classesUuid =
        (json['classes_uuid'] as List<dynamic>?)?.cast<String>() ??
        (json['class_ids'] as List<dynamic>?)?.cast<String>() ??
        (json['class_uuids'] as List<dynamic>?)?.cast<String>() ??
        const [];
    final name = json['name'] as String? ?? '';

    // The backend uses both legacy mobile keys (is_daily/monthly/yearly) and
    // current server keys (is_day/month/year). Fall back to class UUIDs when
    // neither set of flags is present.
    final isDaily =
        (json['is_daily'] as bool? ?? false) ||
        (json['is_day'] as bool? ?? false) ||
        classesUuid.contains(SystemClassUuids.day);
    final isMonthly =
        (json['is_monthly'] as bool? ?? false) ||
        (json['is_month'] as bool? ?? false) ||
        classesUuid.contains(SystemClassUuids.month);
    final isYearly =
        (json['is_yearly'] as bool? ?? false) ||
        (json['is_year'] as bool? ?? false) ||
        classesUuid.contains(SystemClassUuids.year);

    // Display resolution: an explicit display_name (set by local optimistic
    // writes) wins; then the scalar title; finally the content plain text.
    final title = json['title'] as String?;
    var displayName =
        (json['display_name'] as String?)?.trim() ??
        (json['displayName'] as String?)?.trim() ??
        '';
    if (displayName.isEmpty) {
      displayName = title?.trim().isNotEmpty == true
          ? title!.trim()
          : astToPlainText(name);
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
      tagsUuid:
          (json['tags_uuid'] as List<dynamic>?)?.cast<String>() ??
          (json['tag_ids'] as List<dynamic>?)?.cast<String>() ??
          (json['tag_uuids'] as List<dynamic>?)?.cast<String>() ??
          const [],
      properties: (json['properties'] as Map<String, dynamic>?) ?? const {},
      children:
          childrenJson
              ?.map((e) => Node.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      createDate: json['create_date'] as String?,
      writeDate: json['write_date'] as String?,
      extendsUuid:
          (json['extends_uuid'] as List<dynamic>?)?.cast<String>() ??
          (json['extends'] as List<dynamic>?)?.cast<String>() ??
          const [],
      title: title,
      position: json['position'] as String?,
      isClass: json['is_class'] as bool? ?? false,
      presentAsMain: json['present_as_main'] as bool?,
      classOrder:
          (json['class_order'] as List<dynamic>?)?.cast<String>() ??
          const [],
      hlcPhysical: (json['hlc_physical'] as num?)?.toInt() ?? 0,
      hlcLogical: (json['hlc_logical'] as num?)?.toInt() ?? 0,
      actorId: json['actor_id'] as String?,
      coverAssetId: json['cover_asset_id'] as String?,
      bannerAssetId: json['banner_asset_id'] as String?,
      aliasedNodeId: json['aliased_node_id'] as String?,
      description: json['description'] as String?,
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
      extendsUuid: extendsUuid,
      title: title,
      position: position,
      isClass: isClass,
      presentAsMain: presentAsMain,
      classOrder: classOrder,
      hlcPhysical: hlcPhysical,
      hlcLogical: hlcLogical,
      actorId: actorId,
      coverAssetId: coverAssetId,
      bannerAssetId: bannerAssetId,
      aliasedNodeId: aliasedNodeId,
      description: description,
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
      extendsUuid: extendsUuid,
      title: title,
      position: position,
      isClass: isClass,
      presentAsMain: presentAsMain,
      classOrder: classOrder,
      hlcPhysical: hlcPhysical,
      hlcLogical: hlcLogical,
      actorId: actorId,
      coverAssetId: coverAssetId,
      bannerAssetId: bannerAssetId,
      aliasedNodeId: aliasedNodeId,
      description: description,
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
    'extends_uuid': extendsUuid,
    'title': title,
    'position': position,
    'is_class': isClass,
    'present_as_main': presentAsMain,
    'class_order': classOrder,
    'hlc_physical': hlcPhysical,
    'hlc_logical': hlcLogical,
    'actor_id': actorId,
    'cover_asset_id': coverAssetId,
    'banner_asset_id': bannerAssetId,
    'aliased_node_id': aliasedNodeId,
    'description': description,
  };
}
