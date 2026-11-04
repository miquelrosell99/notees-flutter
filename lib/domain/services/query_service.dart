import '../../data/local/app_database.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_cache_repository.dart';
import '../../domain/query/query_ast.dart';
import '../../domain/query/query_compiler.dart';
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
}
