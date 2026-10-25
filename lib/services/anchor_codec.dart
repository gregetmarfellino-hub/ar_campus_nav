import 'dart:convert';

import '../models/anchor_point.dart';
import '../models/venue.dart';

class AnchorCodec {
  const AnchorCodec();

  String encode({
    required Venue venue,
    required AnchorPoint anchor,
  }) {
    return Uri(
      scheme: 'arnav',
      host: 'anchor',
      queryParameters: <String, String>{
        'venue': venue.id,
        'id': anchor.id,
      },
    ).toString();
  }

  AnchorPoint resolve({
    required Venue venue,
    required String rawValue,
  }) {
    final payload = rawValue.trim();
    if (payload.isEmpty) {
      throw const FormatException('The QR code is empty.');
    }

    final parsed = _parsePayload(payload);
    final venueId = parsed.venueId.trim();
    final anchorId = parsed.anchorId.trim();

    if (venueId != venue.id) {
      throw FormatException(
        'This QR belongs to "$venueId", not the loaded venue "${venue.id}".',
      );
    }

    if (anchorId.isEmpty) {
      throw const FormatException('The QR code does not contain an anchor ID.');
    }

    AnchorPoint anchor;
    try {
      anchor = venue.anchorById(anchorId);
    } on StateError {
      throw FormatException(
        'Anchor "$anchorId" is not present in this venue package.',
      );
    }

    final node = venue.nodeById(anchor.nodeId);
    if (node.floor != anchor.floor) {
      throw FormatException(
        'Anchor "$anchorId" has inconsistent floor metadata.',
      );
    }

    return anchor;
  }

  _AnchorPayload _parsePayload(String payload) {
    final uri = Uri.tryParse(payload);
    if (uri != null && uri.scheme.toLowerCase() == 'arnav') {
      if (uri.host.toLowerCase() != 'anchor') {
        throw const FormatException('Unsupported AR Nav QR type.');
      }

      return _AnchorPayload(
        venueId: uri.queryParameters['venue'] ?? '',
        anchorId: uri.queryParameters['id'] ??
            uri.queryParameters['anchor'] ??
            '',
      );
    }

    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Unsupported QR payload.');
      }

      final type = decoded['type'] as String? ?? 'anchor';
      if (type != 'anchor' && type != 'ar_nav_anchor') {
        throw const FormatException('Unsupported AR Nav QR type.');
      }

      return _AnchorPayload(
        venueId: decoded['venue'] as String? ?? '',
        anchorId: decoded['anchor'] as String? ?? decoded['id'] as String? ?? '',
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException(
        'This QR code is not a valid AR Campus Nav anchor.',
      );
    }
  }
}

class _AnchorPayload {
  const _AnchorPayload({
    required this.venueId,
    required this.anchorId,
  });

  final String venueId;
  final String anchorId;
}
