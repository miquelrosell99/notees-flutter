/// QueryAST v2 — the canonical, serializable query model for Notees,
/// a strict Dart port of `packages/protocol/src/query-ast.ts` (zod
/// `.strict()` parity: every unknown key, type, enum value, or version
/// fails loud — there is NO v1 parse path).
///
/// The model folds the v1 flat union of 64 condition types into SIX types
/// with orthogonal axes: `member` carries family × op × target mode;
/// `content`/`name` are the plaintext conditions; `property` folds the
/// range/period ops; `date` folds the created-/updated- families behind an
/// explicit field axis; `nodeField` folds the Revision-12 booleans and the
/// asset/alias wire predicates.
library;

/// Standard UUID shape (`z.string().uuid()` in the zod schemas).
final RegExp _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// Throws when [value] is not a UUID string.
void _requireUuid(Object? value, String what) {
  if (value is! String || !_uuidPattern.hasMatch(value)) {
    throw FormatException('query AST: $what must be a uuid', value);
  }
}

/// A decoded JSON object with EXACTLY [allowed] keys (zod `.strict()`).
Map<String, dynamic> _strictMap(
  Object? input,
  Set<String> allowed,
  String what,
) {
  if (input is! Map) {
    throw FormatException('query AST: $what must be an object', input);
  }
  final map = Map<String, dynamic>.from(input);
  for (final key in map.keys) {
    if (!allowed.contains(key)) {
      throw FormatException('query AST: unknown key "$key" on $what', key);
    }
  }
  return map;
}

/// The strict string-enum read (zod `z.enum`).
String _enum(Object? value, List<String> allowed, String what) {
  if (value is String && allowed.contains(value)) return value;
  throw FormatException(
    'query AST: $what must be one of ${allowed.map((e) => '"$e"').join(' | ')}',
    value,
  );
}

/// The optional string-enum read.
String? _enumOrNull(Object? value, List<String> allowed, String what) {
  if (value == null) return null;
  return _enum(value, allowed, what);
}

/// An optional `z.string().min(1)` read.
String? _minStringOrNull(Object? value, String what) {
  if (value == null) return null;
  if (value is! String || value.isEmpty) {
    throw FormatException('query AST: $what must be a non-empty string', value);
  }
  return value;
}

// --- scope ----------------------------------------------------------------

/// The query scope — the candidate node set the conditions filter.
sealed class Scope {
  const Scope();

  String get type;

  Map<String, dynamic> toJson();

  factory Scope.fromJson(Object? input) {
    final type = input is Map ? input['type'] : null;
    switch (type) {
      case 'entire_workspace':
        _strictMap(input, const {'type'}, 'entire_workspace scope');
        return const EntireWorkspaceScope();
      case 'pages':
        _strictMap(input, const {'type'}, 'pages scope');
        return const PagesScope();
      case 'subtree':
        final map = _strictMap(input, const {'type', 'pageId'}, 'subtree scope');
        _requireUuid(map['pageId'], 'subtree scope pageId');
        return SubtreeScope(pageId: map['pageId'] as String);
      case 'linkedTo':
        final map = _strictMap(input, const {'type', 'nodeId'}, 'linkedTo scope');
        _requireUuid(map['nodeId'], 'linkedTo scope nodeId');
        return LinkedToScope(nodeId: map['nodeId'] as String);
      default:
        throw FormatException(
          'query AST: unknown scope type (expected entire_workspace | pages | '
          'subtree | linkedTo)',
          type,
        );
    }
  }
}

/// Every node in the workspace.
final class EntireWorkspaceScope extends Scope {
  const EntireWorkspaceScope();

  @override
  final String type = 'entire_workspace';

  @override
  Map<String, dynamic> toJson() => const {'type': 'entire_workspace'};
}

/// Only nodes rendering with document chrome (the Page role).
final class PagesScope extends Scope {
  const PagesScope();

  @override
  final String type = 'pages';

