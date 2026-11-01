import 'package:flutter_test/flutter_test.dart';

import 'package:ar_campus_nav/models/anchor_point.dart';
import 'package:ar_campus_nav/models/mapping_session.dart';
import 'package:ar_campus_nav/models/destination.dart';
import 'package:ar_campus_nav/models/nav_edge.dart';
import 'package:ar_campus_nav/models/nav_node.dart';
import 'package:ar_campus_nav/models/venue.dart';
import 'package:ar_campus_nav/services/route_engine.dart';
import 'package:ar_campus_nav/services/venue_codec.dart';
import 'package:ar_campus_nav/services/venue_graph_editor.dart';
import 'package:ar_campus_nav/services/venue_mapping_service.dart';

Venue building() => const Venue(
      id: 'campus',
      name: 'Campus',
      description: 'Multi-floor campus fixture',
      defaultStartNodeId: 'entrance',
      floors: [-1, 1, 2, 3],
      nodes: [
        NavNode(
          id: 'entrance', label: 'Entrance', floor: 1,
          x: 0, y: 0, type: 'entrance',
        ),
        NavNode(
          id: 'f1stair', label: 'Main stairs F1', floor: 1,
          x: 3, y: 0, type: 'stairs',
        ),
        NavNode(
          id: 'f2stair', label: 'Main stairs F2', floor: 2,
          x: 40, y: 22, type: 'stairs',
        ),
        NavNode(
          id: 'f2room', label: 'Room 201', floor: 2,
          x: 42, y: 22, type: 'destination',
        ),
        NavNode(
          id: 'bstair', label: 'Basement landing', floor: -1,
          x: -30, y: 22, type: 'stairs',
        ),
        NavNode(
          id: 'f3stair', label: 'Stairs F3', floor: 3,
          x: 50, y: 40, type: 'stairs',
        ),
        NavNode(
          id: 'f1lift', label: 'Lift F1', floor: 1,
          x: 1, y: 2, type: 'elevator',
        ),
        NavNode(
          id: 'f3lift', label: 'Lift F3', floor: 3,
          x: -12, y: 4, type: 'elevator',
        ),
        NavNode(
          id: 'ordinary', label: 'Unmarked point', floor: 2,
          x: 44, y: 22, type: 'waypoint',
        ),
      ],
      edges: [
        NavEdge(from: 'entrance', to: 'f1stair', distanceMeters: 3),
        NavEdge(from: 'f2stair', to: 'f2room', distanceMeters: 2),
        NavEdge(from: 'entrance', to: 'f1lift', distanceMeters: 3),
      ],
      destinations: [
        Destination(
          id: 'room201', name: 'Room 201', nodeId: 'f2room',
          category: 'place',
        ),
      ],
      anchors: [
        AnchorPoint(
          id: 'start', label: 'Known entrance',
          nodeId: 'entrance', floor: 1,
        ),
      ],
    );

