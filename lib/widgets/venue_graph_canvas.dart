import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/nav_edge.dart';
import '../models/nav_node.dart';
import '../models/venue.dart';

/// A fixed world-meter viewport for one editor session and floor.
/// Recomputing bounds while dragging would make the route jump under a finger.
class VenueGraphViewport {
  const VenueGraphViewport({
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
  });

  final double minX;
  final double maxX;
  final double minY;
  final double maxY;

  factory VenueGraphViewport.forFloor(Venue venue, int floor) {
    final points = venue.nodes.where((node) => node.floor == floor).toList();
    if (points.isEmpty) {
      return const VenueGraphViewport(
        minX: -6, maxX: 6, minY: -6, maxY: 6,
      );
    }
    var minX = points.first.x;
    var maxX = minX;
    var minY = points.first.y;
    var maxY = minY;
    for (final p in points) {
      minX = math.min(minX, p.x);
      maxX = math.max(maxX, p.x);
      minY = math.min(minY, p.y);
      maxY = math.max(maxY, p.y);
    }
    final mx = math.max(3, (maxX - minX) * 0.16);
    final my = math.max(3, (maxY - minY) * 0.16);
    final centerX = (minX + maxX) / 2;
    final centerY = (minY + maxY) / 2;
    final halfWidth = math.max(6, (maxX - minX) / 2 + mx);
    final halfHeight = math.max(6, (maxY - minY) / 2 + my);
    return VenueGraphViewport(
      minX: centerX - halfWidth,
      maxX: centerX + halfWidth,
      minY: centerY - halfHeight,
      maxY: centerY + halfHeight,
    );
  }

  double scale(Size size) => math.min(
        (size.width - 28).clamp(1.0, double.infinity) / (maxX - minX),
        (size.height - 28).clamp(1.0, double.infinity) / (maxY - minY),
      );

  Offset toScreen(Offset meters, Size size) {
    final factor = scale(size);
    final left = (size.width - (maxX - minX) * factor) / 2;
    final top = (size.height - (maxY - minY) * factor) / 2;
    return Offset(
      left + (meters.dx - minX) * factor,
      top + (meters.dy - minY) * factor,
    );
  }

  Offset toMeters(Offset screen, Size size) {
    final factor = scale(size);
    final left = (size.width - (maxX - minX) * factor) / 2;
    final top = (size.height - (maxY - minY) * factor) / 2;
    return Offset(
      minX + (screen.dx - left) / factor,
      minY + (screen.dy - top) / factor,
    );
  }
}

/// An interactive per-floor graph. Dragging moves only editable nodes, tapping
/// chooses nodes/edges, and drawing always uses saved VENUE meters.
class VenueGraphCanvas extends StatefulWidget {
  const VenueGraphCanvas({
    super.key,
    required this.venue,
    required this.floor,
    required this.viewport,
    required this.selectedNodeId,
    required this.connectMode,
    required this.insertMode,
    required this.canMove,
    required this.onTapNode,
    required this.onDragStartNode,
    required this.onDragNode,
    required this.onDragEndNode,
    required this.onPanCanvas,
    required this.onInsertWaypoint,
  });

  final Venue venue;
  final int floor;
  final VenueGraphViewport viewport;
  final String? selectedNodeId;
  final bool connectMode;
  final bool insertMode;
  final bool Function(String nodeId) canMove;
  final ValueChanged<String?> onTapNode;
  final ValueChanged<String> onDragStartNode;
  final void Function(String nodeId, Offset meters) onDragNode;
  final VoidCallback onDragEndNode;
  final ValueChanged<Offset> onPanCanvas;
  final void Function(String from, String to, Offset meters)
      onInsertWaypoint;

  @override
  State<VenueGraphCanvas> createState() => _VenueGraphCanvasState();
}

class _VenueGraphCanvasState extends State<VenueGraphCanvas> {
  String? _dragNodeId;
  bool _dragged = false;
  bool _panningCanvas = false;

  Iterable<NavNode> get _floorNodes =>
      widget.venue.nodes.where((node) => node.floor == widget.floor);

