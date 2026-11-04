/// QueryAST v2 → SQLite compiler over the Flutter derived schema, a
/// method-for-method port of `packages/query/src/compiler.ts`.
///
/// Schema deltas from the TS reference, isolated here (the GTK port's D1/D2/
/// D6 precedent — one documented delta block):
///
///  - **F1 — table + column renames.** The local node table is `node_cache`:
///    `id → uuid`, `content → name` (the content JSON rides the `name`
///    column, the v16 split), `class_ids → classes_uuid`,
///    `parent_id → parent_uuid`; the property tables rename `node_id →
///    node_uuid` and `property_schema.id → uuid`. The rename map is
///    [_NodeColumns]; every fragment below composes from it so the SQL
///    stays diff-reviewable against the TS reference.
///  - **F2 — the active predicate.** The TS `n.is_active = 1` is local
///    `n.is_deleted = 0 AND n.is_archived = 0` — the local read helpers
///    exclude archived rows on every read, so archived rows stay out of
///    every query (pinned in the golden vectors).
///  - **F3 — fresh scopes alias `m`** (the D6 pitfall the GTK port hit on
///    system SQLite): the dynamic-target subqueries ride a `node_cache m`
///    scope distinct from the outer row alias `n`, so the correlated CTE
///    anchors keep the outer row. The node alias threads through every
///    group/condition method as a parameter.
///  - **F4 — the parentlessRole demote reads `class_cache`.** Classes keep
///    their config in the local `class_cache` registry (no
///    `parentless_role` column on `node_cache`), so
///    `hasParentlessBlockClassSql` joins `class_cache c ON c.uuid =
///    ch.ancestor_id` instead of the TS `node c`.
///  - **F5 — the FTS backend is `search_index_fts`.** The local plaintext
///    FTS virtual table (+ the `search_index_fts_docid` docid map) replaces
///    the TS `search_index` FTS5 table; the MATCH/LIKE arms port verbatim
///    against it. (The pre-existing `search_index` term inverted index is a
///    different table and untouched.)
///
/// Everything is parameterized with positional `?` placeholders; user values
/// never reach the SQL string. Parameter binding order is part of the
/// contract: every predicate is built BEFORE the string composes (the
/// `push()`-before-compose discipline), so `?` params bind in SQL text
/// order — pinned by the compiler tests' golden param vectors.
library;

import 'dart:convert';

import 'query_ast.dart';
import 'query_placeholders.dart';

/// A compiled plain query: the SQL text and the positional params.
class CompiledQuery {
  const CompiledQuery({required this.sql, required this.params});

  final String sql;
  final List<Object?> params;
}

/// An aggregate compilation additionally carries the deterministic column
/// order (dimensions in declared order, then measures).
class CompiledAggregate {
  const CompiledAggregate({
    required this.sql,
    required this.params,
    required this.columns,
  });

  final String sql;
  final List<Object?> params;
  final List<String> columns;
}

/// The local derived-schema column rename map (delta F1/F2/F4/F5). TS names
/// on the left of each mapping; the values are the local column names.
abstract final class _NodeColumns {
  static const table = 'node_cache';
  static const id = 'uuid';
  static const parentId = 'parent_uuid';
  static const content = 'name';
  static const classIds = 'classes_uuid';
  static const tagIds = 'tag_ids';
  static const isClass = 'is_class';
  static const isEmbedded = 'is_embedded';
  static const createdAt = 'created_at';
  static const updatedAt = 'updated_at';
  static const coverAssetId = 'cover_asset_id';
  static const bannerAssetId = 'banner_asset_id';
  static const aliasedNodeId = 'aliased_node_id';

  /// Delta F2 — the TS `is_active = 1` as the local two-column predicate.
  static String isActive(String alias) =>
      '($alias.is_deleted = 0 AND $alias.is_archived = 0)';

  /// The property tables' renames (F1).
  static const propertyValueNodeId = 'node_uuid';
  static const tombstoneNodeId = 'node_uuid';
  static const classMemberNodeId = 'node_uuid';
  static const propertySchemaId = 'uuid';

  /// The FTS backend (F5).
  static const ftsTable = 'search_index_fts';
  static const ftsDocidTable = 'search_index_fts_docid';
}

/// Prefix-AND FTS match expression for query filters (the TS
/// `buildMatchExpression` port): each maximal run of letters/digits OUTSIDE
/// double quotes becomes a bare prefix token (`term*`); each double-quoted
/// segment becomes an exact FTS phrase. Splitting at every non-alphanumeric
/// boundary mirrors the unicode61 tokenizer. Null when nothing searchable
/// remains. A filter's contains stays conjunctive (AND) — the search
/// surface ORs bare terms and tiers whole-query matches above partials.
List<String> _splitMatchTerms(String text) => text
    .trim()
    .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
    .where((term) => term.isNotEmpty)
    .toList();

String? buildMatchExpression(String query) {
  final clauses = <String>[];
  final unquoted = <String>[];
  final pattern = RegExp('"([^"]*)"');
  var last = 0;
  for (final match in pattern.allMatches(query)) {
    unquoted.add(query.substring(last, match.start));
    last = match.end;
    final terms = _splitMatchTerms(match.group(1)!);
    if (terms.isNotEmpty) clauses.add('"${terms.join(' ')}"');
  }
  unquoted.add(query.substring(last));
  for (final term in _splitMatchTerms(unquoted.join(' '))) {
    clauses.add('$term*');
  }
  if (clauses.isEmpty) return null;
  return clauses.join(' AND ');
}

/// The title (the flattened content text) for the node row [alias] —
/// title-is-content: concatenating the text-run tokens of the content JSON
/// (the local `name` column, delta F1), the exact expression sort-by-name
/// orders by. group_concat yields NULL when no text run rides the content.
String titleSql(String alias) =>
    "(SELECT group_concat(json_extract(j.value, '\$.text'), ' ') FROM "
    "json_each($alias.${_NodeColumns.content}) j WHERE "
    "json_extract(j.value, '\$.type') = 'text')";

/// One sort column's SQL + ordering behavior.
class _SortColumn {
  const _SortColumn(this.column, {this.nullable = false, this.nocase = false});

  final String column;
  final bool nullable;
  final bool nocase;
}

/// The sort column for [field]. Title-is-content: the name sort orders by
/// the flattened content text (NULL/empty titles fall to the id tiebreak
/// the runner appends) and folds case (NOCASE): "a" sorts before "B".
_SortColumn _sortColumnFor(String field) {
  switch (field) {
    case SortFields.name:
      return _SortColumn(
        "(SELECT group_concat(json_extract(j.value, '\$.text'), ' ') FROM "
        "json_each(n.${_NodeColumns.content}) j WHERE "
        "json_extract(j.value, '\$.type') = 'text')",
        nullable: true,
        nocase: true,
      );
    case SortFields.createdAt:
      return _SortColumn('n.${_NodeColumns.createdAt}', nullable: true);
    case SortFields.isClass:
      return _SortColumn('n.${_NodeColumns.isClass}');
    case SortFields.isEmbedded:
      return _SortColumn('n.${_NodeColumns.isEmbedded}');
    default:
      throw StateError("query compile: unknown sort field '$field'");
  }
}

/// Deterministic aggregate column labels: dimensions in declared order,
/// then measures; collisions get a positional `#n` suffix.
List<String> aggregationColumns(Aggregation aggregation) {
  final names = <String>[
    for (final dimension in aggregation.dimensions)
      switch (dimension) {
        ClassDimension() => 'class:${dimension.id}',
        PropertyDimension() => 'property:${dimension.id}',
        IsClassDimension() => 'isClass',
        IsEmbeddedDimension() => 'isEmbedded',
      },
    for (final measure in aggregation.measures)
      switch (measure) {
        NodeCountMeasure() =>
          measure.function == 'count' ? 'count' : 'countDistinct',
        PropertyMeasure() => '${measure.function}:${measure.id}',
      },
  ];
  final used = <String>{};
  final columns = <String>[];
  for (final name in names) {
    if (used.add(name)) {
      columns.add(name);
      continue;
    }
    var index = 2;
    while (used.contains('$name#$index')) {
      index += 1;
    }
    final suffixed = '$name#$index';
    used.add(suffixed);
    columns.add(suffixed);
  }
  return columns;
}

