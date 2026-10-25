import 'package:flutter_test/flutter_test.dart';
import 'package:ar_campus_nav/services/venue_transform_2d.dart';

void main() {
  group('VenueTransform2D', () {
    test('zero heading maps local forward to venue north', () {
      final transform = VenueTransform2D.atOrigin();

      final point = transform.applyPoint(0, 3);

      expect(point.$1, closeTo(0, 1e-9));
      expect(point.$2, closeTo(-3, 1e-9));
    });

    test('90 degree heading maps local forward to venue east', () {
      final transform = VenueTransform2D.atOrigin(
        headingDegrees: 90,
      );

      final point = transform.applyPoint(0, 4);

      expect(point.$1, closeTo(4, 1e-9));
      expect(point.$2, closeTo(0, 1e-9));
    });

    test('point and heading pins the local origin to a venue point', () {
      final transform = VenueTransform2D.fromPointAndHeading(
        localX: 2,
        localY: 1,
        venueX: 10,
        venueY: 20,
        headingDegrees: 90,
      );

      final pinned = transform.applyPoint(2, 1);
      final oneMeterForward = transform.applyPoint(2, 2);

      expect(pinned.$1, closeTo(10, 1e-9));
      expect(pinned.$2, closeTo(20, 1e-9));
      expect(oneMeterForward.$1, closeTo(11, 1e-9));
      expect(oneMeterForward.$2, closeTo(20, 1e-9));
    });

    test('two point solve recovers translation and rotation', () {
      final transform = VenueTransform2D.fromPointPairs(
        localAX: 0,
        localAY: 0,
        localBX: 0,
        localBY: 5,
        venueAX: 12,
        venueAY: 8,
        venueBX: 17,
        venueBY: 8,
      );

      final a = transform.applyPoint(0, 0);
      final b = transform.applyPoint(0, 5);

      expect(transform.headingDegrees, closeTo(90, 1e-9));
      expect(a.$1, closeTo(12, 1e-9));
      expect(a.$2, closeTo(8, 1e-9));
      expect(b.$1, closeTo(17, 1e-9));
      expect(b.$2, closeTo(8, 1e-9));
    });

    test('two point solve rejects a useless short baseline', () {
      expect(
        () => VenueTransform2D.fromPointPairs(
          localAX: 0,
          localAY: 0,
          localBX: 0.1,
          localBY: 0,
          venueAX: 0,
          venueAY: 0,
          venueBX: 0.1,
          venueBY: 0,
        ),
        throwsArgumentError,
      );
    });
  });
}
