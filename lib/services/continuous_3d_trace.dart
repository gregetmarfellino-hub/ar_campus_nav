import 'dart:math' as math;

import '../models/mapping_session.dart';

/// Independent V10 3D route geometry. The venue's 2D floor maps are untouched.
/// Coordinates are local to ONE uninterrupted ARCore tracking session.
class Continuous3DTrace {
  const Continuous3DTrace._();

  static Continuous3DTraceSummary analyze({
    required List<MappingPoint> points,
    List<MappingMarker> markers = const [],
    List<int> segmentStarts = const [0],
    int? startFloor,
  }) {
    if (points.length < 2) {
      throw StateError('Record at least two spatial samples.');
    }
    if (segmentStarts.length != 1 || segmentStarts.single != 0) {
      throw StateError(
        'A continuous staircase trace cannot contain disconnected sections. '
        'Restart or record a new 3D route after tracking breaks.',
      );
    }
    for (final p in points) {
      if (!p.xMeters.isFinite ||
          !p.yMeters.isFinite ||
          !p.upMeters.isFinite) {
        throw StateError('Recorded 3D position contains invalid coordinates.');
      }
    }
    var horizontal = 0.0;
    var total = 0.0;
    var ascent = 0.0;
    var descent = 0.0;
    var lowest = points.first.upMeters;
    var highest = lowest;
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1];
      final b = points[i];
      final dx = b.xMeters - a.xMeters;
      final dy = b.yMeters - a.yMeters;
      final dz = b.upMeters - a.upMeters;
      final h = math.sqrt(dx * dx + dy * dy);
      horizontal += h;
      total += math.sqrt(h * h + dz * dz);
      if (dz > 0) {
        ascent += dz;
      } else {
        descent -= dz;
      }
      lowest = math.min(lowest, b.upMeters);
      highest = math.max(highest, b.upMeters);
    }
    final floors = <int>[
      if (startFloor != null) startFloor,
      for (final marker in markers)
        if (marker.type == 'floor_level') marker.floor,
    ];
    for (final marker in markers) {
      if (marker.pointIndex < 0 || marker.pointIndex >= points.length) {
        throw StateError('Floor marker points outside saved route.');
      }
    }

    return Continuous3DTraceSummary(
      pathMeters: total,
      horizontalMeters: horizontal,
      ascentMeters: ascent,
      descentMeters: descent,
      netHeightMeters: points.last.upMeters - points.first.upMeters,
      minHeightMeters: lowest,
      maxHeightMeters: highest,
      visitedFloors: List.unmodifiable(floors.toSet()),
    );
  }

  /// Pure, 3D-safe native preview transport. Nothing here projects to XY or
  /// invents the height of a staircase from separate floor entrances.
  static List<Map<String, dynamic>> toLivePreviewPoints({
    required List<MappingPoint> points,
    List<MappingMarker> markers = const [],
    List<int> segmentStarts = const [0],
  }) {
    analyze(
      points: points,
      markers: markers,
      segmentStarts: segmentStarts,
    );
    if (points.length > 1500) {
      throw StateError(
        '3D preview has more than 1500 points. Simplify the recording first.',
      );
    }
    final labels = <int, String>{
      for (final marker in markers)
        if (marker.type == 'floor_level')
          marker.pointIndex: marker.label,
    };
    return List.unmodifiable([
      for (var i = 0; i < points.length; i++)
        <String, dynamic>{
          'right': points[i].xMeters,
          'forward': points[i].yMeters,
          'up': points[i].upMeters,
          'label': labels[i] ?? '3D recorded path',
        },
    ]);
  }
}

class Continuous3DTraceSummary {
  const Continuous3DTraceSummary({
    required this.pathMeters,
    required this.horizontalMeters,
    required this.ascentMeters,
    required this.descentMeters,
    required this.netHeightMeters,
    required this.minHeightMeters,
    required this.maxHeightMeters,
    required this.visitedFloors,
  });

  final double pathMeters;
  final double horizontalMeters;
  final double ascentMeters;
  final double descentMeters;
  final double netHeightMeters;
  final double minHeightMeters;
  final double maxHeightMeters;
  final List<int> visitedFloors;

  bool get hasMeasuredClimb => (maxHeightMeters - minHeightMeters) >= 1.0;
  bool get hasLabeledTransition => visitedFloors.toSet().length > 1;
}
