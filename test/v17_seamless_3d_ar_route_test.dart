import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ar_campus_nav/models/nav_edge.dart';
import 'package:ar_campus_nav/models/nav_node.dart';
import 'package:ar_campus_nav/models/venue.dart';
import 'package:ar_campus_nav/services/ar_route_coordinates.dart';
import 'package:ar_campus_nav/services/route_engine.dart';

const venue = Venue(
  id: 'stairs', name: 'Stairwell', description: '',
  defaultStartNodeId: 'e', floors: [1, 2],
  nodes: [
    NavNode(id: 'e', label: 'Main Entrance', floor: 1,
        x: 0, y: 0, upMeters: 1.4, type: 'anchor'),
    NavNode(id: 's', label: '3D waypoint 2', floor: 1,
        x: 2, y: 0, upMeters: 1.4, type: 'waypoint'),
    NavNode(id: 'm', label: '3D waypoint 3', floor: 1,
        x: 3, y: 0, upMeters: 3.2, type: 'waypoint'),
    NavNode(id: 'u', label: 'Upper landing', floor: 2,
        x: 3, y: 0, upMeters: 5.0, type: 'destination'),
  ],
  edges: [
    NavEdge(from: 'e', to: 's', distanceMeters: 2, measured3D: true),
    NavEdge(from: 's', to: 'm', distanceMeters: 2.06, measured3D: true),
    NavEdge(from: 'm', to: 'u', distanceMeters: 1.8,
        transitionType: 'stairs', measured3D: true),
  ],
  destinations: [], anchors: [],
);

void main() {
  test('V17 measured staircase crosses floors while retaining raw XYZ', () {
    const engine = RouteEngine();
    final route = engine.shortestPath(
      venue: venue, startNodeId: 'e', destinationNodeId: 'u',
    );
    expect(route.crossesFloors, isTrue);
    expect(route.hasMeasured3DContinuity, isTrue);
    expect(route.visitedFloors, [1, 2]);

    final local = ArRouteCoordinates.from3DCheckpointNodes(
      route.nodes,
      checkpointRightMeters: 0.5,
      checkpointForwardMeters: 0,
      checkpointFacingDegrees: 0,
    );
    expect(local, hasLength(4));
    expect(local.first['up'], 1.4);
    expect(local.last['up'], 5.0);
    expect((local.last['up'] as double) - (local.first['up'] as double),
        closeTo(3.6, 0.000001));
    expect(local.last['floor'], 2);
    expect(local[1]['semantic'], isFalse,
        reason: 'Tracking samples must not appear as destinations.');
    expect(local.last['semantic'], isTrue);
  });

  test('turning at a different entrance rotates XZ but not stair height', () {
    final route = const RouteEngine().shortestPath(
      venue: venue, startNodeId: 'e', destinationNodeId: 'u',
    );
    final a = ArRouteCoordinates.from3DCheckpointNodes(
      route.nodes,
      checkpointRightMeters: 0,
      checkpointForwardMeters: 0,
      checkpointFacingDegrees: 0,
    );
    final b = ArRouteCoordinates.from3DCheckpointNodes(
      route.nodes,
      checkpointRightMeters: 0,
      checkpointForwardMeters: 0,
      checkpointFacingDegrees: 90,
    );
    expect(b.last['right'] as double, closeTo(0, 0.000001));
    expect(b.last['forward'] as double, closeTo(3, 0.000001));
    for (var i = 0; i < a.length; i++) {
      expect(b[i]['up'], a[i]['up']);
      expect(b[i]['floor'], a[i]['floor']);
    }
  });

  test('old portal edges can never activate continuous 3D AR', () {
    const manual = Venue(
      id: 'old', name: 'Old venue', description: '',
      defaultStartNodeId: 'f1', floors: [1, 2],
      nodes: [
        NavNode(id: 'f1', label: 'First', floor: 1,
            x: 0, y: 0, type: 'anchor'),
        NavNode(id: 'f2', label: 'Second', floor: 2,
            x: 0, y: 0, type: 'destination'),
      ],
      edges: [
        NavEdge(from: 'f1', to: 'f2', distanceMeters: 3,
            transitionType: 'stairs', measured3D: false),
      ],
      destinations: [], anchors: [],
    );
    // The route engine may reject mismatched legacy portal types outright.
    expect(
      () => const RouteEngine().shortestPath(
        venue: manual, startNodeId: 'f1', destinationNodeId: 'f2',
      ),
      throwsStateError,
    );
  });

  test('native 3D rendering uses measured up and resists XY stair overlap', () {
    final native = File(
      'android/app/src/main/kotlin/com/example/ar_campus_nav/'
      'ArCoreTrackingEngine.kt',
    ).readAsStringSync();
    final start = native.indexOf('private fun routeWorldPoints()');
    final end = native.indexOf('private fun createMappingVisualOverlay(', start);
    expect(start, greaterThan(0));
    expect(end, greaterThan(start));
    final renderer = native.substring(start, end);
    expect(renderer, contains('point.upMeters - startUp'));
    expect(renderer, contains('navigationHeightAware'));

    final progress = native.substring(
      native.indexOf('private fun updateNavigationProgress('),
      native.indexOf('private fun targetAngleDegrees('),
    );
    expect(progress, contains('navigationUserMeasuredUp(local)'));
    expect(progress, contains('target.upMeters - previous.upMeters'));
    expect(progress, contains('end.upMeters - userUp'));
    expect(progress, contains('routeDistance(a, b)'));
    expect(native, contains('VERIFIED_3D_START_REQUIRED'));
    expect(native, contains('OFFLINE_SCENE_REGISTRATION_FAILED'));
    final frameClear = native.substring(
      native.indexOf('private fun clearNavigationFrame()'),
      native.indexOf('private data class NavigationWorldBasis('),
    );
    expect(frameClear, isNot(contains('navigationHeightAware = false')),
        reason: 'startSession clears the frame AFTER selecting 3D mode; '
            'it must not silently flatten the staircase.');
    expect(native, contains('navigationHeightAware = heightAware'));
    expect(native, contains('navigationHeightAware = false'));
    expect(native, contains('routeLocalHeight +'));
    expect(native, contains('navigationUserMeasuredUp(local)'));
  });
}
