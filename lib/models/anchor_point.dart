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
    this.offlineExtraReferenceJson,
    this.checkpointRightMeters,
    this.checkpointForwardMeters,
    this.checkpointUpMeters,
    this.checkpointFacingDegrees,
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

  /// Optional second locally captured image reference (JSON, backward compatible).
  final String? offlineExtraReferenceJson;

  /// Real pose of this virtual checkpoint in the original recording frame.
  /// The route node is normally where the mapper was standing, while the
  /// placed marker can be on an adjacent wall. They must NOT be conflated.
  final double? checkpointRightMeters;
  final double? checkpointForwardMeters;
  final double? checkpointUpMeters;
  final double? checkpointFacingDegrees;

  bool get offlineCheckpointReady => offlineVisualReady &&
      checkpointRightMeters != null && checkpointForwardMeters != null &&
      checkpointUpMeters != null && checkpointFacingDegrees != null &&
      checkpointRightMeters!.isFinite && checkpointForwardMeters!.isFinite &&
      checkpointUpMeters!.isFinite && checkpointFacingDegrees!.isFinite;

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
      offlineExtraReferenceJson: json['offline_extra_reference_json'] as String?,
      checkpointRightMeters: (json['checkpoint_right_m'] as num?)?.toDouble(),
      checkpointForwardMeters: (json['checkpoint_forward_m'] as num?)?.toDouble(),
      checkpointUpMeters: (json['checkpoint_up_m'] as num?)?.toDouble(),
      checkpointFacingDegrees: (json['checkpoint_facing_deg'] as num?)?.toDouble(),
    );
  }
}
