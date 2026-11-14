import 'package:flutter_test/flutter_test.dart';

import 'package:ar_campus_nav/models/mapping_session.dart';
import 'package:ar_campus_nav/models/venue.dart';
import 'package:ar_campus_nav/services/anchor_codec.dart';
import 'package:ar_campus_nav/services/venue_3d_graph_service.dart';
import 'package:ar_campus_nav/services/venue_codec.dart';
import 'package:ar_campus_nav/services/venue_override_storage.dart';
import 'package:ar_campus_nav/services/route_engine.dart';

Venue blankCampus() => const Venue(
      id: 'campus',
      name: 'Real Campus',
      description: 'Original sample',
      defaultStartNodeId: 'sample',
      floors: [1, 2],
      nodes: [],
      edges: [],
      destinations: [],
      anchors: [],
    );

MappingSession climbSession({
  String source = 'arcore_spatial_3d',
  List<int> segmentStarts = const [0],
  String venueId = 'campus',
}) =>
    MappingSession(
      id: 'v11_walk_001',
      venueId: venueId,
      venueName: 'Real Campus',
      floor: 1,
      createdAt: DateTime.utc(2026, 11, 14),
      startAnchorId: null,
      startAnchorLabel: 'Unverified Floor 1 start',
      originHeadingDegrees: 0,
      stepLengthMeters: 0,
      source: source,
      segmentStarts: segmentStarts,
      points: const [
        MappingPoint(
          xMeters: 0, yMeters: 0, upMeters: 0,
          headingDegrees: 0, stepIndex: 0, timestampMs: 100,
        ),
        MappingPoint(
          xMeters: 2, yMeters: 0, upMeters: 0,
          headingDegrees: 0, stepIndex: 1, timestampMs: 1100,
        ),
        MappingPoint(
          xMeters: 4, yMeters: 0, upMeters: 1.5,
          headingDegrees: 0, stepIndex: 2, timestampMs: 2100,
        ),
        MappingPoint(
          xMeters: 6, yMeters: 0, upMeters: 3.1,
          headingDegrees: 0, stepIndex: 3, timestampMs: 3100,
        ),
        MappingPoint(
          xMeters: 9, yMeters: 0, upMeters: 3.1,
          headingDegrees: 0, stepIndex: 4, timestampMs: 4100,
        ),
      ],
      markers: const [
        MappingMarker(
          id: 'qr_entrance',
          label: 'Main Entrance',
          type: 'anchor',
          floor: 1,
          xMeters: 0, yMeters: 0,
          upMeters: 0, pointIndex: 0,
        ),
        MappingMarker(
          id: 'stairs_start',
          label: 'North Stairs',
          type: 'stairs',
          floor: 1,
          xMeters: 2, yMeters: 0,
          upMeters: 0, pointIndex: 1,
        ),
        MappingMarker(
          id: 'floor_2',
          label: 'Reached Floor 2',
          type: 'floor_level',
          floor: 2,
          xMeters: 6, yMeters: 0,
          upMeters: 3.1, pointIndex: 3,
        ),
        MappingMarker(
          id: 'lab_2',
          label: 'Computer Lab',
          type: 'destination',
          floor: 2,
          xMeters: 9, yMeters: 0,
          upMeters: 3.1, pointIndex: 4,
        ),
      ],
    );

