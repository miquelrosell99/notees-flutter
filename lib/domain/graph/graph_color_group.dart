/// The graph's query-driven color groups — a port of the web's
/// `apps/web/src/features/collection/graph/colorGroups.ts`. Each group is
/// a query AST root group (the FilterBlockBuilder grammar — class/type/
/// content/property/link conditions) plus a color; nodes matching a group
/// render in the group's color. The persisted list order IS the
/// first-match-wins priority; a node with no group keeps its own color.
/// Evaluation wraps the group in the workspace-scope AST and rides the
/// local query runner, so groups see exactly what the query surfaces see.
/// Pure evaluation — persistence lives in ColorGroupStore, the run site in
/// GraphService.
///
/// Persistence is the AST itself (JSON-serializable). Two one-time
/// migrations run at load ([migrateColorGroup], the web effect's
/// precedent): the pre-AST stores held a text-DSL `query` string per group
/// (parsed through the DSL, names resolved against the workspace), and the
/// earlier stores hold a v1 query AST per group (rewritten through the
/// pure v1→v2 mapping — no dual-parse anywhere). Fail-loud errors keep the
/// group but mark it erroneous, painted nowhere.
library;

import '../query/query_ast.dart';
import '../query/query_ast_v1_migration.dart';

/// A device-local color group: a label, a color (preset token or
/// `#RRGGBB`), and the query AST root group selecting the group's nodes.
/// [ast] is null with [error] set when a legacy row failed to migrate —
/// the group stays listed, painted nowhere.
class GraphColorGroup {
  const GraphColorGroup({
    required this.id,
    required this.label,
    required this.color,
    this.ast,
    this.error,
  });

  final String id;
  final String label;

  /// Preset token or `#RRGGBB` (stored form; the painter resolves).
  final String color;

  /// The query AST root group selecting the group's nodes.
  final Group? ast;

  /// Set when a legacy row failed to migrate — the group stays listed,
  /// painted nowhere.
  final String? error;

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'color': color,
        if (ast != null) 'ast': ast!.toJson(),
        if (error != null) 'error': error,
      };

  /// Parses a stored (already-migrated) row — the strict group parse
  /// fails loud on corrupt shapes, like the wire model. Stored rows still
  /// holding a v1 tree throw here; [migrateColorGroup] rewrites them
  /// first.
  factory GraphColorGroup.fromJson(Object? input) {
    if (input is! Map) {
      throw const FormatException('color group: expected an object');
    }
    final id = input['id'];
    final label = input['label'];
    final color = input['color'];
    if (id is! String || label is! String || color is! String) {
      throw const FormatException(
          'color group: id, label, and color must be strings');
    }
    final rawAst = input['ast'];
    final rawError = input['error'];
    return GraphColorGroup(
      id: id,
      label: label,
      color: color,
      ast: rawAst == null ? null : Group.fromJson(rawAst),
      error: rawError is String ? rawError : null,
    );
  }
}

/// True when a stored row is a pre-AST legacy group (a `query` string, no
/// AST) — the retired text-DSL storage shape, still read at load.
bool isLegacyColorGroup(Object? group) =>
    group is Map && group['query'] is String;

/// The v2 condition types — a stored group tree is v2 when every condition
/// rides one.
const Set<String> _v2ConditionTypes = {
  'member',
  'content',
  'name',
  'property',
  'date',
  'nodeField',
};

/// Recursive walk over a RAW stored child list: true when every condition
/// in the tree is a v2 shape (the web `isV2ConditionTree` contract).
/// Operates on the stored JSON, not the parsed model — a v1 tree must be
/// detectable BEFORE the strict parse rejects it.
bool isV2ConditionTreeJson(Object? children) {
  if (children is! List) return false;
  for (final child in children) {
    if (child is! Map) return false;
    final type = child['type'];
    if (type == 'group') {
      if (!isV2ConditionTreeJson(child['children'])) return false;
    } else if (type == 'not') {
      final inner = child['child'];
      if (inner is Map && inner['type'] == 'group') {
        if (!isV2ConditionTreeJson(inner['children'])) return false;
      } else if (inner is! Map ||
          !_v2ConditionTypes.contains(inner['type'])) {
        return false;
      }
    } else if (!_v2ConditionTypes.contains(type)) {
      return false;
    }
  }
  return true;
}

