import 'dart:convert';

import '../../core/utils/node_display_name.dart';
import '../../data/local/app_database.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_cache_repository.dart';
import '../../domain/query/builder_facts.dart';
import '../../domain/query/query_ast.dart';
import '../../domain/query/query_dsl.dart' as query_dsl;
import '../../domain/query/query_placeholders.dart';
import '../../domain/query/query_runner.dart';

/// The query surface's run-site seam: owns the local derived store and the
/// query runner, and maps result ids back to node rows. Injected into the
/// search feature via Provider (the repo's Provider + ChangeNotifier idiom);
/// the search screen never touches the compiler directly.
class QueryService {
  QueryService({AppDatabase? database, NodeCacheRepository? cache})
      : _database = database ?? AppDatabase(),
        _cache = cache ?? NodeCacheRepository(AppDatabase());

  final AppDatabase _database;
  final NodeCacheRepository _cache;
  QueryRunner? _runner;

  Future<QueryRunner> get _queryRunner async =>
      _runner ??= QueryRunner(await _database.database);

  /// Runs [ast] locally, returning the matching node rows in the
  /// compiler's deterministic order (missing rows — purged between the
  /// query and the fetch — drop out).
  Future<List<Node>> runNodes(
    QueryAst ast, {
    CompileOptions options = const CompileOptions(),
  }) async {
    final result = await (await _queryRunner).run(ast, options);
    if (result.ids.isEmpty) return const [];
    final byId = <String, Node>{
      for (final node in await _cache.getByUuids(result.ids)) node.uuid: node,
    };
    return [
      for (final id in result.ids)
        if (byId.containsKey(id)) byId[id]!,
    ];
  }

  /// The number of nodes matching [ast] (COUNT over the compiled select).
  Future<int> count(
    QueryAst ast, {
    CompileOptions options = const CompileOptions(),
  }) async =>
      (await _queryRunner).count(ast, options);

  /// Runs an aggregation [ast] locally, returning the grouped grid (the
  /// query-node section's aggregate tab).
  Future<AggregateResult> runAggregate(
    QueryAst ast, {
    CompileOptions options = const CompileOptions(),
  }) async =>
      (await _queryRunner).runAggregate(ast, options);

  /// The builder's picker-source facts (the web `builderFacts.ts` useMemo
  /// twin, derived per open): the active classes plus the bound properties
  /// across all class bindings, enriched with each schema row's select
  /// options and node-typed target filter.
  Future<BuilderFacts> buildFacts() async {
    final db = await _database.database;
    final classRows = await db.query(
      'class_cache',
      columns: ['uuid', 'name'],
      where: 'active = 1',
      orderBy: 'name',
    );
    final bindingRows = await db.query(
      'class_property',
      columns: ['class_id', 'property_schema_id'],
      where: 'active = 1',
    );
    final schemaRows = await db.query(
      'property_schema',
      columns: ['uuid', 'name', 'type', 'options', 'class_filter_uuids'],
      where: 'active = 1',
    );

    final schemasById = <String, Map<String, dynamic>>{
      for (final row in schemaRows) row['uuid'] as String: row,
    };
    final boundIds = <String>{};
    for (final row in bindingRows) {
      boundIds.add(row['property_schema_id'] as String);
    }

    return BuilderFacts(
      classes: [
        for (final row in classRows)
          BuilderClassInfo(
            id: row['uuid'] as String,
            name: deriveDisplayName(row['name'] as String? ?? ''),
          ),
      ],
      boundProperties: [
        for (final schemaId in boundIds)
          if (schemasById[schemaId] case final schema?)
            BuilderPropertyInfo(
              id: schemaId,
              name: schema['name'] as String? ?? '',
              type: schema['type'] as String? ?? 'text',
              options: _schemaOptions(schema['options']),
              targetClassFilter: _schemaClassFilter(schema['class_filter_uuids']),
            ),
      ],
    );
  }

  List<BuilderPropertyOption>? _schemaOptions(Object? raw) {
    try {
      final decoded = jsonDecode(raw as String? ?? '[]') as List<dynamic>;
      if (decoded.isEmpty) return null;
      return [
        for (final option in decoded.cast<Map<String, dynamic>>())
          BuilderPropertyOption(
            id: (option['selection_line_uuid'] as String?) ??
                (option['uuid'] as String? ?? ''),
            label: option['name'] as String? ?? '',
          ),
      ];
    } catch (_) {
      return null;
    }
  }

  List<String>? _schemaClassFilter(Object? raw) {
    try {
      final decoded = jsonDecode(raw as String? ?? '[]') as List<dynamic>;
      if (decoded.isEmpty) return null;
      return decoded.cast<String>();
    } catch (_) {
      return null;
    }
  }

  /// Parses a query-language string into the AST, resolving class/schema/
  /// node names against the local derived store (the web `/resolve` twin's
  /// policy: case-insensitive EXACT matches — classes and property schemas
  /// by their registry name, nodes by the derived display name, the
  /// flattened content text). Syntax errors and unresolvable names throw
  /// [query_dsl.QueryLanguageError] — the DSL fails loud, never silently
  /// degrades to a text search.
  Future<QueryAst> parseQueryLanguage(String text) async {
    final db = await _database.database;
    final classRows = await db.query(
      'class_cache',
      columns: ['uuid', 'name'],
      where: 'active = 1',
    );
    final schemaRows = await db.query(
      'property_schema',
      columns: ['uuid', 'name'],
      where: 'active = 1',
    );
    final nodeRows = await db.rawQuery(
      'SELECT uuid, name FROM node_cache '
      'WHERE is_deleted = 0 AND is_archived = 0 ORDER BY uuid',
    );

    final classes = <String, String>{};
    for (final row in classRows) {
      final name = row['name'] as String?;
      if (name != null) classes.putIfAbsent(name.toLowerCase(), () => row['uuid'] as String);
    }
    final schemas = <String, String>{};
    final schemaNames = <String>[];
    for (final row in schemaRows) {
      final name = row['name'] as String?;
      if (name != null) {
        schemas.putIfAbsent(name.toLowerCase(), () => row['uuid'] as String);
        schemaNames.add(name);
      }
    }
    final nodes = <String, String>{};
    for (final row in nodeRows) {
      final name = row['name'] as String?;
      if (name == null) continue;
      final displayName = deriveDisplayName(name).toLowerCase();
      if (displayName.isNotEmpty) {
        nodes.putIfAbsent(displayName, () => row['uuid'] as String);
      }
    }

    return query_dsl.parseQueryLanguage(
      text,
      query_dsl.ParseQueryLanguageOptions(
        resolvers: query_dsl.QueryLanguageResolvers(
          resolveClass: (name) => classes[name.toLowerCase()],
          resolvePropertySchema: (name) => schemas[name.toLowerCase()],
          resolveNode: (name) => nodes[name.toLowerCase()],
        ),
        knownFields: schemaNames,
      ),
    );
  }
}
