/// The condition-builder draft layer — a faithful Dart port of the web's
/// `apps/web/src/features/collection/filterQuery.ts`: the transient
/// filter state (quick text + a DRAFT root group the structured builder
/// edits), the draft → composed group prune, and the add-menu register
/// (the v2 FILTER_KIND_OPTIONS, 1:1 over the v2 AST — single-word types,
/// operators live in the row's operator column).
///
/// The draft may carry half-typed rows (a class condition with no class
/// picked yet, a content condition with a blank value);
/// [filterQueryToGroup] prunes those into the schema-valid composed root
/// evaluation consumes, returning null when nothing survives.
library;

import 'query_ast.dart';

// --- the draft state ---------------------------------------------------------

/// The bar's state: quick-search text plus the builder's draft root group.
/// The quick text never rides the structured root (it narrows rows through
/// the ranked search first — the web's one-ordering ruling); the mobile
/// builder keeps the field for register parity, the sheet drives on [group].
class FilterQuery {
  const FilterQuery({this.text, required this.group});

  final String? text;
  final Group group;
}

/// The inactive query — the resting state.
const FilterQuery emptyFilterQuery = FilterQuery(
  group: Group(logic: 'and', children: []),
);

/// The factory AST a fresh builder session starts from when the draft is
/// empty (the web's FACTORY_QUERY_AST).
const QueryAst factoryQueryAst = QueryAst(
  scope: EntireWorkspaceScope(),
  root: Group(logic: 'and', children: []),
);

/// The AST a commit writes: the composed draft verbatim, falling back to the
/// factory AST when the draft pruned to nothing (the unspecified state).
QueryAst draftOrFactoryAst(FilterQuery value) {
  final group = filterQueryToGroup(value);
  return group == null
      ? factoryQueryAst
      : QueryAst(scope: const EntireWorkspaceScope(), root: group);
}

/// True when the text is blank AND the draft group has no children.
bool isFilterInactive(FilterQuery query) =>
    (query.text?.trim() ?? '') == '' && query.group.children.isEmpty;

/// The trimmed quick-search text ("" when the facet is blank).
String quickTextOf(FilterQuery query) => query.text?.trim() ?? '';

// --- the draft → composed group prune ----------------------------------------

/// The member condition's prune: the set bits (exists / not-exists) are
/// always fully specified and survive; an ids target with an empty pick
/// drops (the half-typed row); a query target drops when its nested group
/// pruned to empty; the self target survives (the host resolves at run
/// time). The legacy `exact` op drops when its single id is blank.
MemberCondition? _pruneMember(MemberCondition child) {
  final op = child.op;
  if (op == 'exists' || op == 'not-exists') return child;
  final target = child.target!;
  if (op == 'exact') {
    return (target is IdsTarget && target.ids.isNotEmpty && target.ids.first == '')
        ? null
        : child;
  }
  if (target.mode == 'ids') {
    return (target as IdsTarget).ids.isEmpty ? null : child;
  }
  if (target.mode == 'self') return child;
  final nested = _pruneChild((target as QueryTarget).root);
  if (nested is! Group || nested.children.isEmpty) return null;
  return MemberCondition(
    family: child.family,
    op: op,
    target: QueryTarget(root: nested),
  );
}

/// Prune one draft child into its composed form: half-typed conditions drop
/// (content with a blank value, a member with an empty ids pick, property
/// with an empty schemaId or a range missing a bound, date comparisons with
/// a blank timestamp), nested groups recurse (emptied ones drop), a not
/// drops when its child pruned away. Anything fully specified — the set
/// bits, the self target, the node-field predicates, date within — survives
/// verbatim.
QueryAstNode? _pruneChild(QueryAstNode child) {
  if (child is Group) {
    final children = <QueryAstChild>[
      for (final nested in child.children) ? _pruneChild(nested),
    ];
    return children.isEmpty ? null : Group(logic: child.logic, children: children);
  }
  if (child is Not) {
    final pruned = _pruneChild(child.child);
    if (pruned == null) return null;
    final node = pruned;
    if (node is! Condition && node is! Group) return null;
    return Not(child: node);
  }
  switch (child) {
    case ContentCondition():
      return child.op != 'exists' && (child.value ?? '').trim() == ''
          ? null
          : child;
    case NameCondition():
      return child.op != 'exists' && (child.value ?? '').trim() == ''
          ? null
          : child;
    case MemberCondition():
      return _pruneMember(child);
    case PropertyCondition():
      if (child.schemaId == '') return null;
      if (child.op == 'between') {
        return child.from == null || child.to == null ? null : child;
      }
      return child;
    case DateCondition():
      if (child.op == 'between') {
        return (child.from ?? '').trim() == '' || (child.to ?? '').trim() == ''
            ? null
            : child;
      }
      if (child.op == 'within') return child;
      return (child.timestamp ?? '').trim() == '' ? null : child;
    default:
      // nodeField — always fully specified.
      return child;
  }
}