void main() {
  test('V11 publishes continuous measured XYZ with a real stair edge', () {
    final venue = const Venue3DGraphService().build(
      template: blankCampus(),
      session: climbSession(),
    );
    expect(venue.nodes, hasLength(greaterThanOrEqualTo(4)));
    expect(venue.nodes.first.upMeters, 0);
    expect(venue.nodes.last.upMeters, closeTo(3.1, 0.0001));
    expect(venue.nodes.last.floor, 2);
    expect(venue.floors, [1, 2]);
    expect(venue.edges, hasLength(venue.nodes.length - 1));
    expect(
      venue.edges.where((edge) => edge.transitionType == 'stairs'),
      hasLength(1),
    );
    expect(
      venue.edges.map((edge) => edge.distanceMeters).reduce((a, b) => a + b),
      greaterThan(9.0),
      reason: 'Stair distance includes actual measured height.',
    );
    expect(venue.destinations.any((d) => d.name == 'Computer Lab'), isTrue);
    expect(venue.anchors.single.label, 'Main Entrance');
    expect(venue.anchors.single.visualHeadingVerified, isFalse);
  });

  test('Existing offline route graph finds entrance-to-lab path', () {
    final venue = const Venue3DGraphService().build(
      template: blankCampus(),
      session: climbSession(),
    );
    final route = const RouteEngine().shortestPath(
      venue: venue,
      startNodeId: venue.anchors.single.nodeId,
      destinationNodeId: venue.destinations.firstWhere(
        (d) => d.name == 'Computer Lab',
      ).nodeId,
    );
    expect(route.nodes.first.floor, 1);
    expect(route.nodes.last.floor, 2);
    expect(route.nodes.last.upMeters, closeTo(3.1, 0.0001));
    expect(route.crossesFloors, isTrue);
    expect(route.legs.any((leg) => leg.transitionType == 'stairs'), isTrue);
  });

  test('QR anchor payload identifies the correct measured 3D node', () {
    final venue = const Venue3DGraphService().build(
      template: blankCampus(),
      session: climbSession(),
    );
    final anchor = venue.anchors.single;
    const codec = AnchorCodec();
    final payload = codec.encode(venue: venue, anchor: anchor);
    final resolved = codec.resolve(venue: venue, rawValue: payload);
    expect(resolved.id, 'qr_entrance');
    expect(venue.nodeById(resolved.nodeId).upMeters, 0);
    expect(resolved.offlineVisualReady, isFalse,
        reason: 'QR identification is NOT relocalization of a new camera.');
  });

  test('Published XYZ height survives venue override JSON round trip', () {
    final venue = const Venue3DGraphService().build(
      template: blankCampus(),
      session: climbSession(),
    );
    final document = VenueOverrideDocument(
      venue: venue,
      coordinateSpace: 'world_xyz_3d',
      appliedSessionIds: ['v11_walk_001'],
      updatedAt: DateTime.utc(2026, 11, 14),
    );
    final decoded = VenueOverrideDocument.fromJson(document.toJson());
    expect(decoded.isContinuous3D, isTrue);
    expect(decoded.usesRecordedMeters, isTrue);
    expect(decoded.venue.nodes.last.upMeters, 3.1);
    expect(decoded.venue.edges.last.distanceMeters, greaterThan(0));
    expect(decoded.venue.anchors.single.id, 'qr_entrance');
    expect(decoded.venue.destinations.single.name, 'North Stairs',
        reason: 'Only marker-linked places should be published.');
    final serialized = const VenueCodec().toJson(venue);
    expect(
      (serialized['nodes'] as List<dynamic>).last['up_m'],
      closeTo(3.1, 0.0001),
    );
  });

  test('Reject drafts, unrelated venues and disconnected ARCore routes', () {
    const service = Venue3DGraphService();
    expect(
      () => service.build(
        template: blankCampus(),
        session: climbSession(source: 'arcore_spatial_3d_draft'),
      ),
      throwsStateError,
    );
    expect(
      () => service.build(
        template: blankCampus(),
        session: climbSession(venueId: 'other'),
      ),
      throwsStateError,
    );
    expect(
      () => service.build(
        template: blankCampus(),
        session: climbSession(segmentStarts: const [0, 3]),
      ),
      throwsStateError,
    );
    expect(
      () => service.mergeUnaligned(
        current: blankCampus(),
        newRecording: climbSession(),
      ),
      throwsStateError,
    );
  });

  test('Old flat venue schema remains readable with zero-default height', () {
    final node = const VenueCodec().fromJson({
      'id': 'old',
      'name': 'Old',
      'default_start_node_id': 'n1',
      'nodes': [{
        'id': 'n1', 'label': 'Old waypoint',
        'floor': 1, 'x': 1, 'y': 2, 'type': 'waypoint',
      }],
    }).nodes.single;
    expect(node.upMeters, 0);
  });
}
