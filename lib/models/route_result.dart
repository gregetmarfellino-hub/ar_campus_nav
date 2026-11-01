import 'nav_node.dart';

class RouteLeg {
  const RouteLeg({
    required this.from,
    required this.to,
    required this.distanceMeters,
    this.transitionType,
  });

  final NavNode from;
  final NavNode to;
  final double distanceMeters;
  /// 'stairs' or 'elevator' for deliberate floor changes.
  final String? transitionType;
  bool get isFloorTransition => from.floor != to.floor;
}

class RouteResult {
  const RouteResult({
    required this.nodes,
    required this.legs,
    required this.totalDistanceMeters,
  });

  final List<NavNode> nodes;
  final List<RouteLeg> legs;
  final double totalDistanceMeters;

  bool get crossesFloors => legs.any((leg) => leg.isFloorTransition);

  List<int> get visitedFloors => [
        for (final floor in nodes.map((node) => node.floor).toSet()) floor,
      ];
}
