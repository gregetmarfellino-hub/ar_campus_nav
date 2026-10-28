import 'package:flutter_test/flutter_test.dart';
import 'package:ar_campus_nav/models/nav_node.dart';
import 'package:ar_campus_nav/services/ar_route_coordinates.dart';
import 'package:ar_campus_nav/services/venue_transform_2d.dart';

void main() {
  test('offline start keeps original right-then-forward turn', () {
    // At heading zero, venue transform saves +mapping.forward as -venue.y.
    const nodes = [
      NavNode(
        id: 'start', label: 'Entrance', floor: 1,
        x: 12, y: 15, type: 'entrance',
      ),
      NavNode(
        id: 'right', label: 'First corner', floor: 1,
        x: 14, y: 15, type: 'path',
      ),
      NavNode(
        id: 'forward', label: 'Room', floor: 1,
        x: 14, y: 11, type: 'destination',
      ),
    ];
    final points = ArRouteCoordinates.fromMappedVenueNodes(nodes);
    expect(points.length, 3);
    expect(points[0]['right'], 0);
    expect(points[0]['forward'], 0);
    expect(points[1]['right'], 2);
    expect(points[1]['forward'], 0);
    expect(points[2]['right'], 2);
    expect(points[2]['forward'], 4);
    expect(points[2]['semantic'], true);
  });

  test('positive saved Y is BACKWARD from the locked QR at zero heading', () {
    const nodes = [
      NavNode(
        id: 'start', label: 'Entrance', floor: 1,
        x: 0, y: 0, type: 'entrance',
      ),
      NavNode(
        id: 'behind', label: 'Reverse', floor: 1,
        x: -1, y: 3, type: 'path',
      ),
    ];
    final points = ArRouteCoordinates.fromMappedVenueNodes(nodes);
    expect(points[1]['right'], -1);
    expect(points[1]['forward'], -3);
  });

  test('exact inverse of venue mapping for arbitrary heading', () {
    for (final heading in [0.0, 37.0, 90.0, 180.0, 271.0]) {
      final transform = VenueTransform2D.atOrigin(
        headingDegrees: heading, venueX: 12, venueY: -4,
      );
      final a = transform.applyPoint(0, 0);
      final b = transform.applyPoint(2.6, 5.3);
      final nodes = [
        NavNode(
          id: 'start', label: 'Start', floor: 1,
          x: a.$1, y: a.$2, type: 'entrance',
        ),
        NavNode(
          id: 'end', label: 'End', floor: 1,
          x: b.$1, y: b.$2, type: 'destination',
        ),
      ];
      final points = ArRouteCoordinates.fromMappedVenueNodes(
        nodes, mapHeadingDegrees: heading,
      );
      expect(points[1]['right'] as double, closeTo(2.6, 1e-8));
      expect(points[1]['forward'] as double, closeTo(5.3, 1e-8));
    }
  });

  test('route shorter than two points is not navigable', () {
    expect(ArRouteCoordinates.fromMappedVenueNodes(const []), isEmpty);
  });
}
