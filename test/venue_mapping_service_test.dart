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

  test('first spatial apply establishes heading metadata for start anchor', () {
    final venue = service.applySession(
      venue: baseVenue(),
      session: spatialSession(id: 'first'),
    );

    final anchor = venue.anchorById('main_anchor');

    expect(anchor.headingDegrees, isNotNull);
    expect(anchor.headingDegrees!, closeTo(0, 1e-9));
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
          contains('orientation alignment'),
        ),
      ),
    );
  });
}