/// Compiles [ast] to a plain query.
CompiledQuery compile(QueryAst ast, [CompileOptions options = const CompileOptions()]) =>
    QueryCompiler(options).compile(ast);

/// Compiles [ast] to an aggregate query.
CompiledAggregate compileAggregate(QueryAst ast, [CompileOptions options = const CompileOptions()]) =>
    QueryCompiler(options).compileAggregate(ast);

/// The compiler instance: one params accumulator per compile.
final class QueryCompiler {
  QueryCompiler(this._options);

  final CompileOptions _options;
  final List<Object?> _params = [];

  /// The push-before-compose discipline: the param lands BEFORE the string
  /// composes, so positional `?` placeholders bind in SQL text order.
  String _push(Object? value) {
    _params.add(value);
    return '?';
  }

  // --- plain + aggregate compilation ---------------------------------------

  CompiledQuery compile(QueryAst ast) {
    if (ast.aggregation != null) {
      final aggregate = _aggregationSql(ast, ast.aggregation!);
      return CompiledQuery(sql: aggregate.sql, params: _params);
    }

    final (:from, :where, :hasDistance) = _filteredFromWhere(ast);

    final columns = hasDistance ? 'n.*, sc.distance AS distance' : 'n.*';
    final sql =
        'SELECT $columns\nFROM $from\nWHERE ${where.join(' AND ')}\n'
        'ORDER BY ${_orderSql(ast.sort)}';
    return CompiledQuery(sql: sql, params: _params);
  }

  /// Aggregation compilation: the same filtered-node set becomes a
  /// `filtered` CTE; the outer query groups it by the dimensions and
  /// aggregates the measures. Zero dimensions = one grand-total row.
  CompiledAggregate compileAggregate(QueryAst ast) {
    final aggregation = ast.aggregation;
    if (aggregation == null) {
      throw StateError(
        'query compile: compileAggregate requires an AST with an aggregation',
      );
    }
    final compiled = _aggregationSql(ast, aggregation);
    return CompiledAggregate(
      sql: compiled.sql,
      params: _params,
      columns: compiled.columns,
    );
  }

  ({String sql, List<String> columns}) _aggregationSql(
    QueryAst ast,
    Aggregation aggregation,
  ) {
    final filtered = _filteredFromWhere(ast);
    final from = filtered.from;
    final where = filtered.where;
    final dimExprs = [
      for (final dimension in aggregation.dimensions)
        _dimensionSql(dimension),
    ];
    final measureExprs = [
      for (final measure in aggregation.measures) _measureSql(measure),
    ];
    final columns = aggregationColumns(aggregation);
    // GROUP BY/ORDER BY reference the output aliases: repeating the
    // expressions would repeat their `?` placeholders.
    final dimAliases = columns
        .take(dimExprs.length)
        .map((column) => '"$column"')
        .toList();
    final selectList = [
      for (var i = 0; i < dimExprs.length + measureExprs.length; i++)
        '${[...dimExprs, ...measureExprs][i]} AS "${columns[i]}"',
    ];
    var sql =
        'WITH filtered AS (\n'
        'SELECT n.${_NodeColumns.id}, n.${_NodeColumns.isClass}, '
        'n.${_NodeColumns.isEmbedded}, n.${_NodeColumns.classIds}\n'
        'FROM $from\n'
        'WHERE ${where.join(' AND ')}\n'
        ')\n'
        'SELECT ${selectList.join(', ')}\nFROM filtered f\n';
    if (dimExprs.isNotEmpty) {
      sql += 'GROUP BY ${dimAliases.join(', ')}\n';
      sql += 'ORDER BY ${dimAliases.join(', ')} ASC';
    }
    return (sql: sql, columns: columns);
  }

  // --- aggregation ------------------------------------------------------------

  String _dimensionSql(AggregationDimension dimension) {
    switch (dimension) {
      case IsClassDimension():
        return 'f.${_NodeColumns.isClass}';
      case IsEmbeddedDimension():
        return 'f.${_NodeColumns.isEmbedded}';
      case ClassDimension():
        // The same membership probe as the class condition: class_hierarchy
        // carries the extends closure (self-row included).
        final classId = _push(dimension.id);
        return (
          'CASE WHEN EXISTS (\n  SELECT 1 FROM json_each(f.${_NodeColumns.classIds})\n'
          '  WHERE value IN (SELECT class_id FROM class_hierarchy '
          'WHERE ancestor_id = $classId)\n) THEN 1 ELSE 0 END'
        );
      case PropertyDimension():
        return _effectiveValueSql(dimension.id);
    }
  }

  String _measureSql(AggregationMeasure measure) {
    switch (measure) {
      case NodeCountMeasure():
        return measure.function == 'count'
            ? 'COUNT(*)'
            : 'COUNT(DISTINCT f.${_NodeColumns.id})';
      case PropertyMeasure():
        // json_extract yields the JSON number for numeric values; text
        // values aggregate as SQLite's numeric coercion dictates.
        return '${measure.function.toUpperCase()}(${_effectiveValueSql(measure.id)})';
    }
  }

  /// The property_value suppression predicate shared by every authored
  /// read: no winning SLOT tombstone and no strictly-newer ELEMENT
  /// tombstone (add-wins ties).
  static String visibleValuePredicate(String alias) => (
    'NOT EXISTS (\n'
    '  SELECT 1 FROM property_value_tombstone t\n'
    '  WHERE t.${_NodeColumns.tombstoneNodeId} = $alias.${_NodeColumns.propertyValueNodeId} '
    'AND t.property_schema_id = $alias.property_schema_id\n'
    '    AND t.idx = $alias.idx\n'
    '    AND (t.hlc_physical, t.hlc_logical, COALESCE(t.actor_id, \'\')) >=\n'
    '        ($alias.hlc_physical, $alias.hlc_logical, COALESCE($alias.actor_id, \'\'))\n'
    ')\n'
    'AND NOT EXISTS (\n'
    '  SELECT 1 FROM property_value_element_tombstone et\n'
    '  WHERE et.element_id = $alias.id\n'
    '    AND (et.hlc_physical, et.hlc_logical) >\n'
    '        ($alias.hlc_physical, $alias.hlc_logical)\n'
    ')'
  );

  /// The effective/authored value at idx 0 of a property for the filtered
  /// node (alias `f`) — authored idx-0 rows (visible-set suppressed) UNION
  /// the winning ACTIVE binding's default when no authored row shadows it.
  /// Params per call: three schema ids (authored filter, binding filter,
  /// derived-shadow check).
  String _effectiveValueSql(String schemaId) {
    final authored = _push(schemaId);
    final binding = _push(schemaId);
    final shadow = _push(schemaId);
    final tombstone = visibleValuePredicate('pv');
    return (
      '(SELECT json_extract(ev.value, \'\$\') FROM (\n'
      '  SELECT pv.${_NodeColumns.propertyValueNodeId} AS node_id, pv.value AS value '
      'FROM property_value pv\n'
      '  WHERE pv.property_schema_id = $authored AND pv.${_NodeColumns.propertyValueNodeId} = '
      'f.${_NodeColumns.id} AND pv.idx = 0 AND $tombstone\n'
      '  UNION ALL\n'
      '  SELECT wb.node_id, wb.default_value FROM (\n'
      '    SELECT cms.${_NodeColumns.classMemberNodeId} AS node_id, ps.default_value,\n'
      '           ROW_NUMBER() OVER (\n'
      '             PARTITION BY cms.${_NodeColumns.classMemberNodeId}\n'
      '             ORDER BY cms.hlc_physical, cms.hlc_logical, cms.class_id\n'
      '           ) AS rn\n'
      '    FROM class_member_set cms\n'
      '    JOIN class_property cp ON cp.class_id = cms.class_id\n'
      '    JOIN property_schema ps ON ps.${_NodeColumns.propertySchemaId} = cp.property_schema_id\n'
      '    WHERE cms.present = 1 AND cp.property_schema_id = $binding AND cp.active = 1\n'
      '      AND ps.default_value IS NOT NULL\n'
      '  ) wb\n'
      '  WHERE wb.rn = 1 AND wb.node_id = f.${_NodeColumns.id}\n'
      '    AND NOT EXISTS (\n'
      '      SELECT 1 FROM property_value pv\n'
      '      WHERE pv.${_NodeColumns.propertyValueNodeId} = wb.node_id AND '
      'pv.property_schema_id = $shadow\n'
      '        AND pv.idx = 0 AND $tombstone\n'
      '    )\n'
      ') ev LIMIT 1)'
    );
  }

