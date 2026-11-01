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
            transitionType: edge.transitionType,
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

  /// Create a floor layer without inventing mapped nodes or AR anchors.
  Venue addFloor(Venue venue, int floor) {
    if (floor < -10 || floor > 50) {
      throw ArgumentError('Floor must be between B10 and Floor 50.');
    }
    if (venue.floors.contains(floor)) return venue;
    return _copy(venue, floors: ([...venue.floors, floor]..sort()));
  }

  /// Mark an already mapped point as the entrance to stairs or an elevator.
  Venue markFloorPortal(
    Venue venue, {
    required String nodeId,
    required String kind,
  }) {
    if (kind != 'stairs' && kind != 'elevator') {
      throw ArgumentError('Portal must be stairs or elevator.');
    }
    final node = venue.nodeById(nodeId);
    _requireEditableNode(venue, node);
    final activeTransitions = venue.edges.where((edge) =>
        edge.isFloorTransition &&
        (edge.from == nodeId || edge.to == nodeId));
    if (activeTransitions.any((edge) => edge.transitionType != kind)) {
      throw StateError(
        'Disconnect the existing floor transition before changing '
        'this portal from stairs to elevator or vice versa.',
      );
    }
    if (node.type == kind) return venue;
    return _copy(
      venue,
      nodes: [
        for (final n in venue.nodes)
          if (n.id == nodeId)
            NavNode(
              id: n.id,
              label: n.label,
              floor: n.floor,
              x: n.x,
              y: n.y,
              type: kind,
            )
          else n,
      ],
    );
  }

  /// Cross-floor distance is the ACTUAL approximate traversed length, not
  /// a misleading flat XY distance between independently mapped layers.
  Venue linkFloorPortals(
    Venue venue, {
    required String from,
    required String to,
    required String kind,
    required double distanceMeters,
  }) {
    if (kind != 'stairs' && kind != 'elevator') {
      throw ArgumentError('Choose stairs or elevator.');
    }
    if (!distanceMeters.isFinite ||
        distanceMeters < 1.0 ||
        distanceMeters > 250.0) {
      throw ArgumentError('Enter a realistic travel length (1–250 m).');
    }
    final a = venue.nodeById(from);
    final b = venue.nodeById(to);
    if (from == to || a.floor == b.floor) {
      throw StateError('Choose portals on TWO DIFFERENT floors.');
    }
    if (a.type != kind || b.type != kind) {
      throw StateError('Both mapped points must be marked as $kind.');
    }
    final floors = <int>{
      ...venue.floors,
      ...venue.nodes.map((node) => node.floor),
    }.toList()..sort();
    if (kind == 'stairs' &&
        (floors.indexOf(a.floor) - floors.indexOf(b.floor)).abs() != 1) {
      throw StateError(
        'Stairs connect adjacent listed floor layers only. '
        'Map an intermediate floor landing, or choose an elevator.',
      );
    }
    if (venue.edges.any((edge) =>
        (edge.from == from && edge.to == to) ||
        (edge.from == to && edge.to == from))) {
      throw StateError('These floor portals are already linked.');
    }
    final next = _copy(
      venue,
      edges: [
        ...venue.edges,
        NavEdge(
          from: from,
          to: to,
          distanceMeters: distanceMeters,
          transitionType: kind,
          bidirectional: true,
        ),
      ],
    );
    validate(next);
    return next;
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
    final distance = _rawDistance(a, b);
    // A direct graph edge means the person can ACTUALLY walk that straight
    // connection. Missing 50m corridors must be recorded, not fabricated.
    if (distance > 5.0) {
      throw StateError(
        'These points are ${distance.toStringAsFixed(1)} m apart. '
        'Direct links are limited to 5 m. Map the missing corridor or '
        'use ALIGN SECTIONS only for the same verified physical junction.',
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

  /// Align an entirely disconnected and *unanchored* section to one
  /// verified physical junction. It only translates the component; heading
  /// and true physical identity of the two junctions are NOT verified.
  /// The caller must confirm that both points are the same real location.
  ///
  /// This is deliberately not allowed to move a QR-anchored component.
  Venue alignAndJoinSections(
    Venue venue, {
    required String movingPointId,
    required String fixedPointId,
  }) {
    if (movingPointId == fixedPointId) {
      throw StateError('Choose two different points.');
    }
    final moving = venue.nodeById(movingPointId);
    final fixed = venue.nodeById(fixedPointId);
    if (moving.floor != fixed.floor) {
      throw StateError('Both junctions must be on the same floor.');
    }
    final component = <String>{};
    final stack = <String>[movingPointId];
    while (stack.isNotEmpty) {
      final id = stack.removeLast();
      if (!component.add(id)) continue;
      for (final edge in venue.edges) {
        if (edge.from == id && !component.contains(edge.to)) {
          stack.add(edge.to);
        }
        if (edge.to == id && !component.contains(edge.from)) {
          stack.add(edge.from);
        }
      }
    }
    if (component.contains(fixedPointId)) {
      throw StateError('These points are already in the same path network.');
    }
    if (component.contains(venue.defaultStartNodeId) ||
        venue.anchors.any((anchor) => component.contains(anchor.nodeId))) {
      throw StateError(
        'This section contains a saved AR anchor or the venue start. '
        'Select the OTHER disconnected section to move instead.',
      );
    }
    if (venue.nodes
        .where((node) => component.contains(node.id))
        .any((node) => node.floor != moving.floor)) {
      throw StateError(
        'Moving a network spanning different floors is unsafe.',
      );
    }
    final dx = fixed.x - moving.x;
    final dy = fixed.y - moving.y;
    if (!dx.isFinite || !dy.isFinite) {
      throw StateError('Invalid junction coordinates.');
    }
    final shifted = [
      for (final node in venue.nodes)
        if (component.contains(node.id))
          NavNode(
            id: node.id,
            label: node.label,
            floor: node.floor,
            x: node.x + dx,
            y: node.y + dy,
            type: node.type,
          )
        else
          node,
    ];
    final shiftedVenue = _copy(venue, nodes: shifted);
    // With the junctions now co-located, this creates one short deliberate
    // traversal link. If physical junction matching is wrong, the resulting
    // navigation will be wrong: the UI must warn and require confirmation.
    return connectNodes(
      shiftedVenue,
      from: movingPointId,
      to: fixedPointId,
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

  /// Remove an erroneous mapped point and all its incident edges.
  /// NEVER removes a destination, default start or AR localization anchor.
  ///
  /// Optional healing is safe only for a simple 2-edge same-floor corridor
  /// with bidirectional, accessible edges and a <=5 m direct link. No
  /// automatic jump across a tracking-loss gap or branch junction.
  Venue removeBadWaypoint(
    Venue venue,
    String nodeId, {
    bool reconnectNeighbors = false,
  }) {
    final node = venue.nodeById(nodeId);
    _requireEditableNode(venue, node);
    if (venue.destinations.any((d) => d.nodeId == nodeId)) {
      throw StateError(
        'This point represents a named destination. Move or rename it '
        'instead; destination deletion needs an explicit separate action.',
      );
    }
    final incident = venue.edges
        .where((e) => e.from == nodeId || e.to == nodeId)
        .toList();
    final retainedEdges = venue.edges
        .where((e) => e.from != nodeId && e.to != nodeId)
        .toList();
    if (reconnectNeighbors) {
      if (incident.length != 2 ||
          incident.any((e) => !e.bidirectional || !e.accessible)) {
        throw StateError(
          'Automatic reconnect needs exactly two walkable, '
          'bidirectional segments. Use Delete & Disconnect instead.',
        );
      }
      final a = venue.nodeById(
          incident[0].from == nodeId ? incident[0].to : incident[0].from);
      final b = venue.nodeById(
          incident[1].from == nodeId ? incident[1].to : incident[1].from);
      if (a.id == b.id || a.floor != b.floor || a.floor != node.floor) {
        throw StateError('These neighboring points cannot be reconnected.');
      }
      final distance = _rawDistance(a, b);
      if (distance > 5.0) {
        throw StateError(
          'The neighboring points are ${distance.toStringAsFixed(1)} m '
          'apart. Reconnecting would invent a route. '
          'Use Delete & Disconnect, then remap the missing section.',
        );
      }
      if (!retainedEdges.any((edge) =>
          (edge.from == a.id && edge.to == b.id) ||
          (edge.from == b.id && edge.to == a.id))) {
        retainedEdges.add(NavEdge(
          from: a.id,
          to: b.id,
          distanceMeters: _distance(a, b),
          bidirectional: true,
          accessible: true,
        ));
      }
    }
    return _copy(
      venue,
      nodes: venue.nodes.where((n) => n.id != nodeId).toList(),
      edges: retainedEdges,
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
      final a = venue.nodeById(edge.from);
      final b = venue.nodeById(edge.to);
      if (a.floor != b.floor) {
        if (edge.transitionType != 'stairs' &&
            edge.transitionType != 'elevator') {
          throw StateError(
            'Cross-floor edge ${edge.from} → ${edge.to} '
            'needs explicit stairs/elevator metadata.',
          );
        }
        if (a.type != edge.transitionType ||
            b.type != edge.transitionType) {
          throw StateError('Floor portal type does not match its endpoints.');
        }
      } else if (edge.transitionType != null) {
        throw StateError('A floor-transition edge cannot remain on one floor.');
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
    List<int>? floors,
  }) =>
      Venue(
        id: source.id,
        name: source.name,
        description: source.description,
        defaultStartNodeId: source.defaultStartNodeId,
        floors: List.unmodifiable(floors ?? source.floors),
        nodes: List.unmodifiable(nodes ?? source.nodes),
        edges: List.unmodifiable(edges ?? source.edges),
        destinations: List.unmodifiable(destinations ?? source.destinations),
        anchors: source.anchors,
      );
}
