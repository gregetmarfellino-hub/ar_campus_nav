import 'package:flutter_compass/flutter_compass.dart';

class HeadingService {
  const HeadingService();

  Stream<double> get headings async* {
    final events = FlutterCompass.events;
    if (events == null) return;

    double? previous;

    await for (final event in events) {
      final raw = event.heading;
      if (raw == null || raw.isNaN || raw.isInfinite) continue;

      final normalized = _normalize360(raw);
      final filtered = previous == null
          ? normalized
          : _smoothCircular(previous, normalized, 0.22);

      previous = filtered;
      yield filtered;
    }
  }

  double _smoothCircular(double from, double to, double factor) {
    var delta = (to - from) % 360;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    return _normalize360(from + delta * factor);
  }

  double _normalize360(double degrees) {
    var value = degrees % 360;
    if (value < 0) value += 360;
    return value;
  }
}
