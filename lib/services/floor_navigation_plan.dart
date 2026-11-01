import '../models/route_result.dart';

/// Splits a V8 cross-floor graph route into independent floor-local AR legs.
///
/// NEVER feed a floor transition to the single-plane ARCore renderer. Stair
/// travel is an explicit physical/manual handoff, followed by fresh local
/// alignment at the new floor's matching portal.
class FloorNavigationPlan {
  const FloorNavigationPlan({required this.stages});

  final List<FloorNavigationStage> stages;

  int get floorCount => stages.length;
  int get transitionCount =>
      stages.where((stage) => stage.transitionAfter != null).length;

  factory FloorNavigationPlan.fromRoute(RouteResult route) {
    if (!route.crossesFloors) {
      throw StateError('A multi-floor plan needs a cross-floor route.');
    }
    if (route.nodes.length != route.legs.length + 1 ||
        route.nodes.isEmpty) {
      throw StateError('Invalid saved route sequence.');
    }

    final stages = <FloorNavigationStage>[];
    final nodes = <dynamic>[route.nodes.first];
    final legs = <RouteLeg>[];

    void addStage(RouteLeg? transitionAfter) {
      final floor = nodes.first.floor as int;
      for (final node in nodes) {
        if (node.floor != floor) {
          throw StateError('A floor section contains nodes from other floors.');
        }
      }
      stages.add(FloorNavigationStage(
        route: RouteResult(
          nodes: List.unmodifiable(nodes.cast()),
          legs: List<RouteLeg>.unmodifiable(legs),
          totalDistanceMeters: legs.fold(
            0.0, (total, leg) => total + leg.distanceMeters),
        ),
        transitionAfter: transitionAfter,
      ));
    }

    for (var i = 0; i < route.legs.length; i++) {
      final leg = route.legs[i];
      final expectedFrom = route.nodes[i];
      final expectedTo = route.nodes[i + 1];
      if (leg.from.id != expectedFrom.id || leg.to.id != expectedTo.id) {
        throw StateError('Route leg does not match its saved node order.');
      }
      if (!leg.distanceMeters.isFinite || leg.distanceMeters <= 0) {
        throw StateError('A route leg has invalid physical distance.');
      }

      if (leg.isFloorTransition) {
        if (leg.transitionType != 'stairs' &&
            leg.transitionType != 'elevator') {
          throw StateError('A floor transition must have a valid method.');
        }
        if (leg.from.type != leg.transitionType ||
            leg.to.type != leg.transitionType) {
          throw StateError('A floor transition has mismatched portals.');
        }
        addStage(leg);
        nodes
          ..clear()
          ..add(leg.to);
        legs.clear();
      } else {
        if (leg.from.floor != leg.to.floor ||
            leg.transitionType != null) {
          throw StateError('Invalid flat corridor or floor-transition edge.');
        }
        nodes.add(leg.to);
        legs.add(leg);
      }
    }
    addStage(null);

    if (stages.length < 2 ||
        stages.last.transitionAfter != null) {
      throw StateError('Cannot build an ordered cross-floor route.');
    }
    return FloorNavigationPlan(stages: List.unmodifiable(stages));
  }
}

class FloorNavigationStage {
  const FloorNavigationStage({
    required this.route,
    required this.transitionAfter,
  });

  /// One strictly same-floor sub-route, independently localized by ARCore.
  final RouteResult route;

  /// An explicit staircase/elevator leg AFTER the floor-local route.
  /// A null transition marks the final destination floor.
  final RouteLeg? transitionAfter;

  int get floor => route.nodes.first.floor;
  String get entryNodeId => route.nodes.first.id;
  String get exitNodeId => route.nodes.last.id;
  bool get hasWalk => route.legs.isNotEmpty;
  bool get isFinal => transitionAfter == null;
}