/// Compose the structured draft into the schema-valid root group evaluation
/// consumes, returning null when nothing survives (the hook treats null as
/// "no structured filter"). The quick-search text is deliberately absent.
Group? filterQueryToGroup(FilterQuery query) {
  final children = <QueryAstChild>[
    for (final child in query.group.children) ? _pruneChild(child),
  ];
  if (children.isEmpty) return null;
  return Group(logic: query.group.logic, children: children);
}

// --- the add-menu registry ---------------------------------------------------

/// The block FAMILIES (the v2 add-menu register as single-word types — the
/// operator column carries the is/is-not/contains/etc variation).
abstract final class ConditionKinds {
  static const class_ = 'class';
  static const type = 'type';
  static const placement = 'placement';
  static const content = 'content';
  static const property = 'property';
  static const tags = 'tags';
  static const links = 'links';
  static const referencePath = 'referencePath';
  static const parent = 'parent';
  static const child = 'child';
  static const childPath = 'childPath';
  static const page = 'page';
  static const parentPath = 'parentPath';
  static const root = 'root';
  static const cover = 'cover';
  static const banner = 'banner';
  static const alias = 'alias';
  static const created = 'created';
  static const edited = 'edited';

  /// The 20 condition families (the add-menu register minus the group
  /// constructors, the established order).
  static const all = [
    class_,
    type,
    placement,
    content,
    property,
    tags,
    links,
    referencePath,
    parent,
    child,
    childPath,
    page,
    parentPath,
    root,
    cover,
    banner,
    alias,
    created,
    edited,
  ];
}

/// One add-menu entry — a condition family or a group/not constructor.
abstract final class AddMenuKinds {
  static const groupAnd = 'group-and';
  static const groupOr = 'group-or';
  static const not = 'not';
}

/// One add-menu register entry (the web's FilterKindOption — the icon rides
/// the mdi name as data, the sheet maps it to a glyph or a fallback).
class FilterKindOption {
  const FilterKindOption({
    required this.value,
    required this.label,
    required this.icon,
    required this.description,
  });

  final String value;
  final String label;
  final String icon;
  final String description;
}

/// The add-menu register (the v2 FILTER_KIND_OPTIONS, 1:1 over the v2 AST).
/// Group constructors come last, the established order.
const List<FilterKindOption> filterKindOptions = [
  FilterKindOption(
    value: ConditionKinds.class_,
    label: 'Class',
    icon: 'mdi mdi-tag-outline',
    description: 'Filter by node class',
  ),
  FilterKindOption(
    value: ConditionKinds.type,
    label: 'Type',
    icon: 'mdi mdi-shape-outline',
    description: 'A class or not a class',
  ),
  FilterKindOption(
    value: ConditionKinds.placement,
    label: 'Structural role',
    icon: 'mdi mdi-format-align-left',
    description: 'Page (standalone) or Block (embedded in body)',
  ),
  FilterKindOption(
    value: ConditionKinds.content,
    label: 'Content',
    icon: 'mdi mdi-text-box-outline',
    description: 'Filter by text content',
  ),
  FilterKindOption(
    value: ConditionKinds.property,
    label: 'Property',
    icon: 'mdi mdi-code-braces',
    description: 'Filter by property value',
  ),
  FilterKindOption(
    value: ConditionKinds.tags,
    label: 'Tags',
    icon: 'mdi mdi-tag-multiple-outline',
    description: 'Filter by assigned tags (any page)',
  ),
  FilterKindOption(
    value: ConditionKinds.links,
    label: 'Links',
    icon: 'mdi mdi-link-variant',
    description: 'Nodes that link to a node',
  ),
  FilterKindOption(
    value: ConditionKinds.referencePath,
    label: 'Link path',
    icon: 'mdi mdi-link-plus',
    description:
        'The node or its ancestors reference these nodes — or the node sits inside them',
  ),
  FilterKindOption(
    value: ConditionKinds.parent,
    label: 'Parent',
    icon: 'mdi mdi-file-tree-outline',
    description: 'The direct parent is any of these nodes',
  ),
  FilterKindOption(
    value: ConditionKinds.child,
    label: 'Child',
    icon: 'mdi mdi-file-tree',
    description: 'Contains any of these nodes as direct children',
  ),
  FilterKindOption(
    value: ConditionKinds.childPath,
    label: 'Child path',
    icon: 'mdi mdi-arrow-decision-outline',
    description: 'Contains any of these nodes anywhere down their tree',
  ),
  FilterKindOption(
    value: ConditionKinds.page,
    label: 'Page',
    icon: 'mdi mdi-page-layout-body',
    description: 'The containing page is any of these nodes',
  ),
  FilterKindOption(
    value: ConditionKinds.parentPath,
    label: 'Parent path',
    icon: 'mdi mdi-source-branch',
    description: 'An ancestor anywhere up the parent chain is any of these nodes',
  ),
  FilterKindOption(
    value: ConditionKinds.root,
    label: 'Root',
    icon: 'mdi mdi-arrow-collapse-up',
    description: 'The top-level parent (workspace-root child) is any of these nodes',
  ),
  FilterKindOption(
    value: ConditionKinds.cover,
    label: 'Cover',
    icon: 'mdi mdi-image-outline',
    description: 'Cover is set or not',
  ),
  FilterKindOption(
    value: ConditionKinds.banner,
    label: 'Banner',
    icon: 'mdi mdi-page-layout-header',
    description: 'Banner is set or not',
  ),
  FilterKindOption(
    value: ConditionKinds.alias,
    label: 'Alias',
    icon: 'mdi mdi-repeat-variant',
    description: 'Alias of a main page, set or not',
  ),
  FilterKindOption(
    value: ConditionKinds.created,
    label: 'Created',
    icon: 'mdi mdi-calendar-arrow-right',
    description: 'Created after / before a date',
  ),
  FilterKindOption(
    value: ConditionKinds.edited,
    label: 'Edited',
    icon: 'mdi mdi-calendar-edit',
    description: 'Edited after / before a date',
  ),
  FilterKindOption(
    value: AddMenuKinds.groupAnd,
    label: 'All of (AND)',
    icon: 'mdi mdi-set-all',
    description: 'Match all nested conditions',
  ),
  FilterKindOption(
    value: AddMenuKinds.groupOr,
    label: 'Any of (OR)',
    icon: 'mdi mdi-set-center',
    description: 'Match any nested condition',
  ),
  FilterKindOption(
    value: AddMenuKinds.not,
    label: 'Exclude (NOT)',
    icon: 'mdi mdi-cancel',
    description: 'Exclude matching nodes',
  ),
];

