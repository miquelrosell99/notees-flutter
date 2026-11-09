/// Execution helpers over the local derived store — the port of
/// `packages/query/src/execute.ts` over sqflite's [Database]. Deliberately
/// structural: any open sqflite database whose derived schema matches
/// `AppDatabase` v42+ works.
library;

import 'package:sqflite_sqlcipher/sqflite.dart';

import 'query_ast.dart';
import 'query_compiler.dart';
import 'query_placeholders.dart';

/// The plain-query result: node ids in the deterministic compiler order,
/// plus the full `n.*` rows (plus `distance` for subtree/linkedTo scopes).
class QueryResult {
  const QueryResult({required this.ids, required this.rows});

  final List<String> ids;
  final List<Map<String, Object?>> rows;
}

/// The grouped grid: the compiler's deterministic column order, one row
/// per group aligned with [columns].
class AggregateResult {
  const AggregateResult({required this.columns, required this.rows});

  final List<String> columns;
  final List<List<Object?>> rows;
}

/// Compiles ASTs against the local derived schema and runs them.
final class QueryRunner {
  QueryRunner(this._db);

  final Database _db;

  /// Run a plain query: ids + full rows. Aggregation ASTs are rejected —
  /// execute them with [runAggregate].
  Future<QueryResult> run(QueryAst ast, [CompileOptions options = const CompileOptions()]) async {
    if (ast.aggregation != null) {
      throw StateError(
        'query run: AST carries an aggregation — execute it with '
        'runAggregate instead',
      );
    }
    final compiled = compile(ast, options);
    final rows = await _db.rawQuery(compiled.sql, compiled.params);
    return QueryResult(
      ids: [for (final row in rows) '${row[_idColumn]}'],
      rows: rows,
    );
  }

  /// Aggregation execution: the grouped grid.
  Future<AggregateResult> runAggregate(
    QueryAst ast, [
    CompileOptions options = const CompileOptions(),
  ]) async {
    final compiled = compileAggregate(ast, options);
    final raw = await _db.rawQuery(compiled.sql, compiled.params);
    return AggregateResult(
      columns: compiled.columns,
      rows: [
        for (final row in raw)
          [for (final column in compiled.columns) row[column]],
      ],
    );
  }

  /// The number of nodes matching the query (COUNT over the compiled
  /// select).
  Future<int> count(QueryAst ast, [CompileOptions options = const CompileOptions()]) async {
    final compiled = compile(ast, options);
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS count FROM (${compiled.sql})',
      compiled.params,
    );
    return (rows.first['count'] as int?) ?? 0;
  }

  /// Convenience: does this one node match the query? (The wrapped select's
  /// id column is the local `uuid` rename, delta F1.)
  Future<bool> matches(
    String nodeId,
    QueryAst ast, [
    CompileOptions options = const CompileOptions(),
  ]) async {
    final compiled = compile(ast, options);
    final rows = await _db.rawQuery(
      'SELECT 1 FROM (${compiled.sql}) q WHERE q.$_idColumn = ?',
      [...compiled.params, nodeId],
    );
    return rows.isNotEmpty;
  }

  static const _idColumn = 'uuid';
}
