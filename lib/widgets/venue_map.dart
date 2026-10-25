import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/nav_node.dart';
import '../models/route_result.dart';
import '../models/venue.dart';

class VenueMap extends StatelessWidget {
  const VenueMap({
    super.key,
    required this.venue,
    this.route,
    this.floor = 1,
    this.height = 360,
    this.currentNodeId,
    this.onSemanticNodeTap,
  });

  final Venue venue;
  final RouteResult? route;
  final int floor;
  final double height;
  final String? currentNodeId;
  final ValueChanged<NavNode>? onSemanticNodeTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF0D1527),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0x223B82F6)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(
            constraints.maxWidth,
            constraints.maxHeight,
          );

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: onSemanticNodeTap == null
                ? null
                : (details) {
                    final node = _semanticNodeAt(
                      details.localPosition,
                      size,
                    );
                    if (node != null) {
                      onSemanticNodeTap!(node);
                    }
                  },
            child: CustomPaint(
              painter: _VenueMapPainter(
                venue: venue,
                route: route,
                floor: floor,
                currentNodeId: currentNodeId,
              ),
              child: const SizedBox.expand(),
            ),
          );
        },
      ),
    );
  }

  NavNode? _semanticNodeAt(Offset tap, Size size) {
    const padding = 34.0;
    const hitRadius = 28.0;

    final nodes = venue.nodes
        .where((node) => node.floor == floor)
        .toList(growable: false);

    if (nodes.isEmpty) return null;

    final destinationNodeIds =
        venue.destinations.map((item) => item.nodeId).toSet();
    final anchorNodeIds = venue.anchors
        .where((anchor) => anchor.floor == floor)
        .map((anchor) => anchor.nodeId)
        .toSet();

    bool isSemantic(NavNode node) {
      final realWaypoint =
          node.type == 'waypoint' && node.label != 'Recorded path';

      return destinationNodeIds.contains(node.id) ||
          anchorNodeIds.contains(node.id) ||
          node.type == 'destination' ||
          node.type == 'stairs' ||
          node.type == 'anchor' ||
          realWaypoint;
    }

    final semanticNodes = nodes.where(isSemantic).toList(growable: false);
    if (semanticNodes.isEmpty) return null;

    var minX = nodes.first.x;
    var maxX = nodes.first.x;
    var minY = nodes.first.y;
    var maxY = nodes.first.y;

    for (final node in nodes) {
      minX = math.min(minX, node.x);
      maxX = math.max(maxX, node.x);
      minY = math.min(minY, node.y);
      maxY = math.max(maxY, node.y);
    }

    final spanX = math.max(0.0001, maxX - minX);
    final spanY = math.max(0.0001, maxY - minY);
    final availableWidth = math.max(1.0, size.width - padding * 2);
    final availableHeight = math.max(1.0, size.height - padding * 2);
    final scale = math.min(
      availableWidth / spanX,
      availableHeight / spanY,
    );

    final drawnWidth = spanX * scale;
    final drawnHeight = spanY * scale;
    final offsetX = (size.width - drawnWidth) / 2;
    final offsetY = (size.height - drawnHeight) / 2;

    Offset nodePoint(NavNode node) {
      return Offset(
        offsetX + (node.x - minX) * scale,
        offsetY + (node.y - minY) * scale,
      );
    }

    NavNode? closest;
    var closestDistance = hitRadius;

    for (final node in semanticNodes) {
      final distance = (nodePoint(node) - tap).distance;
      if (distance <= closestDistance) {
        closest = node;
        closestDistance = distance;
      }
    }

    return closest;
  }
}

class _VenueMapPainter extends CustomPainter {
  const _VenueMapPainter({
    required this.venue,
    required this.route,
    required this.floor,
    required this.currentNodeId,
  });

  final Venue venue;
  final RouteResult? route;
  final int floor;
  final String? currentNodeId;

