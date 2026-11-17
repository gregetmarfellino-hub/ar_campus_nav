import '../models/mapping_session.dart';

/// Adds a *semantic* finish to an already measured 3D path.
///
/// The endpoint is a destination at the final trusted XYZ sample. All other
/// measured vertices and checkpoint references stay intact for future graph
/// joining; deleting untagged corridor geometry would be destructive.
class RouteEndpointPolicy {
  const RouteEndpointPolicy();

  List<MappingMarker> withFinishDestination({
    required List<MappingPoint> points,
    required List<MappingMarker> markers,
    required int floor,
    required String label,
    required String id,
  }) {
    if (points.isEmpty) {
      throw StateError('Cannot mark a finish on an empty recording.');
    }
    final name = label.trim();
    if (name.length < 2 || name.length > 80) {
      throw const FormatException('End location name must be 2–80 characters.');
    }

    // A destination already tagged at the actual final measured sample is a
    // valid finish. Never create two duplicate selection targets.
    final lastIndex = points.length - 1;
    if (markers.any((marker) =>
        marker.pointIndex == lastIndex &&
        marker.type == 'destination')) {
      return List<MappingMarker>.unmodifiable(markers);
    }

    if (markers.any((marker) => marker.id == id)) {
      throw StateError('A mapping marker already uses the finish ID.');
    }

    final p = points.last;
    return List<MappingMarker>.unmodifiable([
      ...markers,
      MappingMarker(
        id: id,
        label: name,
        type: 'destination',
        floor: floor,
        xMeters: p.xMeters,
        yMeters: p.yMeters,
        upMeters: p.upMeters,
        pointIndex: lastIndex,
      ),
    ]);
  }
}