  // --- filtered set (shared by the plain query and the aggregation) ---------

  ({String from, List<String> where, bool hasDistance}) _filteredFromWhere(
    QueryAst ast,
  ) {
    var from = '${_NodeColumns.table} n';
    var hasDistance = false;
    switch (ast.scope) {
      case EntireWorkspaceScope():
        break;
      case PagesScope():
        // Filtered in WHERE below; no scope join, no distance column.
        break;
      case SubtreeScope(:final pageId):
        from += '\nJOIN (${_subtreeSql(pageId)}) sc ON sc.id = n.${_NodeColumns.id}';
        hasDistance = true;
      case LinkedToScope(:final nodeId):
        from += '\nJOIN (${_linkedToSql(nodeId)}) sc ON sc.id = n.${_NodeColumns.id}';
        hasDistance = true;
    }

    final where = <String>[_NodeColumns.isActive('n')];
    if (ast.scope is PagesScope) {
      // Document-chrome predicate (Revision 12), parentlessRole-aware (the
      // demote is a separate conjunct over the parentless population).
      where.add(
        'n.${_NodeColumns.isClass} = 0 AND (n.${_NodeColumns.parentId} IS NULL '
        'OR n.${_NodeColumns.isEmbedded} = 0)'
        ' AND (n.${_NodeColumns.parentId} IS NOT NULL OR '
        'NOT ${_hasParentlessBlockClassSql('n')})',
      );
    }
    final group = _groupSql(ast.root, 'n');
    if (group != null) {
      where.add('($group)');
    }
    return (from: from, where: where, hasDistance: hasDistance);
  }

  // --- scope -----------------------------------------------------------------

  /// Anchor-set seed for a single node (distance 0).
  String _anchorNodeSql(String nodeId) =>
      'SELECT ${_NodeColumns.id} AS id, 0 AS distance FROM ${_NodeColumns.table} '
      'WHERE ${_NodeColumns.id} = ${_push(nodeId)}';

  /// The SELF id: CompileOptions.selfNodeId, failing loud when the run site
  /// supplied no host.
  String _selfIdValue() {
    final selfNodeId = _options.selfNodeId;
    if (selfNodeId == null || selfNodeId.isEmpty) {
      throw StateError(
        "query compile: a 'self' target requires CompileOptions.selfNodeId "
        '(the query\'s hosting page)',
      );
    }
    return selfNodeId;
  }

  /// The SELF id as one `?` param.
  String _selfId() => _push(_selfIdValue());

  /// Anchor-set seed for the SELF family: the hosting page (distance 0).
  String _selfAnchorSql() =>
      'SELECT ${_NodeColumns.id} AS id, 0 AS distance FROM ${_NodeColumns.table} '
      'WHERE ${_NodeColumns.id} = ${_selfId()}';

  /// Anchor-set seed for a nested group: the matching ACTIVE nodes
  /// (distance 0). The fresh scope rides the F3 alias `m` so the correlated
  /// CTE anchors keep the outer row.
  String _groupAnchorsSql(Group root) {
    final group = _groupSql(root, 'm');
    return (
      'SELECT m.${_NodeColumns.id} AS id, 0 AS distance FROM ${_NodeColumns.table} m '
      'WHERE ${_NodeColumns.isActive('m')}'
      '${group != null ? ' AND ($group)' : ''}'
    );
  }

  /// Anchor SET + descendants, one row per node, distance = levels below.
  String _subtreeSetSql(String anchorsSql) => (
    'WITH RECURSIVE sub(id, distance) AS (\n'
    '$anchorsSql\n'
    '  UNION ALL\n'
    '  SELECT m.${_NodeColumns.id}, sub.distance + 1 FROM sub '
    'JOIN ${_NodeColumns.table} m ON m.${_NodeColumns.parentId} = sub.id\n'
    ') SELECT id, distance FROM sub'
  );

  /// Anchor + descendants — the single-anchor convenience.
  String _subtreeSql(String anchorId) =>
      _subtreeSetSql(_anchorNodeSql(anchorId));

  /// backlinksWithRollup membership over a TARGET SET (direct edges to any
  /// target, UNION sources inside any subtree linking OUTSIDE the whole sub
  /// union; MIN(distance) collapses duplicates).
  String _linkedToSetSql(String targetsSql) => (
    'WITH RECURSIVE anchors AS ($targetsSql),\n'
    'sub(id, distance) AS (\n'
    '  SELECT id, 0 AS distance FROM anchors\n'
    '  UNION ALL\n'
    '  SELECT m.${_NodeColumns.id}, sub.distance + 1 FROM sub '
    'JOIN ${_NodeColumns.table} m ON m.${_NodeColumns.parentId} = sub.id\n'
    '), hits AS (\n'
    '  SELECT e.source_id AS id, 0 AS distance FROM edge e\n'
    '  WHERE e.target_id IN (SELECT id FROM anchors)\n'
    '  UNION ALL\n'
    '  SELECT e.source_id, sub.distance FROM edge e\n'
    '  JOIN sub ON sub.id = e.source_id\n'
    '  WHERE sub.distance > 0 AND e.target_id NOT IN (SELECT id FROM sub)\n'
    ') SELECT id, MIN(distance) AS distance FROM hits GROUP BY id'
  );

  /// Single-node backlinksWithRollup membership.
  String _linkedToSql(String nodeId) =>
      _linkedToSetSql(_anchorNodeSql(nodeId));

  // --- group / not -----------------------------------------------------------

  String? _groupSql(Group group, String alias) {
    final clauses = <String>[];
    for (final child in group.children) {
      switch (child) {
        case Group():
          final nested = _groupSql(child, alias);
          if (nested != null) clauses.add('($nested)');
        case Not():
          clauses.add(_notSql(child, alias));
        case Condition():
          clauses.add(_conditionSql(child, alias));
      }
    }
    if (clauses.isEmpty) return null; // empty group = no constraint
    return clauses.join(group.logic == 'or' ? ' OR ' : ' AND ');
  }

  String _notSql(Not node, String alias) {
    final child = node.child;
    final inner = switch (child) {
      Group() => _groupSql(child, alias),
      Condition() => _conditionSql(child, alias),
      // Impossible by grammar (the parser admits only a condition or a
      // group under `not`); unreachable, listed for exhaustiveness.
      Not() => throw StateError('query compile: nested not is not grammatical'),
    };
    return 'NOT (${inner ?? '1=1'})';
  }

  // --- conditions --------------------------------------------------------------

  /// The v2 condition set — six types.
  String _conditionSql(Condition condition, String alias) {
    switch (condition) {
      case MemberCondition():
        return _memberSql(condition, alias);
      case ContentCondition():
        if (condition.op == ContentOps.exists) {
          // The title/content plaintext is non-empty (the content "is set").
          return (
            'EXISTS (\n  SELECT 1 FROM ${_NodeColumns.ftsDocidTable} d\n'
            '  JOIN ${_NodeColumns.ftsTable} s ON s.rowid = d.docid\n'
            '  WHERE d.node_id = $alias.${_NodeColumns.id} AND length(s.content) > 0\n)'
          );
        }
        return _contentSql(condition, alias);
      case NameCondition():
        return _nameSql(condition, alias);
      case PropertyCondition():
        if (condition.op == PropertyOps.between) {
          return _propertyRangeSql(
            condition.schemaId,
            condition.from,
            condition.to,
            alias,
          );
        }
        if (condition.op == PropertyOps.within) {
          return _propertyWithinSql(condition.schemaId, condition.period, alias);
        }
        return _propertySql(condition, alias);
      case DateCondition():
        return _dateSql(condition, alias);
      case NodeFieldCondition():
        if (condition.field == NodeFieldFields.isClass ||
            condition.field == NodeFieldFields.isEmbedded) {
          // The Revision-12 booleans ride op "eq" with value "true"/"false".
          if (condition.op != NodeFieldOps.eq) {
            throw StateError(
              "query compile: nodeField '${condition.field}' supports only op 'eq'",
            );
          }
          if (condition.value != 'true' && condition.value != 'false') {
            throw StateError(
              "query compile: nodeField '${condition.field}' requires value "
              '"true" or "false"',
            );
          }
          final column = condition.field == NodeFieldFields.isClass
              ? _NodeColumns.isClass
              : _NodeColumns.isEmbedded;
          return '$alias.$column = ${_push(condition.value == 'true' ? 1 : 0)}';
        }
        final columns = const {
          NodeFieldFields.coverAsset: _NodeColumns.coverAssetId,
          NodeFieldFields.bannerAsset: _NodeColumns.bannerAssetId,
          NodeFieldFields.aliasedNode: _NodeColumns.aliasedNodeId,
        };
        return _nodeFieldSql(
          condition.field,
          columns[condition.field]!,
          condition,
          alias,
        );
    }
  }

