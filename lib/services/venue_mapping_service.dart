import 'dart:math' as math;

import '../models/anchor_point.dart';
import '../models/destination.dart';
import '../models/mapping_session.dart';
import '../models/nav_edge.dart';
import '../models/nav_node.dart';
import '../models/venue.dart';
import 'venue_transform_2d.dart';

class VenueMappingService {
  const VenueMappingService();

  bool hasSpatialAlignment({
    required Venue venue,
    required MappingSession session,
  }) {
    if (!session.isSpatial) return true;

    try {
      final startAnchor = _requireStartAnchor(venue, session);
      final originNode = _requireAnchorNode(venue, startAnchor);
      _spatialTransform(
        venue: venue,
        session: session,
        startAnchor: startAnchor,
        originNode: originNode,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

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

    // Preserve an existing start anchor's venue position when a new visual
    // QR pose is placed for it. For a brand-new venue/start, the first
    // recording still defines the persistent venue frame.
    final existingStartNode =
        startAnchor == null ? null : _findNode(venue, startAnchor.nodeId);
    final placedStartQr = _placedStartVisualMarker(
      session,
      startAnchorId: startAnchor?.id,
    );
    final transform = placedStartQr != null && existingStartNode != null
        ? VenueTransform2D.fromPointAndHeading(
            localX: placedStartQr.xMeters,
            localY: placedStartQr.yMeters,
            venueX: existingStartNode.x,
            venueY: existingStartNode.y,
            headingDegrees: startAnchor?.visualPoseReady == true
                ? _headingDelta(
                    startAnchor!.headingDegrees!,
                    placedStartQr.anchorFacingDegrees!,
                  )
                : session.originHeadingDegrees,
          )
        : VenueTransform2D.atOrigin(
            headingDegrees: session.originHeadingDegrees,
          );

    final generated = _buildRecordedFloor(
      venue: venue,
      session: session,
      transform: transform,
      startNodeId: startNodeId,
      startLabel: startLabel,
      startAnchor: startAnchor,
      reuseReferencedAnchors: false,
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

    final startAnchor = _requireStartAnchor(venue, session);
    final originNode = _requireAnchorNode(venue, startAnchor);

    final transform = session.isSpatial
        ? _spatialTransform(
            venue: venue,
            session: session,
            startAnchor: startAnchor,
            originNode: originNode,
          )
        : VenueTransform2D.fromPointAndHeading(
            localX: session.points.first.xMeters,
            localY: session.points.first.yMeters,
            venueX: originNode.x,
            venueY: originNode.y,
            headingDegrees: session.originHeadingDegrees,
          );

    final generated = _buildRecordedFloor(
      venue: venue,
      session: session,
      transform: transform,
      startNodeId: originNode.id,
      startLabel: originNode.label,
      startAnchor: startAnchor,
      reuseReferencedAnchors: session.isSpatial,
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
    required VenueTransform2D transform,
    required String startNodeId,
    required String startLabel,
    required AnchorPoint? startAnchor,
    required bool reuseReferencedAnchors,
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

    final startGroup = markerGroups[selected.first] ?? const <MappingMarker>[];
    final startVisualAnchor = _visualAnchorMarker(startGroup);
    final startPoint = startVisualAnchor == null
        ? _worldPoint(
            session.points.first,
            transform,
          )
        : transform.applyPoint(
            startVisualAnchor.xMeters,
            startVisualAnchor.yMeters,
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
      MappingMarker? visualUpgrade;
      for (final marker in startGroup) {
        if (marker.type == 'anchor' &&
            marker.id == startAnchor.id &&
            marker.anchorFacingDegrees != null) {
          visualUpgrade = marker;
          break;
        }
      }

      anchors.add(
        AnchorPoint(
          id: startAnchor.id,
          label: startAnchor.label,
          nodeId: startNodeId,
          floor: session.floor,
          headingDegrees: visualUpgrade == null
              ? startAnchor.headingDegrees
              : _markerAnchorHeading(visualUpgrade, transform),
          visualHeadingVerified:
              visualUpgrade != null || startAnchor.visualHeadingVerified,
          offlineVisualReferencePngBase64:
              session.offlineVisualReferencePngBase64 ??
                  startAnchor.offlineVisualReferencePngBase64,
          offlineVisualReferenceWidthMeters:
              session.offlineVisualReferenceWidthMeters ??
                  startAnchor.offlineVisualReferenceWidthMeters,
          offlineVisualStartOffsetX:
              session.offlineVisualStartOffsetX ??
                  startAnchor.offlineVisualStartOffsetX,
          offlineVisualStartOffsetY:
              session.offlineVisualStartOffsetY ??
                  startAnchor.offlineVisualStartOffsetY,
          offlineVisualStartOffsetZ:
              session.offlineVisualStartOffsetZ ??
                  startAnchor.offlineVisualStartOffsetZ,
          offlineVisualStartForwardX:
              session.offlineVisualStartForwardX ??
                  startAnchor.offlineVisualStartForwardX,
          offlineVisualStartForwardY:
              session.offlineVisualStartForwardY ??
                  startAnchor.offlineVisualStartForwardY,
          offlineVisualStartForwardZ:
              session.offlineVisualStartForwardZ ??
                  startAnchor.offlineVisualStartForwardZ,
        ),
      );
      usedAnchorIds.add(startAnchor.id);
    }

    // Semantic markers at the first recorded point belong to the start node.
    // A visual QR marker can carry an exact free-space AR pose that differs
    // from the phone's walking sample; the start node above already uses it.
    for (final marker in startGroup) {
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
            nodeId: startNodeId,
            category: marker.type == 'stairs' ? 'stairs' : 'place',
            description: 'Recorded on Floor ${session.floor}',
          ),
        );
      }

      if (marker.type == 'anchor') {
        if (reuseReferencedAnchors &&
            marker.referenceAnchorId != null &&
            marker.referenceAnchorId!.isNotEmpty) {
          continue;
        }

        // If this recording already started from the same known anchor, do not
        // duplicate it merely because an anchor marker also exists at index 0.
        if (startAnchor != null && marker.id == startAnchor.id) {
          continue;
        }

        final id = _uniqueId(
          _safe(marker.id),
          usedAnchorIds,
        );
        usedAnchorIds.add(id);
        anchors.add(
          AnchorPoint(
            id: id,
            label: marker.label,
            nodeId: startNodeId,
            floor: session.floor,
            headingDegrees: _markerAnchorHeading(marker, transform),
            visualHeadingVerified: marker.anchorFacingDegrees != null,
            offlineVisualReferencePngBase64:
                session.offlineVisualReferencePngBase64,
            offlineVisualReferenceWidthMeters:
                session.offlineVisualReferenceWidthMeters,
            offlineVisualStartOffsetX: session.offlineVisualStartOffsetX,
            offlineVisualStartOffsetY: session.offlineVisualStartOffsetY,
            offlineVisualStartOffsetZ: session.offlineVisualStartOffsetZ,
            offlineVisualStartForwardX: session.offlineVisualStartForwardX,
            offlineVisualStartForwardY: session.offlineVisualStartForwardY,
            offlineVisualStartForwardZ: session.offlineVisualStartForwardZ,
          ),
        );
      }
    }

    var genericCounter = 1;

    for (final index in selected.skip(1)) {
      final point = session.points[index];
      final group = markerGroups[index] ?? const <MappingMarker>[];
      final visualAnchor = _visualAnchorMarker(group);
      final world = visualAnchor == null
          ? _worldPoint(
              point,
              transform,
            )
          : transform.applyPoint(
              visualAnchor.xMeters,
              visualAnchor.yMeters,
            );
      final primary = _primaryMarker(group);

      MappingMarker? referenceMarker;
      if (reuseReferencedAnchors) {
        for (final marker in group) {
          if (marker.type == 'anchor' &&
              marker.referenceAnchorId != null &&
              marker.referenceAnchorId!.isNotEmpty) {
            referenceMarker = marker;
            break;
          }
        }
      }

      final referencedAnchor = referenceMarker == null
          ? null
          : _findAnchor(venue, referenceMarker.referenceAnchorId);
      final referencedNode =
          referencedAnchor == null ? null : _findNode(venue, referencedAnchor.nodeId);

      late final String nodeId;
      if (referencedNode != null) {
        // This point is the same physical place as an existing venue anchor.
        // Reuse the node so the merged route connects into the existing graph
        // instead of creating a duplicate location beside it.
        nodeId = referencedNode.id;
      } else {
        final baseNodeId = primary == null
            ? 'path_${genericCounter++}'
            : _safe(primary.id);
        nodeId = _uniqueId(
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
      }
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
          if (reuseReferencedAnchors &&
              marker.referenceAnchorId != null &&
              marker.referenceAnchorId!.isNotEmpty) {
            // This marker only identifies a known physical anchor used for
            // alignment. The venue already owns that anchor.
            continue;
          }

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
              headingDegrees: _markerAnchorHeading(marker, transform),
              visualHeadingVerified: marker.anchorFacingDegrees != null,
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
    VenueTransform2D transform,
  ) {
    return transform.applyPoint(
      point.xMeters,
      point.yMeters,
    );
  }

  double? _markerAnchorHeading(
    MappingMarker marker,
    VenueTransform2D transform,
  ) {
    final localHeading = marker.anchorFacingDegrees;
    if (localHeading == null) return null;

    final radians = localHeading * math.pi / 180.0;
    final localDx = math.sin(radians);
    final localDy = math.cos(radians);
    final venueVector = transform.applyVector(localDx, localDy);

    return VenueTransform2D.venueVectorHeadingDegrees(
      venueVector.$1,
      venueVector.$2,
    );
  }

  double? _headingAtIndex(
    MappingSession session,
    int index,
    VenueTransform2D transform,
  ) {
    if (session.points.length < 2) return null;

    final safeIndex = index.clamp(0, session.points.length - 1).toInt();
    final origin = session.points[safeIndex];
    const minimumBaselineMeters = 0.35;

    MappingPoint? target;

    for (var i = safeIndex + 1; i < session.points.length; i++) {
      final candidate = session.points[i];
      final dx = candidate.xMeters - origin.xMeters;
      final dy = candidate.yMeters - origin.yMeters;
      if (math.sqrt(dx * dx + dy * dy) >= minimumBaselineMeters) {
        target = candidate;
        break;
      }
    }

    if (target == null) {
      for (var i = safeIndex - 1; i >= 0; i--) {
        final candidate = session.points[i];
        final dx = origin.xMeters - candidate.xMeters;
        final dy = origin.yMeters - candidate.yMeters;
        if (math.sqrt(dx * dx + dy * dy) >= minimumBaselineMeters) {
          // At the end of a route, use the incoming direction.
          final vector = transform.applyVector(dx, dy);
          return VenueTransform2D.venueVectorHeadingDegrees(
            vector.$1,
            vector.$2,
          );
        }
      }
      return null;
    }

    final vector = transform.applyVector(
      target.xMeters - origin.xMeters,
      target.yMeters - origin.yMeters,
    );
    return VenueTransform2D.venueVectorHeadingDegrees(
      vector.$1,
      vector.$2,
    );
  }

  MappingMarker? _placedStartVisualMarker(
    MappingSession session, {
    required String? startAnchorId,
  }) {
    MappingMarker? fallback;
    for (final marker in session.markers) {
      if (marker.type != 'anchor' || marker.anchorFacingDegrees == null) {
        continue;
      }
      if (startAnchorId != null && marker.id == startAnchorId) {
        return marker;
      }
      if (startAnchorId == null && marker.pointIndex == 0) {
        fallback ??= marker;
      }
    }
    return fallback;
  }

  double _headingDelta(double targetHeading, double localHeading) {
    var delta = (targetHeading - localHeading) % 360.0;
    if (delta < 0) delta += 360.0;
    return delta;
  }
  MappingMarker? _visualAnchorMarker(List<MappingMarker> markers) {
    for (final marker in markers) {
      if (marker.type == 'anchor' && marker.anchorFacingDegrees != null) {
        return marker;
      }
    }
    return null;
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

  AnchorPoint _requireStartAnchor(
    Venue venue,
    MappingSession session,
  ) {
    final startAnchor = _findAnchor(venue, session.startAnchorId);
    if (startAnchor == null) {
      throw StateError(
        'Merge requires a start QR anchor that already exists in the venue.',
      );
    }
    return startAnchor;
  }

  NavNode _requireAnchorNode(
    Venue venue,
    AnchorPoint anchor,
  ) {
    final node = _findNode(venue, anchor.nodeId);
    if (node == null) {
      throw StateError(
        'Anchor "${anchor.label}" points to a node that is not in the '
        'current venue.',
      );
    }
    return node;
  }

  VenueTransform2D _spatialTransform({
    required Venue venue,
    required MappingSession session,
    required AnchorPoint startAnchor,
    required NavNode originNode,
  }) {
    MappingMarker? bestMarker;
    AnchorPoint? bestAnchor;
    NavNode? bestNode;
    var bestBaseline = 0.0;

    final visualStart = _placedStartVisualMarker(
      session,
      startAnchorId: startAnchor.id,
    );
    final localStartX = visualStart?.xMeters ?? session.points.first.xMeters;
    final localStartY = visualStart?.yMeters ?? session.points.first.yMeters;

    for (final marker in session.markers) {
      final referenceId = marker.referenceAnchorId;
      if (marker.type != 'anchor' ||
          referenceId == null ||
          referenceId.isEmpty ||
          referenceId == startAnchor.id) {
        continue;
      }

      final anchor = _findAnchor(venue, referenceId);
      if (anchor == null || anchor.floor != session.floor) continue;

      final node = _findNode(venue, anchor.nodeId);
      if (node == null) continue;

      final localDx = marker.xMeters - localStartX;
      final localDy = marker.yMeters - localStartY;
      final localDistance = math.sqrt(localDx * localDx + localDy * localDy);

      final venueDx = node.x - originNode.x;
      final venueDy = node.y - originNode.y;
      final venueDistance = math.sqrt(venueDx * venueDx + venueDy * venueDy);

      final baseline = math.min(localDistance, venueDistance);
      if (baseline > bestBaseline) {
        bestBaseline = baseline;
        bestMarker = marker;
        bestAnchor = anchor;
        bestNode = node;
      }
    }

    if (bestMarker == null || bestAnchor == null || bestNode == null) {
      throw StateError(
        'Spatial merge needs a second known anchor on Floor '
        '${session.floor}. During mapping, stand at another existing anchor '
        'and mark it as "Reference existing".',
      );
    }

    const minimumBaselineMeters = 0.75;
    if (bestBaseline < minimumBaselineMeters) {
      throw StateError(
        'The two known anchors are too close together for reliable spatial '
        'alignment. Use anchors at least '
        '${minimumBaselineMeters.toStringAsFixed(2)} m apart.',
      );
    }

    final localDx = bestMarker.xMeters - localStartX;
    final localDy = bestMarker.yMeters - localStartY;
    final localDistance = math.sqrt(localDx * localDx + localDy * localDy);
    final venueDx = bestNode.x - originNode.x;
    final venueDy = bestNode.y - originNode.y;
    final venueDistance = math.sqrt(venueDx * venueDx + venueDy * venueDy);

    final spacingError = (localDistance - venueDistance).abs();
    final allowedSpacingError = math.max(0.75, venueDistance * 0.20);
    if (spacingError > allowedSpacingError) {
      throw StateError(
        'Known-anchor spacing does not match the active venue closely enough '
        '(${localDistance.toStringAsFixed(1)} m recorded vs '
        '${venueDistance.toStringAsFixed(1)} m expected). Recheck the '
        'selected anchor or remap this section.',
      );
    }

    return VenueTransform2D.fromPointPairs(
      localAX: localStartX,
      localAY: localStartY,
      localBX: bestMarker.xMeters,
      localBY: bestMarker.yMeters,
      venueAX: originNode.x,
      venueAY: originNode.y,
      venueBX: bestNode.x,
      venueBY: bestNode.y,
      minimumBaselineMeters: minimumBaselineMeters,
    );
  }

  NavNode? _findNode(Venue venue, String id) {
    for (final node in venue.nodes) {
      if (node.id == id) return node;
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
