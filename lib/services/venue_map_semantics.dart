import '../models/destination.dart';
import '../models/nav_node.dart';
import '../models/venue.dart';

/// Presentation rules only. Never change the published 3D coordinates or
/// invent extra graph edges just to make a route target easier to select.
class VenueMapSemantics {
  const VenueMapSemantics();

  /// Continuous 3D publishes one named internal node per retained XYZ sample.
  /// Those samples belong to the line, not the list of named physical places.
  static bool isNamedWaypoint(NavNode node) {
    return node.type == 'waypoint' &&
        node.label != 'Recorded path' &&
        node.label != 'Recorded start' &&
        !node.label.startsWith('3D waypoint ');
  }

  /// A floor change is a measured graph transition, but it isn't a named
  /// destination unless the mapper explicitly tagged one. Expose a temporary
  /// "first mapped point" target on each other floor so the recorded upstairs
  /// area can be reached without remapping or falsely naming a room.
  ///
  /// These targets are UI-only and are never written into the venue or export.
  static List<Destination> floorEntryTargets(Venue venue) {
    final defaultFloor = venue.nodeById(venue.defaultStartNodeId).floor;
    final firstOnFloor = <int, NavNode>{};
    for (final node in venue.nodes) {
      firstOnFloor.putIfAbsent(node.floor, () => node);
    }

    return [
      for (final entry in firstOnFloor.entries)
        if (entry.key != defaultFloor &&
            !venue.destinations.any((item) => item.nodeId == entry.value.id))
          Destination(
            id: 'ui_floor_entry_${entry.value.id}',
            name: entry.key < 0
                ? 'Basement ${entry.key.abs()} - first mapped point'
                : 'Floor ${entry.key} - first mapped point',
            nodeId: entry.value.id,
            category: 'floor-entry',
            description: 'First recorded node on this floor, where the mapper '
                'changed its floor label; this is not a tagged room.',
          ),
    ];
  }
}