  /// The member condition — family × op × target mode. Every predicate is
  /// built BEFORE the string composes, so `?` params bind in evaluation
  /// order regardless of the wrapping.
  String _memberSql(MemberCondition condition, String alias) {
    switch (condition.op) {
      case 'in':
      case 'not-in':
        final predicate = _memberInSql(condition.family, condition.target!, alias);
        return condition.op == 'not-in' ? 'NOT ($predicate)' : predicate;
      case 'exists':
      case 'not-exists':
        final predicate = _memberExistsSql(condition.family, alias);
        return condition.op == 'not-exists' ? 'NOT ($predicate)' : predicate;
      case 'exact':
        // EXACT class-set equality: exactly one class rides the row AND it
        // is the picked one — the closure deliberately does NOT apply.
        final target = condition.target! as IdsTarget;
        final classId = _push(target.ids[0]);
        return (
          '(SELECT COUNT(*) FROM json_each($alias.${_NodeColumns.classIds})) = 1\n'
          'AND EXISTS (\n  SELECT 1 FROM json_each($alias.${_NodeColumns.classIds}) '
          'WHERE value = $classId\n)'
        );
      default:
        throw StateError("query compile: unknown member op '${condition.op}'");
    }
  }

  /// The family's `in` predicate over the target set. The target mode
  /// selects the anchor SQL: `ids` the manual pick, `query` the nested
  /// group's matches (a fresh `m` scope, delta F3), `self` the hosting
  /// page.
  String _memberInSql(String family, TargetRef target, String alias) {
    switch (family) {
      case MemberFamilies.class_:
        if (target is IdsTarget) {
          // ANY-of membership — closure-aware per picked id.
          final ids = target.ids.map(_push).join(', ');
          return (
            'EXISTS (\n  SELECT 1 FROM json_each($alias.${_NodeColumns.classIds})\n'
            '  WHERE value IN (SELECT class_id FROM class_hierarchy '
            'WHERE ancestor_id IN ($ids))\n)'
          );
        }
        if (target is SelfTarget) {
          // The hosting page used as a class (closure-aware).
          final classId = _selfId();
          return (
            'EXISTS (\n  SELECT 1 FROM json_each($alias.${_NodeColumns.classIds})\n'
            '  WHERE value IN (SELECT class_id FROM class_hierarchy '
            'WHERE ancestor_id = $classId)\n)'
          );
        }
        // DYNAMIC class: closure-aware membership of ANY class matching the
        // nested group. An empty nested group degrades to the
        // never-matching subquery.
        final group = _groupSql((target as QueryTarget).root, 'm');
        final targets = group != null
            ? 'SELECT m.${_NodeColumns.id} FROM ${_NodeColumns.table} m '
                'WHERE ${_NodeColumns.isActive('m')} AND ($group)'
            : 'SELECT m.${_NodeColumns.id} FROM ${_NodeColumns.table} m '
                'WHERE (m.is_deleted = 1 OR m.is_archived = 1)';
        return (
          'EXISTS (\n  SELECT 1 FROM json_each($alias.${_NodeColumns.classIds})\n'
          '  WHERE value IN (SELECT class_id FROM class_hierarchy '
          'WHERE ancestor_id IN ($targets))\n)'
        );
      case MemberFamilies.tags:
        final String targets;
        if (target is IdsTarget) {
          targets = target.ids.map(_push).join(', ');
        } else if (target is SelfTarget) {
          targets = _selfId();
        } else {
          // DYNAMIC tags: tagged with ANY tag matching the nested group.
          final group = _groupSql((target as QueryTarget).root, 'm');
          targets = group != null
              ? 'SELECT m.${_NodeColumns.id} FROM ${_NodeColumns.table} m '
                  'WHERE ${_NodeColumns.isActive('m')} AND ($group)'
              : 'SELECT m.${_NodeColumns.id} FROM ${_NodeColumns.table} m '
                  'WHERE (m.is_deleted = 1 OR m.is_archived = 1)';
        }
        // Tag membership over the OR-set tag_ids.
        return (
          'EXISTS (\n  SELECT 1 FROM json_each($alias.${_NodeColumns.tagIds})\n'
          '  WHERE value IN ($targets)\n)'
        );
      case MemberFamilies.links:
        // backlinksWithRollup membership over the target set.
        final anchorSet = switch (target) {
          IdsTarget() =>
            'SELECT ${_NodeColumns.id} AS id, 0 AS distance FROM ${_NodeColumns.table} '
            'WHERE ${_NodeColumns.id} IN (${target.ids.map(_push).join(', ')})',
          SelfTarget() => _selfAnchorSql(),
          QueryTarget() => _groupAnchorsSql(target.root),
        };
        return '$alias.${_NodeColumns.id} IN (SELECT id FROM (${_linkedToSetSql(anchorSet)}))';
      case MemberFamilies.childPath:
        if (target is IdsTarget) {
          // Subtree membership of ANY picked node, anchors excluded — the
          // anchor list reaches the NOT-IN through ONE json_each param
          // (unindexed `?` placeholders number per occurrence).
          final anchorIds = target.ids.map(_push).join(', ');
          final anchorSet =
              'SELECT ${_NodeColumns.id} AS id, 0 AS distance FROM ${_NodeColumns.table} '
              'WHERE ${_NodeColumns.id} IN ($anchorIds)';
          final subtree = _subtreeSetSql(anchorSet);
          final exclude = _push(jsonEncode(target.ids));
          return (
            '$alias.${_NodeColumns.id} IN (SELECT id FROM ($subtree)) '
            'AND $alias.${_NodeColumns.id} NOT IN '
            '(SELECT value FROM json_each($exclude))'
          );
        }
        if (target is SelfTarget) {
          // The row sits strictly inside the hosting page.
          final subtree = _subtreeSetSql(_selfAnchorSql());
          final anchor = _selfId();
          return '$alias.${_NodeColumns.id} IN (SELECT id FROM ($subtree)) '
              'AND $alias.${_NodeColumns.id} != $anchor';
        }
        // DYNAMIC childPath: subtree membership of the anchor set, anchors
        // excluded. Both subqueries are built before the string.
        final subtree = _subtreeSetSql(_groupAnchorsSql((target as QueryTarget).root));
        final anchors = _groupAnchorsSql(target.root);
        return (
          '$alias.${_NodeColumns.id} IN (SELECT id FROM ($subtree))'
          ' AND $alias.${_NodeColumns.id} NOT IN (SELECT id FROM ($anchors))'
        );
      case MemberFamilies.parent:
        if (target is IdsTarget) {
          // The DIRECT parent is one of the picked nodes (one json_each
          // param; the COALESCE maps the parentless NULL to '').
          final ids = _push(jsonEncode(target.ids));
          return (
            "COALESCE(n.${_NodeColumns.parentId}, '') IN "
            '(SELECT value FROM json_each($ids))'
          );
        }
        if (target is SelfTarget) {
          return "COALESCE(n.${_NodeColumns.parentId}, '') = ${_selfId()}";
        }
        // DYNAMIC parent: the direct parent is one of the group's matches.
        final group = _groupSql((target as QueryTarget).root, 'm');
        final inner = group != null
            ? ' AND p.${_NodeColumns.id} IN (SELECT m.${_NodeColumns.id} '
                'FROM ${_NodeColumns.table} m WHERE ${_NodeColumns.isActive('m')} AND ($group))'
            : '';
        return (
          'EXISTS (\n  SELECT 1 FROM ${_NodeColumns.table} p\n'
          '  WHERE p.${_NodeColumns.id} = n.${_NodeColumns.parentId} '
          'AND ${_NodeColumns.isActive('p')}$inner\n)'
        );
      case MemberFamilies.child:
        if (target is IdsTarget) {
          // A DIRECT child is one of the picked nodes (one json_each param).
          final ids = _push(jsonEncode(target.ids));
          return (
            'EXISTS (\n  SELECT 1 FROM ${_NodeColumns.table} c\n'
            '  WHERE c.${_NodeColumns.parentId} = n.${_NodeColumns.id} AND '
            '${_NodeColumns.isActive('c')} AND c.${_NodeColumns.id} IN '
            '(SELECT value FROM json_each($ids))\n)'
          );
        }
        if (target is SelfTarget) {
          return (
            'EXISTS (\n  SELECT 1 FROM ${_NodeColumns.table} c\n'
            '  WHERE c.${_NodeColumns.parentId} = n.${_NodeColumns.id} AND '
            '${_NodeColumns.isActive('c')} AND c.${_NodeColumns.id} = ${_selfId()}\n)'
          );
        }
        // DYNAMIC child: a direct child is one of the group's matches.
        final group = _groupSql((target as QueryTarget).root, 'm');
        final inner = group != null
            ? ' AND c.${_NodeColumns.id} IN (SELECT m.${_NodeColumns.id} '
                'FROM ${_NodeColumns.table} m WHERE ${_NodeColumns.isActive('m')} AND ($group))'
            : '';
        return (
          'EXISTS (\n  SELECT 1 FROM ${_NodeColumns.table} c\n'
          '  WHERE c.${_NodeColumns.parentId} = n.${_NodeColumns.id} AND '
          '${_NodeColumns.isActive('c')}$inner\n)'
        );
      case MemberFamilies.referencePath:
        if (target is IdsTarget) {
          return _referencePathSql(
            'SELECT value AS id FROM json_each(${_push(jsonEncode(target.ids))})',
            alias,
          );
        }
        if (target is SelfTarget) {
          // The rollup target IS the hosting page.
          return _referencePathSql(_selfAnchorSql(), alias);
        }
        // DYNAMIC referencePath: the rollup targets are the group's matches.
        final group = _groupSql((target as QueryTarget).root, 'm');
        final targets = group != null
            ? 'SELECT m.${_NodeColumns.id} FROM ${_NodeColumns.table} m '
                'WHERE ${_NodeColumns.isActive('m')} AND ($group)'
            : 'SELECT m.${_NodeColumns.id} FROM ${_NodeColumns.table} m '
                'WHERE (m.is_deleted = 1 OR m.is_archived = 1)';
        return _referencePathSql(targets, alias);
      case MemberFamilies.page:
        if (target is IdsTarget) {
          // The CONTAINING PAGE is one of the picked nodes (one json_each
          // param; the page id rides the correlated scalar subquery).
          final ids = _push(jsonEncode(target.ids));
          return (
            'EXISTS (\n  SELECT 1 FROM json_each($ids)\n'
            '  WHERE value = ${_containingPageIdSql(alias)}\n)'
          );
        }
        if (target is SelfTarget) {
          // The ids form over the one-element self list.
          final ids = _push(jsonEncode([_selfIdValue()]));
          return (
            'EXISTS (\n  SELECT 1 FROM json_each($ids)\n'
            '  WHERE value = ${_containingPageIdSql(alias)}\n)'
          );
        }
        // DYNAMIC page: the containing page is one of the group's matches.
        final group = _groupSql((target as QueryTarget).root, 'm');
        final inner = group != null
            ? ' AND page.${_NodeColumns.id} IN (SELECT m.${_NodeColumns.id} '
                'FROM ${_NodeColumns.table} m WHERE ${_NodeColumns.isActive('m')} AND ($group))'
            : '';
        return (
          'EXISTS (\n  SELECT 1 FROM ${_NodeColumns.table} page\n'
          '  WHERE page.${_NodeColumns.id} = ${_containingPageIdSql(alias)} AND '
          '${_NodeColumns.isActive('page')}$inner\n)'
        );
      case MemberFamilies.parentPath:
        String anc(String where) => (
          'EXISTS (\n  WITH RECURSIVE anc(id, depth) AS (\n'
          '    SELECT nd.${_NodeColumns.parentId}, 0 FROM ${_NodeColumns.table} nd '
          'WHERE nd.${_NodeColumns.id} = $alias.${_NodeColumns.id}\n'
          '    UNION ALL\n'
          '    SELECT nd.${_NodeColumns.parentId}, anc.depth + 1 '
          'FROM ${_NodeColumns.table} nd JOIN anc ON nd.${_NodeColumns.id} = anc.id\n'
          '    WHERE anc.id IS NOT NULL AND anc.depth < 64\n'
          '  )\n'
          '  $where\n)'
        );
        if (target is IdsTarget) {
          // Some STRICT ancestor is one of the picked nodes.
          final ids = _push(jsonEncode(target.ids));
          return anc(
            'SELECT 1 FROM anc JOIN json_each($ids) ON value = anc.id',
          );
        }
        if (target is SelfTarget) {
          // A strict ancestor IS the hosting page.
          return anc('SELECT 1 FROM anc WHERE anc.id = ${_selfId()}');
        }
        // DYNAMIC parentPath: some strict ancestor matches the group.
        final group = _groupSql((target as QueryTarget).root, 'm');
        final inner = group != null
            ? ' AND a.${_NodeColumns.id} IN (SELECT m.${_NodeColumns.id} '
                'FROM ${_NodeColumns.table} m WHERE ${_NodeColumns.isActive('m')} AND ($group))'
            : '';
        return anc(
          'SELECT 1 FROM anc JOIN ${_NodeColumns.table} a ON '
          'a.${_NodeColumns.id} = anc.id\n  WHERE ${_NodeColumns.isActive('a')}$inner',
        );
      case MemberFamilies.root:
        if (target is IdsTarget) {
          // The workspace-root ancestor is one of the picked nodes.
          final ids = _push(jsonEncode(target.ids));
          return (
            'EXISTS (\n  SELECT 1 FROM json_each($ids)\n'
            '  WHERE value = ${_rootIdSql(alias)}\n)'
          );
        }
        if (target is SelfTarget) {
          final ids = _push(jsonEncode([_selfIdValue()]));
          return (
            'EXISTS (\n  SELECT 1 FROM json_each($ids)\n'
            '  WHERE value = ${_rootIdSql(alias)}\n)'
          );
        }
        // DYNAMIC root: the workspace-root ancestor matches the group.
        final group = _groupSql((target as QueryTarget).root, 'm');
        final inner = group != null
            ? ' AND root.${_NodeColumns.id} IN (SELECT m.${_NodeColumns.id} '
                'FROM ${_NodeColumns.table} m WHERE ${_NodeColumns.isActive('m')} AND ($group))'
            : '';
        return (
          'EXISTS (\n  SELECT 1 FROM ${_NodeColumns.table} root\n'
          '  WHERE root.${_NodeColumns.id} = ${_rootIdSql(alias)} AND '
          '${_NodeColumns.isActive('root')}$inner\n)'
        );
      default:
        throw StateError("query compile: unknown member family '$family'");
    }
  }