  @override
  Map<String, dynamic> toJson() => const {'type': 'pages'};
}

/// The page plus every node under it (recursive parent walk).
final class SubtreeScope extends Scope {
  const SubtreeScope({required this.pageId});

  @override
  final String type = 'subtree';
  final String pageId;

  @override
  Map<String, dynamic> toJson() => {'type': 'subtree', 'pageId': pageId};
}

/// Roll-up membership: backlinksWithRollup semantics (direct + containment).
final class LinkedToScope extends Scope {
  const LinkedToScope({required this.nodeId});

  @override
  final String type = 'linkedTo';
  final String nodeId;

  @override
  Map<String, dynamic> toJson() => {'type': 'linkedTo', 'nodeId': nodeId};
}

// --- target reference ------------------------------------------------------

/// The target mode axis of every `member` membership op: `ids` a manual
/// pick, `query` a nested group (a saved view re-resolves on every run),
/// `self` the hosting page (resolved at compile time against
/// `CompileOptions.selfNodeId` — a compile without it fails loud).
sealed class TargetRef {
  const TargetRef();

  String get mode;

  Map<String, dynamic> toJson();

  factory TargetRef.fromJson(Object? input) {
    final mode = input is Map ? input['mode'] : null;
    switch (mode) {
      case 'ids':
        final map = _strictMap(input, const {'mode', 'ids'}, 'ids target');
        final rawIds = map['ids'];
        if (rawIds is! List || rawIds.isEmpty) {
          throw FormatException(
            'query AST: ids target requires a non-empty ids list',
            rawIds,
          );
        }
        final ids = <String>[];
        for (final id in rawIds) {
          _requireUuid(id, 'ids target id');
          ids.add(id as String);
        }
        return IdsTarget(ids: ids);
      case 'query':
        final map = _strictMap(input, const {'mode', 'root'}, 'query target');
        return QueryTarget(root: Group.fromJson(map['root']));
      case 'self':
        _strictMap(input, const {'mode'}, 'self target');
        return const SelfTarget();
      default:
        throw FormatException(
          'query AST: unknown target mode (expected ids | query | self)',
          mode,
        );
    }
  }
}

final class IdsTarget extends TargetRef {
  const IdsTarget({required this.ids});

  @override
  final String mode = 'ids';
  final List<String> ids;

  @override
  Map<String, dynamic> toJson() => {'mode': 'ids', 'ids': ids};
}

final class QueryTarget extends TargetRef {
  const QueryTarget({required this.root});

  @override
  final String mode = 'query';
  final Group root;

  @override
  Map<String, dynamic> toJson() => {'mode': 'query', 'root': root.toJson()};
}

final class SelfTarget extends TargetRef {
  const SelfTarget();

  @override
  final String mode = 'self';

  @override
  Map<String, dynamic> toJson() => const {'mode': 'self'};
}

// --- group / not -----------------------------------------------------------

/// A query group: `logic` combining `children` (conditions, nested groups,
/// or `not` wrappers).
final class Group implements QueryAstNode {
  const Group({required this.logic, required this.children});

  static const logics = ['and', 'or'];

  final String logic;
  final List<QueryAstChild> children;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'group',
        'logic': logic,
        'children': [for (final child in children) child.toJson()],
      };

  factory Group.fromJson(Object? input) {
    final map = _strictMap(
      input,
      const {'type', 'logic', 'children'},
      'group',
    );
    if (map['type'] != 'group') {
      throw FormatException('query AST: group type must be "group"', map['type']);
    }
    final logic = _enum(map['logic'], logics, 'group logic');
    final rawChildren = map['children'];
    if (rawChildren is! List) {
      throw FormatException('query AST: group children must be a list', rawChildren);
    }
    return Group(
      logic: logic,
      children: [
        for (final child in rawChildren) QueryAstChild.fromJson(child),
      ],
    );
  }
}

/// A `not` wrapper around a condition or a group.
final class Not implements QueryAstNode {
  const Not({required this.child});

