/// The graph-view topology model — a minimal port of the web store's
/// `graph.ts` contract (`packages/store/src/graph.ts`): the node set is
/// classes + standalone (parentless or non-embedded) pages ONLY — blocks
/// never render as graph nodes — and the edge families ride the local
/// derived `edge` index (mention / property / tag) plus the structural
/// parent family. The semantic/temporal co-occurrence projections and the
/// nearest-node-set-ancestor rollup stay web-only: this model keeps the
/// simple both-endpoints contract (an edge renders only when both
/// endpoints are node-set members) and collapses parallel same-family
/// edges into one weighted edge.
library;

/// The typed edge families the graph knows (the web `GraphEdgeKind`
/// contract, restricted to the families the local edge index + parentage
/// derive).
enum GraphEdgeKind { mention, property, tag, parent }

/// A vertex: an id, a display label, the class flag, and the node's own
/// color/icon tokens (group coloring overrides at render time).
class GraphNode {
  const GraphNode({
    required this.id,
    required this.label,
    required this.isClass,
    this.color,
    this.icon,
  });

  final String id;
  final String label;
  final bool isClass;

  /// The node's own color — a preset token or `#RRGGBB` (never resolved).
  final String? color;
  final String? icon;
}

/// An edge between two node-set members; [weight] is the collapsed
/// multiplicity (parallel same-family rows between the same pair).
class GraphEdge {
  const GraphEdge({
    required this.source,
    required this.target,
    required this.kind,
    this.weight = 1,
  });

  final String source;
  final String target;
  final GraphEdgeKind kind;
  final int weight;

  GraphEdge withWeight(int weight) =>
      GraphEdge(source: source, target: target, kind: kind, weight: weight);
}

/// The immutable derived topology: deterministically sorted nodes and
/// edges, with the incident-edge degree per node.
class GraphTopology {
  GraphTopology._({
    required this.nodes,
    required this.edges,
    required this._degrees,
  });

  /// Nodes sorted by id (input order never leaks into consumers).
  final List<GraphNode> nodes;

  /// Edges sorted by (source, target, kind); self-loops, unknown
  /// endpoints, and parallel duplicates are already resolved.
  final List<GraphEdge> edges;

  final Map<String, int> _degrees;

  /// The incident collapsed-edge count for [id] (0 when absent).
  int degreeOf(String id) => _degrees[id] ?? 0;

  /// True when [id] is a node-set member.
  bool contains(String id) => _degrees.containsKey(id);

  /// Builds the canonical topology from raw node/edge candidates:
  /// dedupes nodes by id, drops self-loops and edges whose endpoints are
  /// not both node-set members, and collapses parallel same-family edges
  /// (first-seen direction wins, weight accumulates).
  factory GraphTopology.build(
    Iterable<GraphNode> nodes,
    Iterable<GraphEdge> edges,
  ) {
    final byId = <String, GraphNode>{};
    for (final node in nodes) {
      byId.putIfAbsent(node.id, () => node);
    }
    final orderedNodes = byId.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));

    final collapsed = <String, GraphEdge>{};
    for (final edge in edges) {
      if (edge.source == edge.target) continue;
      if (!byId.containsKey(edge.source) || !byId.containsKey(edge.target)) {
        continue;
      }
      final key = '${edge.source}${edge.target}${edge.kind.name}';
      final existing = collapsed[key];
      if (existing == null) {
        collapsed[key] = edge;
      } else {
        collapsed[key] = existing.withWeight(existing.weight + edge.weight);
      }
    }
    final orderedEdges = collapsed.values.toList()
      ..sort((a, b) {
        final source = a.source.compareTo(b.source);
        if (source != 0) return source;
        final target = a.target.compareTo(b.target);
        if (target != 0) return target;
        return a.kind.name.compareTo(b.kind.name);
      });

    final degrees = <String, int>{for (final n in orderedNodes) n.id: 0};
    for (final edge in orderedEdges) {
      degrees[edge.source] = degrees[edge.source]! + 1;
      degrees[edge.target] = degrees[edge.target]! + 1;
    }

    return GraphTopology._(
      nodes: orderedNodes,
      edges: orderedEdges,
      degrees: degrees,
    );
  }
}
