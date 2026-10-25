import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/anchor_point.dart';
import '../models/destination.dart';
import '../models/nav_edge.dart';
import '../models/nav_node.dart';
import '../models/venue.dart';
import 'venue_override_storage.dart';

class VenueLoader {
  const VenueLoader();

  Future<Venue> load(String packagePath) async {
    final bundled = await loadBundled(packagePath);
    final override = await const VenueOverrideStorage().load(bundled.id);
    return override?.venue ?? bundled;
  }

  Future<Venue> loadBundled(String packagePath) async {
    final manifest = await _loadMap('$packagePath/venue.json');
    final nodesJson = await _loadList('$packagePath/nodes.json');
    final edgesJson = await _loadList('$packagePath/edges.json');
    final destinationsJson = await _loadList(
      '$packagePath/destinations.json',
    );
    final anchorsJson = await _loadList('$packagePath/anchors.json');

    return Venue(
      id: manifest['id'] as String,
      name: manifest['name'] as String,
      description: manifest['description'] as String? ?? '',
      defaultStartNodeId: manifest['default_start_node_id'] as String,
      floors: (manifest['floors'] as List<dynamic>)
          .map((value) => (value as num).toInt())
          .toList(growable: false),
      nodes: nodesJson.map(NavNode.fromJson).toList(growable: false),
      edges: edgesJson.map(NavEdge.fromJson).toList(growable: false),
      destinations: destinationsJson
          .map(Destination.fromJson)
          .toList(growable: false),
      anchors: anchorsJson.map(AnchorPoint.fromJson).toList(growable: false),
    );
  }

  Future<Map<String, dynamic>> _loadMap(String path) async {
    final raw = await rootBundle.loadString(path);
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> _loadList(String path) async {
    final raw = await rootBundle.loadString(path);
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((item) => item as Map<String, dynamic>)
        .toList(growable: false);
  }
}
