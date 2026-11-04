import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/utils/color_presets.dart';
import '../../../domain/graph/graph_layout.dart';
import '../../../domain/graph/graph_model.dart';

/// The interactive graph canvas: pan + pinch over the deterministic
/// layout, nodes as labeled circles (group colors win over the node's own
/// color token), edges as hairlines, tap a node to open it. All painting
/// rides the theme — the monochrome base dominates, group colors are the
/// only intentional hue.
class GraphCanvas extends StatefulWidget {
  const GraphCanvas({
    super.key,
    required this.topology,
    required this.layout,
    required this.colorFor,
    required this.onNodeTap,
  });

  final GraphTopology topology;
  final Map<String, GraphPoint> layout;

  /// The evaluated group color for a node id (null = no group matches).
  final String? Function(String nodeId) colorFor;

  final void Function(String nodeId) onNodeTap;

  @override
  State<GraphCanvas> createState() => _GraphCanvasState();
}

class _GraphCanvasState extends State<GraphCanvas> {
  static const _minScale = 0.2;
  static const _maxScale = 4.0;

  double _scale = 1;
  Offset _offset = Offset.zero;
  bool _fitted = false;

  double _startScale = 1;
  Offset _startFocalWorld = Offset.zero;

  @override
  void didUpdateWidget(covariant GraphCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A topology rebuild is a new graph — refit once.
    if (!identical(oldWidget.topology, widget.topology)) _fitted = false;
  }

  void _fitToView(Size size) {
    final points = widget.layout.values;
    if (points.isEmpty || size.isEmpty) return;
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final point in points) {
      minX = min(minX, point.x);
      minY = min(minY, point.y);
      maxX = max(maxX, point.x);
      maxY = max(maxY, point.y);
    }
    final worldWidth = max(maxX - minX, 1.0);
    final worldHeight = max(maxY - minY, 1.0);
    final scale = min(
      size.width / worldWidth,
      size.height / worldHeight,
    ).clamp(_minScale, _maxScale) * 0.85;
    final worldCenter = Offset(
      (minX + maxX) / 2,
      (minY + maxY) / 2,
    );
    setState(() {
      _scale = scale;
      _offset = Offset(size.width / 2, size.height / 2) -
          worldCenter * scale;
      _fitted = true;
    });
  }

  Offset _toWorld(Offset local) => (local - _offset) / _scale;

  String? _hitTest(Offset local) {
    final world = _toWorld(local);
    // Reverse paint order: the last-painted (topmost) node wins.
    final nodes = widget.topology.nodes.reversed;
    final slop = 6 / _scale;
    for (final node in nodes) {
      final point = widget.layout[node.id];
      if (point == null) continue;
      final radius = _radiusFor(widget.topology.degreeOf(node.id)) + slop;
      final dx = world.dx - point.x;
      final dy = world.dy - point.y;
      if (dx * dx + dy * dy <= radius * radius) return node.id;
    }
    return null;
  }

  double _radiusFor(int degree) => 13 + min(degree, 6).toDouble();

  void _onScaleStart(ScaleStartDetails details) {
    _startScale = _scale;
    _startFocalWorld = _toWorld(details.localFocalPoint);
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final nextScale =
        (_startScale * details.scale).clamp(_minScale, _maxScale);
    setState(() {
      _scale = nextScale;
      // Anchor the zoom at the focal point: the world point under the
      // finger stays under the finger.
      _offset =
          details.localFocalPoint - _startFocalWorld * nextScale;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (!_fitted && widget.layout.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _fitToView(size);
          });
        }
        return GestureDetector(
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onTapUp: (details) {
            final hit = _hitTest(details.localPosition);
            if (hit != null) widget.onNodeTap(hit);
          },
          child: CustomPaint(
            size: size,
            painter: _GraphPainter(
              topology: widget.topology,
              layout: widget.layout,
              colorFor: widget.colorFor,
              scale: _scale,
              offset: _offset,
              radiusFor: _radiusFor,
              colors: Theme.of(context).colorScheme,
              textStyle: Theme.of(context).textTheme,
            ),
          ),
        );
      },
    );
  }
}

class _GraphPainter extends CustomPainter {
  _GraphPainter({
    required this.topology,
    required this.layout,
    required this.colorFor,
    required this.scale,
    required this.offset,
    required this.radiusFor,
    required this.colors,
    required this.textStyle,
  });

  final GraphTopology topology;
  final Map<String, GraphPoint> layout;
  final String? Function(String nodeId) colorFor;
  final double scale;
  final Offset offset;
  final double Function(int degree) radiusFor;
  final ColorScheme colors;
  final TextTheme textStyle;

  Offset _toScreen(GraphPoint point) =>
      Offset(point.x * scale + offset.dx, point.y * scale + offset.dy);

  @override
  void paint(Canvas canvas, Size size) {
    final edgePaint = Paint()
      ..color = colors.onSurface.withAlpha((0.14 * 255).round())
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final edge in topology.edges) {
      final source = layout[edge.source];
      final target = layout[edge.target];
      if (source == null || target == null) continue;
      canvas.drawLine(_toScreen(source), _toScreen(target), edgePaint);
    }

    for (final node in topology.nodes) {
      final point = layout[node.id];
      if (point == null) continue;
      final center = _toScreen(point);
      final radius = radiusFor(topology.degreeOf(node.id)) * scale;
      final grouped = colorFor(node.id);
      final own = ColorPresets.tryResolve(node.color);
      final fill = grouped != null
          ? (ColorPresets.tryResolve(grouped) ?? colors.primary)
          : (own ?? colors.surfaceContainerHighest);
      final isDarkFill = fill.computeLuminance() < 0.5;

      final circlePaint = Paint()..color = fill;
      canvas.drawCircle(center, radius, circlePaint);

      // Classes read as rings; pages as filled circles with a hairline.
      final outlinePaint = Paint()
        ..color = grouped == null && own == null
            ? colors.outlineVariant
            : (isDarkFill ? fill : colors.outline)
        ..style = PaintingStyle.stroke
        ..strokeWidth = node.isClass ? 2.5 : 1;
      canvas.drawCircle(center, radius, outlinePaint);

      final labelPainter = TextPainter(
        text: TextSpan(
          text: node.label,
          style: textStyle.labelSmall?.copyWith(
            color: grouped != null || own != null
                ? ColorPresets.foregroundFor(fill)
                : colors.onSurfaceVariant,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: 120);
      labelPainter.paint(
        canvas,
        center +
            Offset(
              -labelPainter.width / 2,
              radius + 3,
            ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GraphPainter oldDelegate) =>
      oldDelegate.topology != topology ||
      oldDelegate.layout != layout ||
      oldDelegate.scale != scale ||
      oldDelegate.offset != offset;
}
