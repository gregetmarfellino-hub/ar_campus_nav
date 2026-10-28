import 'package:flutter_test/flutter_test.dart';
import 'package:ar_campus_nav/models/nav_node.dart';
import 'package:ar_campus_nav/services/ar_route_coordinates.dart';

void main() {
  test('offline QR frame preserves turns instead of fitting first segment', () {
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
        x: 14, y: 19, type: 'destination',
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

  test('offline QR frame can point behind initial heading', () {
    const nodes = [
      NavNode(
        id: 'start', label: 'Entrance', floor: 1,
        x: 0, y: 0, type: 'entrance',
      ),
      NavNode(
        id: 'behind', label: 'Reverse', floor: 1,
        x: -1, y: -3, type: 'path',
      ),
    ];
    final points = ArRouteCoordinates.fromMappedVenueNodes(nodes);
    expect(points[1]['right'], -1);
    expect(points[1]['forward'], -3);
  });

  test('route shorter than two points is not navigable', () {
    expect(ArRouteCoordinates.fromMappedVenueNodes(const []), isEmpty);
  });
}
