import 'package:flutter_test/flutter_test.dart';
import 'package:ar_campus_nav/services/mapping_resume_policy.dart';

void main() {
  test('accepts resuming exactly at the last mapped point', () {
    expect(
      MappingResumePolicy.canResumeAt(
        gapMeters: 0,
        trackingReady: true,
      ),
      isTrue,
    );
  });

  test('accepts small same-session 3D drift, including safety boundary', () {
    expect(
      MappingResumePolicy.canResumeAt(
        gapMeters: 0.60,
        trackingReady: true,
      ),
      isTrue,
    );
  });

  test('refuses a teleport between paused and resumed segments', () {
    expect(
      MappingResumePolicy.canResumeAt(
        gapMeters: 0.60001,
        trackingReady: true,
      ),
      isFalse,
    );
    expect(
      MappingResumePolicy.canResumeAt(
        gapMeters: 1.8,
        trackingReady: true,
      ),
      isFalse,
    );
  });

  test('refuses to resume while ARCore tracking is not healthy', () {
    expect(
      MappingResumePolicy.canResumeAt(
        gapMeters: 0.02,
        trackingReady: false,
      ),
      isFalse,
    );
  });

  test('refuses invalid measured movement', () {
    for (final gap in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
      -0.001,
    ]) {
      expect(
        MappingResumePolicy.canResumeAt(
          gapMeters: gap,
          trackingReady: true,
        ),
        isFalse,
      );
    }
  });
}
