import 'package:flutter_test/flutter_test.dart';

import 'package:ar_campus_nav/models/mapping_session.dart';
import 'package:ar_campus_nav/models/nav_node.dart';
import 'package:ar_campus_nav/models/venue.dart';
import 'package:ar_campus_nav/services/continuous_3d_trace.dart';
import 'package:ar_campus_nav/services/mapping_path_simplifier.dart';
import 'package:ar_campus_nav/services/venue_mapping_service.dart';

List<MappingPoint> staircasePoints() => const [
      MappingPoint(
        xMeters: 0, yMeters: 0, upMeters: 0,
        headingDegrees: 0, stepIndex: 0, timestampMs: 100,
      ),
      MappingPoint(
        xMeters: 2, yMeters: 0, upMeters: 0,
        headingDegrees: 0, stepIndex: 1, timestampMs: 1000,
      ),
      MappingPoint(
        xMeters: 4, yMeters: 0, upMeters: 1.5,
        headingDegrees: 0, stepIndex: 2, timestampMs: 3000,
      ),
      MappingPoint(
        xMeters: 6, yMeters: 0, upMeters: 3,
        headingDegrees: 0, stepIndex: 3, timestampMs: 5000,
      ),
      MappingPoint(
        xMeters: 9, yMeters: 0, upMeters: 3,
        headingDegrees: 0, stepIndex: 4, timestampMs: 7000,
      ),
    ];

MappingMarker secondFloor() => const MappingMarker(
      id: 'f2landing',
      label: 'Reached Floor 2',
      type: 'floor_level',
      floor: 2,
      xMeters: 6, yMeters: 0, upMeters: 3,
      pointIndex: 3,
    );

MappingSession staircaseSession() => MappingSession(
      id: 'test_v10_stairs',
      venueId: 'campus',
      venueName: 'Campus',
      floor: 1,
      createdAt: DateTime.utc(2026, 11, 7),
      startAnchorId: null,
      startAnchorLabel: 'Floor 1 temporary session origin',
      originHeadingDegrees: 0,
      stepLengthMeters: 0,
      source: 'arcore_spatial_3d',
      points: staircasePoints(),
      markers: [secondFloor()],
      rawPointCount: 50,
    );

