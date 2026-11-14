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

  bool get isContinuous3D => coordinateSpace == 'world_xyz_3d';

  bool get usesRecordedMeters =>
      coordinateSpace == 'world_meters' || isContinuous3D;

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

  // The selected project is a tiny pointer stored separately from its graph.
  // This lets imported venues have their own IDs instead of masquerading as
  // the built-in demo campus.
  static const _selectionId = 'venue_override__active_project_selection';

  Future<String?> loadSelectedProjectId() async {
    try {
      final raw = await _native.invokeMethod<String>(
        'loadMapping', <String, dynamic>{'id': _selectionId},
      );
      if (raw == null || raw.isEmpty) return null;
      return (jsonDecode(raw) as Map<String, dynamic>)['venue_id'] as String?;
    } catch (_) {
      return null; // Older installs / unsupported platform use bundled demo.
    }
  }

  Future<void> selectProject(String? venueId) async {
    final path = await _native.invokeMethod<String>(
      'saveMapping',
      <String, dynamic>{
        'id': _selectionId,
        'json': jsonEncode(<String, dynamic>{'venue_id': venueId}),
      },
    );
    if (path == null || path.isEmpty) {
      throw StateError('Could not select this offline venue.');
    }
  }

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

  // The newest graph edit is reversible without touching the original
  // walk recording JSONs. Reserved IDs keep backups off the recordings list.
  String _graphBackupId(String venueId) =>
      '${MappingStorage.reservedVenuePrefix}graph_backup__$venueId';

  Future<VenueOverrideDocument?> loadGraphBackup(String venueId) async {
    try {
      final raw = await _native.invokeMethod<String>(
        'loadMapping',
        <String, dynamic>{'id': _graphBackupId(venueId)},
      );
      if (raw == null || raw.isEmpty) return null;
      return VenueOverrideDocument.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  Future<String> saveGraphBackup(VenueOverrideDocument document) async {
    final raw = const JsonEncoder.withIndent('  ').convert(document.toJson());
    final path = await _native.invokeMethod<String>(
      'saveMapping',
      <String, dynamic>{
        'id': _graphBackupId(document.venue.id),
        'json': raw,
      },
    );
    if (path == null || path.isEmpty) {
      throw StateError('Android did not save the previous venue graph.');
    }
    return path;
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
