import 'package:flutter_test/flutter_test.dart';

import 'package:ar_campus_nav/models/mapping_session.dart';
import 'package:ar_campus_nav/models/nav_node.dart';
import 'package:ar_campus_nav/models/venue.dart';
import 'package:ar_campus_nav/services/ar_route_coordinates.dart';
import 'package:ar_campus_nav/services/venue_3d_graph_service.dart';
import 'package:ar_campus_nav/services/route_engine.dart';
import 'package:ar_campus_nav/services/venue_override_storage.dart';
import 'package:ar_campus_nav/services/venue_project_bundle.dart';

const template = Venue(
  id: 'test_campus',
  name: 'Test Campus',
  description: '',
  defaultStartNodeId: 'placeholder',
  floors: [1],
  nodes: [],
  edges: [],
  destinations: [],
  anchors: [],
);

const qrA = MappingMarker(
  id: 'entrance_west',
  label: 'West Entrance',
  type: 'anchor',
  floor: 1,
  xMeters: 0, yMeters: 0, pointIndex: 0,
  checkpointRightMeters: 0.5,
  checkpointForwardMeters: 0,
  checkpointUpMeters: 0,
  anchorFacingDegrees: 0,
  offlineVisualReferencePngBase64: 'YWJj',
  offlineVisualReferenceWidthMeters: 0.6,
  offlineVisualStartOffsetX: 0,
  offlineVisualStartOffsetY: 0,
  offlineVisualStartOffsetZ: 0,
  offlineVisualStartForwardX: 0,
  offlineVisualStartForwardY: 0,
  offlineVisualStartForwardZ: 1,
);

const qrB = MappingMarker(
  id: 'entrance_east',
  label: 'East Entrance',
  type: 'anchor',
  floor: 1,
  xMeters: 4, yMeters: 0, pointIndex: 2,
  checkpointRightMeters: 4.5,
  checkpointForwardMeters: 0.5,
  checkpointUpMeters: 0,
  anchorFacingDegrees: 90,
  offlineVisualReferencePngBase64: 'ZGVm',
  offlineVisualReferenceWidthMeters: 0.6,
  offlineVisualStartOffsetX: 0.12,
  offlineVisualStartOffsetY: 0.03,
  offlineVisualStartOffsetZ: 0.50,
  offlineVisualStartForwardX: 0,
  offlineVisualStartForwardY: 0,
  offlineVisualStartForwardZ: 1,
);

MappingSession fixture() => MappingSession(
      id: 'walk_1',
      venueId: template.id,
      venueName: template.name,
      floor: 1,
      createdAt: DateTime.utc(2026, 11, 14),
      startAnchorId: null,
      startAnchorLabel: 'Recorded start',
      originHeadingDegrees: 0,
      stepLengthMeters: 0,
      source: 'arcore_spatial_3d',
      points: const [
        MappingPoint(xMeters: 0, yMeters: 0, upMeters: 0,
            headingDegrees: 0, stepIndex: 0, timestampMs: 100),
        MappingPoint(xMeters: 2, yMeters: 0, upMeters: 0,
            headingDegrees: 0, stepIndex: 1, timestampMs: 200),
        MappingPoint(xMeters: 4, yMeters: 0, upMeters: 0,
            headingDegrees: 0, stepIndex: 2, timestampMs: 300),
        MappingPoint(xMeters: 6, yMeters: 0, upMeters: 0,
            headingDegrees: 0, stepIndex: 3, timestampMs: 400),
        MappingPoint(xMeters: 8, yMeters: 0, upMeters: 0,
            headingDegrees: 0, stepIndex: 4, timestampMs: 500),
      ],
      markers: const [
        qrA,
        qrB,
        MappingMarker(
          id: 'lab_wing', label: 'Lab Wing', type: 'destination',
          floor: 1, xMeters: 8, yMeters: 0, pointIndex: 4,
        ),
      ],
    );