  final QueryAstNode child;

  @override
  Map<String, dynamic> toJson() => {'type': 'not', 'child': child.toJson()};

  factory Not.fromJson(Object? input) {
    final map = _strictMap(input, const {'type', 'child'}, 'not');
    if (map['type'] != 'not') {
      throw FormatException('query AST: not type must be "not"', map['type']);
    }
    final child = map['child'];
    final node = QueryAstChild.fromJson(child);
    if (node is! Condition && node is! Group) {
      throw FormatException(
        'query AST: not child must be a condition or a group',
        child,
      );
    }
    return Not(child: node);
  }
}

/// Any node in the recursive AST tree below the root.
sealed class QueryAstNode {
  Map<String, dynamic> toJson();

  /// A condition or group (the wire `Child` union — `not` only nests one
  /// level, by grammar).
  factory QueryAstNode.fromJson(Object? input) {
    final type = input is Map ? input['type'] : null;
    if (type == 'group') return Group.fromJson(input);
    if (type == 'not') return Not.fromJson(input);
    return Condition.fromJson(input);
  }
}

/// The wire `Child` union member: a condition, a group, or a `not` wrapper.
typedef QueryAstChild = QueryAstNode;

// --- conditions --------------------------------------------------------------

/// The node-target families — what reference of the node the `member`
/// condition tests (the family ↔ semantics table is the compiler's
/// contract, normative copy in `packages/query/README.md`).
abstract final class MemberFamilies {
  static const class_ = 'class';
  static const tags = 'tags';
  static const links = 'links';
  static const referencePath = 'referencePath';
  static const parent = 'parent';
  static const child = 'child';
  static const childPath = 'childPath';
  static const page = 'page';
  static const parentPath = 'parentPath';
  static const root = 'root';

  static const all = [
    class_,
    tags,
    links,
    referencePath,
    parent,
    child,
    childPath,
    page,
    parentPath,
    root,
  ];
}

/// A condition of the query: one of the six v2 types. The union dispatch
/// (the three `member` sub-shapes share the `type` value, so it is a plain
/// switch like the zod union) lives in [parseQueryAstCondition].
sealed class Condition implements QueryAstNode {
  const Condition();

  /// The wire discriminator (`member` | `content` | `name` | `property` |
  /// `date` | `nodeField`) — every concrete condition carries it.
  String get type;

  factory Condition.fromJson(Object? input) => parseQueryAstCondition(input);
}

/// Parses any condition shape (the sealed factory's dispatch).
Condition parseQueryAstCondition(Object? input) {
  final type = input is Map ? input['type'] : null;
  switch (type) {
    case 'member':
      return MemberCondition.fromJson(input);
    case 'content':
      return ContentCondition.fromJson(input);
    case 'name':
      return NameCondition.fromJson(input);
    case 'property':
      return PropertyCondition.fromJson(input);
    case 'date':
      return DateCondition.fromJson(input);
    case 'nodeField':
      return NodeFieldCondition.fromJson(input);
    default:
      throw FormatException(
        'query AST: unknown condition type (expected member | content | '
        'name | property | date | nodeField)',
        type,
      );
  }
}

/// The `member` condition — family × op × target mode. `in`/`not-in` carry
/// a REQUIRED target; `exists`/`not-exists` forbid one (the family's
/// emptiness read); `exact` pins `family == "class"` and a single-id list.
final class MemberCondition extends Condition {
  const MemberCondition._({
    required this.family,
    required this.op,
    this.target,
  });

  factory MemberCondition({
    required String family,
    required String op,
    required TargetRef target,
  }) {
    _enum(family, MemberFamilies.all, 'member family');
    if (op == 'exact') {
      if (family != MemberFamilies.class_ ||
          target is! IdsTarget ||
          target.ids.length != 1) {
        throw ArgumentError.value(
          op,
          'op',
          "query AST: 'exact' pins family 'class' and a single-id target",
        );
      }
      return MemberCondition._(family: family, op: op, target: target);
    }
    if (op != 'in' && op != 'not-in') {
      throw ArgumentError.value(
        op,
        'op',
        "query AST: member with a target supports only 'in' | 'not-in' | "
            "'exact'",
      );
    }
    return MemberCondition._(family: family, op: op, target: target);
  }

