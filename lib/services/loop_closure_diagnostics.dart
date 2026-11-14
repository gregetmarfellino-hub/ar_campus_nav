import 'dart:math' as math;

import '../models/mapping_session.dart';

/// An honest, operator-confirmed loop check within ONE ARCore session.
///
/// The user must physically return to the original starting point before
/// recording a check. This is a closure discrepancy, not an independently
/// measured accuracy guarantee, and it must NEVER modify route geometry.
class LoopClosureDiagnostics {
  const LoopClosureDiagnostics._();

  static const markerType = 'loop_closure_check';

  static LoopClosureMeasurement? measure({
    required List<MappingPoint> points,
    required int pointIndex,
  }) {
    if (points.length < 2 || pointIndex <= 0 ||
        pointIndex >= points.length) {
      return null;
    }

    final start = points.first;
    final end = points[pointIndex];
    final dx = end.xMeters - start.xMeters;
    final dy = end.yMeters - start.yMeters;
    final dz = end.upMeters - start.upMeters;
    final discrepancy = math.sqrt(dx * dx + dy * dy + dz * dz);
    if (!discrepancy.isFinite) return null;

    var traversed = 0.0;
    for (var i = 1; i <= pointIndex; i++) {
      final a = points[i - 1];
      final b = points[i];
      final vx = b.xMeters - a.xMeters;
      final vy = b.yMeters - a.yMeters;
      final vz = b.upMeters - a.upMeters;
      final step = math.sqrt(vx * vx + vy * vy + vz * vz);
      if (!step.isFinite) return null;
      traversed += step;
    }
    if (!traversed.isFinite) return null;

    return LoopClosureMeasurement(
      pointIndex: pointIndex,
      discrepancyMeters: discrepancy,
      traveledMeters: traversed,
    );
  }

  static List<LoopClosureMeasurement> fromSession(MappingSession session) {
    if (!session.isContinuous3D) return const [];
    return [
      for (final marker in session.markers)
        if (marker.type == markerType)
          if (measure(points: session.points, pointIndex: marker.pointIndex)
              case final LoopClosureMeasurement check)
            check,
    ];
  }
}

class LoopClosureMeasurement {
  const LoopClosureMeasurement({
    required this.pointIndex,
    required this.discrepancyMeters,
    required this.traveledMeters,
  });

  final int pointIndex;
  final double discrepancyMeters;
  final double traveledMeters;
}
