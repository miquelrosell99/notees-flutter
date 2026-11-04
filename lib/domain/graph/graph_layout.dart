/// The deterministic force-directed layout — a pure function over the
/// topology. Fruchterman–Reingold at heart: pairwise repulsion, edge
/// attraction toward an ideal distance, a gentle centering pull, and
/// linear temperature cooling over a FIXED iteration count. The only
/// randomness is the seeded initial placement (mulberry32), so the same
/// topology + seed yields byte-identical positions on every run and every
/// device — no run-to-run drift. Iteration order is the topology's sorted
/// order, never map iteration order.
library;

import 'dart:math';

import 'graph_model.dart';

/// A layout position in world units (the y axis points down, as on a
/// canvas — a pure value, no Flutter dependency).
class GraphPoint {
  const GraphPoint(this.x, this.y);

  final double x;
  final double y;

  double get distance => sqrt(x * x + y * y);

  GraphPoint operator +(GraphPoint other) => GraphPoint(x + other.x, y + other.y);

  GraphPoint operator -(GraphPoint other) => GraphPoint(x - other.x, y - other.y);

  GraphPoint operator *(double factor) => GraphPoint(x * factor, y * factor);
}

/// The fixed physics constants — deliberately simple (the web engine's
/// clustered/mass-aware machinery stays web-only).
const double _idealDistance = 100;
const double _centerGravity = 0.05;
const int _defaultIterations = 300;
const double _startTemperature = 60;
const double _epsilon = 1e-9;

/// mulberry32 — the seeded PRNG for the initial placement. Deterministic
/// across platforms (pure 32-bit integer arithmetic).
class SeededRandom {
  SeededRandom(this._state);

  int _state;

  double nextDouble() {
    _state = (_state + 0x6D2B79F5) & 0xFFFFFFFF;
    var t = _state;
    t = (t ^ (t >> 15)) * (t | 1) & 0xFFFFFFFF;
    t = (t + ((t ^ (t >> 7)) * (t | 61) & 0xFFFFFFFF)) & 0xFFFFFFFF;
    t = t ^ (t >> 14);
    return (t & 0xFFFFFFFF) / 4294967296.0;
  }
}

/// Runs the layout to completion and returns the final node positions
/// keyed by node id. Pure: [topology] is never mutated; the result depends
/// only on the topology, [seed], [iterations], and the constants above.
Map<String, GraphPoint> computeForceLayout(
  GraphTopology topology, {
  int seed = 42,
  int iterations = _defaultIterations,
}) {
  final nodes = topology.nodes;
  if (nodes.isEmpty) return const {};
  if (nodes.length == 1) return {nodes.single.id: const GraphPoint(0, 0)};

  final positions = <String, GraphPoint>{};
  final rng = SeededRandom(seed);
  final ringRadius = 100 + nodes.length * 10;
  for (var i = 0; i < nodes.length; i++) {
    final angle = 2 * pi * i / nodes.length + (rng.nextDouble() - 0.5) * 0.5;
    final radius = ringRadius * (0.8 + 0.4 * rng.nextDouble());
    positions[nodes[i].id] = GraphPoint(
      cos(angle) * radius,
      sin(angle) * radius,
    );
  }

  final k = _idealDistance;
  final kSquared = k * k;

  for (var tick = 0; tick < iterations; tick++) {
    final temperature = _startTemperature * (1 - tick / iterations);

    // Repulsion between every pair (the topology is small — the web
    // engine's Barnes-Hut quadtree is unnecessary here).
    final displacement = <String, GraphPoint>{
      for (final node in nodes) node.id: const GraphPoint(0, 0),
    };
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        final delta = positions[nodes[i].id]! - positions[nodes[j].id]!;
        final distance = max(delta.distance, _epsilon);
        final force = kSquared / distance;
        final unit = delta * (force / distance);
        displacement[nodes[i].id] = displacement[nodes[i].id]! + unit;
        displacement[nodes[j].id] = displacement[nodes[j].id]! - unit;
      }
    }

    // Attraction along each edge toward the ideal distance.
    for (final edge in topology.edges) {
      final delta = positions[edge.source]! - positions[edge.target]!;
      final distance = max(delta.distance, _epsilon);
      final force = (distance * distance / k) * edge.weight;
      final unit = delta * (force / distance);
      displacement[edge.source] = displacement[edge.source]! - unit;
      displacement[edge.target] = displacement[edge.target]! + unit;
    }

    // Displacement capped by the cooling temperature + a gentle centering
    // pull so the whole graph stays around the origin.
    for (final node in nodes) {
      final disp = displacement[node.id]! -
          positions[node.id]! * _centerGravity;
      final magnitude = disp.distance;
      if (magnitude < _epsilon) continue;
      final capped = min(magnitude, temperature);
      positions[node.id] =
          positions[node.id]! + disp * (capped / magnitude);
    }
  }

  return positions;
}
