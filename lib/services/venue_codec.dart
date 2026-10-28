import '../models/anchor_point.dart';
import '../models/destination.dart';
import '../models/nav_edge.dart';
import '../models/nav_node.dart';
import '../models/venue.dart';

class VenueCodec {
  const VenueCodec();

  Map<String, dynamic> toJson(Venue venue) {
    return <String, dynamic>{
      'id': venue.id,
      'name': venue.name,
      'description': venue.description,
      'default_start_node_id': venue.defaultStartNodeId,
      'floors': venue.floors,
      'nodes': [
        for (final node in venue.nodes)
          <String, dynamic>{
            'id': node.id,
            'label': node.label,
            'floor': node.floor,
            'x': node.x,
            'y': node.y,
            'type': node.type,
          },
      ],
      'edges': [
        for (final edge in venue.edges)
          <String, dynamic>{
            'from': edge.from,
            'to': edge.to,
            'distance_m': edge.distanceMeters,
            'bidirectional': edge.bidirectional,
            'accessible': edge.accessible,
          },
      ],
      'destinations': [
        for (final destination in venue.destinations)
          <String, dynamic>{
            'id': destination.id,
            'name': destination.name,
            'node_id': destination.nodeId,
            'category': destination.category,
            'description': destination.description,
          },
      ],
      'anchors': [
        for (final anchor in venue.anchors)
          <String, dynamic>{
            'id': anchor.id,
            'label': anchor.label,
            'node_id': anchor.nodeId,
            'floor': anchor.floor,
            'heading_degrees': anchor.headingDegrees,
            'visual_heading_verified': anchor.visualHeadingVerified,
            if (anchor.persistentAnchorId != null)
              'persistent_anchor_id': anchor.persistentAnchorId,
          },
      ],
    };
  }

  Venue fromJson(Map<String, dynamic> json) {
    final nodes = (json['nodes'] as List<dynamic>? ?? const [])
        .map((item) => NavNode.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
    final edges = (json['edges'] as List<dynamic>? ?? const [])
        .map((item) => NavEdge.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
    final destinations = (json['destinations'] as List<dynamic>? ?? const [])
        .map((item) => Destination.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
    final anchors = (json['anchors'] as List<dynamic>? ?? const [])
        .map((item) => AnchorPoint.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);

    return Venue(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      defaultStartNodeId: json['default_start_node_id'] as String,
      floors: (json['floors'] as List<dynamic>? ?? const [1])
          .map((value) => (value as num).toInt())
          .toList(growable: false),
      nodes: nodes,
      edges: edges,
      destinations: destinations,
      anchors: anchors,
    );
  }
}
