class VisualAnchorSpec {
  const VisualAnchorSpec._();

  /// Physical width of the black/white QR image itself, excluding captions.
  /// ARCore uses this known size to recover metric scale from the image.
  static const double qrWidthMeters = 0.16;

  static const int renderPixels = 512;
}
