class AnchorPoint {
  const AnchorPoint({
    required this.id,
    required this.label,
    required this.nodeId,
    required this.floor,
    this.headingDegrees,
    this.visualHeadingVerified = false,
    this.offlineVisualReferencePngBase64,
    this.offlineVisualReferenceWidthMeters,
    this.offlineVisualStartOffsetX,
    this.offlineVisualStartOffsetY,
    this.offlineVisualStartOffsetZ,
    this.offlineVisualStartForwardX,
    this.offlineVisualStartForwardY,
    this.offlineVisualStartForwardZ,
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

  final String? offlineVisualReferencePngBase64;
  final double? offlineVisualReferenceWidthMeters;
  final double? offlineVisualStartOffsetX;
  final double? offlineVisualStartOffsetY;
  final double? offlineVisualStartOffsetZ;
  final double? offlineVisualStartForwardX;
  final double? offlineVisualStartForwardY;
  final double? offlineVisualStartForwardZ;

  bool get offlineVisualReady =>
      offlineVisualReferencePngBase64?.isNotEmpty == true &&
      offlineVisualReferenceWidthMeters != null &&
      offlineVisualStartOffsetX != null &&
      offlineVisualStartOffsetY != null &&
      offlineVisualStartOffsetZ != null &&
      offlineVisualStartForwardX != null &&
      offlineVisualStartForwardY != null &&
      offlineVisualStartForwardZ != null;

  bool get visualPoseReady =>
      visualHeadingVerified && headingDegrees != null;

  factory AnchorPoint.fromJson(Map<String, dynamic> json) {
    return AnchorPoint(
      id: json['id'] as String,
      label: json['label'] as String? ?? json['id'] as String,
      nodeId: json['node_id'] as String,
      floor: (json['floor'] as num).toInt(),
      headingDegrees: (json['heading_degrees'] as num?)?.toDouble(),
      visualHeadingVerified:
          json['visual_heading_verified'] as bool? ?? false,
      offlineVisualReferencePngBase64:
          json['offline_visual_reference_png_b64'] as String?,
      offlineVisualReferenceWidthMeters:
          (json['offline_visual_reference_width_m'] as num?)?.toDouble(),
      offlineVisualStartOffsetX:
          (json['offline_visual_start_offset_x'] as num?)?.toDouble(),
      offlineVisualStartOffsetY:
          (json['offline_visual_start_offset_y'] as num?)?.toDouble(),
      offlineVisualStartOffsetZ:
          (json['offline_visual_start_offset_z'] as num?)?.toDouble(),
      offlineVisualStartForwardX:
          (json['offline_visual_start_forward_x'] as num?)?.toDouble(),
      offlineVisualStartForwardY:
          (json['offline_visual_start_forward_y'] as num?)?.toDouble(),
      offlineVisualStartForwardZ:
          (json['offline_visual_start_forward_z'] as num?)?.toDouble(),
    );
  }
}
