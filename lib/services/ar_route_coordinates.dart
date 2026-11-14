import 'dart:math' as math;

import '../models/nav_node.dart';

/// Converts persisted venue coordinates back into the QR-locked mapping frame.
///
/// VenueTransform2D saves local (+right, +forward) meters into venue
/// (+east/right, +south/down) coordinates using:
///   venueX =  cos(h) * right + sin(h) * forward
///   venueY =  sin(h) * right - cos(h) * forward
/// The matrix is its own inverse; critically, heading=0 negates Y.
/// Do not fit a new heading to the first route segment: the user may turn.
class ArRouteCoordinates {
  const ArRouteCoordinates._();

  /// V13 map coordinates come straight from the uninterrupted 3D mapping
  /// frame: X=right, Y=forward. A checkpoint QR can sit on a wall a metre
  /// away from the nearest walkable node. Its REAL pose (not the graph node)
  /// is the origin after offline visual relocalization on another phone.
  ///
  /// facingDegrees is atan2(markerFacingRight, markerFacingForward) in the
  /// original map frame, NOT a compass heading.
  static List<Map<String, dynamic>> from3DCheckpointNodes(
    List<NavNode> nodes, {
    required double checkpointRightMeters,
    required double checkpointForwardMeters,
    required double checkpointFacingDegrees,
  }) {
    if (nodes.length < 2) return const [];
    for (final value in <double>[
      checkpointRightMeters, checkpointForwardMeters, checkpointFacingDegrees,
    ]) {
      if (!value.isFinite) {
        throw const FormatException('Offline checkpoint has invalid metric pose.');
      }
    }
    final rad = checkpointFacingDegrees * math.pi / 180.0;
    final sine = math.sin(rad);
    final cosine = math.cos(rad);
    return [
      for (final node in nodes)
        {
          'right': (node.x - checkpointRightMeters) * cosine -
              (node.y - checkpointForwardMeters) * sine,
          'forward': (node.x - checkpointRightMeters) * sine +
              (node.y - checkpointForwardMeters) * cosine,
          'label': node.label,
          'semantic': node.type != 'path',
        },
    ];
  }

  static List<Map<String, dynamic>> fromMappedVenueNodes(
    List<NavNode> nodes, {
    double mapHeadingDegrees = 0,
  }) {
    if (nodes.length < 2) return const [];
    final start = nodes.first;
    final heading = mapHeadingDegrees * math.pi / 180.0;
    final cosHeading = math.cos(heading);
    final sinHeading = math.sin(heading);

    return [
      for (final node in nodes)
        {
          'right': (node.x - start.x) * cosHeading +
              (node.y - start.y) * sinHeading,
          'forward': (node.x - start.x) * sinHeading -
              (node.y - start.y) * cosHeading,
          'label': node.label,
          'semantic': node.type != 'path',
        },
    ];
  }
}
