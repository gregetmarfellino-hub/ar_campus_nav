import 'dart:math' as math;

class MappingPoint {
  const MappingPoint({
    required this.xMeters,
    required this.yMeters,
    required this.headingDegrees,
    required this.stepIndex,
    required this.timestampMs,
    this.upMeters = 0,
    this.qx = 0,
    this.qy = 0,
    this.qz = 0,
    this.qw = 1,
  });

  /// Local right/left axis in meters.
  final double xMeters;

  /// Local forward/back axis in meters.
  final double yMeters;

  /// Vertical offset from the mapping origin in meters.
  final double upMeters;

  /// Compass heading snapshot. For ARCore sessions this is metadata only;
  /// geometry comes from ARCore, not from compass integration.
  final double headingDegrees;

  /// Legacy name retained for JSON/backward compatibility.
  /// For spatial sessions this is simply the sample index.
  final int stepIndex;

  final int timestampMs;

  /// ARCore relative orientation quaternion.
  final double qx;
  final double qy;
  final double qz;
  final double qw;

  Map<String, dynamic> toJson() => {
        'x_m': xMeters,
        'y_m': yMeters,
        'up_m': upMeters,
        'heading_deg': headingDegrees,
        'step_index': stepIndex,
        'timestamp_ms': timestampMs,
        'qx': qx,
        'qy': qy,
        'qz': qz,
        'qw': qw,
      };

  factory MappingPoint.fromJson(Map<String, dynamic> json) {
    double number(String key, [double fallback = 0]) {
      final value = json[key];
      return value is num ? value.toDouble() : fallback;
    }

    return MappingPoint(
      xMeters: number('x_m'),
      yMeters: number('y_m'),
      upMeters: number('up_m'),
      headingDegrees: number('heading_deg'),
      stepIndex: (json['step_index'] as num?)?.toInt() ?? 0,
      timestampMs: (json['timestamp_ms'] as num?)?.toInt() ?? 0,
      qx: number('qx'),
      qy: number('qy'),
      qz: number('qz'),
      qw: number('qw', 1),
    );
  }
}

class MappingMarker {
  const MappingMarker({
    required this.id,
    required this.label,
    required this.type,
    required this.floor,
    required this.xMeters,
    required this.yMeters,
    required this.pointIndex,
    this.upMeters = 0,
    this.referenceAnchorId,
  });

  final String id;
  final String label;
  final String type;
  final int floor;
  final double xMeters;
  final double yMeters;
  final double upMeters;
  final int pointIndex;

  /// Existing venue anchor represented by this marker, when the mapper
  /// scanned a known location QR instead of creating a new anchor.
  final String? referenceAnchorId;

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'type': type,
        'floor': floor,
        'x_m': xMeters,
        'y_m': yMeters,
        'up_m': upMeters,
        'point_index': pointIndex,
        if (referenceAnchorId != null)
          'reference_anchor_id': referenceAnchorId,
      };

  factory MappingMarker.fromJson(Map<String, dynamic> json) {
    return MappingMarker(
      id: json['id'] as String,
      label: json['label'] as String,
      type: json['type'] as String,
      floor: (json['floor'] as num).toInt(),
      xMeters: (json['x_m'] as num).toDouble(),
      yMeters: (json['y_m'] as num).toDouble(),
      upMeters: (json['up_m'] as num?)?.toDouble() ?? 0,
      pointIndex: (json['point_index'] as num).toInt(),
      referenceAnchorId: json['reference_anchor_id'] as String?,
    );
  }
}

class MappingSession {
  const MappingSession({
    required this.id,
    required this.venueId,
    required this.venueName,
    required this.floor,
    required this.createdAt,
    required this.startAnchorId,
    required this.startAnchorLabel,
    required this.originHeadingDegrees,
    required this.stepLengthMeters,
    required this.points,
    required this.markers,
    this.source = 'step_compass',
    this.rawPointCount = 0,
    this.trackingInterruptions = 0,
    this.rejectedPoseJumps = 0,
  });

  final String id;
  final String venueId;
  final String venueName;
  final int floor;
  final DateTime createdAt;
  final String? startAnchorId;
  final String? startAnchorLabel;

  /// One rotation metadata value for placing separate sessions into a shared
  /// 2D venue frame. ARCore still owns the actual path geometry.
  final double originHeadingDegrees;

