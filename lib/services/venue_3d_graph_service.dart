import 'dart:math' as math;

import '../models/anchor_point.dart';
import '../models/destination.dart';
import '../models/mapping_session.dart';
import '../models/nav_edge.dart';
import '../models/nav_node.dart';
import '../models/venue.dart';
import 'continuous_3d_trace.dart';
import 'loop_closure_diagnostics.dart';
import 'mapping_path_simplifier.dart';

/// Builds the ACTIVE campus venue from a single uninterrupted ARCore world.
///
/// One physical XYZ recording becomes a connected graph with full height,
/// floor labels, destinations and printed-QR location IDs. It deliberately
/// refuses to merge unrelated ARCore sessions into an invented shared frame.
/// Geometric (x/y/up) coordinates stay in metres in the recorded local frame.
class Venue3DGraphService {
  const Venue3DGraphService();

  Venue build({
    required Venue template,
    required MappingSession session,
  }) {
    if (!session.isContinuous3D || session.isDraft3D) {
      throw StateError('Finish a continuous 3D recording before publishing.');
    }
    if (session.venueId != template.id) {
      throw StateError('This 3D route belongs to a different campus venue.');
    }
    if (session.effectiveSegmentStarts.length != 1 ||
        session.effectiveSegmentStarts.single != 0) {
      throw StateError('Cannot connect disconnected ARCore trajectories.');
    }
    // Reduce excessive sample density while explicitly retaining each
    // semantic marker and any actual change of direction or height.
    final simplified = const MappingPathSimplifier().simplify(
      points: session.points,
      markers: session.markers,
      toleranceMeters: 0.12,
    );
    final points = simplified.points;
    final markers = simplified.markers;
    Continuous3DTrace.analyze(
      points: points,
      markers: markers,
      segmentStarts: simplified.segmentStarts,
      startFloor: session.floor,
    );
    if (points.length < 2 || session.totalDistanceMeters < 2.0) {
      throw StateError('3D route needs at least two metres of geometry.');
    }
    if (simplified.segmentStarts.length != 1) {
      throw StateError('Simplification introduced a disconnected path.');
    }

    final grouped = <int, List<MappingMarker>>{};
    for (final marker in markers) {
      if (marker.pointIndex < 0 || marker.pointIndex >= points.length) {
        throw StateError('Location marker points outside the 3D route.');
      }
      grouped.putIfAbsent(marker.pointIndex, () => []).add(marker);
    }

    final nodes = <NavNode>[];
    final edges = <NavEdge>[];
    final destinations = <Destination>[];
    final anchors = <AnchorPoint>[];
    final floors = <int>{session.floor};
    final nodeIds = <String>[];
    var currentFloor = session.floor;
    var transitionKind = 'stairs';

    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final group = grouped[i] ?? const <MappingMarker>[];
      for (final marker in group) {
        if (marker.type == 'floor_level') {
          currentFloor = marker.floor;
          floors.add(currentFloor);
        }
      }
      // QA-only return-to-start checks must remain in the saved recording,
      // but must not be presented as rooms, landmarks or route instructions.
      final semantic = group.where((m) =>
          m.type != 'floor_level' &&
          m.type != LoopClosureDiagnostics.markerType).toList();
      for (final marker in semantic) {
        if (marker.type == 'stairs' || marker.type == 'elevator') {
          transitionKind = marker.type;
        }
      }
      final primary = semantic.isEmpty ? null : semantic.first;
      final id = 'v11_${session.id}_pt_$i';
      nodeIds.add(id);
      nodes.add(NavNode(
        id: id,
        label: primary?.label ??
            (i == 0 ? 'Recorded start' : '3D waypoint ${i + 1}'),
        floor: currentFloor,
        x: p.xMeters,
        y: p.yMeters,
        upMeters: p.upMeters,
        type: primary?.type == 'anchor'
            ? 'anchor'
            : primary?.type == 'destination'
                ? 'destination'
                : primary?.type == 'stairs' || primary?.type == 'elevator'
                    ? primary!.type
                    : 'waypoint',
      ));

      for (final marker in semantic) {
        if (marker.floor != currentFloor) {
          throw StateError(
            'Marker "${marker.label}" is on Floor ${marker.floor}, '
            'but the recorded route is on Floor $currentFloor at that sample.',
          );
        }
        if (marker.type == 'anchor') {
          anchors.add(AnchorPoint(
            id: marker.id,
            label: marker.label,
            nodeId: id,
            floor: currentFloor,
            // V13 visual checkpoint is linked to THIS measured path node,
            // but the visual QR itself can be placed on an adjacent surface.
            // Independent offline localization still must verify the scene.
            visualHeadingVerified: false,
            checkpointRightMeters: marker.checkpointRightMeters,
            checkpointForwardMeters: marker.checkpointForwardMeters,
            checkpointUpMeters: marker.checkpointUpMeters,
            checkpointFacingDegrees: marker.anchorFacingDegrees,
            offlineVisualReferencePngBase64:
                marker.offlineVisualReferencePngBase64,
            offlineVisualReferenceWidthMeters:
                marker.offlineVisualReferenceWidthMeters,
            offlineVisualStartOffsetX: marker.offlineVisualStartOffsetX,
            offlineVisualStartOffsetY: marker.offlineVisualStartOffsetY,
            offlineVisualStartOffsetZ: marker.offlineVisualStartOffsetZ,
            offlineVisualStartForwardX: marker.offlineVisualStartForwardX,
            offlineVisualStartForwardY: marker.offlineVisualStartForwardY,
            offlineVisualStartForwardZ: marker.offlineVisualStartForwardZ,
            offlineExtraReferenceJson: marker.offlineExtraReferenceJson,
          ));
        } else if (marker.type == 'destination' ||
                   marker.type == 'stairs' ||
                   marker.type == 'elevator') {
          destinations.add(Destination(
            id: marker.id,
            name: marker.label,
            nodeId: id,
            category: marker.type == 'destination' ? 'place' : marker.type,
            description: 'Measured 3D location on floor $currentFloor',
          ));
        }
      }
      if (i == 0) continue;
      final a = points[i - 1];
      final dx = p.xMeters - a.xMeters;
      final dy = p.yMeters - a.yMeters;
      final dz = p.upMeters - a.upMeters;
      final distance = math.sqrt(dx * dx + dy * dy + dz * dz);
      if (!distance.isFinite || distance <= 0) {
        throw StateError('Measured 3D route contains a zero/invalid link.');
      }
      final previousFloor = nodes[i - 1].floor;
      edges.add(NavEdge(
        from: nodeIds[i - 1],
        to: id,
        distanceMeters: distance,
        transitionType:
            previousFloor == currentFloor ? null : transitionKind,
        measured3D: true,
      ));
    }