  /// The family's emptiness (`exists`) read. `referencePath` and `root`
  /// have no emptiness semantics: the schema admits the shape, the compiler
  /// fails loud.
  String _memberExistsSql(String family, String alias) {
    switch (family) {
      case MemberFamilies.class_:
        // The class set is non-empty.
        return '(SELECT COUNT(*) FROM json_each($alias.${_NodeColumns.classIds})) > 0';
      case MemberFamilies.tags:
        return '(SELECT COUNT(*) FROM json_each($alias.${_NodeColumns.tagIds})) > 0';
      case MemberFamilies.links:
        // At least one inbound link — a direct edge targets the node.
        return 'EXISTS (SELECT 1 FROM edge WHERE target_id = $alias.${_NodeColumns.id})';
      case MemberFamilies.parent:
      case MemberFamilies.parentPath:
        // parentPath's emptiness reads "has a parent" (the parentSet bit).
        return '$alias.${_NodeColumns.parentId} IS NOT NULL';
      case MemberFamilies.child:
        // At least one direct child.
        return (
          'EXISTS (SELECT 1 FROM ${_NodeColumns.table} c '
          'WHERE c.${_NodeColumns.parentId} = $alias.${_NodeColumns.id} '
          'AND ${_NodeColumns.isActive('c')})'
        );
      case MemberFamilies.childPath:
        // At least one descendant (any depth below). The subtree CTE
        // anchors at the outer row (correlated anchor).
        final subtree = _subtreeSetSql('SELECT $alias.${_NodeColumns.id} AS id, 0 AS distance');
        return 'EXISTS (SELECT 1 FROM ($subtree) WHERE id != $alias.${_NodeColumns.id} LIMIT 1)';
      case MemberFamilies.page:
        // The row lives inside a page — the containing page differs from
        // the row itself.
        return '${_containingPageIdSql(alias)} != $alias.${_NodeColumns.id}';
      case MemberFamilies.referencePath:
      case MemberFamilies.root:
        throw StateError(
          "query compile: the '$family' family has no emptiness (exists) semantics",
        );
      default:
        throw StateError("query compile: unknown member family '$family'");
    }
  }

