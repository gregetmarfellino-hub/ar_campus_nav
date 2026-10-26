import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/anchor_point.dart';
import '../models/mapping_session.dart';
import '../models/venue.dart';
import '../services/ar_pose_service.dart';
import '../services/mapping_path_simplifier.dart';
import '../services/mapping_storage.dart';
import '../services/visual_anchor_spec.dart';

class SpatialMappingScreen extends StatefulWidget {
  const SpatialMappingScreen({
    super.key,
    required this.venue,
    this.initialAnchor,
  });

  final Venue venue;
  final AnchorPoint? initialAnchor;

  @override
  State<SpatialMappingScreen> createState() => _SpatialMappingScreenState();
}

class _SpatialMappingScreenState extends State<SpatialMappingScreen> {
  static const Color _green = Color(0xFF3DDC97);

  static const double _minimumSampleDistanceMeters = 0.12;
  static const int _stablePoseSamplesRequired = 10;
  static const int _recoveryPoseSamplesRequired = 6;
  static const int _uiRefreshIntervalMs = 100;
  static const double _poseJumpBaseMeters = 0.35;
  static const double _maxPlausibleWalkingSpeedMps = 3.0;
  static const double _maxAcceptedPoseStepMeters = 1.50;
  static const int _rejectedJumpPauseThreshold = 3;

  final ArPoseService _ar = const ArPoseService();
  final MappingStorage _storage = const MappingStorage();

  StreamSubscription<ArPose>? _poseSubscription;

  AnchorPoint? _startAnchor;
  int _floor = 1;

  String _availability = 'CHECKING';
  ArPose _pose = const ArPose(tracking: 'STOPPED');

  bool _starting = false;
  bool _arStarted = false;
  bool _arming = false;
  bool _awaitingStartQr = false;
  bool _recording = false;
  bool _trackingInterrupted = false;

  String? _placedStartQrId;
  String? _placedStartQrLabel;
  String? _startCloudAnchorId;

  int _stablePoseSamples = 0;
  int _recoveryPoseSamples = 0;
  int _lastUiRefreshMs = 0;
  int _trackingInterruptions = 0;
  int _rejectedPoseJumps = 0;
  int _consecutiveRejectedPoseJumps = 0;
  double _recordedDistanceMeters = 0;

  String _trackingState = 'STOPPED';

  final List<MappingPoint> _points = <MappingPoint>[];
  final List<MappingMarker> _markers = <MappingMarker>[];

  String? _message;
  String? _savedPath;
  String? _savedJson;

  bool get _mappingActive =>
      _arming || _awaitingStartQr || _recording;

  @override
  void initState() {
    super.initState();

    _startAnchor = widget.initialAnchor ??
        (widget.venue.anchors.isEmpty ? null : widget.venue.anchors.first);
    _floor = _startAnchor?.floor ??
        (widget.venue.floors.isEmpty ? 1 : widget.venue.floors.first);

    _poseSubscription = _ar.poses.listen(
      _onPose,
      onError: (Object error) {
        if (!mounted) return;
        setState(() => _message = 'ARCore stream: $error');
      },
    );

    _checkAvailability();
  }

  @override
  void dispose() {
    _poseSubscription?.cancel();
    if (_arStarted) {
      unawaited(_ar.stop());
    }
    super.dispose();
  }

