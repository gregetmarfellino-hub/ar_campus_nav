/// A deliberate pause must never create a teleport segment.
///
/// Paused points and resumed points belong to the same continuously running
/// ARCore session. A new session needs independently aligned anchors and
/// cannot be stitched to the previous recording using this rule.
class MappingResumePolicy {
  const MappingResumePolicy._();

  static const double maximumGapMeters = 0.60;

  static bool canResumeAt({
    required double gapMeters,
    required bool trackingReady,
  }) {
    return trackingReady &&
        gapMeters.isFinite &&
        gapMeters >= 0 &&
        gapMeters <= maximumGapMeters;
  }
}
