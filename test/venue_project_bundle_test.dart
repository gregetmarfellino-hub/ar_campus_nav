import 'package:flutter_test/flutter_test.dart';
import 'package:ar_campus_nav/models/anchor_point.dart';
import 'package:ar_campus_nav/models/destination.dart';
import 'package:ar_campus_nav/models/mapping_session.dart';
import 'package:ar_campus_nav/models/nav_edge.dart';
import 'package:ar_campus_nav/models/nav_node.dart';
import 'package:ar_campus_nav/models/venue.dart';
import 'package:ar_campus_nav/services/route_engine.dart';
import 'package:ar_campus_nav/services/venue_override_storage.dart';
import 'package:ar_campus_nav/services/venue_project_bundle.dart';

VenueProjectBundle fixture() => VenueProjectBundle(
      document: VenueOverrideDocument(
        venue: const Venue(
          id: 'shared_campus',
          name: 'My Shared Campus',
          description: 'Created offline',
          defaultStartNodeId: 'entrance',
          floors: [1, 2],
          nodes: [
            NavNode(
              id: 'entrance', label: 'Entrance', floor: 1,
              x: 0, y: 0, upMeters: 0, type: 'anchor',
            ),
            NavNode(
              id: 'stairs', label: 'Stairs', floor: 2,
              x: 4, y: 2, upMeters: 3.2, type: 'destination',
            ),
          ],
          edges: [
            NavEdge(
              from: 'entrance', to: 'stairs', distanceMeters: 5.5,
              transitionType: 'stairs', measured3D: true,
            ),
          ],
          destinations: [
            Destination(
              id: 'lab', name: 'Lab Upstairs', nodeId: 'stairs',
              category: 'lab',
            ),
          ],
          anchors: [
            AnchorPoint(
              id: 'qr1', label: 'Entry checkpoint',
              nodeId: 'entrance', floor: 1,
              offlineVisualReferencePngBase64: 'YWJj',
              offlineVisualReferenceWidthMeters: 0.25,
              offlineVisualStartOffsetX: 0,
              offlineVisualStartOffsetY: 0,
              offlineVisualStartOffsetZ: 0,
              offlineVisualStartForwardX: 0,
              offlineVisualStartForwardY: 0,
              offlineVisualStartForwardZ: 1,
            ),
          ],
        ),
        coordinateSpace: 'world_xyz_3d',
        appliedSessionIds: const ['mapping_1'],
        updatedAt: DateTime.utc(2026, 11, 14),
      ),
      recordings: [
        MappingSession(
          id: 'mapping_1',
          venueId: 'shared_campus',
          venueName: 'My Shared Campus',
          floor: 1,
          createdAt: DateTime.utc(2026, 11, 14),
          startAnchorId: 'qr1',
          startAnchorLabel: 'Entry checkpoint',
          originHeadingDegrees: 0,
          stepLengthMeters: 0,
          source: 'arcore_spatial_3d',
          points: const [
            MappingPoint(
              xMeters: 0, yMeters: 0, upMeters: 0,
              headingDegrees: 0, stepIndex: 0, timestampMs: 0,
            ),
          ],
          markers: const [],
        ),
      ],
    );

void main() {
  test('portable project round-trips exact XYZ, QR, and session data', () {
    final original = fixture();
    final decoded = VenueProjectBundle.decode(original.encode());
    expect(decoded.document.coordinateSpace, 'world_xyz_3d');
    expect(decoded.document.venue.nodes.last.upMeters, 3.2);
    expect(decoded.document.venue.edges.single.measured3D, isTrue);
    expect(decoded.document.venue.anchors.single.offlineVisualReferencePngBase64, 'YWJj');
    expect(decoded.document.venue.anchors.single.offlineVisualReady, isTrue);
    expect(decoded.recordings.single.venueId, 'shared_campus');
    expect(decoded.encode(), original.encode());
    expect(decoded.suggestedFileName, 'My_Shared_Campus.arnav.json');
  });

  test('rejects unsupported schema and broken cross-file references', () {
    final value = fixture().toJson();
    value['schema'] = 'ar_campus_nav.project.v999';
    expect(() => VenueProjectBundle.decode(
      const VenueProjectBundlePlaceholder().toJsonString(value),
    ), throwsFormatException);
  });
}

/// Avoids depending on platform channels just to serialize malformed fixtures.
class VenueProjectBundlePlaceholder {
  const VenueProjectBundlePlaceholder();
  String toJsonString(Map<String, dynamic> value) =>
      const JsonEncoder().convert(value);
}
