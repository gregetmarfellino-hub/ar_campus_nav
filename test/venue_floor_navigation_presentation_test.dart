import 'package:flutter_test/flutter_test.dart';

import 'package:ar_campus_nav/models/destination.dart';
import 'package:ar_campus_nav/models/nav_edge.dart';
import 'package:ar_campus_nav/models/nav_node.dart';
import 'package:ar_campus_nav/models/venue.dart';
import 'package:ar_campus_nav/services/route_engine.dart';
import 'package:ar_campus_nav/services/venue_map_semantics.dart';

const home = Venue(
  id: 'test_v15',
  name: 'House',
  description: '',
  defaultStartNodeId: 's0',
  floors: [1, 2],
  nodes: [
    NavNode(id: 's0', label: 'Recorded start', floor: 1,
        x: 0, y: 0, type: 'waypoint'),
    NavNode(id: 's1', label: '3D waypoint 7', floor: 1,
        x: 1, y: 0, type: 'waypoint'),
    NavNode(id: 's2', label: 'Main Entrance', floor: 1,
        x: 2, y: 0, type: 'anchor'),
    NavNode(id: 's3', label: '3D waypoint 14', floor: 2,
        x: 2, y: 1, type: 'waypoint', upMeters: 3.5),
    NavNode(id: 's4', label: '3D waypoint 15', floor: 2,
        x: 3, y: 1, type: 'waypoint', upMeters: 3.5),
  ],
  edges: [
    NavEdge(from: 's0', to: 's1', distanceMeters: 1),
    NavEdge(from: 's1', to: 's2', distanceMeters: 1),
    NavEdge(from: 's2', to: 's3', distanceMeters: 3.65,
        transitionType: 'stairs', measured3D: true),
    NavEdge(from: 's3', to: 's4', distanceMeters: 1),
  ],
  destinations: [
    Destination(id: 'room_1', name: 'Room 1',
        nodeId: 's1', category: 'place'),
  ],
  anchors: [],
);

void main() {
  test('Raw 3D samples are not user-facing named waypoints', () {
    expect(VenueMapSemantics.isNamedWaypoint(home.nodes[0]), isFalse);
    expect(VenueMapSemantics.isNamedWaypoint(home.nodes[1]), isFalse);
    expect(VenueMapSemantics.isNamedWaypoint(home.nodes[3]), isFalse);
    expect(
      VenueMapSemantics.isNamedWaypoint(const NavNode(
        id: 'real', label: 'Water fountain', floor: 2,
        x: 0, y: 0, type: 'waypoint',
      )),
      isTrue,
    );
  });

  test('Floor 2 gets selectable, explicitly provisional mapped entry', () {
    final targets = VenueMapSemantics.floorEntryTargets(home);
    expect(targets, hasLength(1));
    expect(targets.single.name, 'Floor 2 - first mapped point');
    expect(targets.single.nodeId, 's3');
    expect(targets.single.description, contains('not a tagged room'));

    // This is a UI-only destination. Underlying XYZ nodes remain unchanged.
    expect(home.destinations, hasLength(1));
    expect(home.nodes, hasLength(5));

    final route = const RouteEngine().shortestPath(
      venue: home, startNodeId: 's2',
      destinationNodeId: targets.single.nodeId,
    );
    expect(route.crossesFloors, isTrue);
    expect(route.nodes.last.id, 's3');
  });

  test('Basement entry points are also selectable without remapping', () {
    const basement = Venue(
      id: 'basement', name: 'House', description: '',
      defaultStartNodeId: 'g', floors: [-1, 1],
      nodes: [
        NavNode(id: 'g', label: 'Recorded start', floor: 1,
            x: 0, y: 0, type: 'waypoint'),
        NavNode(id: 'b', label: '3D waypoint 2', floor: -1,
            x: 0, y: 1, type: 'waypoint', upMeters: -3),
      ],
      edges: [],
      destinations: [],
      anchors: [],
    );
    final targets = VenueMapSemantics.floorEntryTargets(basement);
    expect(targets.single.name, 'Basement 1 - first mapped point');
    expect(targets.single.nodeId, 'b');
  });
}