  // --- date / name / content / property / nodeField ------------------------------

  /// The date condition — the v1 created-/updated- ten types behind an
  /// explicit field axis. eq/neq are DAY-granular; gt/gte/lt/lte compare
  /// against the resolved instant; after/before are the inclusive
  /// day-boundary ops; between is the inclusive range; within the period.
  String _dateSql(DateCondition condition, String alias) {
    final column = condition.field == 'created'
        ? _NodeColumns.createdAt
        : _NodeColumns.updatedAt;
    switch (condition.op) {
      case DateOps.eq:
      case DateOps.neq:
      case DateOps.gt:
      case DateOps.gte:
      case DateOps.lt:
      case DateOps.lte:
        final timestamp = condition.timestamp;
        if (timestamp == null) {
          throw StateError(
            "query compile: date op '${condition.op}' requires a timestamp",
          );
        }
        return _dateCmpSql(column, condition.op, timestamp, alias);
      case DateOps.after:
        final timestamp = condition.timestamp;
        if (timestamp == null) {
          throw StateError("query compile: date op 'after' requires a timestamp");
        }
        return '$alias.$column >= ${_push(resolveTimestampPlaceholder(timestamp, 'after', _options))}';
      case DateOps.before:
        final timestamp = condition.timestamp;
        if (timestamp == null) {
          throw StateError("query compile: date op 'before' requires a timestamp");
        }
        return '$alias.$column <= ${_push(resolveTimestampPlaceholder(timestamp, 'before', _options))}';
      case DateOps.between:
        if (condition.from == null || condition.to == null) {
          throw StateError(
            "query compile: date op 'between' requires both bounds",
          );
        }
        return _dateBetweenSql(column, condition.from!, condition.to!, alias);
      case DateOps.within:
        final period = condition.period;
        if (period == null) {
          throw StateError("query compile: date op 'within' requires a period");
        }
        return _dateWithinSql(column, period, alias);
      default:
        throw StateError("query compile: unknown date op '${condition.op}'");
    }
  }

  /// A wire-field predicate compiles straight into the node-table column:
  /// exists = the IS NOT NULL probe; eq/neq compare the reference id. SQL
  /// NULL semantics hold — an unset field matches neither eq nor neq.
  String _nodeFieldSql(
    String field,
    String column,
    NodeFieldCondition condition,
    String alias,
  ) {
    if (condition.op == NodeFieldOps.exists) {
      return '$alias.$column IS NOT NULL';
    }
    final value = condition.value;
    if (value == null) {
      throw StateError(
        "query compile: $field op '${condition.op}' requires a non-null value",
      );
    }
    return '$alias.$column ${condition.op == NodeFieldOps.eq ? '=' : '!='} ${_push(value)}';
  }

  /// The title condition (title-is-content): the predicate runs over the
  /// flattened content text. exists is COALESCE'd two-valued so the
  /// not-wrap reads "is untitled"; contains LIKEs (ASCII
  /// case-insensitive); eq/neq compare exactly (case-sensitive BINARY).
  String _nameSql(NameCondition condition, String alias) {
    final title = titleSql(alias);
    if (condition.op == NameOps.exists) {
      return 'COALESCE(length($title), 0) > 0';
    }
    final value = condition.value;
    if (value == null) {
      throw StateError(
        "query compile: name op '${condition.op}' requires a non-null value",
      );
    }
    final param = _push(value);
    if (condition.op == NameOps.eq || condition.op == NameOps.neq) {
      return '$title ${condition.op == NameOps.eq ? '=' : '!='} $param';
    }
    return "$title LIKE '%' || $param || '%'";
  }

  String _contentSql(ContentCondition condition, String alias) {
    final value = condition.value;
    if (value == null) {
      throw StateError(
        "query compile: content op '${condition.op}' requires a non-null value",
      );
    }
    if (condition.op == ContentOps.fts) {
      final match = buildMatchExpression(value);
      if (match == null) {
        throw StateError(
          'query compile: content fts value produced no search terms '
          '"$value"',
        );
      }
      final param = _push(match);
      return (
        'EXISTS (\n  SELECT 1 FROM ${_NodeColumns.ftsDocidTable} d\n'
        '  JOIN ${_NodeColumns.ftsTable} s ON s.rowid = d.docid\n'
        '  WHERE d.node_id = $alias.${_NodeColumns.id} AND '
        '${_NodeColumns.ftsTable} MATCH $param\n)'
      );
    }
    final param = _push(value);
    // LIKE is ASCII case-insensitive; eq/neq test the plaintext for full
    // equality; starts/ends anchor the LIKE at one edge.
    if (condition.op == ContentOps.eq || condition.op == ContentOps.neq) {
      return (
        'EXISTS (\n  SELECT 1 FROM ${_NodeColumns.ftsDocidTable} d\n'
        '  JOIN ${_NodeColumns.ftsTable} s ON s.rowid = d.docid\n'
        '  WHERE d.node_id = $alias.${_NodeColumns.id} AND s.content '
        '${condition.op == ContentOps.eq ? '=' : '!='} $param\n)'
      );
    }
    final anchor = switch (condition.op) {
      ContentOps.starts => "$param || '%'",
      ContentOps.ends => "'%' || $param",
      _ => "'%' || $param || '%'",
    };
    return (
      'EXISTS (\n  SELECT 1 FROM ${_NodeColumns.ftsDocidTable} d\n'
      '  JOIN ${_NodeColumns.ftsTable} s ON s.rowid = d.docid\n'
      '  WHERE d.node_id = $alias.${_NodeColumns.id} AND s.content LIKE $anchor\n)'
    );
  }

