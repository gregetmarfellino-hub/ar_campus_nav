class NavNode {
  const NavNode({
    required this.id,
    required this.label,
    required this.floor,
    required this.x,
    required this.y,
    this.upMeters = 0,
    required this.type,
  });

  final String id;
  final String label;
  final int floor;
  final double x;
  final double y;
  /// Measured height in the shared ARCore recording frame; 0 for old maps.
  final double upMeters;
  final String type;

  factory NavNode.fromJson(Map<String, dynamic> json) {
    return NavNode(
      id: json['id'] as String,
      label: json['label'] as String,
      floor: (json['floor'] as num).toInt(),
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
      upMeters: (json['up_m'] as num?)?.toDouble() ?? 0,
      type: json['type'] as String? ?? 'waypoint',
    );
  }
}
