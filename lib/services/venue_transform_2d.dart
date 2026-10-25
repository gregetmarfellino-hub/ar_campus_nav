import 'dart:math' as math;

/// A rigid 2D transform between an ARCore mapping-local frame and the
/// persistent venue frame.
///
/// Mapping-local coordinates use:
///   +x = right
///   +y = forward
///
/// Venue coordinates use the existing map convention:
///   +x = east/right
///   +y = south/down
///
/// [headingDegrees] is clockwise from venue north. At 0 degrees, mapping
/// forward (+y) points toward venue north (-y). Scale is intentionally fixed
/// at 1.0 because ARCore already reports meters.
class VenueTransform2D {
  const VenueTransform2D({
    required this.headingDegrees,
    required this.translationX,
    required this.translationY,
  });

  final double headingDegrees;
  final double translationX;
  final double translationY;

  factory VenueTransform2D.atOrigin({
    double headingDegrees = 0,
    double venueX = 0,
    double venueY = 0,
  }) {
    return VenueTransform2D(
      headingDegrees: _normalizeDegrees(headingDegrees),
      translationX: venueX,
      translationY: venueY,
    );
  }

  factory VenueTransform2D.fromPointAndHeading({
    required double localX,
    required double localY,
    required double venueX,
    required double venueY,
    required double headingDegrees,
  }) {
    final heading = _normalizeDegrees(headingDegrees);
    final rotated = _rotateLocalVector(
      localX,
      localY,
      heading,
    );

    return VenueTransform2D(
      headingDegrees: heading,
      translationX: venueX - rotated.$1,
      translationY: venueY - rotated.$2,
    );
  }

  /// Solve the rigid transform from two corresponding points.
  ///
  /// Throws when either point pair is too close together to define a reliable
  /// direction. No scale correction is applied.
  factory VenueTransform2D.fromPointPairs({
    required double localAX,
    required double localAY,
    required double localBX,
    required double localBY,
    required double venueAX,
    required double venueAY,
    required double venueBX,
    required double venueBY,
    double minimumBaselineMeters = 0.75,
  }) {
    final localDx = localBX - localAX;
    final localDy = localBY - localAY;
    final venueDx = venueBX - venueAX;
    final venueDy = venueBY - venueAY;

    final localDistance = math.sqrt(localDx * localDx + localDy * localDy);
    final venueDistance = math.sqrt(venueDx * venueDx + venueDy * venueDy);

    if (localDistance < minimumBaselineMeters ||
        venueDistance < minimumBaselineMeters) {
      throw ArgumentError(
        'Two-point alignment needs anchors at least '
        '${minimumBaselineMeters.toStringAsFixed(2)} m apart.',
      );
    }

    final localHeading = localVectorHeadingDegrees(localDx, localDy);
    final venueHeading = venueVectorHeadingDegrees(venueDx, venueDy);
    final rotation = _normalizeDegrees(venueHeading - localHeading);

    return VenueTransform2D.fromPointAndHeading(
      localX: localAX,
      localY: localAY,
      venueX: venueAX,
      venueY: venueAY,
      headingDegrees: rotation,
    );
  }

  (double, double) applyPoint(double localX, double localY) {
    final rotated = _rotateLocalVector(
      localX,
      localY,
      headingDegrees,
    );
    return (
      rotated.$1 + translationX,
      rotated.$2 + translationY,
    );
  }

  (double, double) applyVector(double localDx, double localDy) {
    return _rotateLocalVector(
      localDx,
      localDy,
      headingDegrees,
    );
  }

  /// Heading of a vector expressed in mapping-local (+right, +forward) axes.
  static double localVectorHeadingDegrees(double dx, double dy) {
    if (dx.abs() < 1e-9 && dy.abs() < 1e-9) {
      throw ArgumentError('Zero-length local vector has no heading.');
    }
    return _normalizeDegrees(math.atan2(dx, dy) * 180 / math.pi);
  }

  /// Heading of a vector expressed in venue (+east, +south) axes.
  static double venueVectorHeadingDegrees(double dx, double dy) {
    if (dx.abs() < 1e-9 && dy.abs() < 1e-9) {
      throw ArgumentError('Zero-length venue vector has no heading.');
    }
    return _normalizeDegrees(math.atan2(dx, -dy) * 180 / math.pi);
  }

  static (double, double) _rotateLocalVector(
    double localX,
    double localY,
    double headingDegrees,
  ) {
    final theta = headingDegrees * math.pi / 180.0;
    final venueX =
        localX * math.cos(theta) + localY * math.sin(theta);
    final venueY =
        localX * math.sin(theta) - localY * math.cos(theta);
    return (venueX, venueY);
  }

  static double _normalizeDegrees(double value) {
    var normalized = value % 360;
    if (normalized < 0) normalized += 360;
    return normalized;
  }
}