void main() {
  test('V10 measures REAL vertical rise and full 3D path length', () {
    final result = Continuous3DTrace.analyze(
      points: staircasePoints(),
      markers: [secondFloor()],
      startFloor: 1,
    );
    expect(result.netHeightMeters, closeTo(3, 0.000001));
    expect(result.ascentMeters, closeTo(3, 0.000001));
    expect(result.descentMeters, 0);
    expect(result.horizontalMeters, closeTo(9, 0.000001));
    expect(result.pathMeters, greaterThan(result.horizontalMeters));
    expect(result.visitedFloors, [1, 2]);
    expect(result.hasMeasuredClimb, isTrue);
    expect(result.hasLabeledTransition, isTrue);
  });

  test('native trace points retain each UP height without XY flattening', () {
    final exported = Continuous3DTrace.toLivePreviewPoints(
      points: staircasePoints(),
      markers: [secondFloor()],
    );
    expect(exported, hasLength(5));
    expect(exported[0]['up'], 0);
    expect(exported[2]['up'], 1.5);
    expect(exported[3]['up'], 3);
    expect(exported[3]['label'], 'Reached Floor 2');
    expect(exported[4]['forward'], 0);
  });

  test('3D simplifier preserves staircase geometry and physical landing', () {
    final result = const MappingPathSimplifier().simplify(
      points: staircasePoints(),
      markers: [secondFloor()],
      toleranceMeters: 0.12,
    );
    expect(result.points.first.upMeters, 0);
    expect(result.points.last.upMeters, 3);
    // A 3D simplifier may remove collinear intermediate samples (such as
    // the 1.5m point) while preserving the true ascending segment.
    final preserved = Continuous3DTrace.analyze(
      points: result.points,
      markers: result.markers,
      segmentStarts: result.segmentStarts,
      startFloor: 1,
    );
    expect(preserved.netHeightMeters, closeTo(3, 0.000001));
    expect(preserved.pathMeters, greaterThan(preserved.horizontalMeters));
    expect(preserved.hasMeasuredClimb, isTrue);
    expect(result.markers.single.type, 'floor_level');
    final landing = result.points[result.markers.single.pointIndex];
    expect(landing.upMeters, 3);
    expect(result.segmentStarts, [0]);
  });

  test('saved 3D session round trips with its height and floor markers', () {
    final original = staircaseSession();
    final restored = MappingSession.fromJson(original.toJson());
    expect(restored.isContinuous3D, isTrue);
    expect(restored.isSpatial, isTrue);
    expect(restored.segmentCount, 1);
    expect(restored.points[2].upMeters, 1.5);
    expect(restored.markers.single.floor, 2);
    expect(restored.totalDistanceMeters,
        greaterThan(restored.horizontalExtentMeters));
    expect(restored.startAnchorId, isNull);
    expect(restored.qualityLabel, 'GOOD');
  });

  test('never turn disconnected ARCore segments into a fake staircase', () {
    expect(
      () => Continuous3DTrace.analyze(
        points: staircasePoints(),
        segmentStarts: const [0, 2],
      ),
      throwsStateError,
    );
    expect(
      () => Continuous3DTrace.toLivePreviewPoints(
        points: staircasePoints(),
        segmentStarts: const [0, 3],
      ),
      throwsStateError,
    );
  });

  test('invalid xyz and floor marker indices are rejected', () {
    expect(
      () => Continuous3DTrace.analyze(
        points: [
          staircasePoints().first,
          const MappingPoint(
            xMeters: double.nan, yMeters: 2, upMeters: 0,
            headingDegrees: 0, stepIndex: 1, timestampMs: 1100,
          ),
        ],
      ),
      throwsStateError,
    );
    expect(
      () => Continuous3DTrace.analyze(
        points: staircasePoints(),
        markers: [
          const MappingMarker(
            id: 'bad', label: 'Wrong', type: 'floor_level',
            floor: 2, xMeters: 1, yMeters: 1,
            pointIndex: 999,
          ),
        ],
      ),
      throwsStateError,
    );
  });

  test('the old 2D venue cannot APPLY or MERGE a V10 3D trace', () {
    final oldVenue = Venue(
      id: 'campus',
      name: 'Campus',
      description: 'Old 2D graph retained',
      defaultStartNodeId: 'entrance',
      floors: const [1, 2],
      nodes: const [
        NavNode(
          id: 'entrance',
          label: 'Main entrance',
          floor: 1,
          x: 0,
          y: 0,
          type: 'anchor',
        ),
      ],
      edges: const [],
      destinations: const [],
      anchors: const [],
    );
    final trace = staircaseSession();
    const oldEditor = VenueMappingService();
    expect(
      () => oldEditor.applySession(venue: oldVenue, session: trace),
      throwsStateError,
    );
    expect(
      () => oldEditor.mergeSession(venue: oldVenue, session: trace),
      throwsStateError,
    );
    expect(oldVenue.nodes, hasLength(1));
    expect(oldVenue.nodeById('entrance').floor, 1);
  });

  test('V10 does not falsely report staircase ascent on a flat corridor', () {
    final flat = [
      staircasePoints()[0],
      staircasePoints()[1],
    ];
    final result = Continuous3DTrace.analyze(
      points: flat,
      startFloor: 1,
    );
    expect(result.netHeightMeters, 0);
    expect(result.hasMeasuredClimb, isFalse);
    expect(result.visitedFloors, [1]);
    expect(result.hasLabeledTransition, isFalse);
  });
  test('V10 partial autosave round-trips as a protected unfinished draft', () {
    final saved = staircaseSession().toJson();
    saved['source'] = 'arcore_spatial_3d_draft';
    final draft = MappingSession.fromJson(saved);

    expect(draft.isDraft3D, isTrue);
    expect(draft.isContinuous3D, isTrue);
    expect(draft.isSpatial, isTrue);
    expect(draft.qualityLabel, 'DRAFT');
    expect(draft.points[3].upMeters, 3);
    expect(draft.markers.single.floor, 2);

    final campus = Venue(
      id: 'campus',
      name: 'Campus',
      description: '',
      defaultStartNodeId: 'entrance',
      floors: const [1, 2],
      nodes: const [
        NavNode(
          id: 'entrance', label: 'Entrance',
          floor: 1, x: 0, y: 0, type: 'entrance',
        ),
      ],
      edges: const [], destinations: const [], anchors: const [],
    );
    const service = VenueMappingService();
    expect(
      () => service.applySession(venue: campus, session: draft),
      throwsStateError,
    );
    expect(
      () => service.mergeSession(venue: campus, session: draft),
      throwsStateError,
    );
  });

  test('V10 floor labels are metadata, not a requirement for 3D trace', () {
    final summary = Continuous3DTrace.analyze(
      points: staircasePoints(),
      startFloor: 1,
    );
    expect(summary.netHeightMeters, 3);
    expect(summary.hasMeasuredClimb, isTrue);
    expect(summary.visitedFloors, [1]);
    expect(summary.hasLabeledTransition, isFalse);
  });

}