  /// Retained for legacy step recordings. Spatial sessions store 0.
  final double stepLengthMeters;

  /// step_compass | arcore_spatial
  final String source;

  final List<MappingPoint> points;
  final List<MappingMarker> markers;

  /// Number of raw accepted ARCore geometry samples before save-time
  /// simplification. Legacy sessions and old JSON default to points.length.
  final int rawPointCount;

  /// Number of times ARCore tracking paused while a recording was live.
  final int trackingInterruptions;

  /// Impossible pose jumps rejected by the mapper before they could corrupt
  /// route geometry.
  final int rejectedPoseJumps;

  bool get isSpatial => source == 'arcore_spatial';

  int get effectiveRawPointCount =>
      rawPointCount > 0 ? rawPointCount : points.length;

  String get qualityLabel {
    if (!isSpatial) return 'LEGACY';
    if (trackingInterruptions >= 3 || rejectedPoseJumps >= 5) return 'REVIEW';
    if (trackingInterruptions > 0 || rejectedPoseJumps > 0) return 'CAUTION';
    return 'GOOD';
  }

  double get totalDistanceMeters {
    if (points.length < 2) return 0;

    var total = 0.0;
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1];
      final b = points[i];
      final dx = b.xMeters - a.xMeters;
      final dy = b.yMeters - a.yMeters;
      final dz = b.upMeters - a.upMeters;
      total += math.sqrt(dx * dx + dy * dy + dz * dz);
    }
    return total;
  }

  double get horizontalExtentMeters {
    if (points.isEmpty) return 0;
    var minX = points.first.xMeters;
    var maxX = points.first.xMeters;
    var minY = points.first.yMeters;
    var maxY = points.first.yMeters;

    for (final point in points.skip(1)) {
      minX = math.min(minX, point.xMeters);
      maxX = math.max(maxX, point.xMeters);
      minY = math.min(minY, point.yMeters);
      maxY = math.max(maxY, point.yMeters);
    }

    final dx = maxX - minX;
    final dy = maxY - minY;
    return math.sqrt(dx * dx + dy * dy);
  }

  Map<String, dynamic> toJson() => {
        'schema': 'ar_campus_nav.mapping.v2',
        'id': id,
        'venue_id': venueId,
        'venue_name': venueName,
        'floor': floor,
        'created_at': createdAt.toIso8601String(),
        'start_anchor_id': startAnchorId,
        'start_anchor_label': startAnchorLabel,
        'origin_heading_deg': originHeadingDegrees,
        'step_length_m': stepLengthMeters,
        'source': source,
        'raw_point_count': effectiveRawPointCount,
        'tracking_interruptions': trackingInterruptions,
        'rejected_pose_jumps': rejectedPoseJumps,
        'points': points.map((point) => point.toJson()).toList(growable: false),
        'markers': markers.map((marker) => marker.toJson()).toList(growable: false),
      };

  factory MappingSession.fromJson(Map<String, dynamic> json) {
    return MappingSession(
      id: json['id'] as String,
      venueId: json['venue_id'] as String,
      venueName: json['venue_name'] as String,
      floor: (json['floor'] as num).toInt(),
      createdAt: DateTime.parse(json['created_at'] as String),
      startAnchorId: json['start_anchor_id'] as String?,
      startAnchorLabel: json['start_anchor_label'] as String?,
      originHeadingDegrees:
          (json['origin_heading_deg'] as num?)?.toDouble() ?? 0,
      stepLengthMeters: (json['step_length_m'] as num?)?.toDouble() ?? 0,
      source: json['source'] as String? ?? 'step_compass',
      rawPointCount: (json['raw_point_count'] as num?)?.toInt() ?? 0,
      trackingInterruptions:
          (json['tracking_interruptions'] as num?)?.toInt() ?? 0,
      rejectedPoseJumps:
          (json['rejected_pose_jumps'] as num?)?.toInt() ?? 0,
      points: (json['points'] as List<dynamic>)
          .map((item) => MappingPoint.fromJson(item as Map<String, dynamic>))
          .toList(growable: false),
      markers: (json['markers'] as List<dynamic>)
          .map((item) => MappingMarker.fromJson(item as Map<String, dynamic>))
          .toList(growable: false),
    );
  }
}
