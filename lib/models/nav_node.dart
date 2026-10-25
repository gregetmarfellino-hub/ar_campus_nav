class NavNode {
  const NavNode({
    required this.id,
    required this.label,
    required this.floor,
    required this.x,
    required this.y,
    required this.type,
  });

  final String id;
  final String label;
  final int floor;
  final double x;
  final double y;
  final String type;

  factory NavNode.fromJson(Map<String, dynamic> json) {
    return NavNode(
      id: json['id'] as String,
      label: json['label'] as String,
      floor: (json['floor'] as num).toInt(),
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
      type: json['type'] as String? ?? 'waypoint',
    );
  }
}
