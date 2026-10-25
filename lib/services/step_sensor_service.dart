import 'package:flutter/services.dart';

class StepEvent {
  const StepEvent(this.timestampMs);

  final int timestampMs;
}

class StepSensorService {
  const StepSensorService();

  static const MethodChannel _native = MethodChannel('ar_campus_nav/native');
  static const EventChannel _steps = EventChannel('ar_campus_nav/steps');

  Future<bool> isAvailable() async {
    return await _native.invokeMethod<bool>('isStepSensorAvailable') ?? false;
  }

  Future<bool> ensurePermission() async {
    return await _native.invokeMethod<bool>('ensureActivityRecognitionPermission') ??
        false;
  }

  Stream<StepEvent> get events {
    return _steps.receiveBroadcastStream().map((dynamic event) {
      final map = Map<dynamic, dynamic>.from(event as Map);
      return StepEvent((map['timestamp_ms'] as num).toInt());
    });
  }
}