    // QR identifiers must be unique within the published venue. If IDs were
    // duplicated the scanner could resolve to the wrong physical location.
    final anchorIds = anchors.map((a) => a.id).toSet();
    final destinationIds = destinations.map((d) => d.id).toSet();
    if (anchorIds.length != anchors.length ||
        destinationIds.length != destinations.length) {
      throw StateError('Duplicate room or QR anchor IDs in the recording.');
    }

    return Venue(
      id: template.id,
      name: template.name,
      description:
          'Measured XYZ campus graph from one ARCore recording. '
          'Offline; physical QR relocalization not yet verified.',
      defaultStartNodeId: nodes.first.id,
      floors: floors.toList()..sort(),
      nodes: List.unmodifiable(nodes),
      edges: List.unmodifiable(edges),
      destinations: List.unmodifiable(destinations),
      anchors: List.unmodifiable(anchors),
    );
  }

  /// Records are safe to combine only when a verified rigid transform aligns
  /// their independently generated ARCore coordinate systems. V11 intentionally
  /// has no automatic transform solver, so this action is blocked.
  Venue mergeUnaligned({
    required Venue current,
    required MappingSession newRecording,
  }) {
    throw StateError(
      'Independent ARCore recordings do not share an origin. '
      'Start a continuous 3D recording from an existing verified physical '
      'landmark and solve its transform before joining venue graphs.',
    );
  }
}