/// The per-section facet configuration — every facet defaults on;
/// `filterable: true` is the full set. The facets gate which condition kinds
/// the builder's add menu offers (mobile: the sheet passes no config — the
/// full register is always offered).
class NodeCollectionToolbarConfig {
  const NodeCollectionToolbarConfig({
    this.text,
    this.class_,
    this.properties,
    this.dateRange,
  });

  final bool? text;
  final bool? class_;
  final bool? properties;
  final bool? dateRange;
}

/// The add-menu entries a config offers — the gated kinds plus the groups.
List<FilterKindOption> filterKindOptionsForConfig([
  NodeCollectionToolbarConfig? config,
]) {
  final showClass = config?.class_ ?? true;
  final showProperties = config?.properties ?? true;
  final showDateRange = config?.dateRange ?? true;
  return filterKindOptions
      .where((option) {
        if (option.value == ConditionKinds.class_) return showClass;
        if (option.value == ConditionKinds.property) return showProperties;
        if (option.value == ConditionKinds.created ||
            option.value == ConditionKinds.edited) {
          return showDateRange;
        }
        return true;
      })
      .toList(growable: false);
}

/// A fresh, half-typed condition per family — the block the menu appends.
Condition createCondition(String kind) {
  switch (kind) {
    case ConditionKinds.class_:
      // The default CLASS row rides the MULTI-VALUE membership register:
      // "Class contains Day, Week" — closure-aware ANY-of over the picked
      // list. Both bind the wire op "in" over an ids target.
      return MemberCondition(
        family: MemberFamilies.class_,
        op: 'in',
        target: const IdsTarget(ids: []),
      );
    case ConditionKinds.type:
      return const NodeFieldCondition(
        field: NodeFieldFields.isClass,
        op: 'eq',
        value: 'true',
      );
    case ConditionKinds.placement:
      return const NodeFieldCondition(
        field: NodeFieldFields.isEmbedded,
        op: 'eq',
        value: 'false',
      );
    case ConditionKinds.content:
      return const ContentCondition(op: ContentOps.contains, value: '');
    case ConditionKinds.property:
      // The half-typed row carries no schemaId yet — the prune drops it
      // until the schema pick lands (the wire requires a uuid).
      return const PropertyCondition(schemaId: '', op: 'eq', value: '');
    case ConditionKinds.tags:
    case ConditionKinds.links:
    case ConditionKinds.referencePath:
    case ConditionKinds.parent:
    case ConditionKinds.child:
    case ConditionKinds.childPath:
    case ConditionKinds.page:
    case ConditionKinds.parentPath:
    case ConditionKinds.root:
      // The node-target families bind the LIST by default (the Manual
      // target mode; the mode switch re-targets to a nested query or the
      // hosting page).
      return MemberCondition(family: kind, op: 'in', target: const IdsTarget(ids: []));
    case ConditionKinds.cover:
      return const NodeFieldCondition(
        field: NodeFieldFields.coverAsset,
        op: NodeFieldOps.exists,
      );
    case ConditionKinds.banner:
      return const NodeFieldCondition(
        field: NodeFieldFields.bannerAsset,
        op: NodeFieldOps.exists,
      );
    case ConditionKinds.alias:
      return const NodeFieldCondition(
        field: NodeFieldFields.aliasedNode,
        op: NodeFieldOps.exists,
      );
    case ConditionKinds.created:
      return const DateCondition(field: 'created', op: 'after', timestamp: '');
    case ConditionKinds.edited:
      return const DateCondition(field: 'updated', op: 'after', timestamp: '');
    default:
      throw ArgumentError.value(kind, 'kind', 'unknown condition kind');
  }
}
