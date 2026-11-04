import 'package:flutter_test/flutter_test.dart';
import 'package:notees/domain/graph/graph_layout.dart';
import 'package:notees/domain/graph/graph_model.dart';

/// The force-layout pins: the layout is a PURE function over the topology —
/// same input + same seed → byte-identical positions (no run-to-run drift),
/// input ORDER never leaks in (the topology sorts), disconnected components
/// settle into bounded space, and the topology itself is never mutated.
void main() {
  GraphNode node(String id, {bool isClass = false}) =>
      GraphNode(id: id, label: id, isClass: isClass);

  GraphTopology topology(List<GraphNode> nodes, List<GraphEdge> edges) =>
      GraphTopology.build(nodes, edges);

  GraphTopology chain(int count) => topology(
        [for (var i = 0; i < count; i++) node('n${i.toString().padLeft(2, '0')}')],
        [
          for (var i = 1; i < count; i++)
            GraphEdge(
              source: 'n${(i - 1).toString().padLeft(2, '0')}',
              target: 'n${i.toString().padLeft(2, '0')}',
              kind: GraphEdgeKind.mention,
            ),
        ],
      );

  group('computeForceLayout determinism', () {
    test('same seed → identical positions, run to run', () {
      final top = chain(12);
      final a = computeForceLayout(top);
      final b = computeForceLayout(top);
      expect(a.keys, b.keys);
      for (final id in a.keys) {
        expect(a[id]!.x, b[id]!.x);
        expect(a[id]!.y, b[id]!.y);
      }
    });

    test('input order never leaks in (shuffled build, same layout)', () {
      final nodes = [for (var i = 0; i < 10; i++) node('n${i.toString().padLeft(2, '0')}')];
      final edges = [
        for (var i = 1; i < 10; i++)
          GraphEdge(
            source: 'n${(i - 1).toString().padLeft(2, '0')}',
            target: 'n${i.toString().padLeft(2, '0')}',
            kind: GraphEdgeKind.mention,
          ),
      ];
      final forward = computeForceLayout(GraphTopology.build(nodes, edges));
      final shuffled = computeForceLayout(GraphTopology.build(
        nodes.reversed.toList(),
        edges.reversed.toList(),
      ));
      for (final id in forward.keys) {
        expect(shuffled[id]!.x, forward[id]!.x);
        expect(shuffled[id]!.y, forward[id]!.y);
      }
    });

    test('a different seed moves at least one node', () {
      final top = chain(16);
      final a = computeForceLayout(top, seed: 1);
      final b = computeForceLayout(top, seed: 7);
      var differs = false;
      for (final id in a.keys) {
        if (a[id]!.x != b[id]!.x || a[id]!.y != b[id]!.y) differs = true;
      }
      expect(differs, isTrue);
    });

    test('every position is finite and bounded', () {
      final top = chain(40);
      final layout = computeForceLayout(top);
      for (final point in layout.values) {
        expect(point.x.isFinite, isTrue);
        expect(point.y.isFinite, isTrue);
        expect(point.distance, lessThan(1e6));
      }
    });

    test('the topology is never mutated', () {
      final top = chain(8);
      final nodesBefore = top.nodes.map((n) => n.id).toList();
      final edgesBefore = top.edges.map((e) => '${e.source}>${e.target}').toList();
      computeForceLayout(top);
      expect(top.nodes.map((n) => n.id).toList(), nodesBefore);
      expect(top.edges.map((e) => '${e.source}>${e.target}').toList(), edgesBefore);
    });
  });

  group('degenerate inputs', () {
    test('empty topology → empty layout', () {
      expect(computeForceLayout(GraphTopology.build(const [], const [])), isEmpty);
    });

    test('single node settles at the origin', () {
      final layout = computeForceLayout(topology([node('solo')], const []));
      expect(layout, hasLength(1));
      expect(layout['solo']!.distance, lessThan(1e-9));
    });

    test('two disconnected pairs keep both components in bounded space', () {
      final top = topology(
        [node('a1'), node('a2'), node('b1'), node('b2')],
        const [
          GraphEdge(source: 'a1', target: 'a2', kind: GraphEdgeKind.tag),
          GraphEdge(source: 'b1', target: 'b2', kind: GraphEdgeKind.tag),
        ],
      );
      final layout = computeForceLayout(top);
      expect(layout, hasLength(4));
      for (final point in layout.values) {
        expect(point.distance, lessThan(1e4));
      }
      // The components repel: their centroids stay a meaningful apart.
      final centroidA = _centroid(layout, ['a1', 'a2']);
      final centroidB = _centroid(layout, ['b1', 'b2']);
      final gap = GraphPoint(centroidA.x - centroidB.x, centroidA.y - centroidB.y);
      expect(gap.distance, greaterThan(20));
    });
  });
}

GraphPoint _centroid(Map<String, GraphPoint> layout, List<String> ids) {
  var x = 0.0;
  var y = 0.0;
  for (final id in ids) {
    x += layout[id]!.x;
    y += layout[id]!.y;
  }
  return GraphPoint(x / ids.length, y / ids.length);
}
