import 'dart:math' as math;

import '../models/anchor_point.dart';
import '../models/destination.dart';
import '../models/mapping_session.dart';
import '../models/nav_edge.dart';
import '../models/nav_node.dart';
import '../models/venue.dart';

class VenueMappingService {
  const VenueMappingService();

  Venue applySession({
    required Venue venue,
    required MappingSession session,
  }) {
    _validateSession(venue, session);

    final startAnchor = _findAnchor(venue, session.startAnchorId);
    final startNodeId = startAnchor?.nodeId ??
        'recorded_start_${_safe(session.id)}';
    final startLabel = startAnchor?.label ??
        session.startAnchorLabel ??
        'Recorded start';

    final generated = _buildRecordedFloor(
      venue: venue,
      session: session,
      originX: 0,
      originY: 0,
      startNodeId: startNodeId,
      startLabel: startLabel,
      startAnchor: startAnchor,
    );

    final oldFloorNodeIds = venue.nodes
        .where((node) => node.floor == session.floor)
        .map((node) => node.id)
        .toSet();

    final nodes = <NavNode>[
      ...venue.nodes.where((node) => node.floor != session.floor),
      ...generated.nodes,
    ];

    final edges = <NavEdge>[
      ...venue.edges.where(
        (edge) =>
            !oldFloorNodeIds.contains(edge.from) &&
            !oldFloorNodeIds.contains(edge.to),
      ),
      ...generated.edges,
    ];

    final destinations = <Destination>[
      ...venue.destinations.where(
        (destination) => !oldFloorNodeIds.contains(destination.nodeId),
      ),
      ...generated.destinations,
    ];

    final anchors = <AnchorPoint>[
      ...venue.anchors.where(
        (anchor) => anchor.floor != session.floor,
      ),
      ...generated.anchors,
    ];

    final defaultStart = nodes.any((node) => node.id == startNodeId)
        ? startNodeId
        : nodes.first.id;

    return Venue(
      id: venue.id,
      name: venue.name,
      description:
          'Recorded offline venue data · Floor ${session.floor} mapped by walk session.',
      defaultStartNodeId: defaultStart,
      floors: _mergedFloors(venue.floors, session.floor),
      nodes: List<NavNode>.unmodifiable(nodes),
      edges: List<NavEdge>.unmodifiable(edges),
      destinations: List<Destination>.unmodifiable(destinations),
      anchors: List<AnchorPoint>.unmodifiable(anchors),
    );
  }

  Venue mergeSession({
    required Venue venue,
    required MappingSession session,
  }) {
    _validateSession(venue, session);

    final startAnchor = _findAnchor(venue, session.startAnchorId);
    if (startAnchor == null) {
      throw StateError(
        'Merge requires a start QR anchor that already exists in the venue.',
      );
    }

    NavNode? originNode;
    for (final node in venue.nodes) {
      if (node.id == startAnchor.nodeId) {
        originNode = node;
        break;
      }
    }

    if (originNode == null) {
      throw StateError(
        'The start anchor points to a node that is not in the current venue.',
      );
    }

    final generated = _buildRecordedFloor(
      venue: venue,
      session: session,
      originX: originNode.x,
      originY: originNode.y,
      startNodeId: originNode.id,
      startLabel: originNode.label,
      startAnchor: startAnchor,
    );

    final existingNodeIds = venue.nodes.map((node) => node.id).toSet();
    final existingDestinationIds =
        venue.destinations.map((item) => item.id).toSet();
    final existingAnchorIds = venue.anchors.map((item) => item.id).toSet();

    final nodes = <NavNode>[
      ...venue.nodes,
      ...generated.nodes.where((node) => !existingNodeIds.contains(node.id)),
    ];

    final edges = <NavEdge>[
      ...venue.edges,
      ...generated.edges.where(
        (edge) => !_hasEquivalentEdge(venue.edges, edge),
      ),
    ];

    final destinations = <Destination>[
      ...venue.destinations,
      ...generated.destinations.where(
        (item) => !existingDestinationIds.contains(item.id),
      ),
    ];

    final anchors = <AnchorPoint>[
      ...venue.anchors,
      ...generated.anchors.where(
        (item) => !existingAnchorIds.contains(item.id),
      ),
    ];

    return Venue(
      id: venue.id,
      name: venue.name,
      description: venue.description,
      defaultStartNodeId: venue.defaultStartNodeId,
      floors: _mergedFloors(venue.floors, session.floor),
      nodes: List<NavNode>.unmodifiable(nodes),
      edges: List<NavEdge>.unmodifiable(edges),
      destinations: List<Destination>.unmodifiable(destinations),
      anchors: List<AnchorPoint>.unmodifiable(anchors),
    );
  }

