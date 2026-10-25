import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/venue.dart';
import 'mapping_storage.dart';
import 'venue_codec.dart';

class VenueOverrideDocument {
  const VenueOverrideDocument({
    required this.venue,
    required this.coordinateSpace,
    required this.appliedSessionIds,
    required this.updatedAt,
  });

  final Venue venue;
  final String coordinateSpace;
  final List<String> appliedSessionIds;
  final DateTime updatedAt;

  bool get usesRecordedMeters => coordinateSpace == 'world_meters';

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'schema': 'ar_campus_nav.venue_override.v1',
      'coordinate_space': coordinateSpace,
      'updated_at': updatedAt.toIso8601String(),
      'applied_session_ids': appliedSessionIds,
      'venue': const VenueCodec().toJson(venue),
    };
  }

  factory VenueOverrideDocument.fromJson(Map<String, dynamic> json) {
    return VenueOverrideDocument(
      venue: const VenueCodec().fromJson(
        json['venue'] as Map<String, dynamic>,
      ),
      coordinateSpace: json['coordinate_space'] as String? ?? 'sample',
      appliedSessionIds:
          (json['applied_session_ids'] as List<dynamic>? ?? const [])
              .cast<String>(),
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class VenueOverrideStorage {
  const VenueOverrideStorage();

  static const MethodChannel _native = MethodChannel('ar_campus_nav/native');

  String _storageId(String venueId) {
    return '${MappingStorage.reservedVenuePrefix}$venueId';
  }

  Future<VenueOverrideDocument?> load(String venueId) async {
    try {
      final raw = await _native.invokeMethod<String>(
        'loadMapping',
        <String, dynamic>{'id': _storageId(venueId)},
      );
      if (raw == null || raw.isEmpty) return null;

      return VenueOverrideDocument.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      // Reading an override is optional. Asset loading must keep working in
      // tests, unsupported platforms, or before the native channel is ready.
      return null;
    }
  }

  Future<String> save(VenueOverrideDocument document) async {
    final raw = const JsonEncoder.withIndent('  ').convert(document.toJson());
    final path = await _native.invokeMethod<String>(
      'saveMapping',
      <String, dynamic>{
        'id': _storageId(document.venue.id),
        'json': raw,
      },
    );

    if (path == null || path.isEmpty) {
      throw StateError('Android did not return a venue override path.');
    }

    return path;
  }
}