  Future<void> _checkAvailability() async {
    try {
      final value = await _ar.availability();
      if (!mounted) return;
      setState(() => _availability = value);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _availability = 'ERROR';
        _message = error.toString();
      });
    }
  }

  Future<void> _startPersistentPortalRecording() async {
    if (_starting || _mappingActive) return;

    final existing = _startAnchor;
    final label = existing?.label ?? 'Main Entrance';
    final anchorId = existing?.id ?? _uniqueVisualAnchorId(label);

    setState(() {
      _starting = true;
      _arming = false;
      _awaitingStartQr = true;
      _recording = false;
      _placedStartQrId = anchorId;
      _placedStartQrLabel = label;
      _startCloudAnchorId = null;
      _trackingState = 'PLACING PORTAL';
      _message = null;
      _savedPath = null;
      _savedJson = null;
    });

    try {
      final permission = await _ar.ensureCameraPermission();
      if (!permission) {
        if (!mounted) return;
        setState(() {
          _starting = false;
          _awaitingStartQr = false;
          _placedStartQrId = null;
          _placedStartQrLabel = null;
          _trackingState = 'STOPPED';
          _message = 'Camera permission is required for ARCore spatial mapping.';
        });
        return;
      }

      if (_arStarted) {
        await _ar.stop();
        _arStarted = false;
      }

      final qrPng = await _qrPngForAnchorId(anchorId);
      final result = await _ar.startPersistentPortalMapping(
        qrPng: qrPng,
        widthMeters: VisualAnchorSpec.qrWidthMeters,
        label: label,
      );
      if (!mounted) return;

      if (result == 'INSTALL_REQUESTED') {
        setState(() {
          _starting = false;
          _awaitingStartQr = false;
          _trackingState = 'STOPPED';
          _message =
              'Google Play Services for AR needs installation/update. '
              'Return here and start again afterward.';
        });
        return;
      }

      if (result != 'STARTED') {
        setState(() {
          _starting = false;
          _awaitingStartQr = false;
          _trackingState = 'STOPPED';
          _message = 'Could not start persistent AR mapping: $result';
        });
        return;
      }

      setState(() {
        _arStarted = true;
        _starting = false;
        _trackingInterrupted = false;
        _stablePoseSamples = 0;
        _recoveryPoseSamples = 0;
        _trackingInterruptions = 0;
        _rejectedPoseJumps = 0;
        _consecutiveRejectedPoseJumps = 0;
        _recordedDistanceMeters = 0;
        _trackingState = 'PLACE START PORTAL';
        _pose = const ArPose(tracking: 'INITIALIZING');
        _points.clear();
        _markers.clear();
        _message =
            'Place the floating QR start portal where the route entrance should '
            'live. Recording begins automatically after the portal is saved.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _awaitingStartQr = false;
        _arStarted = false;
        _trackingState = 'STOPPED';
        _message = 'Could not start persistent AR mapping: $error';
      });
    }
  }

  void _onPose(ArPose pose) {
    if (!mounted) return;

    final hasRealPose = pose.isTracking && pose.timestampNanos > 0;
    final stateChanged = _trackingState != pose.tracking;
    _trackingState = pose.tracking;

    // Persistent portal hosting returns a Cloud Anchor ID as a status event.
    // Native has already rebased the local mapping frame to this portal pose.
    if (pose.tracking == 'PERSISTENT_PORTAL_HOSTED' && _awaitingStartQr) {
      final anchorId = _placedStartQrId;
      final label = _placedStartQrLabel;
      final cloudAnchorId = pose.cloudAnchorId;

      if (anchorId == null || label == null || cloudAnchorId == null) {
        setState(() {
          _message = 'Persistent portal hosted without a valid anchor ID.';
        });
        return;
      }

      setState(() {
        _startCloudAnchorId = cloudAnchorId;
        _awaitingStartQr = false;
        _recording = true;
        _trackingInterrupted = false;
        _recoveryPoseSamples = 0;
        _consecutiveRejectedPoseJumps = 0;
        _recordedDistanceMeters = 0;
        _trackingState = 'READY';
        _points
          ..clear()
          ..add(
            MappingPoint(
              xMeters: 0,
              yMeters: 0,
              upMeters: 0,
              headingDegrees: 0,
              stepIndex: 0,
              timestampMs: DateTime.now().millisecondsSinceEpoch,
            ),
          );
        _markers
          ..clear()
          ..add(
            MappingMarker(
              id: anchorId,
              label: label,
              type: 'anchor',
              floor: _floor,
              xMeters: 0,
              yMeters: 0,
              upMeters: 0,
              pointIndex: 0,
              anchorFacingDegrees: 0,
            ),
          );
        _message =
            'START PORTAL SAVED — $label is now the persistent route origin. '
            'Start walking and add the destination.';
      });
      return;
    }

    if (pose.tracking == 'PERSISTENT_PORTAL_CANCELLED') {
      setState(() {
        _awaitingStartQr = false;
        _recording = false;
        _arStarted = false;
        _trackingState = 'STOPPED';
        _placedStartQrId = null;
        _placedStartQrLabel = null;
        _startCloudAnchorId = null;
        _message = 'Start portal placement cancelled.';
      });
      return;
    }

    // Status-only events (PAUSED, RESETTING_ORIGIN, etc.) do not contain
    // coordinates. Keep the last good pose on screen instead of snapping
    // X/Forward back to zero.
    if (!hasRealPose) {
      _stablePoseSamples = 0;

      if (_recording && pose.tracking == 'PAUSED') {
        if (!_trackingInterrupted) {
          _trackingInterruptions++;
        }
        _trackingInterrupted = true;
        _recoveryPoseSamples = 0;
        _message =
            'TRACKING LOST — stop walking. '
            '${pose.errorMessage ?? 'Hold the phone steady and aim at visible detail.'}';
      } else if (_arming && pose.tracking == 'PAUSED') {
        _message =
            'WAIT — ARCore has not locked yet. '
            '${pose.errorMessage ?? 'Move the phone slowly and aim at visible detail.'}';
      } else if (_awaitingStartQr && pose.tracking == 'PAUSED') {
        _message =
            'WAIT — tracking paused before the start portal was locked. '
            '${pose.errorMessage ?? 'Move the phone slowly until ARCore recovers.'}';
      } else if (pose.errorMessage != null) {
        _message = pose.errorMessage;
      }

      _refreshUi(force: stateChanged || pose.errorMessage != null);
      return;
    }

    _pose = pose;

    // Bootstrap mapping: once ARCore is stable, recording starts immediately.
    // The entrance anchor is provisional until/unless a physical QR is bound.
    if (_arming) {
      _stablePoseSamples++;

      if (_stablePoseSamples >= _stablePoseSamplesRequired) {
        final anchorId = _placedStartQrId;
        final label = _placedStartQrLabel;
        _arming = false;
        _awaitingStartQr = false;
        _recording = true;
        _trackingState = 'READY';
        _recordedDistanceMeters = 0;
        _points.clear();
        _markers.clear();
        if (anchorId != null && label != null) {
          _markers.add(
            MappingMarker(
              id: anchorId,
              label: label,
              type: 'anchor',
              floor: _floor,
              xMeters: 0,
              yMeters: 0,
              upMeters: 0,
              pointIndex: 0,
            ),
          );
        }
        _message =
            'RECORDING READY — start walking. $label is the provisional start '
            'location; you can map geometry now even without a deployed QR.';
        _refreshUi(force: true);
        return;
      }

      _trackingState =
          'LOCKING $_stablePoseSamples/$_stablePoseSamplesRequired';
      _message =
          'WAIT — keep the phone steady. Recording starts automatically after '
          'a stable ARCore lock.';
      _refreshUi();
      return;
    }

    if (_awaitingStartQr) {
      _trackingState = 'START QR';
      _refreshUi();
      return;
    }

    // If tracking was interrupted, wait for a short run of stable poses.
    // Users are told to stop walking while PAUSED so we do not silently lose
    // meters and bridge a broken section of the route.
    if (_trackingInterrupted) {
      _recoveryPoseSamples++;
      if (_recoveryPoseSamples < _recoveryPoseSamplesRequired) {
        _trackingState =
            'RECOVERING $_recoveryPoseSamples/$_recoveryPoseSamplesRequired';
        _message = 'Tracking is recovering. Keep still for a moment.';
        _refreshUi();
        return;
      }

      if (_points.isNotEmpty) {
        final probe = _mappingPointFromPose(pose);
        final gap = _distance3d(_points.last, probe);
        if (gap > 1.5) {
          _trackingState = 'RECOVERY GAP';
          _message =
              'ARCore recovered ${gap.toStringAsFixed(1)} m from the last '
              'recorded point. Walk back near the last known spot or restart '
              'this mapping so the route is not corrupted.';
          _recoveryPoseSamples = _recoveryPoseSamplesRequired;
          _refreshUi(force: true);
          return;
        }
      }

      _trackingInterrupted = false;
      _recoveryPoseSamples = 0;
      _consecutiveRejectedPoseJumps = 0;
      _trackingState = 'TRACKING';
      _message = 'Tracking recovered. Continue walking.';
      _refreshUi(force: true);
    }

    if (_recording) {
      final candidate = _mappingPointFromPose(pose);

      if (_points.isEmpty) {
        _points.add(candidate);
        _consecutiveRejectedPoseJumps = 0;
      } else {
        final previous = _points.last;
        final delta = _distance3d(previous, candidate);

        if (!_isPlausiblePoseStep(previous, candidate, delta)) {
          _rejectedPoseJumps++;
          _consecutiveRejectedPoseJumps++;
          _trackingState = 'POSE REJECTED';
          _message =
              'Impossible ARCore position jump rejected '
              '(${delta.toStringAsFixed(1)} m). Keep walking smoothly and '
              'keep visible detail in frame.';

          if (_consecutiveRejectedPoseJumps >=
              _rejectedJumpPauseThreshold) {
            _trackingInterrupted = true;
            _trackingInterruptions++;
            _recoveryPoseSamples = 0;
            _trackingState = 'POSITION UNCERTAIN';
            _message =
                'POSITION UNCERTAIN — stop walking. Repeated impossible '
                'ARCore jumps were blocked before they could corrupt the map. '
                'Wait for tracking to recover near the last trusted point.';
          }

          _refreshUi(force: true);
          return;
        }

        _consecutiveRejectedPoseJumps = 0;
        if (delta >= _minimumSampleDistanceMeters) {
          _recordedDistanceMeters += delta;
          _points.add(candidate);
        }
      }
    }

    _trackingState = 'TRACKING';
    _refreshUi(force: stateChanged);
  }

  MappingPoint _mappingPointFromPose(ArPose pose) {
    return MappingPoint(
      xMeters: pose.x,
      yMeters: pose.forward,
      upMeters: pose.y,
      headingDegrees: 0,
      stepIndex: _points.length,
      timestampMs: pose.timestampNanos <= 0
          ? DateTime.now().millisecondsSinceEpoch
          : pose.timestampNanos ~/ 1000000,
      qx: pose.qx,
      qy: pose.qy,
      qz: pose.qz,
      qw: pose.qw,
    );
  }

  void _refreshUi({bool force = false}) {
    if (!mounted) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastUiRefreshMs < _uiRefreshIntervalMs) {
      return;
    }

    _lastUiRefreshMs = now;
    setState(() {});
  }

  double _distance3d(MappingPoint a, MappingPoint b) {
    final dx = b.xMeters - a.xMeters;
    final dy = b.yMeters - a.yMeters;
    final dz = b.upMeters - a.upMeters;
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  bool _isPlausiblePoseStep(
    MappingPoint previous,
    MappingPoint candidate,
    double deltaMeters,
  ) {
    final deltaMs = candidate.timestampMs - previous.timestampMs;
    if (deltaMs <= 0) return true;

    final deltaSeconds = deltaMs / 1000.0;
    final allowed = math.min(
      _maxAcceptedPoseStepMeters,
      _poseJumpBaseMeters + _maxPlausibleWalkingSpeedMps * deltaSeconds,
    );
    return deltaMeters <= allowed;
  }

  String get _liveQualityLabel {
    if (_trackingInterruptions >= 3 || _rejectedPoseJumps >= 3) {
      return 'REVIEW';
    }
    if (_trackingInterruptions > 0 || _rejectedPoseJumps > 0) {
      return 'CAUTION';
    }
    return 'GOOD';
  }

  double get _distanceMeters => _recordedDistanceMeters;

  double get _heightDeltaMeters {
    if (_points.isEmpty) return 0;
    return _points.last.upMeters - _points.first.upMeters;
  }


  int _nearestPointIndex(double xMeters, double yMeters) {
    var bestIndex = 0;
    var bestDistanceSquared = double.infinity;

    for (var i = 0; i < _points.length; i++) {
      final dx = _points[i].xMeters - xMeters;
      final dy = _points[i].yMeters - yMeters;
      final distanceSquared = dx * dx + dy * dy;
      if (distanceSquared < bestDistanceSquared) {
        bestDistanceSquared = distanceSquared;
        bestIndex = i;
      }
    }

    return bestIndex;
  }

  String _uniqueVisualAnchorId(String label) {
    final base = label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final root = base.isEmpty ? 'anchor' : base;
    final used = <String>{
      for (final anchor in widget.venue.anchors) anchor.id,
      for (final marker in _markers) marker.id,
    };

    var candidate = root;
    var suffix = 2;
    while (used.contains(candidate)) {
      candidate = '${root}_$suffix';
      suffix++;
    }
    return candidate;
  }

  String _qrPayloadForAnchorId(String anchorId) {
    return Uri(
      scheme: 'arnav',
      host: 'anchor',
      queryParameters: <String, String>{
        'venue': widget.venue.id,
        'id': anchorId,
      },
    ).toString();
  }

  Future<Uint8List> _qrPngForAnchorId(String anchorId) async {
    final payload = _qrPayloadForAnchorId(anchorId);

    final painter = QrPainter(
      data: payload,
      version: QrVersions.auto,
      errorCorrectionLevel: QrErrorCorrectLevel.L,
      gapless: true,
      eyeStyle: const QrEyeStyle(
        eyeShape: QrEyeShape.square,
        color: Color(0xFF000000),
      ),
      dataModuleStyle: const QrDataModuleStyle(
        dataModuleShape: QrDataModuleShape.square,
        color: Color(0xFF000000),
      ),
    );

    final bytes = await painter.toImageData(
      512,
      format: ui.ImageByteFormat.png,
    );
    if (bytes == null) {
      throw StateError('Could not render QR preview.');
    }

    return bytes.buffer.asUint8List(
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
  }

  Future<void> _addMarker(String type) async {
    if (!_recording || _trackingInterrupted || _points.isEmpty) return;

    if (type == 'anchor') {
      await _addAnchorMarker();
      return;
    }

    final markerPoint = _points.last;
    final markerPointIndex = _points.length - 1;

    final defaultLabel = switch (type) {
      'destination' => 'Room / destination',
      'stairs' => 'Stairs to another floor',
      'anchor' => 'QR anchor checkpoint',
      _ => 'Junction / waypoint',
    };

    var draftLabel = defaultLabel;
    final label = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('Add ${type == 'waypoint' ? 'waypoint' : type}'),
          content: TextFormField(
            initialValue: defaultLabel,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Label'),
            onChanged: (value) => draftLabel = value,
            onFieldSubmitted: (value) {
              final trimmed = value.trim();
              if (trimmed.isNotEmpty) {
                Navigator.of(dialogContext).pop(trimmed);
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final value = draftLabel.trim();
                if (value.isNotEmpty) {
                  Navigator.of(dialogContext).pop(value);
                }
              },
              child: const Text('Add'),
            ),
          ],
        );
      },
    );

    if (!mounted || label == null) return;

    final idBase = label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');

    setState(() {
      _markers.add(
        MappingMarker(
          id: '${idBase.isEmpty ? type : idBase}_${_markers.length + 1}',
          label: label,
          type: type,
          floor: _floor,
          xMeters: markerPoint.xMeters,
          yMeters: markerPoint.yMeters,
          upMeters: markerPoint.upMeters,
          pointIndex: markerPointIndex,
        ),
      );
    });
  }

  Future<void> _addAnchorMarker() async {
    if (!_recording || _trackingInterrupted || _points.isEmpty) return;

    final markerPoint = _points.last;
    final markerPointIndex = _points.length - 1;
    final candidates = widget.venue.anchors
        .where(
          (anchor) =>
              anchor.floor == _floor &&
              anchor.id != _startAnchor?.id &&
              !_markers.any(
                (marker) => marker.referenceAnchorId == anchor.id,
              ),
        )
        .toList(growable: false);

    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No other deployed venue anchors are available on this floor yet.',
          ),
        ),
      );
      return;
    }

    final anchorId = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Link existing physical QR anchor'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              'Use this only while physically standing at an already-deployed '
              'anchor. It helps stitch this recording into the existing venue graph.',
            ),
          ),
          for (final anchor in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(anchor.id),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.qr_code_2_rounded),
                title: Text(anchor.label),
                subtitle: Text('Floor ${anchor.floor} • ${anchor.id}'),
              ),
            ),
        ],
      ),
    );

    if (!mounted || anchorId == null) return;
    final anchor = candidates.firstWhere((item) => item.id == anchorId);

    setState(() {
      _markers.add(
        MappingMarker(
          id: 'ref_${anchor.id}_${_markers.length + 1}',
          label: anchor.label,
          type: 'anchor',
          floor: _floor,
          xMeters: markerPoint.xMeters,
          yMeters: markerPoint.yMeters,
          upMeters: markerPoint.upMeters,
          pointIndex: markerPointIndex,
          referenceAnchorId: anchor.id,
        ),
      );
      _message =
          'Known physical anchor linked: ${anchor.label}. This recording can '
          'use it as an additional merge reference.';
    });
  }
  Future<void> _finishAndSave() async {
    if (_startCloudAnchorId == null || _startCloudAnchorId!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Start portal is not persistent yet. Lock the portal first.'),
        ),
      );
      return;
    }
    if (_placedStartQrId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Start location is missing. Restart mapping.')),
      );
      return;
    }

    if (!_recording || _points.length < 2 || _distanceMeters < 0.5) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Walk at least about 0.5 m before saving.'),
        ),
      );
      return;
    }

    final rawPointCount = _points.length;
    final simplified = const MappingPathSimplifier().simplify(
      points: _points,
      markers: _markers,
    );

    final now = DateTime.now();
    final session = MappingSession(
      id: 'spatial_floor_${_floor}_${now.millisecondsSinceEpoch}',
      venueId: widget.venue.id,
      venueName: widget.venue.name,
      floor: _floor,
      createdAt: now,
      startAnchorId: _startAnchor?.id,
      startAnchorLabel: _placedStartQrLabel ?? _startAnchor?.label,
      startCloudAnchorId: _startCloudAnchorId,
      originHeadingDegrees: 0,
      stepLengthMeters: 0,
      source: 'arcore_spatial',
      points: simplified.points,
      markers: simplified.markers,
      rawPointCount: rawPointCount,
      trackingInterruptions: _trackingInterruptions,
      rejectedPoseJumps: _rejectedPoseJumps,
    );

    try {
      final path = await _storage.save(session);
      final prettyJson = const JsonEncoder.withIndent(' ').convert(
        session.toJson(),
      );

      if (_arStarted) {
        await _ar.stop();
      }

      if (!mounted) return;
      setState(() {
        _arming = false;
        _awaitingStartQr = false;
        _recording = false;
        _trackingInterrupted = false;
        _arStarted = false;
        _trackingState = 'STOPPED';
        _savedPath = path;
        _savedJson = prettyJson;
        _pose = const ArPose(tracking: 'STOPPED');
        _placedStartQrId = null;
        _placedStartQrLabel = null;
        _startCloudAnchorId = null;
        _message =
            'Spatial mapping saved: $rawPointCount raw samples → '
            '${simplified.points.length} saved geometry points. '
            'Review quality before applying or merging.';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ARCore spatial mapping saved offline.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = 'Could not save mapping: $error');
    }
  }

  Future<void> _discardRecording() async {
    if (_arStarted) {
      await _ar.stop();
    }
    if (!mounted) return;
    setState(() {
      _arming = false;
      _awaitingStartQr = false;
      _recording = false;
      _trackingInterrupted = false;
      _arStarted = false;
      _trackingState = 'STOPPED';
      _trackingInterruptions = 0;
      _rejectedPoseJumps = 0;
      _consecutiveRejectedPoseJumps = 0;
      _recordedDistanceMeters = 0;
      _points.clear();
      _markers.clear();
      _placedStartQrId = null;
      _placedStartQrLabel = null;
      _startCloudAnchorId = null;
      _pose = const ArPose(tracking: 'STOPPED');
      _message = 'Spatial recording discarded.';
    });
  }

  Future<void> _copyJson() async {
    final value = _savedJson;
    if (value == null) return;
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Mapping JSON copied.')),
    );
  }

  Widget _markerButton(String type, IconData icon) {
    return OutlinedButton.icon(
      onPressed: (!_recording || _trackingInterrupted || _points.isEmpty)
          ? null
          : () => _addMarker(type),
      icon: Icon(icon, size: 18),
      label: Text(
        switch (type) {
          'destination' => 'Destination',
          'stairs' => 'Stairs',
          'anchor' => 'Anchor options',
          _ => 'Waypoint',
        },
      ),
    );
  }

  BoxDecoration _cardDecoration() {
    return BoxDecoration(
      color: const Color(0xFF111A2E),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0x223B82F6)),
    );
  }

  Widget _section(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white54,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Spatial Mapper',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 32),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF182641), Color(0xFF111A2E)],
              ),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0x3372A7FF)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ARCORE SPATIAL MAPPING',
                  style: TextStyle(
                    color: Color(0xFF9DBEF7),
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.1,
                  ),
                ),
                SizedBox(height: 10),
                Text(
                  'Drop a start portal, then walk.',
                  style: TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Place one floating QR portal at the route entrance. Once '
                  'it is saved, walk the path and mark the destination.',
                  style: TextStyle(color: Colors.white60, height: 1.45),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _section('START / FLOOR'),
          DropdownButtonFormField<String?>(
            key: ValueKey(_startAnchor?.id),
            initialValue: _startAnchor?.id,
            decoration: const InputDecoration(
              labelText: 'Route start / entrance',
              prefixIcon: Icon(Icons.view_in_ar_rounded),
            ),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('Create a new route start'),
              ),
              for (final anchor in widget.venue.anchors)
                DropdownMenuItem<String?>(
                  value: anchor.id,
                  child: Text(anchor.label),
                ),
            ],
            onChanged: _mappingActive || _starting
                ? null
                : (value) {
                    if (value == null) {
                      setState(() => _startAnchor = null);
                      return;
                    }
                    final anchor = widget.venue.anchors.firstWhere(
                      (item) => item.id == value,
                    );
                    setState(() {
                      _startAnchor = anchor;
                      _floor = anchor.floor;
                    });
                  },
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<int>(
            key: ValueKey(_floor),
            initialValue: _floor,
            decoration: const InputDecoration(
              labelText: 'Floor layer',
              prefixIcon: Icon(Icons.layers_rounded),
            ),
            items: [
              for (final floor in widget.venue.floors)
                DropdownMenuItem(
                  value: floor,
                  child: Text('Floor $floor'),
                ),
              if (!widget.venue.floors.contains(_floor))
                DropdownMenuItem(
                  value: _floor,
                  child: Text('Floor $_floor'),
                ),
            ],
            onChanged: _mappingActive || _starting
                ? null
                : (value) {
                    if (value != null) setState(() => _floor = value);
                  },
          ),
          const SizedBox(height: 18),
          _section('SPATIAL TRACKING'),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: _cardDecoration(),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _Metric(
                        label: 'ARCORE',
                        value: _availability.replaceAll('_', ' '),
                      ),
                    ),
                    Expanded(
                      child: _Metric(
                        label: 'TRACKING',
                        value: _trackingState.replaceAll('_', ' '),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _Metric(
                        label: 'DISTANCE',
                        value: '${_distanceMeters.toStringAsFixed(1)} m',
                      ),
                    ),
                    Expanded(
                      child: _Metric(
                        label: 'SAMPLES',
                        value: '${_points.length}',
                      ),
                    ),
                    Expanded(
                      child: _Metric(
                        label: 'MARKERS',
                        value: '${_markers.length}',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _Metric(
                        label: 'QUALITY',
                        value: _liveQualityLabel,
                      ),
                    ),
                    Expanded(
                      child: _Metric(
                        label: 'PAUSES',
                        value: '$_trackingInterruptions',
                      ),
                    ),
                    Expanded(
                      child: _Metric(
                        label: 'JUMPS BLOCKED',
                        value: '$_rejectedPoseJumps',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'X ${_pose.x.toStringAsFixed(2)} m  •  '
                        'Forward ${_pose.forward.toStringAsFixed(2)} m  •  '
                        'Up ${_pose.y.toStringAsFixed(2)} m',
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Height Δ ${_heightDeltaMeters.toStringAsFixed(2)} m  •  '
                        'Position geometry: ARCore',
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                SizedBox(
                  height: 310,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFF0E1729),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: CustomPaint(
                      painter: _SpatialPathPainter(
                        points: List<MappingPoint>.unmodifiable(_points),
                        markers: List<MappingMarker>.unmodifiable(_markers),
                        current: Offset(_pose.x, _pose.forward),
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Top-down position trace · turning in place rotates the '
                  'camera but does not create a path; physically walking a curve does.',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                if (_message != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _message!,
                    style: const TextStyle(
                      color: Color(0xFFF9D976),
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                if (!_mappingActive) ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: _green,
                        foregroundColor: Colors.black,
                      ),
                      onPressed:
                          _starting ? null : _startPersistentPortalRecording,
                      icon: _starting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.view_in_ar_rounded),
                      label: Text(
                        _starting ? 'STARTING AR...' : 'START MAPPING',
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Place the floating start QR portal once, lock it, then '
                    'walk the route and add the destination.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                ]
                else if (_awaitingStartQr) ...[
                  const Text(
                    'DO NOT WALK YET. Place the floating QR start portal in AR. '
                    'Recording begins automatically after the portal is saved.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFFF9D976),
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _discardRecording,
                      icon: const Icon(Icons.close_rounded),
                      label: const Text('CANCEL PORTAL'),
                    ),
                  ),
                ] else if (!_recording) ...[
                  const Text(
                    'DO NOT WALK YET. ARCore is acquiring a stable spatial '
                    'lock. Recording starts automatically when it is ready.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFFF9D976),
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _discardRecording,
                      icon: const Icon(Icons.close_rounded),
                      label: const Text('CANCEL'),
                    ),
                  ),
                ] else ...[
                  Text(
                    _trackingInterrupted
                        ? 'STOP WALKING until tracking recovers.'
                        : 'Recording is live. Walk naturally; add rooms, '
                            'junctions, stairs, and link existing physical '
                            'anchors only at real locations.',
                    style: TextStyle(
                      color: _trackingInterrupted
                          ? const Color(0xFFF9D976)
                          : Colors.white54,
                      fontSize: 11,
                      fontWeight: _trackingInterrupted
                          ? FontWeight.w800
                          : FontWeight.normal,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _markerButton('waypoint', Icons.add_road_rounded),
                      _markerButton('destination', Icons.flag_rounded),
                      _markerButton('stairs', Icons.stairs_rounded),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _discardRecording,
                          icon: const Icon(Icons.delete_outline_rounded),
                          label: const Text('DISCARD'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: _green,
                            foregroundColor: Colors.black,
                          ),
                          onPressed: _trackingInterrupted
                              ? null
                              : _finishAndSave,
                          icon: const Icon(Icons.save_rounded),
                          label: const Text('FINISH & SAVE'),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (_savedPath != null) ...[
            const SizedBox(height: 18),
            _section('SAVED OFFLINE'),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0x143DDC97),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0x333DDC97)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.check_circle_rounded, color: _green),
                      SizedBox(width: 8),
                      Text(
                        'ARCore mapping saved',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    _savedPath!,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 10,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _copyJson,
                    icon: const Icon(Icons.copy_rounded),
                    label: const Text('Copy mapping JSON'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Column(
        children: [
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 8,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _SpatialPathPainter extends CustomPainter {
  const _SpatialPathPainter({
    required this.points,
    required this.markers,
    required this.current,
  });

  final List<MappingPoint> points;
  final List<MappingMarker> markers;
  final Offset current;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = const Color(0x123A4B68)
      ..strokeWidth = 1;

    for (var x = 20.0; x < size.width; x += 40) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 20.0; y < size.height; y += 40) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final worldPoints = <Offset>[
      Offset.zero,
      ...points.map((p) => Offset(p.xMeters, p.yMeters)),
      current,
    ];

    var minX = worldPoints.first.dx;
    var maxX = worldPoints.first.dx;
    var minY = worldPoints.first.dy;
    var maxY = worldPoints.first.dy;

    for (final p in worldPoints.skip(1)) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }

    const pad = 40.0;
    final spanX = math.max(2.0, maxX - minX);
    final spanY = math.max(2.0, maxY - minY);
    final scale = math.min(
      (size.width - pad * 2) / spanX,
      (size.height - pad * 2) / spanY,
    );

    final centerWorld = Offset((minX + maxX) / 2, (minY + maxY) / 2);
    final centerScreen = Offset(size.width / 2, size.height / 2);

    Offset project(Offset p) {
      final dx = (p.dx - centerWorld.dx) * scale;
      final dy = (p.dy - centerWorld.dy) * scale;
      return Offset(centerScreen.dx + dx, centerScreen.dy - dy);
    }

    if (points.length > 1) {
      final path = Path();
      final first = project(Offset(points.first.xMeters, points.first.yMeters));
      path.moveTo(first.dx, first.dy);
      for (final point in points.skip(1)) {
        final p = project(Offset(point.xMeters, point.yMeters));
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF56C7FF)
          ..strokeWidth = 5
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    final origin = project(Offset.zero);
    canvas.drawCircle(origin, 7, Paint()..color = const Color(0xFF3DDC97));

    for (final marker in markers) {
      final p = project(Offset(marker.xMeters, marker.yMeters));
      final color = switch (marker.type) {
        'destination' => const Color(0xFFFF6B8A),
        'stairs' => const Color(0xFFF9C74F),
        'anchor' => const Color(0xFF3DDC97),
        _ => const Color(0xFFCBA6F7),
      };
      canvas.drawCircle(p, 7, Paint()..color = color);
    }

    final currentPoint = project(current);
    canvas.drawCircle(
      currentPoint,
      9,
      Paint()..color = const Color(0xFFFF6B8A),
    );
    canvas.drawCircle(
      currentPoint,
      14,
      Paint()
        ..color = const Color(0x66FF6B8A)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _SpatialPathPainter oldDelegate) => true;
}