  factory MemberCondition.exists({
    required String family,
    required String op,
  }) {
    _enum(family, MemberFamilies.all, 'member family');
    if (op != 'exists' && op != 'not-exists') {
      throw ArgumentError.value(
        op,
        'op',
        "query AST: member without a target supports only 'exists' | "
            "'not-exists'",
      );
    }
    return MemberCondition._(family: family, op: op);
  }

  @override
  final String type = 'member';
  final String family;
  final String op;
  final TargetRef? target;

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'family': family,
        'op': op,
        if (target != null) 'target': target!.toJson(),
      };

  factory MemberCondition.fromJson(Object? input) {
    final map = _strictMap(input, const {'type', 'family', 'op', 'target'}, 'member');
    if (map['type'] != 'member') {
      throw FormatException('query AST: member type must be "member"', map['type']);
    }
    final family = _enum(map['family'], MemberFamilies.all, 'member family');
    final op = map['op'];
    if (op == 'in' || op == 'not-in') {
      final rawTarget = map['target'];
      if (rawTarget == null) {
        throw FormatException(
          "query AST: member op '$op' requires a target",
          input,
        );
      }
      return MemberCondition(
        family: family,
        op: op,
        target: TargetRef.fromJson(rawTarget),
      );
    }
    if (op == 'exists' || op == 'not-exists') {
      if (map.containsKey('target')) {
        throw FormatException(
          "query AST: member op '$op' forbids a target",
          input,
        );
      }
      return MemberCondition.exists(family: family, op: op);
    }
    if (op == 'exact') {
      final rawTarget = map['target'];
      if (rawTarget == null) {
        throw FormatException("query AST: member op 'exact' requires a target", input);
      }
      final target = TargetRef.fromJson(rawTarget);
      if (family != MemberFamilies.class_ ||
          target is! IdsTarget ||
          target.ids.length != 1) {
        throw FormatException(
          "query AST: 'exact' pins family 'class' and a single-id target",
          input,
        );
      }
      return MemberCondition._(family: family, op: op, target: target);
    }
    throw FormatException(
      "query AST: unknown member op (expected in | not-in | exists | "
      'not-exists | exact)',
      op,
    );
  }
}

/// The plaintext condition operators.
abstract final class ContentOps {
  static const contains = 'contains';
  static const fts = 'fts';
  static const eq = 'eq';
  static const neq = 'neq';
  static const starts = 'starts';
  static const ends = 'ends';
  static const exists = 'exists';
  static const all = [contains, fts, eq, neq, starts, ends, exists];
}

/// The plaintext condition over the derived search text (the same text the
/// FTS index holds): LIKE substring / FTS prefix-AND MATCH / full-text
/// equality / anchored LIKEs / the non-empty probe.
final class ContentCondition extends Condition {
  const ContentCondition({required this.op, this.value});

  @override
  final String type = 'content';
  final String op;
  final String? value;

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'op': op,
        if (value != null) 'value': value,
      };

  factory ContentCondition.fromJson(Object? input) {
    final map = _strictMap(input, const {'type', 'op', 'value'}, 'content');
    if (map['type'] != 'content') {
      throw FormatException('query AST: content type must be "content"', map['type']);
    }
    return ContentCondition(
      op: _enum(map['op'], ContentOps.all, 'content op'),
      value: _minStringOrNull(map['value'], 'content value'),
    );
  }
}

/// The title-condition operators (title-is-content: the flattened content
/// text is the name).
abstract final class NameOps {
  static const eq = 'eq';
  static const neq = 'neq';
  static const contains = 'contains';
  static const exists = 'exists';
  static const all = [eq, neq, contains, exists];
}