/// The one-time legacy migrations, run per device at load (the web
/// `migrateColorGroup` port). A text-DSL string parses through
/// [parseDsl] (names resolve against the workspace) and the group
/// re-persists as an AST. A stored v1 AST rewrites through the pure
/// v1→v2 mapping (`{version: 1}` envelope → mapped root, validated through
/// the strict parser). A fail-loud error KEEPS the group but marks it
/// erroneous (`ast: null` + the message). Already-migrated (v2) rows pass
/// through. [parseDsl] is injected so the pure pins drive it with stubs.
Future<GraphColorGroup> migrateColorGroup(
  Object? stored, {
  required Future<QueryAst> Function(String dsl) parseDsl,
}) async {
  if (isLegacyColorGroup(stored)) {
    final map = Map<String, dynamic>.from(stored as Map);
    final id = (map['id'] as String?) ?? '';
    final label = (map['label'] as String?) ?? '';
    final color = (map['color'] as String?) ?? '';
    try {
      final parsed = await parseDsl(map['query'] as String);
      return GraphColorGroup(
          id: id, label: label, color: color, ast: parsed.root);
    } catch (error) {
      return GraphColorGroup(
        id: id,
        label: label,
        color: color,
        ast: null,
        error: error.toString(),
      );
    }
  }
  if (stored is! Map) {
    throw const FormatException('color group: expected an object');
  }
  final id = (stored['id'] as String?) ?? '';
  final label = (stored['label'] as String?) ?? '';
  final color = (stored['color'] as String?) ?? '';
  final rawAst = stored['ast'];
  if (rawAst is Map && !isV2ConditionTreeJson(rawAst['children'])) {
    try {
      final envelope = <String, dynamic>{
        'version': 1,
        'scope': const {'type': 'entire_workspace'},
        'root': rawAst,
      };
      if (!isQueryAstV1(envelope)) {
        throw const FormatException('not a v1 query AST');
      }
      final mapped = QueryAst.parse(mapQueryAstV1ToV2(envelope));
      return GraphColorGroup(
        id: id,
        label: label,
        color: color,
        ast: mapped.root,
      );
    } catch (error) {
      return GraphColorGroup(
        id: id,
        label: label,
        color: color,
        ast: null,
        error: error.toString(),
      );
    }
  }
  // The v2 row (or an already-marked erroneous row) passes through the
  // strict parse — corrupt shapes fail loud here, like the wire model.
  return GraphColorGroup.fromJson(stored);
}

/// Wrap a group's root in the workspace-scope AST the query runner
/// consumes.
QueryAst colorGroupQueryAst(Group root) => QueryAst(
      scope: const EntireWorkspaceScope(),
      root: root,
    );

/// Evaluate the groups in list order — returns nodeId → the FIRST group's
/// stored color each node matches (the list order IS the priority; a
/// drag-reorder rewrites it — sheet-only for now). Erroneous (unmigrated)
/// groups and empty groups match nothing; a runner failure skips that
/// group. [runIds] rides the local query runner and returns the matching
/// node ids in the compiler's deterministic order.
Future<Map<String, String>> evaluateColorGroups(
  List<GraphColorGroup> groups,
  Future<List<String>> Function(QueryAst ast) runIds,
) async {
  final assignment = <String, String>{};
  for (final group in groups) {
    final ast = group.ast;
    if (ast == null || ast.children.isEmpty) continue;
    final List<String> ids;
    try {
      ids = await runIds(colorGroupQueryAst(ast));
    } catch (_) {
      continue;
    }
    for (final id in ids) {
      assignment.putIfAbsent(id, () => group.color);
    }
  }
  return assignment;
}