void main() {
  const editor = VenueGraphEditor();
  const routes = RouteEngine();
  const codec = VenueCodec();

  test('cannot route upstairs before physically linking stair portals', () {
    final venue = building();
    expect(
      () => routes.shortestPath(
        venue: venue,
        startNodeId: 'entrance',
        destinationNodeId: 'f2room',
      ),
      throwsStateError,
    );
  });

  test('explicit stairs link crosses floor and keeps actual travel distance', () {
    final venue = editor.linkFloorPortals(
      building(),
      from: 'f1stair',
      to: 'f2stair',
      kind: 'stairs',
      distanceMeters: 8.5,
    );
    editor.validate(venue);
    final route = routes.shortestPath(
      venue: venue,
      startNodeId: 'entrance',
      destinationNodeId: 'f2room',
    );
    expect(route.nodes.map((n) => n.id),
        ['entrance', 'f1stair', 'f2stair', 'f2room']);
    expect(route.crossesFloors, isTrue);
    expect(route.visitedFloors, [1, 2]);
    expect(route.legs[1].transitionType, 'stairs');
    expect(route.legs[1].isFloorTransition, isTrue);
    expect(route.totalDistanceMeters, closeTo(13.5, 0.00001));

    final restored = codec.fromJson(codec.toJson(venue));
    expect(restored.edges.last.transitionType, 'stairs');
    final restoredRoute = routes.shortestPath(
      venue: restored,
      startNodeId: 'entrance',
      destinationNodeId: 'f2room',
    );
    expect(restoredRoute.totalDistanceMeters, closeTo(13.5, 0.00001));
    expect(restored.anchors.single.nodeId, 'entrance');
  });

  test('basement and Floor 1 are adjacent floor layers', () {
    final venue = editor.linkFloorPortals(
      building(),
      from: 'f1stair',
      to: 'bstair',
      kind: 'stairs',
      distanceMeters: 7,
    );
    expect(venue.edges.last.transitionType, 'stairs');
    editor.validate(venue);
  });

  test('stairs refuse skipped floor; elevator can span levels', () {
    expect(
      () => editor.linkFloorPortals(
        building(),
        from: 'f1stair',
        to: 'f3stair',
        kind: 'stairs',
        distanceMeters: 12,
      ),
      throwsStateError,
    );
    final venue = editor.linkFloorPortals(
      building(),
      from: 'f1lift',
      to: 'f3lift',
      kind: 'elevator',
      distanceMeters: 16,
    );
    expect(venue.edges.last.transitionType, 'elevator');
    editor.validate(venue);
  });

  test('portal links cannot connect ordinary points or same-floor endpoints', () {
    expect(
      () => editor.linkFloorPortals(
        building(),
        from: 'ordinary',
        to: 'f1stair',
        kind: 'stairs',
        distanceMeters: 5,
      ),
      throwsStateError,
    );
    expect(
      () => editor.linkFloorPortals(
        building(),
        from: 'entrance',
        to: 'f1stair',
        kind: 'stairs',
        distanceMeters: 5,
      ),
      throwsStateError,
    );
    expect(
      () => editor.linkFloorPortals(
        building(),
        from: 'f1stair',
        to: 'f2stair',
        kind: 'stairs',
        distanceMeters: double.nan,
      ),
      throwsArgumentError,
    );
  });

  test('floor layer creation preserves old mapping and anchor', () {
    final venue = editor.addFloor(building(), 4);
    expect(venue.floors, [-1, 1, 2, 3, 4]);
    expect(venue.nodes.length, building().nodes.length);
    expect(venue.anchors.single.nodeId, 'entrance');
    expect(codec.fromJson(codec.toJson(venue)).floors, [-1, 1, 2, 3, 4]);
  });

  test('mark an already recorded waypoint as stair entrance', () {
    final venue = editor.markFloorPortal(
      building(),
      nodeId: 'ordinary',
      kind: 'stairs',
    );
    expect(venue.nodeById('ordinary').type, 'stairs');
    expect(venue.nodeById('ordinary').x, 44);
    expect(venue.nodes.length, building().nodes.length);
    expect(() => editor.markFloorPortal(
      venue, nodeId: 'entrance', kind: 'stairs',
    ), throwsStateError);
  });

  test('reject legacy unlabeled connections between different floors', () {
    final base = building();
    final broken = Venue(
      id: base.id,
      name: base.name,
      description: base.description,
      defaultStartNodeId: base.defaultStartNodeId,
      floors: base.floors,
      nodes: base.nodes,
      edges: [
        ...base.edges,
        const NavEdge(
          from: 'f1stair',
          to: 'f2stair',
          distanceMeters: 5,
        ),
      ],
      anchors: base.anchors,
      destinations: base.destinations,
    );
    expect(() => editor.validate(broken), throwsStateError);
  });

  test('same-floor route keeps its normal graph behavior', () {
    final route = routes.shortestPath(
      venue: building(),
      startNodeId: 'entrance',
      destinationNodeId: 'f1stair',
    );
    expect(route.crossesFloors, isFalse);
    expect(route.visitedFloors, [1]);
    expect(route.legs.single.transitionType, isNull);
  });
  test('applying a new floor recording retains the original entrance', () {
    final initial = building();
    final upstairs = MappingSession(
      id: 'floor2_new_map',
      venueId: initial.id,
      venueName: initial.name,
      floor: 2,
      createdAt: DateTime.utc(2026, 11, 1),
      startAnchorId: null,
      startAnchorLabel: 'Upper floor start',
      originHeadingDegrees: 0,
      stepLengthMeters: 0,
      source: 'arcore_spatial',
      points: const [
        MappingPoint(
          xMeters: 0, yMeters: 0, upMeters: 0,
          headingDegrees: 0, stepIndex: 0, timestampMs: 0,
        ),
        MappingPoint(
          xMeters: 0, yMeters: 3, upMeters: 0,
          headingDegrees: 0, stepIndex: 1, timestampMs: 1000,
        ),
      ],
      markers: const [],
    );
    final next = const VenueMappingService().applySession(
      venue: initial,
      session: upstairs,
    );
    expect(next.defaultStartNodeId, 'entrance');
    expect(next.nodeById('entrance').floor, 1);
    expect(next.anchors.single.nodeId, 'entrance');
    expect(next.floors, containsAll([-1, 1, 2, 3]));
    expect(next.nodes.where((node) => node.floor == 2), isNotEmpty);
    expect(next.nodes.any((node) => node.id == 'f1stair'), isTrue);
  });

}
