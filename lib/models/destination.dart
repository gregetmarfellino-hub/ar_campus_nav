class Destination {
  const Destination({
    required this.id,
    required this.name,
    required this.nodeId,
    required this.category,
    this.description = '',
  });

  final String id;
  final String name;
  final String nodeId;
  final String category;
  final String description;

  factory Destination.fromJson(Map<String, dynamic> json) {
    return Destination(
      id: json['id'] as String,
      name: json['name'] as String,
      nodeId: json['node_id'] as String,
      category: json['category'] as String? ?? 'place',
      description: json['description'] as String? ?? '',
    );
  }
}
