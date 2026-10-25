import 'package:flutter_test/flutter_test.dart';
import 'package:ar_campus_nav/models/mapping_session.dart';
import 'package:ar_campus_nav/services/mapping_path_simplifier.dart';

MappingPoint point(double x, double y, int index, {double up = 0}) {
  return MappingPoint(
    xMeters: x,
    yMeters: y,
    upMeters: up,
    headingDegrees: 0,
    stepIndex: index,
    timestampMs: index * 100,
  );
}

void main() {
  const simplifier = MappingPathSimplifier();

  test('straight geometry is reduced while semantic marker is preserved', () {
    final points = <MappingPoint>[
      point(0, 0, 0),
      point(0, 1, 1),
      point(0, 2, 2),
      point(0, 3, 3),
      point(0, 4, 4),
    ];
    const markers = <MappingMarker>[
      MappingMarker(
        id: 'room',
        label: 'Room',
        type: 'destination',
        floor: 1,
        xMeters: 0,
        yMeters: 2,
        pointIndex: 2,
      ),
    ];

    final result = simplifier.simplify(
      points: points,
      markers: markers,
      toleranceMeters: 0.10,
    );

    expect(result.points.length, 3);
    expect(result.points[0].yMeters, 0);
    expect(result.points[1].yMeters, 2);
    expect(result.points[2].yMeters, 4);
    expect(result.markers.single.pointIndex, 1);
    expect(result.markers.single.label, 'Room');
  });

  test('meaningful curve survives simplification', () {
    final points = <MappingPoint>[
      point(0, 0, 0),
      point(0, 1, 1),
      point(1, 2, 2),
      point(2, 2, 3),
    ];

    final result = simplifier.simplify(
      points: points,
      markers: const [],
      toleranceMeters: 0.15,
    );

    expect(result.points.length, greaterThan(2));
    expect(
      result.points.any((item) => item.xMeters == 1 && item.yMeters == 2),
      isTrue,
    );
  });

  test('vertical deviation is considered part of route geometry', () {
    final points = <MappingPoint>[
      point(0, 0, 0),
      point(0, 1, 1, up: 0.8),
      point(0, 2, 2, up: 0),
    ];

    final result = simplifier.simplify(
      points: points,
      markers: const [],
      toleranceMeters: 0.10,
    );

    expect(result.points.length, 3);
  });

  test('mapping quality metadata round-trips through JSON', () {
    final session = MappingSession(
      id: 'test',
      venueId: 'venue',
      venueName: 'Venue',
      floor: 1,
      createdAt: DateTime.utc(2026, 1, 1),
      startAnchorId: null,
      startAnchorLabel: null,
      originHeadingDegrees: 0,
      stepLengthMeters: 0,
      source: 'arcore_spatial',
      points: <MappingPoint>[
        point(0, 0, 0),
        point(0, 1, 1),
      ],
      markers: const [],
      rawPointCount: 20,
      trackingInterruptions: 1,
      rejectedPoseJumps: 2,
    );

    final restored = MappingSession.fromJson(session.toJson());

    expect(restored.effectiveRawPointCount, 20);
    expect(restored.trackingInterruptions, 1);
    expect(restored.rejectedPoseJumps, 2);
    expect(restored.qualityLabel, 'CAUTION');
  });
}