/// The title (name) condition: LIKE substring (ASCII case-insensitive),
/// exact BINARY eq/neq, the non-empty probe.
final class NameCondition extends Condition {
  const NameCondition({required this.op, this.value});

  @override
  final String type = 'name';
  final String op;
  final String? value;

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'op': op,
        if (value != null) 'value': value,
      };

  factory NameCondition.fromJson(Object? input) {
    final map = _strictMap(input, const {'type', 'op', 'value'}, 'name');
    if (map['type'] != 'name') {
      throw FormatException('query AST: name type must be "name"', map['type']);
    }
    return NameCondition(
      op: _enum(map['op'], NameOps.all, 'name op'),
      value: _minStringOrNull(map['value'], 'name value'),
    );
  }
}

/// The property-condition operators (eq/neq/contains/exists plus the
/// GREATER_THAN/LESS_THAN family and the folded between/within).
abstract final class PropertyOps {
  static const eq = 'eq';
  static const neq = 'neq';
  static const contains = 'contains';
  static const exists = 'exists';
  static const gt = 'gt';
  static const gte = 'gte';
  static const lt = 'lt';
  static const lte = 'lte';
  static const between = 'between';
  static const within = 'within';
  static const all = [eq, neq, contains, exists, gt, gte, lt, lte, between, within];
}

/// The relative periods ("is within today / this week / this month / this
/// year").
abstract final class DatePeriods {
  static const today = 'today';
  static const thisWeek = 'this_week';
  static const thisMonth = 'this_month';
  static const thisYear = 'this_year';
  static const all = [today, thisWeek, thisMonth, thisYear];
}

/// The `property` condition — the effective-values read model (authored
/// rows plus class-binding defaults, first-class-applied-wins) unless
/// [includeDefaults] is false.
final class PropertyCondition extends Condition {
  const PropertyCondition({
    required this.schemaId,
    required this.op,
    this.value,
    this.from,
    this.to,
    this.period,
    this.includeDefaults,
  });

  @override
  final String type = 'property';
  final String schemaId;
  final String op;

  /// The comparison value (eq/neq/contains/gt/gte/lt/lte).
  final Object? value;

  /// The inclusive range lower bound (op `between`).
  final Object? from;

  /// The inclusive range upper bound (op `between`).
  final Object? to;

  /// The relative period (op `within`).
  final String? period;

  /// Read through the effective-values read model (default true); pass
  /// false to test authored property_value rows only.
  final bool? includeDefaults;

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'schemaId': schemaId,
        'op': op,
        if (value != null) 'value': value,
        if (from != null) 'from': from,
        if (to != null) 'to': to,
        if (period != null) 'period': period,
        if (includeDefaults != null) 'includeDefaults': includeDefaults,
      };

  factory PropertyCondition.fromJson(Object? input) {
    final map = _strictMap(
      input,
      const {'type', 'schemaId', 'op', 'value', 'from', 'to', 'period', 'includeDefaults'},
      'property',
    );
    if (map['type'] != 'property') {
      throw FormatException('query AST: property type must be "property"', map['type']);
    }
    _requireUuid(map['schemaId'], 'property schemaId');
    final includeDefaults = map['includeDefaults'];
    if (includeDefaults != null && includeDefaults is! bool) {
      throw FormatException(
        'query AST: property includeDefaults must be a boolean',
        includeDefaults,
      );
    }
    return PropertyCondition(
      schemaId: map['schemaId'] as String,
      op: _enum(map['op'], PropertyOps.all, 'property op'),
      value: map['value'],
      from: map['from'],
      to: map['to'],
      period: _enumOrNull(map['period'], DatePeriods.all, 'property period'),
      includeDefaults: includeDefaults,
    );
  }
}

