import 'nav_node.dart';

class RouteLeg {
  const RouteLeg({
    required this.from,
    required this.to,
    required this.distanceMeters,
    this.transitionType,
    this.measured3D = false,
  });

  final NavNode from;
  final NavNode to;
  final double distanceMeters;
  /// 'stairs' or 'elevator' for deliberate floor changes.
  final String? transitionType;
  /// The 3D geometry of this connection was measured in one ARCore session.
  final bool measured3D;
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

  /// V17 permits a continuous 3D camera route ONLY for measured links.
  /// Legacy manually linked floor portals are not safe to extrapolate.
  bool get hasMeasured3DContinuity =>
      legs.isNotEmpty && legs.every((leg) => leg.measured3D) &&
      nodes.every((node) => node.upMeters.isFinite) &&
      (!crossesFloors ||
       nodes.map((node) => node.upMeters).reduce((a, b) => a < b ? a : b) <
           nodes.map((node) => node.upMeters).reduce((a, b) => a > b ? a : b) - 0.60);

  List<int> get visitedFloors => [
        for (final floor in nodes.map((node) => node.floor).toSet()) floor,
      ];
}
