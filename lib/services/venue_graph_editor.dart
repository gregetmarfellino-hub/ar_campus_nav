import 'dart:math' as math;

import '../models/destination.dart';
import '../models/nav_edge.dart';
import '../models/nav_node.dart';
import '../models/venue.dart';

/// Edits the active venue's already-mapped graph without touching its original
/// walk recordings or ARCore reference-anchor metadata.
///
/// Pass 7 intentionally edits one floor at a time. Cross-floor links must be
/// explicit vertical portals with floor transition metadata (Pass 8), never a
/// misleading zero-height Euclidean shortcut.
class VenueGraphEditor {
  const VenueGraphEditor();

  Venue moveNode(
    Venue venue, {
    required String nodeId,
    required double x,
    required double y,
  }) {
    if (!x.isFinite || !y.isFinite) {
      throw ArgumentError('Waypoint coordinates must be finite.');
    }
    final node = venue.nodeById(nodeId);
    _requireEditableNode(venue, node);
    if (node.x == x && node.y == y) return venue;

    final nodes = [
      for (final current in venue.nodes)
        if (current.id == nodeId)
          NavNode(
            id: current.id,
            label: current.label,
            floor: current.floor,
            x: x,
            y: y,
            type: current.type,
          )
        else
          current,
    ];

    // Only affected same-floor segment lengths are recalculated. Existing
    // vertical links retain their explicitly authored traversal distances.
    final byId = {for (final item in nodes) item.id: item};
    final edges = [
      for (final edge in venue.edges)
        if ((edge.from == nodeId || edge.to == nodeId) &&
            byId[edge.from]?.floor == byId[edge.to]?.floor)
          NavEdge(
            from: edge.from,
            to: edge.to,
            distanceMeters: _distance(byId[edge.from]!, byId[edge.to]!),
            bidirectional: edge.bidirectional,
            accessible: edge.accessible,
          )
        else
          edge,
    ];
    return _copy(venue, nodes: nodes, edges: edges);
  }

  Venue renameNode(Venue venue, String nodeId, String label) {
    final updated = label.trim();
    if (updated.isEmpty || updated.length > 80) {
      throw ArgumentError('Use a label between 1 and 80 characters.');
    }
    final node = venue.nodeById(nodeId);
    _requireEditableNode(venue, node);
    if (node.label == updated) return venue;

    final nodes = [
      for (final item in venue.nodes)
        if (item.id == nodeId)
          NavNode(
            id: item.id,
            label: updated,
            floor: item.floor,
            x: item.x,
            y: item.y,
            type: item.type,
          )
        else
          item,
    ];
    final destinations = [
      for (final item in venue.destinations)
        if (item.nodeId == nodeId)
          Destination(
            id: item.id,
            name: updated,
            nodeId: item.nodeId,
            category: item.category,
            description: item.description,
          )
        else
          item,
    ];
    return _copy(venue, nodes: nodes, destinations: destinations);
  }

  Venue connectNodes(
    Venue venue, {
    required String from,
    required String to,
  }) {
    if (from == to) throw StateError('A point cannot link to itself.');
    final a = venue.nodeById(from);
    final b = venue.nodeById(to);
    if (a.floor != b.floor) {
      throw StateError(
        'Cross-floor connections require a stair/elevator portal. '
        'Use Pass 8 for vertical transitions.',
      );
    }
    if (venue.edges.any((edge) =>
        (edge.from == from && edge.to == to) ||
        (edge.from == to && edge.to == from))) {
      throw StateError('Those waypoints are already connected.');
    }
    return _copy(
      venue,
      edges: [
        ...venue.edges,
        NavEdge(
          from: from,
          to: to,
          distanceMeters: _distance(a, b),
        ),
      ],
    );
  }

  Venue disconnectNodes(
    Venue venue, {
    required String from,
    required String to,
  }) {
    final next = venue.edges
        .where((edge) =>
            !((edge.from == from && edge.to == to) ||
                (edge.from == to && edge.to == from)))
        .toList(growable: false);
    if (next.length == venue.edges.length) {
      throw StateError('No connection exists between those waypoints.');
    }
    return _copy(venue, edges: next);
  }

