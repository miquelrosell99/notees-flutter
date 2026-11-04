import 'package:notees/core/utils/node_display_name.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/models/node.dart';
import 'package:notees/domain/graph/graph_model.dart';

import 'node_cache_repository.dart';

/// The graph topology's read site: one derived projection over the local
/// store, a minimal port of the web store's `graph.ts` contract. Pages ride
/// the Page-role predicate the list surfaces use (`parent_uuid IS NULL OR
/// is_embedded = 0`, active, non-journal), classes ride `class_cache`, and
/// the typed edges come from the derived `edge` index (mention / property /
/// tag — typed links stay out, their target resolution is deferred by
/// design) plus the structural parent family between node-set members. An
/// edge endpoint outside the node set rolls up to its nearest node-set
/// ancestor — the backlinksWithRollup semantics the web projection uses —
/// because a standalone page's own content is text-only by the flatten
/// contract, so the surviving mentions live on embedded blocks. Read-only
/// and offline-local: no server reads.
class GraphRepository {
  GraphRepository(this._database, {NodeCacheRepository? cache})
      : _cache = cache ?? NodeCacheRepository(_database);

  final AppDatabase _database;
  final NodeCacheRepository _cache;

  static const _untitled = 'Untitled';

  /// Cycle-guard cap for the ancestor rollup walk (parent chains are
  /// user-built and short; the cap bounds pathological data).
  static const _rollupDepthCap = 32;

  Future<GraphTopology> loadTopology() async {
    final db = await _database.database;

    final pageRows = await db.query(
      'node_cache',
      columns: const ['uuid'],
      where:
          'is_class = 0 AND is_deleted = 0 AND is_archived = 0 AND '
          '(parent_uuid IS NULL OR is_embedded = 0) AND is_daily = 0 AND '
          'is_monthly = 0 AND is_yearly = 0 AND uuid NOT IN '
          '(SELECT uuid FROM class_cache WHERE active = 1)',
    );
    final pageUuids = [
      for (final row in pageRows) row['uuid'] as String,
    ];
    final pages = await _cache.getByUuids(pageUuids);
    final classes = await _cache.getClasses();

    final nodes = <GraphNode>[
      for (final node in pages) _nodeFromPage(node),
      for (final klass in classes) _nodeFromClass(klass),
    ];
    final nodeIds = {for (final node in nodes) node.id};

    final parentOf = <String, String?>{};
    final parentRows = await db.query(
      'node_cache',
      columns: const ['uuid', 'parent_uuid'],
    );
    for (final row in parentRows) {
      parentOf[row['uuid'] as String] = row['parent_uuid'] as String?;
    }

    String? rollup(String id) {
      var current = id;
      for (var depth = 0; depth < _rollupDepthCap; depth++) {
        if (nodeIds.contains(current)) return current;
        final parent = parentOf[current];
        if (parent == null || parent == current) return null;
        current = parent;
      }
      return null;
    }

    final edges = <GraphEdge>[
      ...await _indexEdges(db, rollup),
      ..._parentEdges(pages, nodeIds),
    ];

    return GraphTopology.build(nodes, edges);
  }

  GraphNode _nodeFromPage(Node node) => GraphNode(
        id: node.uuid,
        label: node.displayName.isEmpty ? _untitled : node.displayName,
        isClass: false,
        color: node.color,
        icon: node.icon,
      );

  GraphNode _nodeFromClass(Node node) {
    final label = deriveDisplayName(node.name);
    return GraphNode(
      id: node.uuid,
      label: label.isEmpty ? _untitled : label,
      isClass: true,
      color: node.color,
      icon: node.icon,
    );
  }

  /// The content/property/tag families of the derived `edge` index, one
  /// row per (source, target, type) with the collapsed multiplicity. Both
  /// endpoints roll up to their nearest node-set ancestor via [rollup];
  /// edges with no node-set ancestor on either side drop.
  Future<List<GraphEdge>> _indexEdges(
    dynamic db,
    String? Function(String) rollup,
  ) async {
    final rows = await db.rawQuery(
      'SELECT source_id, target_id, type, COUNT(*) AS weight FROM edge '
      "WHERE target_id IS NOT NULL AND type IN ('mention', 'property', 'tag') "
      'GROUP BY source_id, target_id, type',
    );
    final edges = <GraphEdge>[];
    for (final row in rows) {
      final kind = _kindFor(row['type'] as String);
      if (kind == null) continue;
      final source = rollup(row['source_id'] as String);
      final target = rollup(row['target_id'] as String);
      if (source == null || target == null) continue;
      edges.add(GraphEdge(
        source: source,
        target: target,
        kind: kind,
        weight: (row['weight'] as int?) ?? 1,
      ));
    }
    return edges;
  }

  GraphEdgeKind? _kindFor(String type) => switch (type) {
        'mention' => GraphEdgeKind.mention,
        'property' => GraphEdgeKind.property,
        'tag' => GraphEdgeKind.tag,
        _ => null,
      };

  /// The structural family: a node-set page whose parent is also a
  /// node-set member links to that parent (classes are roots by the
  /// schema's CHECK, so parents are always pages here).
  List<GraphEdge> _parentEdges(List<Node> pages, Set<String> nodeIds) => [
        for (final node in pages)
          if (node.parentUuid != null && nodeIds.contains(node.parentUuid))
            GraphEdge(
              source: node.parentUuid!,
              target: node.uuid,
              kind: GraphEdgeKind.parent,
            ),
      ];
}
