class AnchorPoint {
  const AnchorPoint({
    required this.id,
    required this.label,
    required this.nodeId,
    required this.floor,
    this.headingDegrees,
  });

  final String id;
  final String label;
  final String nodeId;
  final int floor;
  final double? headingDegrees;

  factory AnchorPoint.fromJson(Map<String, dynamic> json) {
    return AnchorPoint(
      id: json['id'] as String,
      label: json['label'] as String? ?? json['id'] as String,
      nodeId: json['node_id'] as String,
      floor: (json['floor'] as num).toInt(),
      headingDegrees: (json['heading_degrees'] as num?)?.toDouble(),
    );
  }
}
