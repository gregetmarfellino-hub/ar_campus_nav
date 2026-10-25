import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/mapping_session.dart';

class MappingStorage {
  const MappingStorage();

  static const MethodChannel _native = MethodChannel('ar_campus_nav/native');
  static const String reservedVenuePrefix = 'venue_override__';

  Future<String> save(MappingSession session) async {
    final json = const JsonEncoder.withIndent('  ').convert(session.toJson());
    final path = await _native.invokeMethod<String>(
      'saveMapping',
      <String, dynamic>{
        'id': session.id,
        'json': json,
      },
    );
    if (path == null || path.isEmpty) {
      throw StateError('Android did not return a mapping file path.');
    }
    return path;
  }

  Future<List<String>> listIds() async {
    final raw = await _native.invokeMethod<List<dynamic>>('listMappings');
    if (raw == null) return const [];

    return raw
        .cast<String>()
        .where((id) => !id.startsWith(reservedVenuePrefix))
        .toList(growable: false);
  }

  Future<List<MappingSession>> listSessions() async {
    final sessions = <MappingSession>[];

    for (final id in await listIds()) {
      try {
        final session = await load(id);
        if (session != null) sessions.add(session);
      } catch (_) {
        // Ignore malformed/legacy files instead of breaking the whole review list.
      }
    }

    sessions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return sessions;
  }

  Future<MappingSession?> load(String id) async {
    final raw = await _native.invokeMethod<String>(
      'loadMapping',
      <String, dynamic>{'id': id},
    );
    if (raw == null || raw.isEmpty) return null;
    return MappingSession.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
  }

  Future<void> delete(String id) async {
    final deleted = await _native.invokeMethod<bool>(
      'deleteMapping',
      <String, dynamic>{'id': id},
    );
    if (deleted != true) {
      throw StateError('Android could not delete the mapping file.');
    }
  }
}
