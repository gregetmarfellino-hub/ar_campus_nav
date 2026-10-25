import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/mapping_session.dart';

class MappingSessionMap extends StatelessWidget {
  const MappingSessionMap({
    super.key,
    required this.session,
    this.height = 320,
  });

  final MappingSession session;
  final double height;

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
      child: CustomPaint(
        painter: _MappingSessionPainter(session),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _MappingSessionPainter extends CustomPainter {
  const _MappingSessionPainter(this.session);

  final MappingSession session;

  @override
  void paint(Canvas canvas, Size size) {
    final points = session.points;
    final markers = session.markers;

    final gridPaint = Paint()
      ..color = const Color(0x143A4B68)
      ..strokeWidth = 1;
    for (var x = 20.0; x < size.width; x += 40) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (var y = 20.0; y < size.height; y += 40) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (points.isEmpty) return;

    var minX = points.first.xMeters;
    var maxX = points.first.xMeters;
    var minY = points.first.yMeters;
    var maxY = points.first.yMeters;

    for (final point in points) {
      minX = math.min(minX, point.xMeters);
      maxX = math.max(maxX, point.xMeters);
      minY = math.min(minY, point.yMeters);
      maxY = math.max(maxY, point.yMeters);
    }

    const pad = 34.0;
    final spanX = math.max(4.0, maxX - minX);
    final spanY = math.max(4.0, maxY - minY);
    final scale = math.min(
      (size.width - pad * 2) / spanX,
      (size.height - pad * 2) / spanY,
    );

    Offset project(double x, double y) {
      return Offset(
        pad + (x - minX) * scale,
        size.height - pad - (y - minY) * scale,
      );
    }

    final start = project(points.first.xMeters, points.first.yMeters);
    final path = Path()..moveTo(start.dx, start.dy);
    for (final point in points.skip(1)) {
      final p = project(point.xMeters, point.yMeters);
      path.lineTo(p.dx, p.dy);
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF63C7FF)
        ..strokeWidth = 5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    canvas.drawCircle(start, 7, Paint()..color = const Color(0xFF3DDC97));

    final end = project(points.last.xMeters, points.last.yMeters);
    canvas.drawCircle(end, 7, Paint()..color = const Color(0xFF72A7FF));

    for (final marker in markers) {
      final p = project(marker.xMeters, marker.yMeters);
      final color = switch (marker.type) {
        'destination' => const Color(0xFFFF6B8A),
        'stairs' => const Color(0xFFF9C74F),
        'anchor' => const Color(0xFF3DDC97),
        _ => const Color(0xFFCBA6F7),
      };
      canvas.drawCircle(p, 8, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _MappingSessionPainter oldDelegate) {
    return oldDelegate.session != session;
  }
}
