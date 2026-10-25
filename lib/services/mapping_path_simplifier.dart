import 'dart:math' as math;

import '../models/mapping_session.dart';

class MappingSimplificationResult {
  const MappingSimplificationResult({
    required this.points,
    required this.markers,
  });

  final List<MappingPoint> points;
  final List<MappingMarker> markers;
}

class MappingPathSimplifier {
  const MappingPathSimplifier();

  MappingSimplificationResult simplify({
    required List<MappingPoint> points,
    required List<MappingMarker> markers,
    double toleranceMeters = 0.10,
  }) {
    if (points.length <= 2) {
      return MappingSimplificationResult(
        points: List<MappingPoint>.unmodifiable(points),
        markers: _reindexMarkers(
          markers: markers,
          oldToNew: {
            for (var i = 0; i < points.length; i++) i: i,
          },
          points: points,
        ),
      );
    }

    final protected = <int>{0, points.length - 1};
    for (final marker in markers) {
      protected.add(
        marker.pointIndex.clamp(0, points.length - 1).toInt(),
      );
    }

    final boundaries = protected.toList()..sort();
    final kept = <int>{};

    for (var i = 0; i < boundaries.length - 1; i++) {
      _rdp(
        points,
        boundaries[i],
        boundaries[i + 1],
        toleranceMeters,
        kept,
      );
    }

    kept.addAll(protected);

    final indices = kept.toList()..sort();
    final simplified = <MappingPoint>[
      for (final index in indices) points[index],
    ];
    final oldToNew = <int, int>{
      for (var i = 0; i < indices.length; i++) indices[i]: i,
    };

    return MappingSimplificationResult(
      points: List<MappingPoint>.unmodifiable(simplified),
      markers: _reindexMarkers(
        markers: markers,
        oldToNew: oldToNew,
        points: points,
      ),
    );
  }

  void _rdp(
    List<MappingPoint> points,
    int start,
    int end,
    double tolerance,
    Set<int> kept,
  ) {
    kept
      ..add(start)
      ..add(end);

    if (end <= start + 1) return;

    final a = points[start];
    final b = points[end];

    var maxError = -1.0;
    var maxIndex = -1;

    for (var i = start + 1; i < end; i++) {
      final error = _pointToSegmentError(points[i], a, b);
      if (error > maxError) {
        maxError = error;
        maxIndex = i;
      }
    }

    if (maxIndex >= 0 && maxError > tolerance) {
      _rdp(points, start, maxIndex, tolerance, kept);
      _rdp(points, maxIndex, end, tolerance, kept);
    }
  }

  double _pointToSegmentError(
    MappingPoint point,
    MappingPoint a,
    MappingPoint b,
  ) {
    final abX = b.xMeters - a.xMeters;
    final abY = b.yMeters - a.yMeters;
    final abZ = b.upMeters - a.upMeters;
    final lengthSquared = abX * abX + abY * abY + abZ * abZ;

    if (lengthSquared <= 1e-12) {
      return _distance(point, a);
    }

    final apX = point.xMeters - a.xMeters;
    final apY = point.yMeters - a.yMeters;
    final apZ = point.upMeters - a.upMeters;
    final t = ((apX * abX + apY * abY + apZ * abZ) / lengthSquared)
        .clamp(0.0, 1.0);

    final projectedX = a.xMeters + abX * t;
    final projectedY = a.yMeters + abY * t;
    final projectedZ = a.upMeters + abZ * t;

    final dx = point.xMeters - projectedX;
    final dy = point.yMeters - projectedY;
    final dz = point.upMeters - projectedZ;
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  double _distance(MappingPoint a, MappingPoint b) {
    final dx = b.xMeters - a.xMeters;
    final dy = b.yMeters - a.yMeters;
    final dz = b.upMeters - a.upMeters;
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  List<MappingMarker> _reindexMarkers({
    required List<MappingMarker> markers,
    required Map<int, int> oldToNew,
    required List<MappingPoint> points,
  }) {
    return List<MappingMarker>.unmodifiable(
      markers.map((marker) {
        final oldIndex =
            marker.pointIndex.clamp(0, math.max(0, points.length - 1)).toInt();
        final newIndex = oldToNew[oldIndex];
        if (newIndex == null) {
          throw StateError(
            'Semantic marker point $oldIndex was removed during simplification.',
          );
        }

        return MappingMarker(
          id: marker.id,
          label: marker.label,
          type: marker.type,
          floor: marker.floor,
          xMeters: marker.xMeters,
          yMeters: marker.yMeters,
          upMeters: marker.upMeters,
          pointIndex: newIndex,
          referenceAnchorId: marker.referenceAnchorId,
        );
      }),
    );
  }
}
