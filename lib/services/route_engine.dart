import '../models/nav_edge.dart';
import '../models/route_result.dart';
import '../models/venue.dart';

class RouteEngine {
  const RouteEngine();

  RouteResult shortestPath({
    required Venue venue,
    required String startNodeId,
    required String destinationNodeId,
  }) {
    if (startNodeId == destinationNodeId) {
      final node = venue.nodeById(startNodeId);
      return RouteResult(
        nodes: [node],
        legs: const [],
        totalDistanceMeters: 0,
      );
    }

    final nodesById = {
      for (final node in venue.nodes) node.id: node,
    };

    if (!nodesById.containsKey(startNodeId) ||
        !nodesById.containsKey(destinationNodeId)) {
      throw StateError('Route start or destination does not exist.');
    }

    final distances = <String, double>{
      for (final node in venue.nodes) node.id: double.infinity,
    };
    final previous = <String, String?>{};
    final unvisited = venue.nodes.map((node) => node.id).toSet();

    distances[startNodeId] = 0;

    while (unvisited.isNotEmpty) {
      String? current;
      var currentDistance = double.infinity;

      for (final nodeId in unvisited) {
        final distance = distances[nodeId] ?? double.infinity;
        if (distance < currentDistance) {
          currentDistance = distance;
          current = nodeId;
        }
      }

      if (current == null || currentDistance == double.infinity) {
        break;
      }

      if (current == destinationNodeId) {
        break;
      }

      unvisited.remove(current);

      for (final neighbor in _neighbors(venue.edges, current)) {
        if (!unvisited.contains(neighbor.nodeId)) continue;

        final candidate = currentDistance + neighbor.distanceMeters;
        if (candidate < (distances[neighbor.nodeId] ?? double.infinity)) {
          distances[neighbor.nodeId] = candidate;
          previous[neighbor.nodeId] = current;
        }
      }
    }

    final totalDistance = distances[destinationNodeId] ?? double.infinity;
    if (totalDistance == double.infinity) {
      throw StateError('No accessible route exists between these points.');
    }

    final reversedIds = <String>[destinationNodeId];
    var cursor = destinationNodeId;

    while (cursor != startNodeId) {
      final prior = previous[cursor];
      if (prior == null) {
        throw StateError('Route reconstruction failed.');
      }
      reversedIds.add(prior);
      cursor = prior;
    }

    final routeIds = reversedIds.reversed.toList(growable: false);
    final routeNodes = routeIds
        .map((id) => nodesById[id]!)
        .toList(growable: false);

    final legs = <RouteLeg>[];
    for (var index = 0; index < routeIds.length - 1; index++) {
      final from = routeIds[index];
      final to = routeIds[index + 1];
      final edge = _edgeBetween(venue.edges, from, to);
      legs.add(
        RouteLeg(
          from: nodesById[from]!,
          to: nodesById[to]!,
          distanceMeters: edge.distanceMeters,
        ),
      );
    }

    return RouteResult(
      nodes: routeNodes,
      legs: legs,
      totalDistanceMeters: totalDistance,
    );
  }

  Iterable<_Neighbor> _neighbors(List<NavEdge> edges, String nodeId) sync* {
    for (final edge in edges) {
      if (!edge.accessible) continue;

      if (edge.from == nodeId) {
        yield _Neighbor(edge.to, edge.distanceMeters);
      }

      if (edge.bidirectional && edge.to == nodeId) {
        yield _Neighbor(edge.from, edge.distanceMeters);
      }
    }
  }

  NavEdge _edgeBetween(List<NavEdge> edges, String from, String to) {
    return edges.firstWhere((edge) {
      if (!edge.accessible) return false;
      if (edge.from == from && edge.to == to) return true;
      return edge.bidirectional && edge.from == to && edge.to == from;
    });
  }
}

class _Neighbor {
  const _Neighbor(this.nodeId, this.distanceMeters);

  final String nodeId;
  final double distanceMeters;
}
