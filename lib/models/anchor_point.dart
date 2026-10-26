class AnchorPoint {
  const AnchorPoint({
    required this.id,
    required this.label,
    required this.nodeId,
    required this.floor,
    this.headingDegrees,
    this.visualHeadingVerified = false,
    this.cloudAnchorId,
  });

  final String id;
  final String label;
  final String nodeId;
  final int floor;
  /// Venue heading of the QR poster's outward-facing normal.
  /// Only trusted for one-scan visual localization when
  /// [visualHeadingVerified] is true.
  final double? headingDegrees;
  final bool visualHeadingVerified;

  /// ARCore Cloud Anchor ID for the persistent virtual start portal.
  /// Null for legacy/non-persistent anchors.
  final String? cloudAnchorId;

  bool get visualPoseReady =>
      visualHeadingVerified && headingDegrees != null;

  bool get persistentPoseReady =>
      cloudAnchorId != null && cloudAnchorId!.isNotEmpty;

  factory AnchorPoint.fromJson(Map<String, dynamic> json) {
    return AnchorPoint(
      id: json['id'] as String,
      label: json['label'] as String? ?? json['id'] as String,
      nodeId: json['node_id'] as String,
      floor: (json['floor'] as num).toInt(),
      headingDegrees: (json['heading_degrees'] as num?)?.toDouble(),
      visualHeadingVerified:
          json['visual_heading_verified'] as bool? ?? false,
      cloudAnchorId: json['cloud_anchor_id'] as String?,
    );
  }
}
