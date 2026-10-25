import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/anchor_point.dart';
import '../models/mapping_session.dart';
import '../models/venue.dart';
import '../services/anchor_codec.dart';
import '../services/ar_pose_service.dart';
import '../services/mapping_storage.dart';
import 'mapping_screen.dart';
import 'qr_anchor_scanner_screen.dart';

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

  final ArPoseService _ar = const ArPoseService();
  final MappingStorage _storage = const MappingStorage();
  final AnchorCodec _anchorCodec = const AnchorCodec();

  StreamSubscription<ArPose>? _poseSubscription;

  AnchorPoint? _startAnchor;
  int _floor = 1;

  String _availability = 'CHECKING';
  ArPose _pose = const ArPose(tracking: 'STOPPED');

  bool _starting = false;
  bool _arStarted = false;
  bool _arming = false;
  bool _awaitingFreshOrigin = false;
  bool _recording = false;
  bool _trackingInterrupted = false;

  int _stablePoseSamples = 0;
  int _recoveryPoseSamples = 0;
  int _lastUiRefreshMs = 0;
  double _recordedDistanceMeters = 0;

  String _trackingState = 'STOPPED';

  final List<MappingPoint> _points = <MappingPoint>[];
  final List<MappingMarker> _markers = <MappingMarker>[];

  String? _message;
  String? _savedPath;
  String? _savedJson;

  bool get _mappingActive =>
      _arming || _awaitingFreshOrigin || _recording;

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

  Future<void> _scanStartAnchor() async {
    if (_mappingActive || _starting) return;

    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => const QrAnchorScannerScreen(),
      ),
    );
    if (!mounted || raw == null) return;

    try {
      final anchor = _anchorCodec.resolve(
        venue: widget.venue,
        rawValue: raw,
      );
      setState(() {
        _startAnchor = anchor;
        _floor = anchor.floor;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Spatial origin: ${anchor.label}')),
      );
    } on FormatException catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    }
  }

  Future<void> _startSpatialRecording() async {
    if (_starting || _mappingActive) return;

    setState(() {
      _starting = true;
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
          _message = 'Camera permission is required for ARCore spatial mapping.';
        });
        return;
      }

      if (_arStarted) {
        await _ar.stop();
        _arStarted = false;
      }

      final result = await _ar.start();
      if (!mounted) return;

      if (result == 'INSTALL_REQUESTED') {
        setState(() {
          _starting = false;
          _message =
              'Google Play Services for AR needs installation/update. '
              'Return here and start again afterward.';
        });
        return;
      }

      if (result != 'STARTED') {
        setState(() {
          _starting = false;
          _message = 'Could not start ARCore: $result';
        });
        return;
      }

      setState(() {
        _arStarted = true;
        _arming = true;
        _awaitingFreshOrigin = false;
        _recording = false;
        _trackingInterrupted = false;
        _stablePoseSamples = 0;
        _recoveryPoseSamples = 0;
        _recordedDistanceMeters = 0;
        _starting = false;
        _trackingState = 'ACQUIRING';
        _pose = const ArPose(tracking: 'INITIALIZING');
        _points.clear();
        _markers.clear();
        _message =
            'WAIT — do not walk yet. Hold the phone naturally and point the '
            'rear camera at a textured, well-lit area while ARCore locks on.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _message = 'Could not start spatial mapping: $error';
      });
    }
  }

  void _onPose(ArPose pose) {
    if (!mounted) return;

    final hasRealPose = pose.isTracking && pose.timestampNanos > 0;
    final stateChanged = _trackingState != pose.tracking;
    _trackingState = pose.tracking;

    // Status-only events (PAUSED, RESETTING_ORIGIN, etc.) do not contain
    // coordinates. Keep the last good pose on screen instead of snapping
    // X/Forward back to zero.
    if (!hasRealPose) {
      _stablePoseSamples = 0;

      if (_recording && pose.tracking == 'PAUSED') {
        _trackingInterrupted = true;
        _recoveryPoseSamples = 0;
        _message =
            'TRACKING LOST — stop walking. '
            '${pose.errorMessage ?? 'Hold the phone steady and aim at visible detail.'}';
      } else if (_arming && pose.tracking == 'PAUSED') {
        _message =
            'WAIT — ARCore has not locked yet. '
            '${pose.errorMessage ?? 'Move the phone slowly and aim at visible detail.'}';
      } else if (pose.errorMessage != null) {
        _message = pose.errorMessage;
      }

      _refreshUi(force: stateChanged || pose.errorMessage != null);
      return;
    }

    _pose = pose;

    // Initial acquisition: demand several consecutive good poses before
    // allowing mapping to begin. Once stable, reset the native local origin
    // exactly where the user is standing.
    if (_arming) {
      _stablePoseSamples++;

      if (_stablePoseSamples >= _stablePoseSamplesRequired) {
        _arming = false;
        _awaitingFreshOrigin = true;
        _trackingState = 'LOCKED';
        _message =
            'Tracking locked. Hold still for a moment while the mapping origin '
            'is set here.';
        unawaited(_resetOriginAndBegin());
        _refreshUi(force: true);
        return;
      }

      _trackingState =
          'LOCKING $_stablePoseSamples/$_stablePoseSamplesRequired';
      _message =
          'WAIT — keep the phone steady. Mapping starts only after a stable '
          'ARCore lock.';
      _refreshUi();
      return;
    }

    // resetArOrigin() clears the native frame. Do not record an old pose that
    // raced with the reset command.
    if (_awaitingFreshOrigin) {
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
      _trackingState = 'TRACKING';
      _message = 'Tracking recovered. Continue walking.';
      _refreshUi(force: true);
    }

    if (_recording) {
      final candidate = _mappingPointFromPose(pose);

      if (_points.isEmpty) {
        _points.add(candidate);
      } else {
        final delta = _distance3d(_points.last, candidate);
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

  Future<void> _resetOriginAndBegin() async {
    try {
      await _ar.resetOrigin();
      if (!mounted || !_awaitingFreshOrigin) return;

      // Give the next real TRACKING pose ownership of the freshly reset frame.
      // The next EventChannel pose arrives at ~20 Hz.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (!mounted || !_awaitingFreshOrigin) return;

      setState(() {
        _awaitingFreshOrigin = false;
        _recording = true;
        _trackingInterrupted = false;
        _recordedDistanceMeters = 0;
        _points.clear();
        _markers.clear();
        _trackingState = 'READY';
        _message =
            'READY — start walking now. If tracking pauses, stop walking until '
            'the app says it has recovered.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _arming = false;
        _awaitingFreshOrigin = false;
        _recording = false;
        _trackingState = 'ERROR';
        _message = 'Could not set mapping origin: $error';
      });
    }
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

  double get _distanceMeters => _recordedDistanceMeters;

  double get _heightDeltaMeters {
    if (_points.isEmpty) return 0;
    return _points.last.upMeters - _points.first.upMeters;
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

    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add anchor checkpoint'),
        content: const Text(
          'Reference an existing venue anchor when you are physically standing '
          'at that known location. This gives later spatial merges a second '
          'point for rotation + translation. Create a new anchor when this is '
          'a brand-new checkpoint.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('new'),
            child: const Text('Create new'),
          ),
          FilledButton(
            onPressed: candidates.isEmpty
                ? null
                : () => Navigator.of(dialogContext).pop('reference'),
            child: const Text('Reference existing'),
          ),
        ],
      ),
    );

    if (!mounted || action == null) return;

    if (action == 'new') {
      await _addNewAnchorMarker(
        markerPoint: markerPoint,
        markerPointIndex: markerPointIndex,
      );
      return;
    }

    final anchorId = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Which known anchor is here?'),
        children: [
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
          'Known anchor linked: ${anchor.label}. This recording now has an '
          'orientation reference for venue alignment.';
    });
  }

  Future<void> _addNewAnchorMarker({
    required MappingPoint markerPoint,
    required int markerPointIndex,
  }) async {
    var draftLabel = 'QR anchor checkpoint';
    final label = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create new anchor'),
        content: TextFormField(
          initialValue: draftLabel,
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
      ),
    );

    if (!mounted || label == null) return;
    final idBase = label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');

    setState(() {
      _markers.add(
        MappingMarker(
          id: '${idBase.isEmpty ? 'anchor' : idBase}_${_markers.length + 1}',
          label: label,
          type: 'anchor',
          floor: _floor,
          xMeters: markerPoint.xMeters,
          yMeters: markerPoint.yMeters,
          upMeters: markerPoint.upMeters,
          pointIndex: markerPointIndex,
        ),
      );
    });
  }

  Future<void> _finishAndSave() async {
    if (!_recording || _points.length < 2 || _distanceMeters < 0.5) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Walk at least about 0.5 m before saving.'),
        ),
      );
      return;
    }

    final now = DateTime.now();
    final session = MappingSession(
      id: 'spatial_floor_${_floor}_${now.millisecondsSinceEpoch}',
      venueId: widget.venue.id,
      venueName: widget.venue.name,
      floor: _floor,
      createdAt: now,
      startAnchorId: _startAnchor?.id,
      startAnchorLabel: _startAnchor?.label,
      originHeadingDegrees: 0,
      stepLengthMeters: 0,
      source: 'arcore_spatial',
      points: List<MappingPoint>.unmodifiable(_points),
      markers: List<MappingMarker>.unmodifiable(_markers),
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
        _awaitingFreshOrigin = false;
        _recording = false;
        _trackingInterrupted = false;
        _arStarted = false;
        _trackingState = 'STOPPED';
        _savedPath = path;
        _savedJson = prettyJson;
        _pose = const ArPose(tracking: 'STOPPED');
        _message =
            'Spatial mapping saved. Review it, then Apply or Merge it into '
            'the active venue.';
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
      _awaitingFreshOrigin = false;
      _recording = false;
      _trackingInterrupted = false;
      _arStarted = false;
      _trackingState = 'STOPPED';
      _recordedDistanceMeters = 0;
      _points.clear();
      _markers.clear();
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

  Future<void> _openLegacyMapper() async {
    if (_mappingActive || _starting) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MappingScreen(
          venue: widget.venue,
          initialAnchor: _startAnchor,
        ),
      ),
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
          'anchor' => 'QR anchor',
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
                  'Walk the real path once.',
                  style: TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'ARCore records the phone position directly in meters. '
                  'No compass heading or step-length integration is used to '
                  'shape a spatial recording.',
                  style: TextStyle(color: Colors.white60, height: 1.45),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _section('START / FLOOR'),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String?>(
                  key: ValueKey(_startAnchor?.id),
                  initialValue: _startAnchor?.id,
                  decoration: const InputDecoration(
                    labelText: 'Start anchor',
                    prefixIcon: Icon(Icons.qr_code_2_rounded),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('No QR anchor / local origin'),
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
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: 'Scan start anchor',
                onPressed: _mappingActive || _starting ? null : _scanStartAnchor,
                icon: const Icon(Icons.qr_code_scanner_rounded),
              ),
            ],
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
                if (!_mappingActive)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _starting ? null : _startSpatialRecording,
                      icon: _starting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.view_in_ar_rounded),
                      label: Text(
                        _starting
                            ? 'STARTING ARCORE...'
                            : 'START SPATIAL MAPPING',
                      ),
                    ),
                  )
                else if (!_recording) ...[
                  const Text(
                    'DO NOT WALK YET. Mapping begins only after ARCore has a '
                    'stable visual lock and the local origin is reset.',
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
                        : 'Recording is live. Walk naturally and add semantic '
                            'markers only at real locations.',
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
                      _markerButton('anchor', Icons.qr_code_2_rounded),
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
          const SizedBox(height: 18),
          _section('LEGACY / DEBUG'),
          OutlinedButton.icon(
            onPressed: _mappingActive || _starting ? null : _openLegacyMapper,
            icon: const Icon(Icons.directions_walk_rounded),
            label: const Text('OPEN STEP + COMPASS MAPPER'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Legacy mapping is kept only for fallback/testing. New venue '
            'geometry should be captured with ARCore Spatial Mapping.',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 11,
              height: 1.4,
            ),
          ),
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
