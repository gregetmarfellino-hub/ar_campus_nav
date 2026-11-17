import 'package:flutter_test/flutter_test.dart';

import 'package:ar_campus_nav/models/destination.dart';
import 'package:ar_campus_nav/models/mapping_session.dart';
import 'package:ar_campus_nav/models/nav_edge.dart';
import 'package:ar_campus_nav/models/nav_node.dart';
import 'package:ar_campus_nav/models/venue.dart';
import 'package:ar_campus_nav/services/mapping_path_simplifier.dart';
import 'package:ar_campus_nav/services/route_endpoint_policy.dart';
import 'package:ar_campus_nav/services/venue_map_semantics.dart';

const path = <MappingPoint>[
  MappingPoint(
    xMeters: 0, yMeters: 0, upMeters: 0,
    headingDegrees: 0, stepIndex: 0, timestampMs: 10,
  ),
  MappingPoint(
    xMeters: 1, yMeters: 0.2, upMeters: 0,
    headingDegrees: 0, stepIndex: 1, timestampMs: 20,
  ),
  MappingPoint(
    xMeters: 1.5, yMeters: 1, upMeters: 1,
    headingDegrees: 0, stepIndex: 2, timestampMs: 30,
  ),
  MappingPoint(
    xMeters: 2, yMeters: 1.6, upMeters: 3.2,
    headingDegrees: 0, stepIndex: 3, timestampMs: 40,
  ),
];
const entrance = MappingMarker(
  id: 'entrance',
  label: 'Main Entrance',
  type: 'anchor',
  floor: 1,
  xMeters: 0, yMeters: 0,
  pointIndex: 0,
);

void main() {
  test('final measured point becomes a floor 2 destination', () {
    final markers = const RouteEndpointPolicy().withFinishDestination(
      points: path,
      markers: [entrance],
      floor: 2,
      label: 'Second floor corridor end',
      id: 'end_1',
    );

    expect(markers, hasLength(2));
    expect(markers.first.id, 'entrance');
    expect(markers.last.type, 'destination');
    expect(markers.last.floor, 2);
    expect(markers.last.pointIndex, path.length - 1);
    expect(markers.last.upMeters, 3.2);
    expect(markers.last.xMeters, path.last.xMeters);
    expect(markers.last.label, 'Second floor corridor end');

    final simplified = const MappingPathSimplifier().simplify(
      points: path,
      markers: markers,
    );
    expect(simplified.points.first.xMeters, path.first.xMeters);
    expect(simplified.points.last.upMeters, path.last.upMeters);
    expect(simplified.markers.last.pointIndex, simplified.points.length - 1);
    expect(simplified.markers.first.id, entrance.id);
  });

  test('existing user-tagged end destination is not duplicated', () {
    const namedEnd = MappingMarker(
      id: 'actual_room',
      label: 'Room on Floor 2',
      type: 'destination',
      floor: 2,
      xMeters: 2, yMeters: 1.6, upMeters: 3.2,
      pointIndex: 3,
    );
    final markers = const RouteEndpointPolicy().withFinishDestination(
      points: path,
      markers: [entrance, namedEnd],
      floor: 2,
      label: 'Another name',
      id: 'end_1',
    );
    expect(markers, hasLength(2));
    expect(markers.last.id, 'actual_room');
  });

  test('invalid or empty geometry never silently creates fake endpoints', () {
    expect(
      () => const RouteEndpointPolicy().withFinishDestination(
        points: const [],
        markers: const [],
        floor: 2,
        label: 'End',
        id: 'end_1',
      ),
      throwsStateError,
    );
    expect(
      () => const RouteEndpointPolicy().withFinishDestination(
        points: path,
        markers: const [],
        floor: 2,
        label: ' ',
        id: 'end_1',
      ),
      throwsFormatException,
    );
  });

  test('old published path gets nonpersistent last-XYZ destination', () {
    const legacy = Venue(
      id: 'legacy',
      name: 'Old map',
      description: '',
      defaultStartNodeId: 'origin',
      floors: [1, 2],
      nodes: [
        NavNode(id: 'origin', label: 'Main Entrance',
            floor: 1, x: 0, y: 0, type: 'anchor'),
        NavNode(id: 'upstairs', label: '3D waypoint 2',
            floor: 2, x: 2, y: 1.6, upMeters: 3.2, type: 'waypoint'),
      ],
      edges: [
        NavEdge(from: 'origin', to: 'upstairs', distanceMeters: 4,
            measured3D: true, transitionType: 'stairs'),
      ],
      destinations: [],
      anchors: [],
    );
    final targets = VenueMapSemantics.recordedRouteEndTargets(legacy);
    expect(targets, hasLength(1));
    expect(targets.single.nodeId, 'upstairs');
    expect(targets.single.name, 'Floor 2 - recorded route end');
    expect(legacy.destinations, isEmpty);

    const published = Venue(
      id: 'new', name: 'New map', description: '',
      defaultStartNodeId: 'origin', floors: [1, 2],
      nodes: [
        NavNode(id: 'origin', label: 'Main Entrance',
            floor: 1, x: 0, y: 0, type: 'anchor'),
        NavNode(id: 'upstairs', label: 'Second floor corridor end',
            floor: 2, x: 2, y: 1.6, type: 'destination'),
      ],
      edges: [],
      destinations: [
        Destination(id: 'end', name: 'Second floor corridor end',
            nodeId: 'upstairs', category: 'place'),
      ],
      anchors: [],
    );
    expect(VenueMapSemantics.recordedRouteEndTargets(published), isEmpty,
        reason: 'A truly named route end beats the provisional UI target.');
  });
}
