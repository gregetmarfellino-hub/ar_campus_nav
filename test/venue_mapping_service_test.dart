import 'package:flutter_test/flutter_test.dart';
import 'package:ar_campus_nav/models/anchor_point.dart';
import 'package:ar_campus_nav/models/mapping_session.dart';
import 'package:ar_campus_nav/models/nav_node.dart';
import 'package:ar_campus_nav/models/venue.dart';
import 'package:ar_campus_nav/services/venue_mapping_service.dart';

void main() {
  const service = VenueMappingService();

  Venue baseVenue() {
    return const Venue(
      id: 'venue',
      name: 'Venue',
      description: 'test',
      defaultStartNodeId: 'old_start',
      floors: [1],
      nodes: [
        NavNode(
          id: 'old_start',
          label: 'Main Entrance',
          floor: 1,
          x: 10,
          y: 10,
          type: 'entrance',
        ),
      ],
      edges: [],
      destinations: [],
      anchors: [
        AnchorPoint(
          id: 'main_anchor',
          label: 'Main Entrance',
          nodeId: 'old_start',
          floor: 1,
        ),
      ],
    );
  }

  MappingSession spatialSession({
    required String id,
    String? startAnchorId = 'main_anchor',
  }) {
    return MappingSession(
      id: id,
      venueId: 'venue',
      venueName: 'Venue',
      floor: 1,
      createdAt: DateTime.utc(2026, 1, 1),
      startAnchorId: startAnchorId,
      startAnchorLabel: 'Main Entrance',
      originHeadingDegrees: 0,
      stepLengthMeters: 0,
      source: 'arcore_spatial',
      points: const [
        MappingPoint(
          xMeters: 0,
          yMeters: 0,
          headingDegrees: 0,
          stepIndex: 0,
          timestampMs: 0,
        ),
        MappingPoint(
          xMeters: 0,
          yMeters: 1,
          headingDegrees: 0,
          stepIndex: 1,
          timestampMs: 1000,
        ),
        MappingPoint(
          xMeters: 0,
          yMeters: 2,
          headingDegrees: 0,
          stepIndex: 2,
          timestampMs: 2000,
        ),
      ],
      markers: const [],
    );
  }

  test('legacy start anchor stays position-only unless facing was verified', () {
    final venue = service.applySession(
      venue: baseVenue(),
      session: spatialSession(id: 'first'),
    );

    final anchor = venue.anchorById('main_anchor');

    expect(anchor.headingDegrees, isNull);
    expect(anchor.visualPoseReady, isFalse);
  });

  test('visual QR marker at first point creates a pose-ready start anchor', () {
    final session = MappingSession(
      id: 'visual_start',
      venueId: 'venue',
      venueName: 'Venue',
      floor: 1,
      createdAt: DateTime.utc(2026, 1, 1),
      startAnchorId: null,
      startAnchorLabel: 'Recorded start',
      originHeadingDegrees: 0,
      stepLengthMeters: 0,
      source: 'arcore_spatial',
      points: const [
        MappingPoint(
          xMeters: 0,
          yMeters: 0,
          headingDegrees: 0,
          stepIndex: 0,
          timestampMs: 0,
        ),
        MappingPoint(
          xMeters: 0,
          yMeters: 3,
          headingDegrees: 0,
          stepIndex: 1,
          timestampMs: 1000,
        ),
      ],
      markers: const [
        MappingMarker(
          id: 'front_qr',
          label: 'Front Entrance QR',
          type: 'anchor',
          floor: 1,
          xMeters: 0,
          yMeters: 0,
          pointIndex: 0,
          anchorFacingDegrees: 90,
        ),
      ],
    );

    final venue = service.applySession(
      venue: baseVenue(),
      session: session,
    );

    final anchor = venue.anchorById('front_qr');
    expect(anchor.nodeId, startsWith('recorded_start_'));
    expect(anchor.visualPoseReady, isTrue);
    expect(anchor.headingDegrees, closeTo(90, 1e-9));
  });

  test('visual QR node keeps the exact AR wall hit position', () {
    final session = MappingSession(
      id: 'wall_qr',
      venueId: 'venue',
      venueName: 'Venue',
      floor: 1,
      createdAt: DateTime.utc(2026, 1, 1),
      startAnchorId: null,
      startAnchorLabel: 'Recorded start',
      originHeadingDegrees: 0,
      stepLengthMeters: 0,
      source: 'arcore_spatial',
      points: const [
        MappingPoint(
          xMeters: 0,
          yMeters: 0,
          headingDegrees: 0,
          stepIndex: 0,
          timestampMs: 0,
        ),
        MappingPoint(
          xMeters: 0,
          yMeters: 3,
          headingDegrees: 0,
          stepIndex: 1,
          timestampMs: 1000,
        ),
      ],
      markers: const [
        MappingMarker(
          id: 'wall_qr',
          label: 'Wall QR',
          type: 'anchor',
          floor: 1,
          xMeters: 0.40,
          yMeters: -0.20,
          upMeters: 1.45,
          pointIndex: 0,
          anchorFacingDegrees: 90,
        ),
      ],
    );

    final venue = service.applySession(
      venue: baseVenue(),
      session: session,
    );

    final anchor = venue.anchorById('wall_qr');
    final node = venue.nodeById(anchor.nodeId);

    expect(anchor.visualPoseReady, isTrue);
    expect(anchor.headingDegrees, closeTo(90, 1e-9));
    expect(node.x, closeTo(0.40, 1e-9));
    expect(node.y, closeTo(0.20, 1e-9));
  });

  test('spatial merge uses two known anchors and reuses the target node', () {
    const venue = Venue(
      id: 'venue',
      name: 'Venue',
      description: 'test',
      defaultStartNodeId: 'start',
      floors: [1],
      nodes: [
        NavNode(
          id: 'start',
          label: 'Anchor A',
          floor: 1,
          x: 0,
          y: 0,
          type: 'anchor',
        ),
        NavNode(
          id: 'anchor_b_node',
          label: 'Anchor B',
          floor: 1,
          x: 5,
          y: 0,
          type: 'anchor',
        ),
      ],
      edges: [],
      destinations: [],
      anchors: [
        AnchorPoint(
          id: 'main_anchor',
          label: 'Anchor A',
          nodeId: 'start',
          floor: 1,
        ),
        AnchorPoint(
          id: 'anchor_b',
          label: 'Anchor B',
          nodeId: 'anchor_b_node',
          floor: 1,
        ),
      ],
    );

    final session = MappingSession(
      id: 'merge_two_anchor',
      venueId: 'venue',
      venueName: 'Venue',
      floor: 1,
      createdAt: DateTime.utc(2026, 1, 1),
      startAnchorId: 'main_anchor',
      startAnchorLabel: 'Anchor A',
      originHeadingDegrees: 0,
      stepLengthMeters: 0,
      source: 'arcore_spatial',
      points: const [
        MappingPoint(
          xMeters: 0,
          yMeters: 0,
          headingDegrees: 0,
          stepIndex: 0,
          timestampMs: 0,
        ),
        MappingPoint(
          xMeters: 0,
          yMeters: 2.5,
          headingDegrees: 0,
          stepIndex: 1,
          timestampMs: 1000,
        ),
        MappingPoint(
          xMeters: 0,
          yMeters: 5,
          headingDegrees: 0,
          stepIndex: 2,
          timestampMs: 2000,
        ),
      ],
      markers: const [
        MappingMarker(
          id: 'anchor_b_ref',
          label: 'Anchor B',
          type: 'anchor',
          floor: 1,
          xMeters: 0,
          yMeters: 5,
          pointIndex: 2,
          referenceAnchorId: 'anchor_b',
        ),
      ],
    );

    expect(
      service.hasSpatialAlignment(venue: venue, session: session),
      isTrue,
    );

    final merged = service.mergeSession(
      venue: venue,
      session: session,
    );

    expect(merged.anchors.length, 2);
    expect(
      merged.nodes.where((node) => node.id == 'anchor_b_node').length,
      1,
    );
    expect(
      merged.edges.any((edge) => edge.to == 'anchor_b_node'),
      isTrue,
    );

    final middle = merged.nodes.firstWhere(
      (node) => node.id.startsWith('rec_merge_two_anchor_path_'),
    );
    expect(middle.x, closeTo(2.5, 1e-9));
    expect(middle.y, closeTo(0, 1e-9));
  });

  test('spatial merge refuses one-point orientation ambiguity', () {
    final active = service.applySession(
      venue: baseVenue(),
      session: spatialSession(id: 'first'),
    );

    expect(
      () => service.mergeSession(
        venue: active,
        session: spatialSession(id: 'second'),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('second known anchor'),
        ),
      ),
    );
  });
}
