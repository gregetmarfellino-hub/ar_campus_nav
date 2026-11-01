import 'package:flutter_test/flutter_test.dart';

import 'package:ar_campus_nav/models/nav_edge.dart';
import 'package:ar_campus_nav/models/nav_node.dart';
import 'package:ar_campus_nav/models/route_result.dart';
import 'package:ar_campus_nav/models/venue.dart';
import 'package:ar_campus_nav/services/floor_navigation_plan.dart';
import 'package:ar_campus_nav/services/route_engine.dart';

Venue multiFloorVenue() => const Venue(
      id: 'v9',
      name: 'V9 fixture',
      description: 'Three floors',
      defaultStartNodeId: 'start',
      floors: [1, 2, 3],
      nodes: [
        NavNode(
          id: 'start', label: 'Entrance', floor: 1,
          x: 0, y: 0, type: 'entrance',
        ),
        NavNode(
          id: 'f1stairs', label: 'F1 stairs', floor: 1,
          x: 0, y: 5, type: 'stairs',
        ),
        NavNode(
          id: 'f2stairs', label: 'F2 stairs', floor: 2,
          x: 30, y: 40, type: 'stairs',
        ),
        NavNode(
          id: 'f2stairsOther', label: 'Other F2 stairs', floor: 2,
          x: 30, y: 44, type: 'stairs',
        ),
        NavNode(
          id: 'f3stairs', label: 'F3 stairs', floor: 3,
          x: 10, y: 0, type: 'stairs',
        ),
        NavNode(
          id: 'f3room', label: 'Room 301', floor: 3,
          x: 14, y: 0, type: 'destination',
        ),
      ],
      edges: [
        NavEdge(from: 'start', to: 'f1stairs', distanceMeters: 5),
        NavEdge(
          from: 'f1stairs', to: 'f2stairs',
          distanceMeters: 7, transitionType: 'stairs',
        ),
        NavEdge(
          from: 'f2stairs', to: 'f2stairsOther', distanceMeters: 4,
        ),
        NavEdge(
          from: 'f2stairsOther', to: 'f3stairs',
          distanceMeters: 7, transitionType: 'stairs',
        ),
        NavEdge(from: 'f3stairs', to: 'f3room', distanceMeters: 4),
      ],
      destinations: [],
      anchors: [],
    );

void main() {
  const router = RouteEngine();

  test('V9 separates floor AR legs from two independent stair transitions', () {
    final route = router.shortestPath(
      venue: multiFloorVenue(),
      startNodeId: 'start',
      destinationNodeId: 'f3room',
    );
    final plan = FloorNavigationPlan.fromRoute(route);

    expect(plan.floorCount, 3);
    expect(plan.transitionCount, 2);
    expect(plan.stages.map((s) => s.floor), [1, 2, 3]);
    expect(plan.stages.map((s) => s.route.totalDistanceMeters), [5, 4, 4]);
    expect(plan.stages[0].transitionAfter!.distanceMeters, 7);
    expect(plan.stages[1].transitionAfter!.transitionType, 'stairs');
    expect(plan.stages[2].transitionAfter, isNull);
    expect(plan.stages[0].route.nodes.map((n) => n.id),
        ['start', 'f1stairs']);
    expect(plan.stages[1].route.nodes.map((n) => n.id),
        ['f2stairs', 'f2stairsOther']);
    expect(plan.stages[2].route.nodes.map((n) => n.id),
        ['f3stairs', 'f3room']);
    for (final stage in plan.stages) {
      expect(stage.route.crossesFloors, isFalse);
      expect(stage.route.nodes.every((n) => n.floor == stage.floor), isTrue);
      expect(stage.route.legs.every((leg) => !leg.isFloorTransition), isTrue);
    }
    final totalArDistance = plan.stages.fold(
      0.0, (sum, s) => sum + s.route.totalDistanceMeters);
    final totalStairs = plan.stages.fold(
      0.0, (sum, s) => sum + (s.transitionAfter?.distanceMeters ?? 0.0));
    expect(totalArDistance + totalStairs, closeTo(route.totalDistanceMeters, 1e-9));
  });

  test('starting at stairs permits empty first corridor without fake AR', () {
    final route = router.shortestPath(
      venue: multiFloorVenue(),
      startNodeId: 'f1stairs',
      destinationNodeId: 'f2stairs',
    );
    final plan = FloorNavigationPlan.fromRoute(route);
    expect(plan.stages, hasLength(2));
    expect(plan.stages[0].hasWalk, isFalse);
    expect(plan.stages[0].route.nodes.single.id, 'f1stairs');
    expect(plan.stages[0].transitionAfter!.to.id, 'f2stairs');
    expect(plan.stages[1].hasWalk, isFalse);
    expect(plan.stages[1].isFinal, isTrue);
  });

  test('same-floor route is rejected by cross-floor coordinator', () {
    final route = router.shortestPath(
      venue: multiFloorVenue(),
      startNodeId: 'start',
      destinationNodeId: 'f1stairs',
    );
    expect(() => FloorNavigationPlan.fromRoute(route), throwsStateError);
  });

  test('invalid untyped crossing cannot be passed to floor-local AR', () {
    final a = multiFloorVenue().nodeById('f1stairs');
    final b = multiFloorVenue().nodeById('f2stairs');
    final fabricated = RouteResult(
      nodes: [a, b],
      legs: [RouteLeg(from: a, to: b, distanceMeters: 7)],
      totalDistanceMeters: 7,
    );
    expect(() => FloorNavigationPlan.fromRoute(fabricated), throwsStateError);
  });

  test('wrong stair endpoints are rejected before floor handoff', () {
    final v = multiFloorVenue();
    final a = v.nodeById('f1stairs');
    final b = v.nodeById('f2stairs');
    final c = v.nodeById('f3stairs');
    final invalid = RouteResult(
      nodes: [a, b],
      legs: [
        RouteLeg(
          from: a, to: c, distanceMeters: 7,
          transitionType: 'stairs',
        ),
      ],
      totalDistanceMeters: 7,
    );
    expect(() => FloorNavigationPlan.fromRoute(invalid), throwsStateError);
  });

  test('portal route never depends on matching independent floor XY', () {
    final v = multiFloorVenue();
    final route = router.shortestPath(
      venue: v,
      startNodeId: 'start',
      destinationNodeId: 'f3room',
    );
    final plan = FloorNavigationPlan.fromRoute(route);
    expect(
      plan.stages[0].transitionAfter!.from.x,
      isNot(plan.stages[0].transitionAfter!.to.x),
    );
    expect(plan.stages[0].transitionAfter!.distanceMeters, 7);
  });
}