/// The base date-comparison ops (eq/neq are DAY-granular; gt/gte/lt/lte
/// compare against the resolved instant).
abstract final class DateOps {
  static const eq = 'eq';
  static const neq = 'neq';
  static const gt = 'gt';
  static const gte = 'gte';
  static const lt = 'lt';
  static const lte = 'lte';
  static const after = 'after';
  static const before = 'before';
  static const between = 'between';
  static const within = 'within';
  static const all = [eq, neq, gt, gte, lt, lte, after, before, between, within];
}

/// The `date` condition — the v1 created-/updated- ten types folded behind
/// an explicit field axis.
final class DateCondition extends Condition {
  const DateCondition({
    required this.field,
    required this.op,
    this.timestamp,
    this.from,
    this.to,
    this.period,
  });

  @override
  final String type = 'date';
  final String field;
  final String op;
  final String? timestamp;
  final String? from;
  final String? to;
  final String? period;

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'field': field,
        'op': op,
        if (timestamp != null) 'timestamp': timestamp,
        if (from != null) 'from': from,
        if (to != null) 'to': to,
        if (period != null) 'period': period,
      };

  factory DateCondition.fromJson(Object? input) {
    final map = _strictMap(
      input,
      const {'type', 'field', 'op', 'timestamp', 'from', 'to', 'period'},
      'date',
    );
    if (map['type'] != 'date') {
      throw FormatException('query AST: date type must be "date"', map['type']);
    }
    return DateCondition(
      field: _enum(map['field'], const ['created', 'updated'], 'date field'),
      op: _enum(map['op'], DateOps.all, 'date op'),
      timestamp: _minStringOrNull(map['timestamp'], 'date timestamp'),
      from: _minStringOrNull(map['from'], 'date from'),
      to: _minStringOrNull(map['to'], 'date to'),
      period: _enumOrNull(map['period'], DatePeriods.all, 'date period'),
    );
  }
}

/// The node wire-field condition fields (the Revision-12 booleans ride
/// op `eq` with value "true"/"false"; the asset/alias references keep
/// eq/neq/exists).
abstract final class NodeFieldFields {
  static const coverAsset = 'coverAsset';
  static const bannerAsset = 'bannerAsset';
  static const aliasedNode = 'aliasedNode';
  static const isClass = 'isClass';
  static const isEmbedded = 'isEmbedded';
  static const all = [coverAsset, bannerAsset, aliasedNode, isClass, isEmbedded];
}

/// The node wire-field predicate operators.
abstract final class NodeFieldOps {
  static const eq = 'eq';
  static const neq = 'neq';
  static const exists = 'exists';
  static const all = [eq, neq, exists];
}

/// The nodeField condition: `isClass`/`isEmbedded` (eq "true"/"false") and
/// `coverAsset`/`bannerAsset`/`aliasedNode` (eq/neq a node id, exists).
final class NodeFieldCondition extends Condition {
  const NodeFieldCondition({required this.field, required this.op, this.value});

  @override
  final String type = 'nodeField';
  final String field;
  final String op;

  /// Not a uuid on purpose: isClass/isEmbedded ride "true"/"false".
  final String? value;

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'field': field,
        'op': op,
        if (value != null) 'value': value,
      };

  factory NodeFieldCondition.fromJson(Object? input) {
    final map = _strictMap(input, const {'type', 'field', 'op', 'value'}, 'nodeField');
    if (map['type'] != 'nodeField') {
      throw FormatException('query AST: nodeField type must be "nodeField"', map['type']);
    }
    return NodeFieldCondition(
      field: _enum(map['field'], NodeFieldFields.all, 'nodeField field'),
      op: _enum(map['op'], NodeFieldOps.all, 'nodeField op'),
      value: _minStringOrNull(map['value'], 'nodeField value'),
    );
  }
}

// --- sort --------------------------------------------------------------------

/// The sort fields (name sorts over the flattened title, NOCASE).
abstract final class SortFields {
  static const name = 'name';
  static const createdAt = 'createdAt';
  static const isClass = 'isClass';
  static const isEmbedded = 'isEmbedded';
  static const all = [name, createdAt, isClass, isEmbedded];
}