  void _validateSession(Venue venue, MappingSession session) {
    if (session.venueId != venue.id) {
      throw StateError(
        'This recording belongs to ${session.venueName}, not ${venue.name}.',
      );
    }
    if (session.points.length < 2) {
      throw StateError('This recording does not contain a usable path.');
    }
  }

  _GeneratedFloor _buildRecordedFloor({
    required Venue venue,
    required MappingSession session,
    required double originX,
    required double originY,
    required String startNodeId,
    required String startLabel,
    required AnchorPoint? startAnchor,
  }) {
    final selected = _selectedPointIndices(session);
    final markerGroups = <int, List<MappingMarker>>{};

    for (final marker in session.markers) {
      final index = marker.pointIndex.clamp(0, session.points.length - 1).toInt();
      markerGroups.putIfAbsent(index, () => <MappingMarker>[]).add(marker);
    }

    final nodes = <NavNode>[];
    final nodeIdByIndex = <int, String>{};
    final destinations = <Destination>[];
    final anchors = <AnchorPoint>[];
    final usedNodeIds = <String>{startNodeId};
    final usedAnchorIds = <String>{};
    final usedDestinationIds = <String>{};

    final startPoint = _worldPoint(
      session.points.first,
      session.originHeadingDegrees,
      originX,
      originY,
    );

    nodes.add(
      NavNode(
        id: startNodeId,
        label: startLabel,
        floor: session.floor,
        x: startPoint.$1,
        y: startPoint.$2,
        type: 'entrance',
      ),
    );
    nodeIdByIndex[selected.first] = startNodeId;

    if (startAnchor != null) {
      anchors.add(
        AnchorPoint(
          id: startAnchor.id,
          label: startAnchor.label,
          nodeId: startNodeId,
          floor: session.floor,
          headingDegrees: startAnchor.headingDegrees,
        ),
      );
      usedAnchorIds.add(startAnchor.id);
    }

    var genericCounter = 1;

    for (final index in selected.skip(1)) {
      final point = session.points[index];
      final world = _worldPoint(
        point,
        session.originHeadingDegrees,
        originX,
        originY,
      );
      final group = markerGroups[index] ?? const <MappingMarker>[];
      final primary = _primaryMarker(group);

      final baseNodeId = primary == null
          ? 'path_${genericCounter++}'
          : _safe(primary.id);
      final nodeId = _uniqueId(
        'rec_${_safe(session.id)}_$baseNodeId',
        usedNodeIds,
      );
      usedNodeIds.add(nodeId);

      final label = primary?.label ?? 'Recorded path';
      final type = _nodeType(primary?.type);

      nodes.add(
        NavNode(
          id: nodeId,
          label: label,
          floor: session.floor,
          x: world.$1,
          y: world.$2,
          type: type,
        ),
      );
      nodeIdByIndex[index] = nodeId;

      for (final marker in group) {
        if (marker.type == 'destination' || marker.type == 'stairs') {
          final id = _uniqueId(
            'dest_${_safe(marker.id)}',
            usedDestinationIds,
          );
          usedDestinationIds.add(id);
          destinations.add(
            Destination(
              id: id,
              name: marker.label,
              nodeId: nodeId,
              category: marker.type == 'stairs' ? 'stairs' : 'place',
              description: 'Recorded on Floor ${session.floor}',
            ),
          );
        }

        if (marker.type == 'anchor') {
          final id = _uniqueId(
            _safe(marker.id),
            usedAnchorIds,
          );
          usedAnchorIds.add(id);
          anchors.add(
            AnchorPoint(
              id: id,
              label: marker.label,
              nodeId: nodeId,
              floor: session.floor,
              headingDegrees: null,
            ),
          );
        }
      }
    }

    final edges = <NavEdge>[];
    for (var i = 0; i < selected.length - 1; i++) {
      final fromIndex = selected[i];
      final toIndex = selected[i + 1];
      final from = nodeIdByIndex[fromIndex]!;
      final to = nodeIdByIndex[toIndex]!;
      final distance = _distanceBetweenIndices(
        session,
        fromIndex,
        toIndex,
      );

      edges.add(
        NavEdge(
          from: from,
          to: to,
          distanceMeters: math.max(0.1, distance).toDouble(),
          bidirectional: true,
          accessible: true,
        ),
      );
    }

    return _GeneratedFloor(
      nodes: nodes,
      edges: edges,
      destinations: destinations,
      anchors: anchors,
    );
  }

