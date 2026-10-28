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