/// One sort term: field + direction.
final class SortSpec {
  const SortSpec({required this.field, required this.dir});

  final String field;
  final String dir;

  Map<String, dynamic> toJson() => {'field': field, 'dir': dir};

  factory SortSpec.fromJson(Object? input) {
    final map = _strictMap(input, const {'field', 'dir'}, 'sort spec');
    return SortSpec(
      field: _enum(map['field'], SortFields.all, 'sort field'),
      dir: _enum(map['dir'], const ['asc', 'desc'], 'sort dir'),
    );
  }
}

// --- aggregation --------------------------------------------------------------

/// A grouping dimension: class membership (hierarchy-aware), a property's
/// effective value, or the Revision-12 booleans.
sealed class AggregationDimension {
  const AggregationDimension();

  String get kind;

  Map<String, dynamic> toJson();

  factory AggregationDimension.fromJson(Object? input) {
    final kind = input is Map ? input['kind'] : null;
    switch (kind) {
      case 'class':
        final map = _strictMap(input, const {'kind', 'id'}, 'class dimension');
        _requireUuid(map['id'], 'class dimension id');
        return ClassDimension(id: map['id'] as String);
      case 'property':
        final map = _strictMap(input, const {'kind', 'id'}, 'property dimension');
        _requireUuid(map['id'], 'property dimension id');
        return PropertyDimension(id: map['id'] as String);
      case 'isClass':
        _strictMap(input, const {'kind'}, 'isClass dimension');
        return const IsClassDimension();
      case 'isEmbedded':
        _strictMap(input, const {'kind'}, 'isEmbedded dimension');
        return const IsEmbeddedDimension();
      default:
        throw FormatException(
          'query AST: unknown dimension kind (expected class | property | '
          'isClass | isEmbedded)',
          kind,
        );
    }
  }
}

final class ClassDimension extends AggregationDimension {
  const ClassDimension({required this.id});

  @override
  final String kind = 'class';
  final String id;

  @override
  Map<String, dynamic> toJson() => {'kind': kind, 'id': id};
}

final class PropertyDimension extends AggregationDimension {
  const PropertyDimension({required this.id});

  @override
  final String kind = 'property';
  final String id;

  @override
  Map<String, dynamic> toJson() => {'kind': kind, 'id': id};
}

final class IsClassDimension extends AggregationDimension {
  const IsClassDimension();

  @override
  final String kind = 'isClass';

  @override
  Map<String, dynamic> toJson() => const {'kind': 'isClass'};
}

final class IsEmbeddedDimension extends AggregationDimension {
  const IsEmbeddedDimension();

  @override
  final String kind = 'isEmbedded';

  @override
  Map<String, dynamic> toJson() => const {'kind': 'isEmbedded'};
}

/// An aggregation measure: node counts, or a property-value aggregate.
sealed class AggregationMeasure {
  const AggregationMeasure();

  String get function;

  Map<String, dynamic> toJson();

  factory AggregationMeasure.fromJson(Object? input) {
    if (input is! Map) {
      throw FormatException('query AST: measure must be an object', input);
    }
    final function = input['function'];
    if (function == 'count' || function == 'countDistinct') {
      final map = _strictMap(
        input,
        const {'function', 'kind'},
        '$function measure',
      );
      final kind = map['kind'];
      if (kind != null && kind != 'node') {
        throw FormatException(
          'query AST: $function measure kind must be "node"',
          kind,
        );
      }
      return NodeCountMeasure(function: function);
    }
    if (function == 'sum' || function == 'avg' || function == 'min' || function == 'max') {
      final map = _strictMap(
        input,
        const {'function', 'kind', 'id'},
        '$function measure',
      );
      if (map['kind'] != 'property') {
        throw FormatException(
          'query AST: $function measure requires kind "property"',
          map['kind'],
        );
      }
      _requireUuid(map['id'], '$function measure id');
      return PropertyMeasure(function: function, id: map['id'] as String);
    }
    throw FormatException(
      'query AST: unknown measure function (expected count | countDistinct | '
      'sum | avg | min | max)',
      function,
    );
  }
}