  NavNode? _nearNode(Offset location, Size size) {
    NavNode? closest;
    // Android's recommended tappable target is ~48 logical pixels.
    // A 34px selection radius leaves room for pointer imprecision and laggy
    // screen casting while always picking the NEAREST actual point.
    var minDistance = 34.0;
    for (final node in _floorNodes) {
      final point = widget.viewport.toScreen(Offset(node.x, node.y), size);
      final dist = (location - point).distance;
      if (dist < minDistance) {
        minDistance = dist;
        closest = node;
      }
    }
    return closest;
  }

  (NavEdge, Offset)? _nearEdge(Offset point, Size size) {
    final byId = {for (final n in widget.venue.nodes) n.id: n};
    NavEdge? chosen;
    Offset? projection;
    var minDistance = 32.0;
    for (final edge in widget.venue.edges) {
      final a = byId[edge.from];
      final b = byId[edge.to];
      if (a == null || b == null ||
          a.floor != widget.floor || b.floor != widget.floor) {
        continue;
      }
      final pa = widget.viewport.toScreen(Offset(a.x, a.y), size);
      final pb = widget.viewport.toScreen(Offset(b.x, b.y), size);
      final delta = pb - pa;
      final lengthSquared = delta.dx * delta.dx + delta.dy * delta.dy;
      if (lengthSquared < 0.01) continue;
      final relative = point - pa;
      final t = ((relative.dx * delta.dx + relative.dy * delta.dy) /
              lengthSquared)
          .clamp(0.0, 1.0).toDouble();
      final candidate = pa + delta * t;
      final distance = (candidate - point).distance;
      if (distance < minDistance) {
        minDistance = distance;
        chosen = edge;
        projection = candidate;
      }
    }
    if (chosen == null || projection == null) return null;
    return (chosen, widget.viewport.toMeters(projection, size));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) {
          if (widget.insertMode) {
            final found = _nearEdge(details.localPosition, size);
            if (found != null) {
              widget.onInsertWaypoint(
                found.$1.from, found.$1.to, found.$2,
              );
            } else {
              widget.onTapNode(null);
            }
            return;
          }
          widget.onTapNode(
            _nearNode(details.localPosition, size)?.id,
          );
        },
        onPanStart: (details) {
          if (widget.connectMode || widget.insertMode) return;
          final node = _nearNode(details.localPosition, size);
          if (node == null) {
            _panningCanvas = true;
            return;
          }
          widget.onTapNode(node.id);
          if (!widget.canMove(node.id)) return;
          _dragNodeId = node.id;
          _dragged = false;
          widget.onDragStartNode(node.id);
        },
        onPanUpdate: (details) {
          if (_panningCanvas) {
            widget.onPanCanvas(details.delta / widget.viewport.scale(size));
            return;
          }
          final id = _dragNodeId;
          if (id == null) return;
          _dragged = true;
          final meters = widget.viewport.toMeters(
            details.localPosition, size,
          );
          widget.onDragNode(
            id,
            Offset(
              meters.dx.clamp(widget.viewport.minX, widget.viewport.maxX).toDouble(),
              meters.dy.clamp(widget.viewport.minY, widget.viewport.maxY).toDouble(),
            ),
          );
        },
        onPanEnd: (_) {
          if (_dragNodeId != null && _dragged) {
            widget.onDragEndNode();
          }
          _dragNodeId = null;
          _dragged = false;
          _panningCanvas = false;
        },
        onPanCancel: () {
          if (_dragNodeId != null && _dragged) {
            widget.onDragEndNode();
          }
          _dragNodeId = null;
          _dragged = false;
          _panningCanvas = false;
        },
        child: CustomPaint(
          painter: _GraphPainter(
            venue: widget.venue,
            floor: widget.floor,
            viewport: widget.viewport,
            selectedNodeId: widget.selectedNodeId,
            connectMode: widget.connectMode,
          ),
          child: const SizedBox.expand(),
        ),
      );
    });
  }
}

class _GraphPainter extends CustomPainter {
  const _GraphPainter({
    required this.venue,
    required this.floor,
    required this.viewport,
    required this.selectedNodeId,
    required this.connectMode,
  });

  final Venue venue;
  final int floor;
  final VenueGraphViewport viewport;
  final String? selectedNodeId;
  final bool connectMode;

