import 'anchor_point.dart';
import 'destination.dart';
import 'nav_edge.dart';
import 'nav_node.dart';

class Venue {
  const Venue({
    required this.id,
    required this.name,
    required this.description,
    required this.defaultStartNodeId,
    required this.floors,
    required this.nodes,
    required this.edges,
    required this.destinations,
    required this.anchors,
  });

  final String id;
  final String name;
  final String description;
  final String defaultStartNodeId;
  final List<int> floors;
  final List<NavNode> nodes;
  final List<NavEdge> edges;
  final List<Destination> destinations;
  final List<AnchorPoint> anchors;

  NavNode nodeById(String id) {
    return nodes.firstWhere((node) => node.id == id);
  }

  AnchorPoint anchorById(String id) {
    return anchors.firstWhere((anchor) => anchor.id == id);
  }
}
