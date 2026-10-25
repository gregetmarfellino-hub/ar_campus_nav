import 'nav_node.dart';

class RouteLeg {
  const RouteLeg({
    required this.from,
    required this.to,
    required this.distanceMeters,
  });

  final NavNode from;
  final NavNode to;
  final double distanceMeters;
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
}
