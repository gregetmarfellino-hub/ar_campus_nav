class NavEdge {
  const NavEdge({
    required this.from,
    required this.to,
    required this.distanceMeters,
    this.bidirectional = true,
    this.accessible = true,
  });

  final String from;
  final String to;
  final double distanceMeters;
  final bool bidirectional;
  final bool accessible;

  factory NavEdge.fromJson(Map<String, dynamic> json) {
    return NavEdge(
      from: json['from'] as String,
      to: json['to'] as String,
      distanceMeters: (json['distance_m'] as num).toDouble(),
      bidirectional: json['bidirectional'] as bool? ?? true,
      accessible: json['accessible'] as bool? ?? true,
    );
  }
}