  /// Splits a saved same-floor segment into two at an editable waypoint.
  /// The original segment's direction and accessibility are preserved.
  Venue insertWaypoint(
    Venue venue, {
    required String from,
    required String to,
    required String newNodeId,
    required double x,
    required double y,
  }) {
    if (!x.isFinite || !y.isFinite) {
      throw ArgumentError('Waypoint coordinates must be finite.');
    }
    if (venue.nodes.any((node) => node.id == newNodeId)) {
      throw StateError('Waypoint ID already exists.');
    }
    NavEdge? original;
    for (final edge in venue.edges) {
      if ((edge.from == from && edge.to == to) ||
          (edge.from == to && edge.to == from)) {
        original = edge;
        break;
      }
    }
    if (original == null) {
      throw StateError('Select an existing segment to insert a waypoint.');
    }
    final a = venue.nodeById(original.from);
    final b = venue.nodeById(original.to);
    if (a.floor != b.floor) {
      throw StateError('Cannot split an inter-floor connection.');
    }
    final inserted = NavNode(
      id: newNodeId,
      label: 'Waypoint',
      floor: a.floor,
      x: x,
      y: y,
      type: 'waypoint',
    );
    if (_rawDistance(a, inserted) < 0.15 ||
        _rawDistance(inserted, b) < 0.15) {
      throw StateError('Place the waypoint at least 15 cm from each endpoint.');
    }

    final edges = <NavEdge>[];
    for (final edge in venue.edges) {
      if (identical(edge, original)) {
        edges.addAll([
          NavEdge(
            from: a.id,
            to: inserted.id,
            distanceMeters: _distance(a, inserted),
            bidirectional: edge.bidirectional,
            accessible: edge.accessible,
          ),
          NavEdge(
            from: inserted.id,
            to: b.id,
            distanceMeters: _distance(inserted, b),
            bidirectional: edge.bidirectional,
            accessible: edge.accessible,
          ),
        ]);
      } else {
        edges.add(edge);
      }
    }
    return _copy(venue, nodes: [...venue.nodes, inserted], edges: edges);
  }

  /// A node has to be disconnected first. Never silently remove a corridor
  /// segment, destination, real-world QR anchor or another graph dependency.
  Venue deleteUnusedWaypoint(Venue venue, String nodeId) {
    final node = venue.nodeById(nodeId);
    _requireEditableNode(venue, node);
    if (venue.destinations.any((dest) => dest.nodeId == nodeId) ||
        nodeId == venue.defaultStartNodeId) {
      throw StateError('This waypoint is used by a destination or start.');
    }
    if (venue.edges.any((edge) =>
        edge.from == nodeId || edge.to == nodeId)) {
      throw StateError('Disconnect every attached segment before deleting.');
    }
    return _copy(
      venue,
      nodes: venue.nodes.where((node) => node.id != nodeId).toList(),
    );
  }

  /// Warn, but don't silently destroy existing disconnected map components.
  List<String> unreachableDestinations(Venue venue) {
    final visited = <String>{};
    final pending = <String>[venue.defaultStartNodeId];
    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      if (!visited.add(id)) continue;
      for (final edge in venue.edges) {
        if (!edge.accessible) continue;
        if (edge.from == id && !visited.contains(edge.to)) {
          pending.add(edge.to);
        }
        if (edge.bidirectional &&
            edge.to == id &&
            !visited.contains(edge.from)) {
          pending.add(edge.from);
        }
      }
    }
    return [
      for (final dest in venue.destinations)
        if (!visited.contains(dest.nodeId)) dest.name,
    ];
  }

  void validate(Venue venue) {
    final ids = <String>{};
    for (final node in venue.nodes) {
      if (!ids.add(node.id)) {
        throw StateError('Duplicate waypoint ID: ${node.id}');
      }
      if (!node.x.isFinite || !node.y.isFinite) {
        throw StateError('Invalid position at ${node.label}.');
      }
    }
    if (!ids.contains(venue.defaultStartNodeId)) {
      throw StateError('The default start waypoint is missing.');
    }
    for (final edge in venue.edges) {
      if (!ids.contains(edge.from) || !ids.contains(edge.to) ||
          !edge.distanceMeters.isFinite || edge.distanceMeters <= 0) {
        throw StateError('Invalid saved segment: ${edge.from} → ${edge.to}.');
      }
    }
    for (final dest in venue.destinations) {
      if (!ids.contains(dest.nodeId)) {
        throw StateError('Destination ${dest.name} has no waypoint.');
      }
    }
    for (final anchor in venue.anchors) {
      if (!ids.contains(anchor.nodeId) ||
          venue.nodeById(anchor.nodeId).floor != anchor.floor) {
        throw StateError('QR anchor ${anchor.label} has no valid floor waypoint.');
      }
    }
  }

  bool isAnchored(Venue venue, String nodeId) =>
      venue.anchors.any((item) => item.nodeId == nodeId);

  void _requireEditableNode(Venue venue, NavNode node) {
    if (isAnchored(venue, node.id) || node.id == venue.defaultStartNodeId) {
      throw StateError(
        'This point is tied to a real AR start anchor. '
        'Moving it would invalidate saved localization. '
        'Only ordinary waypoints and destinations are editable.',
      );
    }
  }

  double _distance(NavNode a, NavNode b) =>
      math.max(0.1, _rawDistance(a, b));

  double _rawDistance(NavNode a, NavNode b) =>
      math.sqrt(math.pow(b.x - a.x, 2) + math.pow(b.y - a.y, 2));

  Venue _copy(
    Venue source, {
    List<NavNode>? nodes,
    List<NavEdge>? edges,
    List<Destination>? destinations,
  }) =>
      Venue(
        id: source.id,
        name: source.name,
        description: source.description,
        defaultStartNodeId: source.defaultStartNodeId,
        floors: source.floors,
        nodes: List.unmodifiable(nodes ?? source.nodes),
        edges: List.unmodifiable(edges ?? source.edges),
        destinations: List.unmodifiable(destinations ?? source.destinations),
        anchors: source.anchors,
      );
}