  static const Color blue = Color(0xFF6CAFFF);
  static const Color green = Color(0xFF3DDC97);
  static const Color yellow = Color(0xFFFFC978);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0D1527));

    // Two-metre reference grid in venue coordinates.
    final scale = viewport.scale(size);
    if (scale >= 5) {
      final gridPaint = Paint()
        ..color = const Color(0x194A6B88)
        ..strokeWidth = 0.7;
      for (var x = (viewport.minX / 2).ceil() * 2.0;
          x <= viewport.maxX;
          x += 2) {
        final a = viewport.toScreen(Offset(x, viewport.minY), size);
        final b = viewport.toScreen(Offset(x, viewport.maxY), size);
        canvas.drawLine(a, b, gridPaint);
      }
      for (var y = (viewport.minY / 2).ceil() * 2.0;
          y <= viewport.maxY;
          y += 2) {
        final a = viewport.toScreen(Offset(viewport.minX, y), size);
        final b = viewport.toScreen(Offset(viewport.maxX, y), size);
        canvas.drawLine(a, b, gridPaint);
      }
    }

    final nodes = {
      for (final node in venue.nodes)
        if (node.floor == floor) node.id: node,
    };
    for (final edge in venue.edges) {
      final a = nodes[edge.from];
      final b = nodes[edge.to];
      if (a == null || b == null) continue;
      final highlighted =
          a.id == selectedNodeId || b.id == selectedNodeId;
      canvas.drawLine(
        viewport.toScreen(Offset(a.x, a.y), size),
        viewport.toScreen(Offset(b.x, b.y), size),
        Paint()
          ..strokeWidth = highlighted ? 4 : 2.7
          ..strokeCap = StrokeCap.round
          ..color = !edge.accessible
              ? const Color(0xFF697486)
              : highlighted ? green : blue,
      );
    }

    final anchors = venue.anchors.map((anchor) => anchor.nodeId).toSet();
    final destinations =
        venue.destinations.map((destination) => destination.nodeId).toSet();
    for (final node in nodes.values) {
      final selected = node.id == selectedNodeId;
      final anchored = anchors.contains(node.id);
      final destination = destinations.contains(node.id) ||
          node.type == 'destination';
      final stairs = node.type == 'stairs' || node.type == 'elevator';
      final color = anchored
          ? green
          : destination
              ? yellow
              : stairs
                  ? const Color(0xFFBC9BFF)
                  : blue;
      final p = viewport.toScreen(Offset(node.x, node.y), size);
      final radius = selected ? 8.5 : anchored || destination || stairs ? 6.5 : 3.6;
      if (selected) {
        canvas.drawCircle(
          p, radius + 4, Paint()..color = const Color(0x88FFFFFF),
        );
      }
      canvas.drawCircle(p, radius, Paint()..color = color);
      canvas.drawCircle(
        p, radius,
        Paint()
          ..color = const Color(0xFF0D1527)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3,
      );
      if (anchored || destination || stairs || selected) {
        final label = TextPainter(
          text: TextSpan(
            text: node.label == 'Recorded path'
                ? 'Waypoint' : node.label,
            style: TextStyle(
              color: selected ? Colors.white : const Color(0xFFCDD8EA),
              fontSize: selected ? 11 : 9,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: 110);
        label.paint(
          canvas,
          Offset(
            (p.dx + 7).clamp(1.0, math.max(1.0, size.width - label.width - 2)).toDouble(),
            (p.dy - 16).clamp(0.0, size.height - label.height).toDouble(),
          ),
        );
      }
    }

    if (nodes.isEmpty) {
      const label = 'No mapped waypoints on this floor';
      final painter = TextPainter(
        text: const TextSpan(
          text: label,
          style: TextStyle(color: Color(0xFFADC2DB), fontSize: 14),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        Offset(
          (size.width - painter.width) / 2,
          (size.height - painter.height) / 2,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GraphPainter oldDelegate) =>
      oldDelegate.venue != venue ||
      oldDelegate.floor != floor ||
      oldDelegate.viewport != viewport ||
      oldDelegate.selectedNodeId != selectedNodeId ||
      oldDelegate.connectMode != connectMode;
}
