import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class ArPose {
  const ArPose({
    required this.tracking,
    this.x = 0,
    this.y = 0,
    this.z = 0,
    this.forward = 0,
    this.horizontalDistance = 0,
    this.qx = 0,
    this.qy = 0,
    this.qz = 0,
    this.qw = 1,
    this.timestampNanos = 0,
    this.errorCode,
    this.errorMessage,
  });

  final String tracking;
  final double x;
  final double y;
  final double z;
  final double forward;
  final double horizontalDistance;
  final double qx;
  final double qy;
  final double qz;
  final double qw;
  final int timestampNanos;
  final String? errorCode;
  final String? errorMessage;

  bool get isTracking => tracking == 'TRACKING';

  factory ArPose.fromEvent(dynamic event) {
    if (event is! Map) {
      return const ArPose(
        tracking: 'ERROR',
        errorCode: 'INVALID_EVENT',
        errorMessage: 'ARCore returned an invalid pose event.',
      );
    }

    double number(String key) {
      final value = event[key];
      return value is num ? value.toDouble() : 0.0;
    }

    int integer(String key) {
      final value = event[key];
      return value is num ? value.toInt() : 0;
    }

    return ArPose(
      tracking: (event['tracking'] ?? 'UNKNOWN').toString(),
      x: number('x'),
      y: number('y'),
      z: number('z'),
      forward: number('forward'),
      horizontalDistance: number('horizontal_distance'),
      qx: number('qx'),
      qy: number('qy'),
      qz: number('qz'),
      qw: number('qw'),
      timestampNanos: integer('timestamp_ns'),
      errorCode: event['code']?.toString(),
      errorMessage: event['message']?.toString(),
    );
  }
}

class ArPoseService {
  const ArPoseService();

  static const MethodChannel _native = MethodChannel('ar_campus_nav/native');
  static const EventChannel _poses = EventChannel('ar_campus_nav/ar_pose');

  bool get platformSupported => Platform.isAndroid;

  Future<String> availability() async {
    if (!platformSupported) return 'ANDROID_ONLY';
    return await _native.invokeMethod<String>('arCoreAvailability') ?? 'UNKNOWN';
  }

  Future<bool> ensureCameraPermission() async {
    if (!platformSupported) return false;
    return await _native.invokeMethod<bool>('ensureCameraPermission') ?? false;
  }

  Future<String> start() async {
    if (!platformSupported) return 'ANDROID_ONLY';
    return await _native.invokeMethod<String>('startArTracking') ?? 'UNKNOWN';
  }

  Future<void> resetOrigin() async {
    if (!platformSupported) return;
    await _native.invokeMethod<void>('resetArOrigin');
  }

  Future<String> startNavigation({
    required String destinationName,
    required String startLabel,
    required bool anchorLocalized,
    required List<Map<String, dynamic>> points,
  }) async {
    if (!platformSupported) return 'ANDROID_ONLY';
    return await _native.invokeMethod<String>(
          'startArNavigation',
          <String, dynamic>{
            'destination': destinationName,
            'start_label': startLabel,
            'anchor_localized': anchorLocalized,
            'points': points,
          },
        ) ??
        'UNKNOWN';
  }

  Future<void> stopNavigation() async {
    if (!platformSupported) return;
    await _native.invokeMethod<void>('stopArNavigation');
  }

  Future<void> stop() async {
    if (!platformSupported) return;
    await _native.invokeMethod<void>('stopArTracking');
  }

  Stream<ArPose> get poses {
    if (!platformSupported) {
      return Stream<ArPose>.value(
        const ArPose(
          tracking: 'UNSUPPORTED',
          errorMessage: 'ARCore world tracking is Android-only in this prototype.',
        ),
      );
    }

    return _poses.receiveBroadcastStream().map(ArPose.fromEvent);
  }
}
