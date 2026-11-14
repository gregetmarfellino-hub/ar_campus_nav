import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Structural contract only: a device field-test is still needed to confirm
/// that the live ARCore surface and virtual QR renderer actually appear.
void main() {
  test('V14 opens native virtual QR BEFORE any naming dialog', () {
    final source = File(
      'lib/screens/continuous_3d_mapping_screen.dart',
    ).readAsStringSync();
    final begin = source.indexOf('Future<void> _placeOfflineCheckpoint()');
    final end = source.indexOf('Future<void> _markLandmark()', begin);
    expect(begin, greaterThan(0));
    expect(end, greaterThan(begin));
    final action = source.substring(begin, end);

    final captureAt = action.indexOf('_ar.placeVisualQrAnchor(');
    final nameAt = action.indexOf('_nameOfflineCheckpoint(');
    expect(captureAt, greaterThan(0));
    expect(nameAt, greaterThan(captureAt),
        reason: 'The QR camera must open first; naming cannot gate placement.');
    expect(action.substring(0, captureAt), isNot(contains('showDialog')),
        reason: 'No modal input before virtual AR QR becomes visible.');
    expect(action, contains('preserveMappingFrame: true'));
    expect(action, contains('if (placement == null) return;'));
    expect(action, contains('_autoSaveDraft(force: true)'));
    expect(source, contains('PLACE VIRTUAL QR / ENTRANCE'));
  });

  test('native checkpoint QR is visible without first recognizing a plane', () {
    final native = File(
      'android/app/src/main/kotlin/com/example/ar_campus_nav/'
      'ArCoreTrackingEngine.kt',
    ).readAsStringSync();

    final begin = native.indexOf('fun beginVisualQrPlacement(');
    final end = native.indexOf('private fun createQrPlacementOverlay()', begin);
    expect(begin, greaterThan(0));
    expect(end, greaterThan(begin));
    final initialization = native.substring(begin, end);
    expect(initialization, contains('qrPlacementSnapToSurface = !preserveMappingFrame'));
    expect(initialization, contains('qrPlacementMode = true'));
    expect(initialization, contains('createQrPlacementOverlay()'));

    final draw = native.substring(
      native.indexOf('private fun handleQrPlacementFrame('),
      native.indexOf('private fun captureOfflineStartReference('),
    );
    expect(draw, contains('qrPlacementRenderer.draw('));
    expect(draw, contains('if (snapToSurface)'));
    expect(draw, contains('FLOATING QR'));
    expect(draw, contains('qrCheckpointWorldAnchor = newAnchor'));
    expect(draw, contains('trackingOriginPosition = anchorPose.translation.copyOf()'));
    final preserveFrame = draw.substring(
      draw.indexOf('if (qrPlacementPreserveFrame)'),
      draw.indexOf('} else {', draw.indexOf('if (qrPlacementPreserveFrame)')),
    );
    expect(preserveFrame, isNot(contains('trackingOriginPosition = anchorPose.translation')),
        reason: 'Placing the next QR may not move the existing measured XYZ path.');
  });

  test('camera hides manual world alignment on V13 visual 3D routes', () {
    final native = File(
      'android/app/src/main/kotlin/com/example/ar_campus_nav/'
      'ArCoreTrackingEngine.kt',
    ).readAsStringSync();
    expect(native, contains('navigationVerifiedOfflineRequired'));
    expect(native, contains('if (navigationVerifiedOfflineRequired) quickAlign.visibility = View.GONE'));
    expect(native, contains('if (navigationVerifiedOfflineRequired) align.visibility = View.GONE'));
  });
}
