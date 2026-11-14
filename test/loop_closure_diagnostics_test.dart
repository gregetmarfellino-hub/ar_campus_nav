import 'package:flutter_test/flutter_test.dart';

import 'package:ar_campus_nav/models/mapping_session.dart';
import 'package:ar_campus_nav/services/loop_closure_diagnostics.dart';
import 'package:ar_campus_nav/services/mapping_path_simplifier.dart';

MappingPoint point(double x, double y, double up, int index) =>
    MappingPoint(
      xMeters: x,
      yMeters: y,
      upMeters: up,
      headingDegrees: 0,
      stepIndex: index,
      timestampMs: 1000 * index,
    );

void main() {
  final loop = [
    point(0, 0, 0, 0),
    point(4, 0, 0, 1),
    point(4, 3, 0, 2),
    point(0.6, 0.8, 0.6, 3),
  ];
  final checkMarker = const MappingMarker(
    id: 'closure_one',
    label: 'Return to start - drift check',
    type: LoopClosureDiagnostics.markerType,
    floor: 1,
    xMeters: 0.6,
    yMeters: 0.8,
    upMeters: 0.6,
    pointIndex: 3,
  );

  test('reports full XYZ closure discrepancy without snapping geometry', () {
    final original = List<MappingPoint>.of(loop);
    final check = LoopClosureDiagnostics.measure(
      points: loop,
      pointIndex: 3,
    )!;

    expect(check.discrepancyMeters, closeTo(1.16619, 0.0001));
    expect(check.traveledMeters, greaterThan(10));
    expect(loop, orderedEquals(original));
    expect(loop.last.xMeters, 0.6);
    expect(loop.last.upMeters, 0.6);
  });

  test('invalid indices and non-finite geometry cannot produce a check', () {
    expect(
      LoopClosureDiagnostics.measure(points: loop, pointIndex: 0),
      isNull,
    );
    expect(
      LoopClosureDiagnostics.measure(points: loop, pointIndex: 9),
      isNull,
    );
    expect(
      LoopClosureDiagnostics.measure(
        points: [point(0, 0, 0, 0), point(double.nan, 1, 0, 1)],
        pointIndex: 1,
      ),
      isNull,
    );
  });

  test('check marker survives route simplification and saved session JSON', () {
    final simplified = const MappingPathSimplifier().simplify(
      points: loop,
      markers: [checkMarker],
      toleranceMeters: 0.2,
    );
    final session = MappingSession(
      id: 'diagnostic',
      venueId: 'campus',
      venueName: 'Campus',
      floor: 1,
      createdAt: DateTime.utc(2026, 11, 14),
      startAnchorId: null,
      startAnchorLabel: null,
      originHeadingDegrees: 0,
      stepLengthMeters: 0,
      points: simplified.points,
      markers: simplified.markers,
      source: 'arcore_spatial_3d',
    );
    final restored = MappingSession.fromJson(session.toJson());
    final checks = LoopClosureDiagnostics.fromSession(restored);

    expect(restored.markers.single.type, LoopClosureDiagnostics.markerType);
    expect(checks, hasLength(1));
    expect(checks.single.discrepancyMeters, closeTo(1.16619, 0.0001));
    expect(checks.single.traveledMeters, greaterThan(10));
    expect(restored.points.last.xMeters, 0.6);
  });
}