  List<int> _selectedPointIndices(MappingSession session) {
    final last = session.points.length - 1;
    final selected = <int>{0, last};

    // Routing density is now based on real traveled distance, not sample count.
    // This works for both legacy step recordings and high-frequency ARCore poses.
    const targetSpacingMeters = 2.5;
    var distanceSinceNode = 0.0;

    for (var i = 1; i < last; i++) {
      distanceSinceNode += _pointDistance(
        session.points[i - 1],
        session.points[i],
      );

      if (distanceSinceNode >= targetSpacingMeters) {
        selected.add(i);
        distanceSinceNode = 0.0;
      }
    }

    // Intentional semantic markers are never simplified away.
    for (final marker in session.markers) {
      selected.add(marker.pointIndex.clamp(0, last).toInt());
    }

    final result = selected.toList()..sort();
    return result;
  }

  double _distanceBetweenIndices(
    MappingSession session,
    int fromIndex,
    int toIndex,
  ) {
    final start = math.min(fromIndex, toIndex);
    final end = math.max(fromIndex, toIndex);
    var total = 0.0;

    for (var i = start + 1; i <= end; i++) {
      total += _pointDistance(
        session.points[i - 1],
        session.points[i],
      );
    }

    return total;
  }

  double _pointDistance(MappingPoint a, MappingPoint b) {
    final dx = b.xMeters - a.xMeters;
    final dy = b.yMeters - a.yMeters;
    final dz = b.upMeters - a.upMeters;
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  (double, double) _worldPoint(
    MappingPoint point,
    double originHeadingDegrees,
    double originX,
    double originY,
  ) {
    final theta = originHeadingDegrees * math.pi / 180.0;
    final east =
        point.xMeters * math.cos(theta) + point.yMeters * math.sin(theta);
    final south =
        point.xMeters * math.sin(theta) - point.yMeters * math.cos(theta);

    // Venue coordinates intentionally use screen/map convention:
    // +x = east/right, +y = south/down. This keeps recorded-meter venues
    // compatible with DirectionGuidance and the bundled sample graph.
    return (originX + east, originY + south);
  }

  MappingMarker? _primaryMarker(List<MappingMarker> markers) {
    if (markers.isEmpty) return null;

    const priority = <String, int>{
      'destination': 4,
      'stairs': 3,
      'anchor': 2,
      'waypoint': 1,
    };

    final sorted = List<MappingMarker>.of(markers)
      ..sort(
        (a, b) => (priority[b.type] ?? 0).compareTo(priority[a.type] ?? 0),
      );
    return sorted.first;
  }

  String _nodeType(String? markerType) {
    return switch (markerType) {
      'destination' => 'destination',
      'stairs' => 'stairs',
      'anchor' => 'anchor',
      'waypoint' => 'waypoint',
      _ => 'path',
    };
  }

  AnchorPoint? _findAnchor(Venue venue, String? id) {
    if (id == null || id.isEmpty) return null;
    for (final anchor in venue.anchors) {
      if (anchor.id == id) return anchor;
    }
    return null;
  }

  bool _hasEquivalentEdge(List<NavEdge> edges, NavEdge candidate) {
    for (final edge in edges) {
      final same = edge.from == candidate.from && edge.to == candidate.to;
      final reverse = edge.bidirectional &&
          candidate.bidirectional &&
          edge.from == candidate.to &&
          edge.to == candidate.from;
      if (same || reverse) return true;
    }
    return false;
  }

  List<int> _mergedFloors(List<int> floors, int floor) {
    final result = <int>{...floors, floor}.toList()..sort();
    return result;
  }

  String _safe(String value) {
    final cleaned = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return cleaned.isEmpty ? 'item' : cleaned;
  }

  String _uniqueId(String preferred, Set<String> used) {
    if (!used.contains(preferred)) return preferred;
    var counter = 2;
    while (used.contains('${preferred}_$counter')) {
      counter++;
    }
    return '${preferred}_$counter';
  }
}

class _GeneratedFloor {
  const _GeneratedFloor({
    required this.nodes,
    required this.edges,
    required this.destinations,
    required this.anchors,
  });

  final List<NavNode> nodes;
  final List<NavEdge> edges;
  final List<Destination> destinations;
  final List<AnchorPoint> anchors;
}
