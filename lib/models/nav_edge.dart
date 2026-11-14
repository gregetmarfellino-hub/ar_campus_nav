class NavEdge {
  const NavEdge({
    required this.from,
    required this.to,
    required this.distanceMeters,
    this.bidirectional = true,
    this.accessible = true,
    this.transitionType,
    this.measured3D = false,
  });

  final String from;
  final String to;
  final double distanceMeters;
  final bool bidirectional;
  final bool accessible;

  /// Only for explicit links between different floor layers.
  /// 'stairs' | 'elevator'. Null means an ordinary on-floor corridor.
  final String? transitionType;

  /// True ONLY when a cross-floor edge came from one continuous, measured
  /// ARCore XYZ session. Legacy portals still require two matching stairs
  /// or elevator nodes rather than inventing links between unrelated maps.
  final bool measured3D;

  bool get isFloorTransition => transitionType != null;

  factory NavEdge.fromJson(Map<String, dynamic> json) {
    return NavEdge(
      from: json['from'] as String,
      to: json['to'] as String,
      distanceMeters: (json['distance_m'] as num).toDouble(),
      bidirectional: json['bidirectional'] as bool? ?? true,
      accessible: json['accessible'] as bool? ?? true,
      transitionType: json['transition_type'] as String?,
      measured3D: json['measured_3d'] as bool? ?? false,
    );
  }
}
