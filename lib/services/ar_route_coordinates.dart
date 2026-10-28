import '../models/nav_node.dart';

/// Restores a route to the mapper's QR-local metric frame.
///
/// The offline entrance reference recovers the original start pose.
/// Therefore we must NOT estimate another heading from the first route
/// segment: a route may begin with a turn, or even go backwards.
class ArRouteCoordinates {
  const ArRouteCoordinates._();

  static List<Map<String, dynamic>> fromMappedVenueNodes(
    List<NavNode> nodes,
  ) {
    if (nodes.length < 2) return const [];
    final start = nodes.first;
    return [
      for (final node in nodes)
        {
          'right': node.x - start.x,
          'forward': node.y - start.y,
          'label': node.label,
          'semantic': node.type != 'path',
        },
    ];
  }
}