void main() {
  test('two independent visual starts survive all three serialization steps', () {
    final session = MappingSession.fromJson(fixture().toJson());
    final venue = const Venue3DGraphService().build(
      template: template, session: session,
    );
    expect(venue.anchors, hasLength(2));
    expect(venue.anchors.every((a) => a.offlineCheckpointReady), isTrue);
    expect(venue.anchors[0].checkpointRightMeters, 0.5);
    expect(venue.anchors[1].checkpointRightMeters, 4.5);
    expect(venue.anchors[1].checkpointFacingDegrees, 90);
    expect(venue.anchors[1].offlineVisualStartOffsetZ, .5);
    expect(venue.nodes.last.x, 8);

    final bundle = VenueProjectBundle(
      document: VenueOverrideDocument(
        venue: venue,
        coordinateSpace: 'world_xyz_3d',
        appliedSessionIds: const ['walk_1'],
        updatedAt: DateTime.utc(2026, 11, 14),
      ),
      recordings: [session],
    );
    final imported = VenueProjectBundle.decode(bundle.encode());
    expect(imported.document.venue.anchors, hasLength(2));
    expect(imported.document.venue.anchors.last.offlineCheckpointReady, isTrue);
    expect(imported.recordings.single.markers[1].anchorFacingDegrees, 90);
    expect(imported.document.venue.edges.length, greaterThanOrEqualTo(2));
    expect(imported.document.venue.edges.every((e) => e.measured3D), isTrue);
  });

  test('each placed entrance generates a distinct correctly rotated route', () {
    final venue = const Venue3DGraphService().build(
      template: template, session: fixture(),
    );
    const engine = RouteEngine();
    final target = venue.destinations.single.nodeId;
    final west = venue.anchors.first;
    final east = venue.anchors.last;
    final westRoute = engine.shortestPath(
      venue: venue, startNodeId: west.nodeId, destinationNodeId: target,
    );
    final eastRoute = engine.shortestPath(
      venue: venue, startNodeId: east.nodeId, destinationNodeId: target,
    );
    final westPoints = ArRouteCoordinates.from3DCheckpointNodes(
      westRoute.nodes,
      checkpointRightMeters: west.checkpointRightMeters!,
      checkpointForwardMeters: west.checkpointForwardMeters!,
      checkpointFacingDegrees: west.checkpointFacingDegrees!,
    );
    final eastPoints = ArRouteCoordinates.from3DCheckpointNodes(
      eastRoute.nodes,
      checkpointRightMeters: east.checkpointRightMeters!,
      checkpointForwardMeters: east.checkpointForwardMeters!,
      checkpointFacingDegrees: east.checkpointFacingDegrees!,
    );
    // Facing 0°: along the saved +right corridor is rightward on device.
    expect(westPoints.first['right'] as double, closeTo(-.5, 1e-8));
    expect(westPoints.last['right'] as double, closeTo(7.5, 1e-8));
    expect(westPoints.last['forward'] as double, closeTo(0, 1e-8));
    // Facing 90°: exactly the same physical corridor now appears forward.
    expect(eastPoints.first['right'] as double, closeTo(.5, 1e-8));
    expect(eastPoints.first['forward'] as double, closeTo(-.5, 1e-8));
    expect(eastPoints.last['forward'] as double, closeTo(3.5, 1e-8));
    expect(westRoute.totalDistanceMeters, 8);
    expect(eastRoute.totalDistanceMeters, 4);
  });

  test('plain QR tag can identify a node but cannot unlock AR localization', () {
    final venue = const Venue3DGraphService().build(
      template: template,
      session: MappingSession.fromJson({
        ...fixture().toJson(),
        'markers': [
          const MappingMarker(
            id: 'plain_qr', label: 'ID-only', type: 'anchor',
            floor: 1, xMeters: 0, yMeters: 0, pointIndex: 0,
          ).toJson(),
        ],
      }),
    );
    expect(venue.anchors.single.offlineCheckpointReady, isFalse);
    expect(venue.anchors.single.offlineVisualReady, isFalse);
  });

  test('invalid checkpoint pose is rejected before attempting AR route', () {
    const nodes = [
      NavNode(id: 'a', label: 'Start', floor: 1,
          x: 0, y: 0, type: 'anchor'),
      NavNode(id: 'b', label: 'End', floor: 1,
          x: 2, y: 0, type: 'destination'),
    ];
    expect(
      () => ArRouteCoordinates.from3DCheckpointNodes(
        nodes,
        checkpointRightMeters: double.nan,
        checkpointForwardMeters: 0,
        checkpointFacingDegrees: 0,
      ),
      throwsFormatException,
    );
  });
}
