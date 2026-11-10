import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level Android lifecycle regression: the real GL rendering result
/// still needs a physical ARCore device test. This catches the exact V10
/// bug where the preview camera opened but no line was ever drawn because
/// the breadcrumb shader had only been created in navigation mode.
void main() {
  test('GL breadcrumb renderer is initialized even for mapping-only start', () {
    final source = File(
      'android/app/src/main/kotlin/com/example/ar_campus_nav/'
      'ArCoreTrackingEngine.kt',
    ).readAsStringSync();

    final start = source.indexOf('override fun onSurfaceCreated(');
    final end = source.indexOf('override fun onSurfaceChanged(', start);
    expect(start, greaterThan(0));
    expect(end, greaterThan(start));

    final surfaceInitialization = source.substring(start, end);
    expect(
      surfaceInitialization,
      contains('breadcrumbRenderer.createOnGlThread()'),
      reason: 'V10 starts in mapping mode, so preview shader initialization '
          'cannot depend on navigationMode.',
    );
    expect(
      surfaceInitialization,
      isNot(contains(
        'if (navigationMode) {\n            breadcrumbRenderer.createOnGlThread()',
      )),
      reason: 'This was the precise cause of the blank V10 line preview.',
    );
  });

  test('3D live preview projects upMeters and invokes breadcrumb draw', () {
    final source = File(
      'android/app/src/main/kotlin/com/example/ar_campus_nav/'
      'ArCoreTrackingEngine.kt',
    ).readAsStringSync();

    final begin = source.indexOf('private fun continuous3DWorldPoints()');
    final end = source.indexOf('fun resetOrigin()', begin);
    expect(begin, greaterThan(0));
    expect(end, greaterThan(begin));
    expect(
      source.substring(begin, end),
      contains('origin[1] + point.upMeters - 1.10f'),
      reason: 'Do not flatten a measured stair route onto one floor height.',
    );

    final frameStart = source.indexOf('override fun onDrawFrame(');
    final frameEnd = source.indexOf('catch (error: CameraNotAvailableException)', frameStart);
    expect(frameStart, greaterThan(0));
    expect(frameEnd, greaterThan(frameStart));
    final frameRender = source.substring(frameStart, frameEnd);
    expect(frameRender, contains('if (continuous3DPreviewEnabled)'));
    expect(frameRender, contains('breadcrumbRenderer.draw('));
  });
}
