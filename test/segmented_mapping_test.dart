import 'package:flutter_test/flutter_test.dart';

import 'package:ar_campus_nav/models/anchor_point.dart';
import 'package:ar_campus_nav/models/mapping_session.dart';
import 'package:ar_campus_nav/models/nav_node.dart';
import 'package:ar_campus_nav/models/venue.dart';
import 'package:ar_campus_nav/services/mapping_path_simplifier.dart';
import 'package:ar_campus_nav/services/route_engine.dart';
import 'package:ar_campus_nav/services/venue_graph_editor.dart';
import 'package:ar_campus_nav/services/venue_mapping_service.dart';

MappingPoint p(int index, double x, double y) => MappingPoint(
      xMeters: x,
      yMeters: y,
      headingDegrees: 0,
      stepIndex: index,
      timestampMs: index * 100,
    );

Venue sourceVenue() => const Venue(
      id: 'campus',
      name: 'Campus',
      description: 'test',
      defaultStartNodeId: 'entry',
      floors: [1],
      nodes: [
        NavNode(
          id: 'entry', label: 'Entrance', floor: 1,
          x: 0, y: 0, type: 'entrance',
        ),
      ],
      edges: [],
      destinations: [],
      anchors: [
        AnchorPoint(
          id: 'entrance_qr', label: 'Entrance QR',
          nodeId: 'entry', floor: 1,
        ),
      ],
    );

MappingSession recording({
  List<int> boundaries = const [0, 2],
}) => MappingSession(
      id: 'several_paths',
      venueId: 'campus',
      venueName: 'Campus',
      floor: 1,
      createdAt: DateTime.utc(2026, 11, 1),
      startAnchorId: 'entrance_qr',
      startAnchorLabel: 'Entrance QR',
      originHeadingDegrees: 0,
      stepLengthMeters: 0,
      source: 'arcore_spatial',
      points: [
        p(0, 0, 0),
        p(1, 0, 2),
        p(2, 100, 0),
        p(3, 100, 2),
      ],
      markers: const [
        MappingMarker(
          id: 'supermarket',
          label: 'Supermarket',
          type: 'destination',
          floor: 1,
          xMeters: 100,
          yMeters: 2,
          pointIndex: 3,
        ),
      ],
      segmentStarts: boundaries,
    );

void main() {
  const simplifier = MappingPathSimplifier();
  const graphs = VenueGraphEditor();

  test('raw saved JSON v3 preserves section boundaries and distance', () {
    final session = recording();
    expect(session.totalDistanceMeters, closeTo(4, 1e-8));
    expect(session.segmentCount, 2);
    expect(session.toJson()['segment_starts'], [0, 2]);
    expect(session.toJson()['schema'], 'ar_campus_nav.mapping.v3');
    final restored = MappingSession.fromJson(session.toJson());
    expect(restored.effectiveSegmentStarts, [0, 2]);
    expect(restored.totalDistanceMeters, closeTo(4, 1e-8));
    expect(restored.markers.single.pointIndex, 3);
  });

  test('old recordings without section metadata remain continuous', () {
    final json = recording().toJson()..remove('segment_starts');
    json['schema'] = 'ar_campus_nav.mapping.v2';
    final previous = MappingSession.fromJson(json);
    expect(previous.effectiveSegmentStarts, [0]);
    expect(previous.segmentCount, 1);
    expect(previous.totalDistanceMeters, greaterThan(100));
  });

  test('simplification never removes the two sides of a section break', () {
    final original = [
      p(0, 0, 0),
      p(1, 0, 1),
      p(2, 0, 2),
      p(3, 100, 0),
      p(4, 100, 1),
      p(5, 100, 2),
    ];
    const marker = MappingMarker(
      id: 'destination', label: 'End',
      type: 'destination', floor: 1,
      xMeters: 100, yMeters: 1, pointIndex: 4,
    );
    final simplified = simplifier.simplify(
      points: original,
      segmentStarts: const [0, 3],
      markers: const [marker],
      toleranceMeters: 0.10,
    );
    expect(simplified.segmentStarts.length, 2);
    final newBreak = simplified.segmentStarts[1];
    expect(simplified.points[newBreak].xMeters, 100);
    expect(simplified.points[newBreak - 1].xMeters, 0);
    expect(
      simplified.points[simplified.markers.single.pointIndex].yMeters, 1,
    );
    expect(simplified.points.length, lessThan(original.length));
  });

  test('short two-point recordings keep explicit split indices', () {
    final simplified = simplifier.simplify(
      points: [p(0, 0, 0), p(1, 10, 0)],
      segmentStarts: const [0, 1],
      markers: const [],
    );
    expect(simplified.segmentStarts, [0, 1]);
  });

  test('applied venue never invents a route across 100-metre gap', () {
    final venue = const VenueMappingService().applySession(
      venue: sourceVenue(),
      session: recording(),
    );
    expect(venue.edges, hasLength(2));
    expect(venue.edges.every(
      (e) => e.distanceMeters < 5,
    ), isTrue);
    final dest = venue.destinations.single;
    expect(graphs.unreachableDestinations(venue), ['Supermarket']);
    expect(
      () => const RouteEngine().shortestPath(
        venue: venue,
        startNodeId: venue.defaultStartNodeId,
        destinationNodeId: dest.nodeId,
      ),
      throwsStateError,
    );
  });

  test('deliberate alignment translates only the disconnected section', () {
    final venue = const VenueMappingService().applySession(
      venue: sourceVenue(),
      session: recording(),
    );
    final fixed = venue.nodes.firstWhere(
      (n) => n.id != venue.defaultStartNodeId && n.x.abs() < 5,
    );
    final moving = venue.nodes.firstWhere((n) => n.x.abs() > 50);
    final movedPartBefore = venue.edges.last.distanceMeters;
    final aligned = graphs.alignAndJoinSections(
      venue,
      movingPointId: moving.id,
      fixedPointId: fixed.id,
    );
    final route = const RouteEngine().shortestPath(
      venue: aligned,
      startNodeId: aligned.defaultStartNodeId,
      destinationNodeId: aligned.destinations.single.nodeId,
    );
    expect(route.nodes, isNotEmpty);
    expect(aligned.nodeById('entry').x, venue.nodeById('entry').x);
    expect(aligned.nodeById('entry').y, venue.nodeById('entry').y);
    expect(aligned.edges, hasLength(3));
    expect(aligned.edges[1].distanceMeters, movedPartBefore);
    expect(aligned.anchors.single.id, 'entrance_qr');
    expect(aligned.nodeById(moving.id).x, closeTo(fixed.x, 1e-6));
    expect(aligned.nodeById(moving.id).y, closeTo(fixed.y, 1e-6));
    graphs.validate(aligned);
  });

  test('unverified distant endpoints cannot become direct walkable edges', () {
    final venue = const VenueMappingService().applySession(
      venue: sourceVenue(),
      session: recording(),
    );
    final source = venue.defaultStartNodeId;
    final distant = venue.nodes.firstWhere((n) => n.x.abs() > 50);
    expect(
      () => graphs.connectNodes(venue, from: source, to: distant.id),
      throwsStateError,
    );
  });

  test('cannot translate a section containing a real start anchor', () {
    final venue = const VenueMappingService().applySession(
      venue: sourceVenue(),
      session: recording(),
    );
    final distant = venue.nodes.firstWhere((n) => n.x.abs() > 50);
    expect(
      () => graphs.alignAndJoinSections(
        venue, movingPointId: 'entry', fixedPointId: distant.id,
      ),
      throwsStateError,
    );
  });
}
