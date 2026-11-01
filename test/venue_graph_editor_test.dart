import 'package:flutter_test/flutter_test.dart';

import 'package:ar_campus_nav/models/anchor_point.dart';
import 'package:ar_campus_nav/models/destination.dart';
import 'package:ar_campus_nav/models/nav_edge.dart';
import 'package:ar_campus_nav/models/nav_node.dart';
import 'package:ar_campus_nav/models/venue.dart';
import 'package:ar_campus_nav/services/route_engine.dart';
import 'package:ar_campus_nav/services/venue_codec.dart';
import 'package:ar_campus_nav/services/venue_graph_editor.dart';
import 'package:ar_campus_nav/services/venue_override_storage.dart';

void main() {
  const editor = VenueGraphEditor();

  Venue mappedVenue() => const Venue(
        id: 'campus',
        name: 'Mapped campus',
        description: 'One saved ARCore walkway',
        defaultStartNodeId: 'entrance',
        floors: [-1, 1],
        nodes: [
          NavNode(
            id: 'entrance',
            label: 'Start QR',
            floor: 1,
            x: 0,
            y: 0,
            type: 'entrance',
          ),
          NavNode(
            id: 'hall',
            label: 'Recorded path',
            floor: 1,
            x: 0,
            y: 3,
            type: 'path',
          ),
          NavNode(
            id: 'room',
            label: 'Room 101',
            floor: 1,
            x: 0,
            y: 7,
            type: 'destination',
          ),
          NavNode(
            id: 'branch',
            label: 'Extra waypoint',
            floor: 1,
            x: 3,
            y: 3,
            type: 'waypoint',
          ),
          NavNode(
            id: 'basement',
            label: 'Basement stairs',
            floor: -1,
            x: 1,
            y: 1,
            type: 'stairs',
          ),
        ],
        edges: [
          NavEdge(from: 'entrance', to: 'hall', distanceMeters: 3),
          NavEdge(from: 'hall', to: 'room', distanceMeters: 4),
        ],
        destinations: [
          Destination(
            id: 'd101',
            name: 'Room 101',
            nodeId: 'room',
            category: 'place',
          ),
        ],
        anchors: [
          AnchorPoint(
            id: 'a1',
            label: 'Saved visual QR',
            nodeId: 'entrance',
            floor: 1,
            offlineVisualReferencePngBase64: 'fake_saved_reference',
          ),
        ],
      );

  test('moving a mapped waypoint only changes its incident distances', () {
    final before = mappedVenue();
    final after = editor.moveNode(before, nodeId: 'hall', x: 1, y: 4);

    expect(before.nodeById('hall').x, 0);
    expect(after.nodeById('hall').x, 1);
    expect(after.nodeById('hall').y, 4);
    expect(after.edges[0].distanceMeters, closeTo(4.1231056, 0.0001));
    expect(after.edges[1].distanceMeters, closeTo(3.16227766, 0.0001));
    expect(after.anchors.single.offlineVisualReferencePngBase64,
        'fake_saved_reference');
    expect(after.nodes.where((node) => node.floor == -1).single.x, 1);
  });

  test('saving a manually connected branch makes it routeable', () {
    final base = mappedVenue();
    expect(
      () => const RouteEngine().shortestPath(
        venue: base,
        startNodeId: 'entrance',
        destinationNodeId: 'branch',
      ),
      throwsStateError,
    );
    final connected = editor.connectNodes(
      base,
      from: 'hall',
      to: 'branch',
    );
    final route = const RouteEngine().shortestPath(
      venue: connected,
      startNodeId: 'entrance',
      destinationNodeId: 'branch',
    );
    expect(route.nodes.map((node) => node.id),
        ['entrance', 'hall', 'branch']);
    expect(route.totalDistanceMeters, closeTo(6, 0.0001));
    expect(base.edges.length, 2);
    expect(connected.edges.length, 3);
  });

  test('duplicate connections and self-connections are blocked', () {
    final venue = mappedVenue();
    expect(
      () => editor.connectNodes(venue, from: 'hall', to: 'entrance'),
      throwsStateError,
    );
    expect(
      () => editor.connectNodes(venue, from: 'hall', to: 'hall'),
      throwsStateError,
    );
  });

  test('vertical connection is rejected until stair portals exist', () {
    expect(
      () => editor.connectNodes(
        mappedVenue(), from: 'hall', to: 'basement',
      ),
      throwsStateError,
    );
  });

  test('splitting a recorded segment preserves reachability', () {
    final venue = editor.insertWaypoint(
      mappedVenue(),
      from: 'hall',
      to: 'room',
      newNodeId: 'inserted',
      x: 1,
      y: 5,
    );
    expect(venue.nodeById('inserted').floor, 1);
    expect(venue.edges.length, 3);
    expect(venue.edges.any((edge) =>
        edge.from == 'hall' && edge.to == 'room'), isFalse);
    final route = const RouteEngine().shortestPath(
      venue: venue,
      startNodeId: 'entrance',
      destinationNodeId: 'room',
    );
    expect(route.nodes.map((node) => node.id),
        ['entrance', 'hall', 'inserted', 'room']);
  });

  test('inserting a waypoint near an endpoint is rejected', () {
    expect(
      () => editor.insertWaypoint(
        mappedVenue(),
        from: 'hall',
        to: 'room',
        newNodeId: 'inserted',
        x: 0,
        y: 3.02,
      ),
      throwsStateError,
    );
  });

  test('removing an edge is reversible in a previously saved venue object', () {
    final before = mappedVenue();
    final after = editor.disconnectNodes(
      before, from: 'hall', to: 'room',
    );
    expect(before.edges.length, 2);
    expect(after.edges.length, 1);
    expect(editor.unreachableDestinations(after), ['Room 101']);
    expect(editor.unreachableDestinations(before), isEmpty);
  });

  test('AR start anchor position and label cannot be edited', () {
    final venue = mappedVenue();
    expect(
      () => editor.moveNode(venue, nodeId: 'entrance', x: 1, y: 2),
      throwsStateError,
    );
    expect(
      () => editor.renameNode(venue, 'entrance', 'Moved QR'),
      throwsStateError,
    );
  });

  test('renaming a destination updates both graph and destination record', () {
    final after = editor.renameNode(mappedVenue(), 'room', 'Computer Lab');
    expect(after.nodeById('room').label, 'Computer Lab');
    expect(after.destinations.single.name, 'Computer Lab');
  });

  test('only unconnected, unreferenced waypoints can be deleted', () {
    final before = mappedVenue();
    final after = editor.deleteUnusedWaypoint(before, 'branch');
    expect(after.nodes.length, before.nodes.length - 1);
    expect(() => editor.deleteUnusedWaypoint(before, 'hall'),
        throwsStateError);
    expect(() => editor.deleteUnusedWaypoint(before, 'room'),
        throwsStateError);
    expect(() => editor.deleteUnusedWaypoint(before, 'entrance'),
        throwsStateError);
  });

  test('saved venue and start reference survive codec round-trip', () {
    final moved = editor.moveNode(mappedVenue(), nodeId: 'hall', x: 1, y: 4);
    final edited = editor.connectNodes(
      moved, from: 'hall', to: 'branch',
    );
    final previousDocument = VenueOverrideDocument(
      venue: edited,
      coordinateSpace: 'world_meters',
      appliedSessionIds: const ['mapping_1'],
      updatedAt: DateTime.utc(2026, 11, 1),
    );
    final roundTrip = VenueOverrideDocument.fromJson(
      previousDocument.toJson(),
    );
    expect(roundTrip.coordinateSpace, 'world_meters');
    expect(roundTrip.appliedSessionIds, ['mapping_1']);
    expect(roundTrip.venue.anchors.single.offlineVisualReferencePngBase64,
        'fake_saved_reference');
    expect(roundTrip.venue.edges.length, 3);
    expect(const VenueCodec().toJson(roundTrip.venue)['floors'],
        [-1, 1]);
    editor.validate(roundTrip.venue);
  });

  test('invalid point positions and duplicate IDs are rejected', () {
    expect(
      () => editor.moveNode(
        mappedVenue(), nodeId: 'hall', x: double.nan, y: 5,
      ),
      throwsArgumentError,
    );
    expect(
      () => editor.insertWaypoint(
        mappedVenue(),
        from: 'hall',
        to: 'room',
        newNodeId: 'room',
        x: 0,
        y: 5,
      ),
      throwsStateError,
    );
  });
  test('delete corrupt waypoint disconnects edges and preserves anchors', () {
    final before = mappedVenue();
    final after = editor.removeBadWaypoint(before, 'hall');
    expect(after.nodes.any((node) => node.id == 'hall'), isFalse);
    expect(after.edges, isEmpty);
    expect(before.edges.length, 2);
    expect(after.anchors.single.nodeId, 'entrance');
    expect(editor.unreachableDestinations(after), ['Room 101']);
    editor.validate(after);
  });

  test('repair simple bad bend reconnects nearby neighbors safely', () {
    final before = editor.moveNode(mappedVenue(), nodeId: 'room', x: 0, y: 4.5);
    final after = editor.removeBadWaypoint(
      before, 'hall', reconnectNeighbors: true,
    );
    expect(after.nodes.any((node) => node.id == 'hall'), isFalse);
    expect(after.edges, hasLength(1));
    expect(after.edges.single.from, 'entrance');
    expect(after.edges.single.to, 'room');
    expect(after.edges.single.distanceMeters, closeTo(4.5, 0.001));
  });

  test('repair refuses a large fabricated shortcut', () {
    final before = mappedVenue();
    expect(
      () => editor.removeBadWaypoint(
        before, 'hall', reconnectNeighbors: true,
      ),
      throwsStateError,
    );
  });

  test('corrupt point removal cannot delete destination or QR anchor', () {
    final before = mappedVenue();
    expect(() => editor.removeBadWaypoint(before, 'room'), throwsStateError);
    expect(() => editor.removeBadWaypoint(before, 'entrance'), throwsStateError);
  });

}