/// A `COUNT(*)` / `COUNT(DISTINCT f.id)` measure.
final class NodeCountMeasure extends AggregationMeasure {
  const NodeCountMeasure({required this.function});

  @override
  final String function;

  @override
  Map<String, dynamic> toJson() => {'function': function, 'kind': 'node'};
}

/// A `sum`/`avg`/`min`/`max` measure over a property's effective value.
final class PropertyMeasure extends AggregationMeasure {
  const PropertyMeasure({required this.function, required this.id});

  @override
  final String function;
  final String id;

  @override
  Map<String, dynamic> toJson() => {'function': function, 'kind': 'property', 'id': id};
}

/// The aggregation clause: dimensions to group by, measures to compute.
final class Aggregation {
  const Aggregation({required this.dimensions, required this.measures});

  final List<AggregationDimension> dimensions;
  final List<AggregationMeasure> measures;

  Map<String, dynamic> toJson() => {
        'dimensions': [for (final d in dimensions) d.toJson()],
        'measures': [for (final m in measures) m.toJson()],
      };

  factory Aggregation.fromJson(Object? input) {
    final map = _strictMap(input, const {'dimensions', 'measures'}, 'aggregation');
    final rawDimensions = map['dimensions'];
    if (rawDimensions is! List) {
      throw FormatException(
        'query AST: aggregation dimensions must be a list',
        rawDimensions,
      );
    }
    final rawMeasures = map['measures'];
    if (rawMeasures is! List || rawMeasures.isEmpty) {
      throw FormatException(
        'query AST: aggregation measures must be a non-empty list',
        rawMeasures,
      );
    }
    return Aggregation(
      dimensions: [
        for (final d in rawDimensions) AggregationDimension.fromJson(d),
      ],
      measures: [
        for (final m in rawMeasures) AggregationMeasure.fromJson(m),
      ],
    );
  }
}

// --- root ----------------------------------------------------------------------

/// The versioned query AST — the source of truth; UI and SQL are
/// projections of it. Strictly versioned: `version` must be the literal 2.
final class QueryAst {
  const QueryAst({
    required this.scope,
    required this.root,
    this.sort,
    this.aggregation,
  });

  static const int version = 2;

  final Scope scope;
  final Group root;
  final List<SortSpec>? sort;
  final Aggregation? aggregation;

  Map<String, dynamic> toJson() => {
        'version': version,
        'scope': scope.toJson(),
        'root': root.toJson(),
        if (sort != null)
          'sort': [for (final spec in sort!) spec.toJson()],
        if (aggregation != null) 'aggregation': aggregation!.toJson(),
      };

  /// Parse + validate a serialized AST. Unknown condition types, families,
  /// ops, target modes, keys, or versions fail loud (FormatException).
  factory QueryAst.parse(Object? input) {
    final map = _strictMap(
      input,
      const {'version', 'scope', 'root', 'sort', 'aggregation'},
      'query AST',
    );
    final version = map['version'];
    if (version != 2) {
      throw FormatException(
        'query AST: version must be the literal 2 (v1 is rejected '
        'outright — no dual-parse)',
        version,
      );
    }
    final rawSort = map['sort'];
    if (rawSort != null && rawSort is! List) {
      throw FormatException('query AST: sort must be a list', rawSort);
    }
    return QueryAst(
      scope: Scope.fromJson(map['scope']),
      root: Group.fromJson(map['root']),
      sort: rawSort == null
          ? null
          : [for (final spec in rawSort) SortSpec.fromJson(spec)],
      aggregation:
          map['aggregation'] == null ? null : Aggregation.fromJson(map['aggregation']),
    );
  }
}
