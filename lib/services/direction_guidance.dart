import 'dart:math' as math;

import '../models/nav_node.dart';

class DirectionGuidance {
  const DirectionGuidance._();

  static double mapBearingDegrees(NavNode from, NavNode to) {
    final dx = to.x - from.x;
    final dy = to.y - from.y;

    final radians = math.atan2(dx, -dy);
    return normalize360(radians * 180 / math.pi);
  }

  static double normalize360(double degrees) {
    var value = degrees % 360;
    if (value < 0) value += 360;
    return value;
  }

  static double normalizeSigned(double degrees) {
    var value = normalize360(degrees);
    if (value > 180) value -= 360;
    return value;
  }

  static String compassPoint(double heading) {
    const points = <String>['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    final index = ((normalize360(heading) + 22.5) ~/ 45) % 8;
    return points[index];
  }

  static String relativeInstruction(double relativeDegrees) {
    final angle = normalizeSigned(relativeDegrees);
    final magnitude = angle.abs();

    if (magnitude <= 12) return 'Straight ahead';
    if (magnitude <= 40) return angle > 0 ? 'Bear right' : 'Bear left';
    if (magnitude <= 125) return angle > 0 ? 'Turn right' : 'Turn left';
    return 'Turn around';
  }

  static String relativeAngleLabel(double relativeDegrees) {
    final angle = normalizeSigned(relativeDegrees);
    final magnitude = angle.abs().round();
    if (magnitude <= 3) return 'Aligned';
    return angle > 0 ? '$magnitude° right' : '$magnitude° left';
  }
}
