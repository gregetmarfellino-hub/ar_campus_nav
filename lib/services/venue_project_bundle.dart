import 'dart:convert';

import '../models/mapping_session.dart';
import '../services/venue_override_storage.dart';

/// A self-contained, versioned file that a second phone can open offline.
///
/// It contains the published graph (XYZ, floors, edges, destinations, QR
/// checkpoints and any visual reference bytes), plus original walk recordings.
/// Neither Android file paths nor ARCore session identifiers are necessary.
class VenueProjectBundle {
  const VenueProjectBundle({
    required this.document,
    this.recordings = const <MappingSession>[],
  });

  static const schema = 'ar_campus_nav.project.v1';

  final VenueOverrideDocument document;
  final List<MappingSession> recordings;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schema': schema,
        'document': document.toJson(),
        'recordings': [
          for (final session in recordings) session.toJson(),
        ],
      };

  String encode() {
    validate();
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }

  factory VenueProjectBundle.decode(String raw) {
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> || value['schema'] != schema) {
      throw const FormatException(
        'Unsupported mapping project format. Expected ar_campus_nav.project.v1.',
      );
    }
    final documentJson = value['document'];
    final recordingsJson = value['recordings'];
    if (documentJson is! Map<String, dynamic> ||
        recordingsJson is! List<dynamic>) {
      throw const FormatException('Project is missing its graph or recordings.');
    }
    final bundle = VenueProjectBundle(
      document: VenueOverrideDocument.fromJson(documentJson),
      recordings: [
        for (final item in recordingsJson)
          MappingSession.fromJson(item as Map<String, dynamic>),
      ],
    );
    bundle.validate();
    return bundle;
  }

  /// Reject broken references before replacing the active offline map.
  void validate() {
    final venue = document.venue;
    final validId = RegExp(r'^[A-Za-z0-9_.-]{1,100}$');
    if (!validId.hasMatch(venue.id) || venue.name.trim().isEmpty) {
      throw const FormatException('Project has an invalid venue ID or name.');
    }
    if (!const {'sample', 'world_meters', 'world_xyz_3d'}
        .contains(document.coordinateSpace)) {
      throw const FormatException('Unsupported map coordinate system.');
    }
    if (venue.nodes.isEmpty || venue.floors.isEmpty) {
      throw const FormatException('Project has no usable route nodes or floors.');
    }
    final nodeIds = <String>{};
    for (final node in venue.nodes) {
      if (!validId.hasMatch(node.id) ||
          !nodeIds.add(node.id) ||
          !node.x.isFinite ||
          !node.y.isFinite ||
          !node.upMeters.isFinite ||
          !venue.floors.contains(node.floor)) {
        throw const FormatException('Invalid or duplicate route node.');
      }
    }
    if (!nodeIds.contains(venue.defaultStartNodeId)) {
      throw const FormatException('Default start does not exist in the graph.');
    }
    for (final edge in venue.edges) {
      if (!nodeIds.contains(edge.from) ||
          !nodeIds.contains(edge.to) ||
          !edge.distanceMeters.isFinite ||
          edge.distanceMeters < 0) {
        throw const FormatException('Route edge has invalid geometry/references.');
      }
    }
    final destinationIds = <String>{};
    for (final destination in venue.destinations) {
      if (!validId.hasMatch(destination.id) ||
          !destinationIds.add(destination.id) ||
          !nodeIds.contains(destination.nodeId)) {
        throw const FormatException('Invalid destination or missing node.');
      }
    }
    final anchorIds = <String>{};
    for (final anchor in venue.anchors) {
      if (!nodeIds.contains(anchor.nodeId)) {
        throw const FormatException('QR checkpoint points to a missing node.');
      }
      final node = venue.nodeById(anchor.nodeId);
      if (!validId.hasMatch(anchor.id) ||
          !anchorIds.add(anchor.id) ||
          node.floor != anchor.floor ||
          (anchor.headingDegrees != null && !anchor.headingDegrees!.isFinite)) {
        throw const FormatException('Invalid QR checkpoint or floor reference.');
      }
    }
    final sessionIds = <String>{};
    for (final session in recordings) {
      if (!validId.hasMatch(session.id) ||
          !sessionIds.add(session.id) ||
          session.venueId != venue.id) {
        throw const FormatException('Invalid or unrelated mapping recording.');
      }
    }
  }

  String get suggestedFileName {
    final safeName = document.venue.name
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final prefix = safeName.isEmpty ? 'campus' : safeName;
    return '${prefix.length > 48 ? prefix.substring(0, 48) : prefix}.arnav.json';
  }
}
