import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

class VisualQrPlacement {
  const VisualQrPlacement({
    required this.rightMeters,
    required this.forwardMeters,
    required this.upMeters,
    required this.facingDegrees,
    this.offlineReferencePng,
    this.offlineReferenceWidthMeters,
    this.offlineStartOffsetX,
    this.offlineStartOffsetY,
    this.offlineStartOffsetZ,
    this.offlineStartForwardX,
    this.offlineStartForwardY,
    this.offlineStartForwardZ,
    this.offlineExtraReferenceJson,
  });

  final double rightMeters;
  final double forwardMeters;
  final double upMeters;
  final double facingDegrees;
  final Uint8List? offlineReferencePng;
  final double? offlineReferenceWidthMeters;
  final double? offlineStartOffsetX;
  final double? offlineStartOffsetY;
  final double? offlineStartOffsetZ;
  final double? offlineStartForwardX;
  final double? offlineStartForwardY;
  final double? offlineStartForwardZ;
  final String? offlineExtraReferenceJson;

  bool get hasOfflineReference =>
      offlineReferencePng?.isNotEmpty == true &&
      offlineReferenceWidthMeters != null &&
      offlineStartOffsetX != null &&
      offlineStartOffsetY != null &&
      offlineStartOffsetZ != null &&
      offlineStartForwardX != null &&
      offlineStartForwardY != null &&
      offlineStartForwardZ != null;

  factory VisualQrPlacement.fromMap(Map<dynamic, dynamic> map) {
    double number(String key) {
      final value = map[key];
      if (value is! num) {
        throw FormatException('Missing visual QR placement field: $key');
      }
      return value.toDouble();
    }

    return VisualQrPlacement(
      rightMeters: number('right_m'),
      forwardMeters: number('forward_m'),
      upMeters: number('up_m'),
      facingDegrees: number('facing_deg'),
      offlineReferencePng: map['offline_reference_png'] is Uint8List
          ? map['offline_reference_png'] as Uint8List
          : null,
      offlineReferenceWidthMeters:
          (map['offline_reference_width_m'] as num?)?.toDouble(),
      offlineStartOffsetX:
          (map['offline_start_offset_x'] as num?)?.toDouble(),
      offlineStartOffsetY:
          (map['offline_start_offset_y'] as num?)?.toDouble(),
      offlineStartOffsetZ:
          (map['offline_start_offset_z'] as num?)?.toDouble(),
      offlineStartForwardX:
          (map['offline_start_forward_x'] as num?)?.toDouble(),
      offlineStartForwardY:
          (map['offline_start_forward_y'] as num?)?.toDouble(),
      offlineStartForwardZ:
          (map['offline_start_forward_z'] as num?)?.toDouble(),
      offlineExtraReferenceJson: map['offline_extra_reference_json'] as String?,
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

  Future<String> startMappingWithVisualAnchor({
    required Uint8List qrPng,
    required double widthMeters,
    required String label,
  }) async {
    if (!platformSupported) return 'ANDROID_ONLY';
    return await _native.invokeMethod<String>(
          'startArTracking',
          <String, dynamic>{
            'mapping_visual_anchor_png': qrPng,
            'mapping_visual_anchor_width_m': widthMeters,
            'mapping_visual_anchor_label': label,
          },
        ) ??
        'UNKNOWN';
  }

  Future<VisualQrPlacement?> placeVisualQrAnchor({
    required Uint8List qrPng,
    required double widthMeters,
  }) async {
    if (!platformSupported) return null;
    final result = await _native.invokeMethod<dynamic>(
      'placeVisualQrAnchor',
      <String, dynamic>{
        'qr_png': qrPng,
        'qr_width_m': widthMeters,
      },
    );
    if (result == null) return null;
    if (result is! Map) {
      throw const FormatException('Invalid visual QR placement result.');
    }
    return VisualQrPlacement.fromMap(result);
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
    Uint8List? visualAnchorPng,
    double? visualAnchorWidthMeters,
    String? visualAnchorLabel,
    double? visualAnchorRouteOffsetDegrees,
    Uint8List? offlineReferencePng,
    double? offlineReferenceWidthMeters,
    double? offlineStartOffsetX,
    double? offlineStartOffsetY,
    double? offlineStartOffsetZ,
    double? offlineStartForwardX,
    double? offlineStartForwardY,
    double? offlineStartForwardZ,
    String? offlineExtraReferenceJson,
  }) async {
    if (!platformSupported) return 'ANDROID_ONLY';
    return await _native.invokeMethod<String>(
          'startArNavigation',
          <String, dynamic>{
            'destination': destinationName,
            'start_label': startLabel,
            'anchor_localized': anchorLocalized,
            'points': points,
            if (visualAnchorPng != null)
              'visual_anchor_png': visualAnchorPng,
            if (visualAnchorWidthMeters != null)
              'visual_anchor_width_m': visualAnchorWidthMeters,
            if (visualAnchorLabel != null)
              'visual_anchor_label': visualAnchorLabel,
            if (visualAnchorRouteOffsetDegrees != null)
              'visual_anchor_route_offset_deg':
                  visualAnchorRouteOffsetDegrees,
            if (offlineReferencePng != null)
              'offline_reference_png': offlineReferencePng,
            if (offlineReferenceWidthMeters != null)
              'offline_reference_width_m': offlineReferenceWidthMeters,
            if (offlineStartOffsetX != null)
              'offline_start_offset_x': offlineStartOffsetX,
            if (offlineStartOffsetY != null)
              'offline_start_offset_y': offlineStartOffsetY,
            if (offlineStartOffsetZ != null)
              'offline_start_offset_z': offlineStartOffsetZ,
            if (offlineStartForwardX != null)
              'offline_start_forward_x': offlineStartForwardX,
            if (offlineStartForwardY != null)
              'offline_start_forward_y': offlineStartForwardY,
            if (offlineStartForwardZ != null)
              'offline_start_forward_z': offlineStartForwardZ,
            if (offlineExtraReferenceJson != null)
              'offline_extra_reference_json': offlineExtraReferenceJson,
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