  /// The property condition over the effective-values read model:
  /// tombstone-suppressed authored rows UNION derived binding defaults for
  /// nodes with no authored value at idx 0. eq/contains are value-level
  /// (any effective row matches); neq is "has at least one effective value
  /// different from v"; gt/gte/lt/lte compare numerically for JSON numbers,
  /// lexicographically for text. ISO-date bound values (YYYY-MM-DD) gain a
  /// second arm for the SCHEMA.md "Datetime" value shapes (the point/range
  /// date-node refs).
  String _propertySql(PropertyCondition condition, String alias) {
    const valueOps = [
      PropertyOps.eq,
      PropertyOps.neq,
      PropertyOps.contains,
      PropertyOps.gt,
      PropertyOps.gte,
      PropertyOps.lt,
      PropertyOps.lte,
    ];
    // The comparison bound rides the placeholder clock: a `{today}`-style
    // token resolves to the period start as a plain YYYY-MM-DD date.
    final rawBound = condition.value;
    final bound = rawBound is String &&
            condition.op != PropertyOps.contains &&
            condition.op != PropertyOps.exists
        ? resolveValuePlaceholder(rawBound, _options)
        : rawBound;
    if (valueOps.contains(condition.op) && (bound == null)) {
      throw StateError(
        "query compile: property op '${condition.op}' requires a non-null value",
      );
    }
    final includeDefaults = condition.includeDefaults ?? true;

    final (:ctes, :unions) = _effectiveValueCtes(condition.schemaId, includeDefaults);

    var predicate = '';
    final boundIso =
        bound is String && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(bound)
            ? bound
            : null;
    if (condition.op == PropertyOps.eq) {
      final scalar = "json_extract(value, '\$') = ${_push(bound)}";
      predicate = boundIso != null
          ? 'WHERE $scalar OR ${_dateRefSql('=', boundIso)}'
          : 'WHERE $scalar';
    } else if (condition.op == PropertyOps.neq) {
      if (boundIso != null) {
        final scalar = "json_extract(value, '\$') = ${_push(bound)}";
        predicate = 'WHERE NOT ($scalar OR ${_dateRefSql('=', boundIso)})';
      } else {
        predicate = "WHERE json_extract(value, '\$') != ${_push(bound)}";
      }
    } else if (condition.op == PropertyOps.contains) {
      final scalar =
          "CAST(json_extract(value, '\$') AS TEXT) LIKE '%' || ${_push(condition.value)} || '%'";
      predicate = boundIso != null
          ? 'WHERE $scalar OR ${_dateRefSql('=', boundIso)}'
          : 'WHERE $scalar';
    } else if (condition.op != PropertyOps.exists) {
      // gt/gte/lt/lte — plain comparison over the extracted scalar.
      final sqlOp = switch (condition.op) {
        PropertyOps.gt => '>',
        PropertyOps.gte => '>=',
        PropertyOps.lt => '<',
        PropertyOps.lte => '<=',
        _ => throw StateError('unreachable'),
      };
      if (boundIso != null) {
        // The scalar arm is gated to non-object values: a {"nodeId": …} ref
        // would otherwise compare as raw JSON text.
        final scalar =
            "json_type(value, '\$') != 'object' AND json_extract(value, '\$') $sqlOp ${_push(bound)}";
        predicate = 'WHERE ($scalar) OR ${_dateRefSql(sqlOp, boundIso)}';
      } else {
        predicate = "WHERE json_extract(value, '\$') $sqlOp ${_push(bound)}";
      }
    }

    return (
      '$alias.${_NodeColumns.id} IN (\n  $ctes,\n  effective AS (\n  $unions\n  )\n'
      '  SELECT node_id FROM effective\n  $predicate\n)'
    );
  }

  /// The effective-values CTE pair shared by every property-shaped
  /// condition. Params push in CTE text order (schema, then the two
  /// derived arms) — callers build the predicate AFTER this, so bound
  /// params always follow the CTE params.
  ({String ctes, String unions}) _effectiveValueCtes(
    String schemaId,
    bool includeDefaults,
  ) {
    final schemaParam = _push(schemaId);
    var ctes =
        'WITH authored AS (\n'
        '  SELECT pv.${_NodeColumns.propertyValueNodeId} AS node_id, pv.value AS value\n'
        '  FROM property_value pv\n'
        '  WHERE pv.property_schema_id = $schemaParam\n'
        '    AND ${visibleValuePredicate('pv')}\n'
        ')';
    var unions = 'SELECT node_id, value FROM authored';
    if (includeDefaults) {
      final bindingSchemaId = _push(schemaId);
      final authoredSchemaId = _push(schemaId);
      ctes += (
        ',\nderived AS (\n'
        '  SELECT wb.node_id AS node_id, wb.default_value AS value\n'
        '  FROM (\n'
        '    SELECT cms.${_NodeColumns.classMemberNodeId} AS node_id, ps.default_value,\n'
        '           ROW_NUMBER() OVER (\n'
        '             PARTITION BY cms.${_NodeColumns.classMemberNodeId}\n'
        '             ORDER BY cms.hlc_physical, cms.hlc_logical, cms.class_id\n'
        '           ) AS rn\n'
        '    FROM class_member_set cms\n'
        '    JOIN class_property cp ON cp.class_id = cms.class_id\n'
        '    JOIN property_schema ps ON ps.${_NodeColumns.propertySchemaId} = cp.property_schema_id\n'
        '    WHERE cms.present = 1 AND cp.property_schema_id = $bindingSchemaId AND cp.active = 1\n'
        '      AND ps.default_value IS NOT NULL\n'
        // Read-side option membership: a select-typed default whose value
        // is no longer among the schema's options derives nothing.
        '      AND (ps.type NOT IN (\'select\', \'multi_select\')\n'
        '        OR EXISTS (\n'
        '          SELECT 1 FROM json_each(ps.options) je\n'
        '          WHERE json_extract(je.value, \'\$.id\') = json_extract(ps.default_value, \'\$\')\n'
        '        ))\n'
        '  ) wb\n'
        '  WHERE wb.rn = 1\n'
        '    AND NOT EXISTS (\n'
        '      SELECT 1 FROM property_value pv\n'
        '      WHERE pv.${_NodeColumns.propertyValueNodeId} = wb.node_id AND '
        'pv.property_schema_id = $authoredSchemaId\n'
        '        AND pv.idx = 0\n'
        '        AND ${visibleValuePredicate('pv')}\n'
        '    )\n'
        ')'
      );
      unions += '\nUNION ALL\nSELECT node_id, value FROM derived';
    }
    return (ctes: ctes, unions: unions);
  }

  /// The class-level parentlessRole demote, flattened for SQL consumers:
  /// true when the row's class set includes a class that EFFECTIVELY
  /// carries parentlessRole "block" — its own flag or an
  /// extends-ancestor's, via the self-inclusive class_hierarchy closure.
  /// Delta F4: the class config reads `class_cache` (classes keep their
  /// config in the registry locally).
  String _hasParentlessBlockClassSql(String alias) => (
    'EXISTS (SELECT 1 FROM class_hierarchy ch\n'
    '  JOIN class_cache c ON c.uuid = ch.ancestor_id\n'
    '  WHERE ch.class_id IN (SELECT value FROM json_each($alias.${_NodeColumns.classIds}))\n'
    "    AND c.parentless_role = 'block')"
  );

  /// The CONTAINING PAGE id as a correlated scalar subquery (references the
  /// outer row [alias]): the nearest self-or-ancestor rendering with
  /// document chrome, plus the parentlessRole demote. No params.
  String _containingPageIdSql(String alias) => (
    '(SELECT pg.${_NodeColumns.id} FROM ${_NodeColumns.table} pg JOIN (\n'
    '  WITH RECURSIVE up(id, depth) AS (\n'
    '    SELECT $alias.${_NodeColumns.id}, 0\n'
    '    UNION ALL\n'
    '    SELECT nd.${_NodeColumns.parentId}, up.depth + 1 FROM ${_NodeColumns.table} nd '
    'JOIN up ON nd.${_NodeColumns.id} = up.id\n'
    '    WHERE nd.${_NodeColumns.parentId} IS NOT NULL AND up.depth < 64\n'
    '  ) SELECT id, depth FROM up\n'
    ') ch ON ch.id = pg.${_NodeColumns.id}\n'
    'WHERE (pg.${_NodeColumns.isClass} = 1 OR pg.${_NodeColumns.parentId} IS NULL '
    'OR pg.${_NodeColumns.isEmbedded} = 0)\n'
    '  AND (pg.${_NodeColumns.parentId} IS NOT NULL OR '
    'NOT ${_hasParentlessBlockClassSql('pg')})\n'
    'ORDER BY ch.depth LIMIT 1)'
  );

  /// The ROOT ancestor id (the workspace-root child) as a correlated
  /// scalar subquery. No params.
  String _rootIdSql(String alias) => (
    '(SELECT pg.${_NodeColumns.id} FROM ${_NodeColumns.table} pg WHERE pg.${_NodeColumns.id} = (\n'
    '  WITH RECURSIVE up(id) AS (\n'
    '    SELECT $alias.${_NodeColumns.id}\n'
    '    UNION ALL\n'
    '    SELECT nd.${_NodeColumns.parentId} FROM ${_NodeColumns.table} nd JOIN up '
    'ON nd.${_NodeColumns.id} = up.id\n'
    '    WHERE nd.${_NodeColumns.parentId} IS NOT NULL\n'
    '  )\n'
    '  SELECT up.id FROM up JOIN ${_NodeColumns.table} nd ON nd.${_NodeColumns.id} = up.id\n'
    '  WHERE nd.${_NodeColumns.parentId} IS NULL LIMIT 1\n))'
  );