  @override
  void paint(Canvas canvas, Size size) {
    const padding = 34.0;
    final nodes = venue.nodes.where((node) => node.floor == floor).toList();

    if (nodes.isEmpty) {
      final painter = TextPainter(
        text: const TextSpan(
          text: 'No mapped nodes on this floor',
          style: TextStyle(color: Colors.white30, fontSize: 13),
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
      return;
    }

    var minX = nodes.first.x;
    var maxX = nodes.first.x;
    var minY = nodes.first.y;
    var maxY = nodes.first.y;

    for (final node in nodes) {
      minX = math.min(minX, node.x);
      maxX = math.max(maxX, node.x);
      minY = math.min(minY, node.y);
      maxY = math.max(maxY, node.y);
    }

    final spanX = math.max(0.0001, maxX - minX);
    final spanY = math.max(0.0001, maxY - minY);
    final availableWidth = math.max(1.0, size.width - padding * 2);
    final availableHeight = math.max(1.0, size.height - padding * 2);
    final scale = math.min(availableWidth / spanX, availableHeight / spanY);

    final drawnWidth = spanX * scale;
    final drawnHeight = spanY * scale;
    final offsetX = (size.width - drawnWidth) / 2;
    final offsetY = (size.height - drawnHeight) / 2;

    Offset point(String nodeId) {
      final node = venue.nodeById(nodeId);
      return Offset(
        offsetX + (node.x - minX) * scale,
        offsetY + (node.y - minY) * scale,
      );
    }

    final floorNodeIds = nodes.map((node) => node.id).toSet();

    final edgePaint = Paint()
      ..color = const Color(0xFF263654)
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;

    for (final edge in venue.edges) {
      if (!edge.accessible ||
          !floorNodeIds.contains(edge.from) ||
          !floorNodeIds.contains(edge.to)) {
        continue;
      }
      canvas.drawLine(point(edge.from), point(edge.to), edgePaint);
    }

    final routeNodes = route?.nodes
            .where((node) => node.floor == floor)
            .map((node) => node.id)
            .toList(growable: false) ??
        const <String>[];

    if (routeNodes.length > 1) {
      final routePaint = Paint()
        ..color = const Color(0xFF56C7FF)
        ..strokeWidth = 8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;

      final first = point(routeNodes.first);
      final path = Path()..moveTo(first.dx, first.dy);
      for (final id in routeNodes.skip(1)) {
        final p = point(id);
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, routePaint);
    }

    final routeSet = routeNodes.toSet();
    final destinationNodeIds =
        venue.destinations.map((destination) => destination.nodeId).toSet();
    final anchorNodeIds = venue.anchors
        .where((anchor) => anchor.floor == floor)
        .map((anchor) => anchor.nodeId)
        .toSet();

    bool isRealWaypoint(NavNode node) {
      // Pass 5.2 used "waypoint" for both semantic waypoints and sampled
      // path geometry. The "Recorded path" label lets us migrate old
      // overrides visually without forcing the user to rebuild them first.
      return node.type == 'waypoint' && node.label != 'Recorded path';
    }

    for (final node in nodes) {
      final p = point(node.id);
      final isOnRoute = routeSet.contains(node.id);
      final isDestination =
          destinationNodeIds.contains(node.id) || node.type == 'destination';
      final isAnchor = anchorNodeIds.contains(node.id) || node.type == 'anchor';
      final isStairs = node.type == 'stairs';
      final isWaypoint = isRealWaypoint(node);
      final isEntrance = node.type == 'entrance';
      final isCurrent = node.id == currentNodeId;

      // Plain recorded path samples are represented by the edge line itself.
      // This keeps long recordings from turning into hundreds of fake dots.
      if (isOnRoute &&
          !isDestination &&
          !isAnchor &&
          !isStairs &&
          !isWaypoint &&
          !isEntrance) {
        canvas.drawCircle(
          p,
          4,
          Paint()..color = const Color(0xFFEAF6FF),
        );
      }

      if (isEntrance && !isAnchor) {
        canvas.drawCircle(
          p,
          6,
          Paint()..color = const Color(0xFF72A7FF),
        );
      }

      if (isWaypoint) {
        _drawWaypointMarker(canvas, p);
      }
      if (isDestination) {
        _drawDestinationMarker(canvas, p);
      }
      if (isStairs) {
        _drawStairsMarker(canvas, p);
      }
      if (isAnchor) {
        _drawAnchorMarker(canvas, p);
      }

      if (isCurrent) {
        final currentPaint = Paint()
          ..color = const Color(0xFF3DDC97)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3;
        canvas.drawCircle(p, 12, currentPaint);
      }
    }

    final labelNodes = nodes.where((node) {
      // Route geometry may contain hundreds of raw sampled points. Keep those
      // samples visible only through the route/path line; labels are reserved
      // for semantic locations the mapper deliberately created.
      return destinationNodeIds.contains(node.id) ||
          anchorNodeIds.contains(node.id) ||
          isRealWaypoint(node) ||
          node.type == 'destination' ||
          node.type == 'anchor' ||
          node.type == 'stairs' ||
          node.type == 'entrance' ||
          node.id == currentNodeId;
    }).toList()
      ..sort((a, b) => _labelPriority(
            b,
            routeSet,
            destinationNodeIds,
            anchorNodeIds,
          ).compareTo(
            _labelPriority(
              a,
              routeSet,
              destinationNodeIds,
              anchorNodeIds,
            ),
          ));

    final occupied = <Rect>[];
    for (final node in labelNodes) {
      _drawSmartLabel(
        canvas,
        node.label,
        point(node.id),
        size,
        occupied,
      );
    }
  }

  void _drawWaypointMarker(Canvas canvas, Offset p) {
    canvas.drawCircle(p, 7, Paint()..color = const Color(0xFFCBA6F7));
    canvas.drawCircle(
      p,
      3,
      Paint()..color = const Color(0xFF0D1527),
    );
  }

  void _drawDestinationMarker(Canvas canvas, Offset p) {
    final stem = Paint()
      ..color = const Color(0xFFFF6B8A)
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(p + const Offset(-4, 7), p + const Offset(-4, -7), stem);

    final flag = Path()
      ..moveTo(p.dx - 4, p.dy - 7)
      ..lineTo(p.dx + 7, p.dy - 4)
      ..lineTo(p.dx - 4, p.dy)
      ..close();
    canvas.drawPath(flag, Paint()..color = const Color(0xFFFF6B8A));
  }

  void _drawStairsMarker(Canvas canvas, Offset p) {
    final paint = Paint()
      ..color = const Color(0xFFF9C74F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final path = Path()
      ..moveTo(p.dx - 7, p.dy + 6)
      ..lineTo(p.dx - 2, p.dy + 6)
      ..lineTo(p.dx - 2, p.dy + 1)
      ..lineTo(p.dx + 3, p.dy + 1)
      ..lineTo(p.dx + 3, p.dy - 4)
      ..lineTo(p.dx + 8, p.dy - 4);
    canvas.drawPath(path, paint);
  }

  void _drawAnchorMarker(Canvas canvas, Offset p) {
    final border = Paint()
      ..color = const Color(0xFF3DDC97)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: p, width: 15, height: 15),
        const Radius.circular(3),
      ),
      border,
    );
    canvas.drawCircle(p, 2.3, Paint()..color = const Color(0xFF3DDC97));
  }