  /// The referencePath family rollup over a target set: a row matches when
  /// the row OR any of its ancestors links to a target, or a target is a
  /// STRICT ancestor of the row. The ancestor chain CTE is seeded at the
  /// row itself so the edge arm includes the row's own outbound links.
  String _referencePathSql(String targetsSql, String alias) => (
    'EXISTS (\n  WITH RECURSIVE anc(id, depth) AS (\n'
    '    SELECT $alias.${_NodeColumns.id}, 0\n'
    '    UNION ALL\n'
    '    SELECT nd.${_NodeColumns.parentId}, anc.depth + 1 FROM ${_NodeColumns.table} nd '
    'JOIN anc ON nd.${_NodeColumns.id} = anc.id\n'
    '    WHERE anc.id IS NOT NULL AND anc.depth < 64\n'
    '  )\n'
    '  SELECT 1 FROM ($targetsSql) tv\n'
    "  WHERE tv.id IN (SELECT id FROM anc WHERE id != $alias.${_NodeColumns.id})\n"
    '     OR EXISTS (\n       SELECT 1 FROM edge e\n'
    '       WHERE e.target_id = tv.id AND e.source_id IN (SELECT id FROM anc)\n     ))'
  );

  /// The day-granular equality + the instant comparisons.
  String _dateCmpSql(String column, String op, String timestamp, String alias) {
    if (op == DateOps.eq || op == DateOps.neq) {
      final day = resolveDayBounds(timestamp, _options);
      final start = _push(day.from);
      final end = _push(day.to);
      final match = '$alias.$column >= $start AND $alias.$column <= $end';
      return op == DateOps.eq ? match : 'NOT ($match)';
    }
    final direction = op == DateOps.gt || op == DateOps.gte ? 'after' : 'before';
    final sqlOp = switch (op) {
      DateOps.gt => '>',
      DateOps.gte => '>=',
      DateOps.lt => '<',
      DateOps.lte => '<=',
      _ => throw StateError('unreachable'),
    };
    final bound = _push(resolveTimestampPlaceholder(timestamp, direction, _options));
    return '$alias.$column $sqlOp $bound';
  }

  /// The inclusive date range: from day-start to to day-end.
  String _dateBetweenSql(String column, String from, String to, String alias) {
    final fromBound = _push(resolveTimestampPlaceholder(from, 'after', _options));
    final toBound = _push(resolveTimestampPlaceholder(to, 'before', _options));
    return '$alias.$column >= $fromBound AND $alias.$column <= $toBound';
  }

  /// The relative-period arm: the resolved period bounds against the column.
  String _dateWithinSql(String column, String period, String alias) {
    final bounds = resolvePeriodBounds(period, _options);
    final from = _push(bounds.from);
    final to = _push(bounds.to);
    return '$alias.$column >= $from AND $alias.$column <= $to';
  }

  /// property op between: the effective value inside the inclusive
  /// [from, to]. ISO bounds also speak to date-node refs.
  String _propertyRangeSql(
    String schemaId,
    Object? from,
    Object? to,
    String alias,
  ) {
    if (from == null || to == null) {
      throw StateError("query compile: property op 'between' requires both bounds");
    }
    final (:ctes, :unions) = _effectiveValueCtes(schemaId, true);
    final fromIso = from is String && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(from)
        ? from
        : null;
    final toIso = to is String && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(to)
        ? to
        : null;
    final fromParam = _push(from);
    final toParam = _push(to);
    var predicate =
        "WHERE json_extract(value, '\$') >= $fromParam AND json_extract(value, '\$') <= $toParam";
    if (fromIso != null && toIso != null) {
      // ISO bounds also speak to date-node refs; the scalar arm gates
      // non-object values (raw JSON text would sort wrong).
      final scalar =
          "json_type(value, '\$') != 'object' AND ${predicate.substring('WHERE '.length)}";
      predicate =
          'WHERE ($scalar) OR (${_dateRefSql('>=', fromIso)} AND ${_dateRefSql('<=', toIso)})';
    }
    return (
      '$alias.${_NodeColumns.id} IN (\n  $ctes,\n  effective AS (\n  $unions\n  )\n'
      '  SELECT node_id FROM effective\n  $predicate\n)'
    );
  }

  /// property op within: the effective DATE-valued property inside the
  /// period.
  String _propertyWithinSql(String? schemaId, String? period, String alias) {
    if (period == null) {
      throw StateError("query compile: property op 'within' requires a period");
    }
    final (:ctes, :unions) = _effectiveValueCtes(schemaId!, true);
    final token = '{$period}';
    final fromIso = placeholderStartDate(token, _options);
    final toIso = placeholderEndDate(token, _options);
    if (fromIso == null || toIso == null) {
      throw StateError('query compile: unknown property period "$period"');
    }
    final fromParam = _push(fromIso);
    final toParam = _push(toIso);
    final scalar =
        "json_type(value, '\$') != 'object' AND json_extract(value, '\$') >= $fromParam "
        "AND json_extract(value, '\$') <= $toParam";
    final predicate =
        'WHERE ($scalar) OR (${_dateRefSql('>=', fromIso)} AND ${_dateRefSql('<=', toIso)})';
    return (
      '$alias.${_NodeColumns.id} IN (\n  $ctes,\n  effective AS (\n  $unions\n  )\n'
      '  SELECT node_id FROM effective\n  $predicate\n)'
    );
  }

  /// Date-ref match arms over the deterministic date-node ids carried in
  /// the datetime value union: the POINT arm reads the top-level
  /// `{"nodeId": …}`; the RANGE arm reads `$.start.nodeId`/`$.end.nodeId`,
  /// gated on the value actually carrying a start/end key. Params are
  /// pushed in arm order — point arm first, then the range arm.
  String _dateRefSql(String op, String iso) {
    final compact = iso.replaceAll('-', '');
    const nodeId = "json_extract(value, '\$.nodeId')";
    final marker = 'substr($nodeId, 22, 2)';
    const startId = "json_extract(value, '\$.start.nodeId')";
    final startMarker = 'substr($startId, 22, 2)';
    const endId = "json_extract(value, '\$.end.nodeId')";
    final endMarker = 'substr($endId, 22, 2)';
    const rangeGate =
        "(json_type(value, '\$.start') IS NOT NULL OR json_type(value, '\$.end') IS NOT NULL)";
    if (op == '=') {
      final pointArm =
          '($marker = \'dd\' AND substr($nodeId, 25, 8) = ${_push(compact)} '
          'OR $marker = \'aa\' AND ${_push(compact.substring(0, 6))} = substr($nodeId, 25, 6) '
          'OR $marker = \'bb\' AND ${_push(compact.substring(0, 4))} = substr($nodeId, 25, 4))';
      final startPayload = _push('${compact}0000');
      final endDay = _push(compact);
      final endMonth = _push(compact.substring(0, 6));
      final endYear = _push(compact.substring(0, 4));
      final rangeArm =
          '$rangeGate '
          'AND ($startId IS NULL OR $startMarker IN (\'dd\', \'aa\', \'bb\') AND substr($startId, 25) <= $startPayload) '
          'AND ($endId IS NULL OR ($endMarker = \'dd\' AND substr($endId, 25, 8) >= $endDay '
          'OR $endMarker = \'aa\' AND substr($endId, 25, 6) >= $endMonth '
          'OR $endMarker = \'bb\' AND substr($endId, 25, 4) >= $endYear))';
      return '($pointArm OR $rangeArm)';
    }
    final pointArm =
        '($marker IN (\'dd\', \'aa\', \'bb\') AND substr($nodeId, 25) $op ${_push('${compact}0000')})';
    final rangeArm =
        '$rangeGate AND $startMarker IN (\'dd\', \'aa\', \'bb\') '
        'AND substr($startId, 25) $op ${_push('${compact}0000')}';
    return '($pointArm OR ($rangeArm))';
  }

  // --- sort ----------------------------------------------------------------------

  String _orderSql(List<SortSpec>? sort) {
    final terms = <String>[];
    for (final spec in sort ?? const <SortSpec>[]) {
      final column = _sortColumnFor(spec.field);
      final dir = spec.dir == 'desc' ? 'DESC' : 'ASC';
      final ordered = column.nocase
          ? '${column.column} COLLATE NOCASE $dir'
          : '${column.column} $dir';
      // NULLs last on nullable columns (IS NULL is portable across
      // FTS4/FTS5-era SQLite builds).
      if (column.nullable) {
        terms.add('${column.column} IS NULL');
      }
      terms.add(ordered);
    }
    terms.add('n.${_NodeColumns.id} ASC');
    return terms.join(', ');
  }
}