  int _labelPriority(
    NavNode node,
    Set<String> routeSet,
    Set<String> destinations,
    Set<String> anchors,
  ) {
    if (node.id == currentNodeId) return 8;
    if (destinations.contains(node.id) || node.type == 'destination') return 7;
    if (anchors.contains(node.id) || node.type == 'anchor') return 6;
    if (node.type == 'stairs') return 5;
    if (node.type == 'waypoint' && node.label != 'Recorded path') return 4;
    if (routeSet.contains(node.id)) return 3;
    if (node.type == 'entrance') return 2;
    return 0;
  }

  void _drawSmartLabel(
    Canvas canvas,
    String text,
    Offset point,
    Size size,
    List<Rect> occupied,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Color(0xFFCFDCF3),
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: math.max(72, size.width * 0.30));

    final w = painter.width + 10;
    final h = painter.height + 6;

    final candidates = <Offset>[
      point + const Offset(10, -24),
      point + const Offset(10, 10),
      point + Offset(-w - 10, -24),
      point + Offset(-w - 10, 10),
      point + Offset(-w / 2, -h - 12),
      point + Offset(-w / 2, 12),
    ];

    Rect? chosen;
    var bestOverlap = double.infinity;

    for (final candidate in candidates) {
      final rect = _clampRect(
        Rect.fromLTWH(candidate.dx, candidate.dy, w, h),
        size,
      );
      final overlap = _totalOverlap(rect.inflate(3), occupied);
      if (overlap == 0) {
        chosen = rect;
        break;
      }
      if (overlap < bestOverlap) {
        bestOverlap = overlap;
        chosen = rect;
      }
    }

    final rect = chosen ?? Rect.fromLTWH(4, 4, w, h);
    final bubble = Paint()..color = const Color(0xD90D1527);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(6)),
      bubble,
    );

    painter.paint(
      canvas,
      Offset(rect.left + 5, rect.top + 3),
    );
    occupied.add(rect);
  }

  Rect _clampRect(Rect rect, Size size) {
    final left = rect.left
        .clamp(4.0, math.max(4.0, size.width - rect.width - 4))
        .toDouble();
    final top = rect.top
        .clamp(4.0, math.max(4.0, size.height - rect.height - 4))
        .toDouble();
    return Rect.fromLTWH(left, top, rect.width, rect.height);
  }

  double _totalOverlap(Rect rect, List<Rect> occupied) {
    var area = 0.0;
    for (final other in occupied) {
      final intersection = rect.intersect(other.inflate(3));
      if (!intersection.isEmpty) {
        area += intersection.width * intersection.height;
      }
    }
    return area;
  }

  @override
  bool shouldRepaint(covariant _VenueMapPainter oldDelegate) {
    return oldDelegate.venue != venue ||
        oldDelegate.route != route ||
        oldDelegate.floor != floor ||
        oldDelegate.currentNodeId != currentNodeId;
  }
}
