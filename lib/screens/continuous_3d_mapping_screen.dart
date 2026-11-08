import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/mapping_session.dart';
import '../models/venue.dart';
import '../services/ar_pose_service.dart';
import '../services/continuous_3d_trace.dart';
import '../services/mapping_path_simplifier.dart';
import '../services/mapping_storage.dart';

/// V10 experiment: record a REAL 3D trajectory in ONE running ARCore world.
///
/// This deliberately does NOT apply a floor-flattened venue override or
/// pretend that separate saved 2D floors already share a 6DoF alignment.
class Continuous3DMappingScreen extends StatefulWidget {
  const Continuous3DMappingScreen({
    super.key,
    required this.venue,
    required this.startFloor,
  });

  final Venue venue;
  final int startFloor;

  @override
  State<Continuous3DMappingScreen> createState() =>
      _Continuous3DMappingScreenState();
}

class _Continuous3DMappingScreenState
    extends State<Continuous3DMappingScreen> {
  static const _blue = Color(0xFF66B7FF);
  static const _green = Color(0xFF3DDC97);
  static const _requiredStableSamples = 10;

  final _ar = const ArPoseService();
  final _storage = const MappingStorage();
  StreamSubscription<ArPose>? _poses;

  final List<MappingPoint> _points = [];
  final List<MappingMarker> _markers = [];
  ArPose _pose = const ArPose(tracking: 'STOPPED');
  int _floor = 1;
  int _stableSamples = 0;
  int _recoverySamples = 0;
  bool _automaticRecoveryPending = false;
  int _trackingInterruptions = 0;
  int _rejectedJumps = 0;
  int _lastRefreshMs = 0;
  bool _starting = false;
  bool _arStarted = false;
  bool _recording = false;
  bool _paused = false;
  bool _trackingInterrupted = false;
  bool _busy = false;
  String _message =
      'Start once at a known corridor on the lower floor. Keep the same '
      'ARCore session running while you climb and reach the upper floor.';
  String? _savedId;
  // Every recording has a stable ID. Periodic local drafts are overwritten by
  // the final saved route, so a crash never creates dozens of orphan files.
  String? _recordingId;
  DateTime? _recordingStartedAt;
  Future<void>? _pendingDraftSave;
  bool _draftSaving = false;
  int _lastDraftSaveMs = 0;
  int _draftSavedPoints = 0;
  String? _draftError;

  @override
  void initState() {
    super.initState();
    _floor = widget.startFloor;
    _poses = _ar.poses.listen(_onPose, onError: (Object error) {
      if (!mounted) return;
      setState(() => _message = 'ARCore event: $error');
    });
  }

  @override
  void dispose() {
    _poses?.cancel();
    if (_arStarted) unawaited(_ar.stop());
    super.dispose();
  }

  String _floorName(int floor) =>
      floor < 0 ? 'Basement ${floor.abs()}' : 'Floor $floor';

  MappingPoint _pointFrom(ArPose pose) => MappingPoint(
        xMeters: pose.x,
        yMeters: pose.forward,
        upMeters: pose.y,
        headingDegrees: 0,
        stepIndex: _points.length,
        timestampMs: pose.timestampNanos ~/ 1000000,
      );

  double _distance(MappingPoint a, MappingPoint b) {
    final dx = b.xMeters - a.xMeters;
    final dy = b.yMeters - a.yMeters;
    final dz = b.upMeters - a.upMeters;
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  void _refresh({bool force = false}) {
    if (!mounted) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (force || now - _lastRefreshMs >= 125) {
      _lastRefreshMs = now;
      setState(() {});
    }
  }

  void _onPose(ArPose pose) {
    if (!mounted || !_arStarted) return;
    final real = pose.isTracking && pose.timestampNanos > 0;
    if (!real) {
      if (_recording && !_trackingInterrupted &&
          pose.tracking == 'PAUSED') {
        _trackingInterruptions++;
        _trackingInterrupted = true;
        _paused = true;
        _automaticRecoveryPending = true;
        _recoverySamples = 0;
        _message =
            'TRACKING PAUSED — the saved path is protected. '
            'Hold steady near your last location; recording will resume '
            'automatically only if ARCore returns to that same 3D point.';
        _refresh(force: true);
      }
      return;
    }

    _pose = pose;
    if (_starting && !_recording) {
      _stableSamples++;
      if (_stableSamples >= _requiredStableSamples) {
        _recording = true;
        _starting = false;
        _points
          ..clear()
          ..add(_pointFrom(pose));
        _markers.clear();
        _message =
            'RECORDING 3D. Keep walking naturally through the real staircase '
            'without closing this screen. No QR, no floor reset.';
      }
      _refresh(force: _recording);
      return;
    }
    if (!_recording) return;
    if (_trackingInterrupted) {
      final gap = _points.isEmpty
          ? double.infinity
          : _distance(_points.last, _pointFrom(pose));
      if (gap <= 0.80) {
        _recoverySamples++;
      } else {
        _recoverySamples = 0;
      }
      if (_recoverySamples >= 6) {
        _trackingInterrupted = false;
        if (_automaticRecoveryPending) {
          _paused = false;
          _message =
              'TRACKING RESTORED at the same physical point. '
              '3D recording resumed automatically; no staircase gap added.';
        } else {
          _message = 'Tracking restored. Press RESUME when ready.';
        }
        _automaticRecoveryPending = false;
        _recoverySamples = 0;
        _refresh(force: true);
      } else if (gap > 1.20) {
        _message =
            'ARCore recovered but shifted ${gap.toStringAsFixed(1)} m '
            'from the last trusted sample. Path stays stopped to avoid '
            'a false staircase. You can FINISH & SAVE the safe portion '
            'instead of losing your entire recording.';
        _refresh();
      } else {
        _refresh();
      }
      return;
    }
    if (_paused) {
      _refresh();
      return;
    }
    final next = _pointFrom(pose);
    if (_points.isEmpty) {
      _points.add(next);
      _refresh(force: true);
      return;
    }
    final previous = _points.last;
    final delta = _distance(previous, next);
    final elapsed = (next.timestampMs - previous.timestampMs) / 1000.0;
    if (delta > 1.5 ||
        (elapsed > 0 && delta > 0.35 + 3.0 * elapsed)) {
      _rejectedJumps++;
      _paused = true;
      _trackingInterrupted = true;
      _automaticRecoveryPending = true;
      _recoverySamples = 0;
      _message =
          'SUDDEN ARCORE JUMP rejected (${delta.toStringAsFixed(1)} m). '
          'Hold steady: tracking resumes itself if it returns to the '
          'last trusted location. Otherwise SAVE the safe part of this route.';
      _refresh(force: true);
      return;
    }
    if (delta >= 0.10 && next.timestampMs > previous.timestampMs) {
      if (_points.length >= 12000) {
        _paused = true;
        _message = 'Recording limit reached. Save this route.';
      } else {
        _points.add(next);
        _autoSaveDraft();
      }
    }
    _refresh();
  }

  MappingSession _sessionSnapshot({
    required List<MappingPoint> points,
    required List<MappingMarker> markers,
    required bool isDraft,
    required int rawPointCount,
  }) {
    final id = _recordingId;
    final created = _recordingStartedAt;
    if (id == null || created == null) {
      throw StateError('Recording identity is not initialized.');
    }
    return MappingSession(
      id: id,
      venueId: widget.venue.id,
      venueName: widget.venue.name,
      floor: widget.startFloor,
      createdAt: created,
      startAnchorId: null,
      startAnchorLabel:
          '${_floorName(widget.startFloor)} live 3D session origin',
      originHeadingDegrees: 0,
      stepLengthMeters: 0,
      source: isDraft ? 'arcore_spatial_3d_draft' : 'arcore_spatial_3d',
      points: points,
      markers: markers,
      rawPointCount: rawPointCount,
      trackingInterruptions: _trackingInterruptions,
      rejectedPoseJumps: _rejectedJumps,
    );
  }

  void _autoSaveDraft({bool force = false}) {
    if (!_recording || _busy || _draftSaving || _points.length < 3 ||
        _recordingId == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastDraftSaveMs < 10000) return;
    if (!force && _points.length == _draftSavedPoints) return;

    _draftSaving = true;
    _lastDraftSaveMs = now;
    final pointCount = _points.length;
    final snapshot = _sessionSnapshot(
      points: List<MappingPoint>.unmodifiable(_points),
      markers: List<MappingMarker>.unmodifiable(_markers),
      isDraft: true,
      rawPointCount: pointCount,
    );
    _pendingDraftSave = _persistDraft(snapshot, pointCount);
  }

  Future<void> _persistDraft(MappingSession snapshot, int count) async {
    try {
      await _storage.save(snapshot);
      _draftSavedPoints = count;
      _draftError = null;
    } catch (error) {
      _draftError = error.toString();
    } finally {
      _draftSaving = false;
      _refresh();
    }
  }

  Future<void> _startRecording() async {
    if (_starting || _arStarted || _busy) return;
    setState(() {
      _starting = true;
      _stableSamples = 0;
      _recording = false;
      _paused = false;
      _trackingInterrupted = false;
      _recoverySamples = 0;
      _automaticRecoveryPending = false;
      _floor = widget.startFloor;
      _trackingInterruptions = 0;
      _rejectedJumps = 0;
      _savedId = null;
      _recordingStartedAt = DateTime.now();
      _recordingId =
          'continuous3d_${_recordingStartedAt!.microsecondsSinceEpoch}';
      _lastDraftSaveMs = DateTime.now().millisecondsSinceEpoch;
      _draftSavedPoints = 0;
      _draftError = null;
      _pendingDraftSave = null;
      _draftSaving = false;
      _points.clear();
      _markers.clear();
      _message = 'Checking camera and starting continuous ARCore tracking...';
    });
    try {
      final granted = await _ar.ensureCameraPermission();
      if (!granted) {
        if (mounted) setState(() {
          _starting = false;
          _message = 'Camera permission is required for this experiment.';
        });
        return;
      }
      final status = await _ar.start();
      if (!mounted) return;
      if (status != 'STARTED') {
        setState(() {
          _starting = false;
          _message = 'ARCore could not start: $status';
        });
        return;
      }
      setState(() {
        _arStarted = true;
        _message = 'Hold steady until ARCore is stable: '
            '0/$_requiredStableSamples tracking samples.';
      });
    } catch (error) {
      if (mounted) setState(() {
        _starting = false;
        _message = 'Failed to start 3D capture: $error';
      });
    }
  }

  void _togglePause() {
    if (!_recording || _busy) return;
    if (!_paused) {
      setState(() {
        _paused = true;
        _automaticRecoveryPending = false;
        _message =
            'Paused. The same ARCore session is still tracking. '
            'Do NOT move far away before resuming a continuous path.';
      });
      return;
    }
    if (!_pose.isTracking || _trackingInterrupted || _points.isEmpty) return;
    final gap = _distance(_points.last, _pointFrom(_pose));
    if (gap > 1.2) {
      setState(() {
        _message =
            'Cannot resume: ${gap.toStringAsFixed(1)} m from the last '
            'recorded point. Walk back. V10 never invents a staircase '
            'connection across a tracking gap.';
      });
      return;
    }
    setState(() {
      _paused = false;
      _message = 'Continuous 3D recording resumed in the same ARCore frame.';
    });
  }

  // One tap at a known landing; NO keyboard, route reset, or interruption.
  // A floor marker is OPTIONAL metadata — measured XYZ is already recorded.
  void _markNextFloor() {
    if (!_recording || _paused || _trackingInterrupted || _points.isEmpty) {
      return;
    }
    final next = _floor == -1 ? 1 : _floor + 1;
    final last = _points.last;
    setState(() {
      _floor = next;
      _markers.add(MappingMarker(
        id: 'v10_level_${_markers.length + 1}_$next',
        label: 'Reached ${_floorName(next)}',
        type: 'floor_level',
        floor: next,
        xMeters: last.xMeters,
        yMeters: last.yMeters,
        upMeters: last.upMeters,
        pointIndex: _points.length - 1,
      ));
      _message = '${_floorName(next)} noted at relative height '
          '${last.upMeters.toStringAsFixed(1)} m. '
          'Mapping continues in the SAME ARCore session.';
    });
    _autoSaveDraft(force: true);
  }

  void _undoLastFloor() {
    if (!_recording || _markers.isEmpty) return;
    final last = _markers.last;
    if (last.type != 'floor_level') return;
    setState(() {
      _markers.removeLast();
      _floor = _markers.where((m) => m.type == 'floor_level').isEmpty
          ? widget.startFloor
          : _markers.last.floor;
      _message = 'Last floor label removed. Recorded XYZ samples unchanged.';
    });
    _autoSaveDraft(force: true);
  }

  Future<void> _previewInAr() async {
    if (!_recording || _trackingInterrupted ||
        _points.length < 3 || _busy) {
      return;
    }
    // Opening the native live preview automatically pauses the recording:
    // the user never needs to perform a separate pause step.
    final wasPaused = _paused;
    setState(() {
      _busy = true;
      _paused = true;
      _automaticRecoveryPending = false;
    });
    try {
      final simplified = const MappingPathSimplifier().simplify(
        points: _points,
        markers: _markers,
        toleranceMeters: 0.13,
      );
      final preview = Continuous3DTrace.toLivePreviewPoints(
        points: simplified.points,
        markers: simplified.markers,
        segmentStarts: simplified.segmentStarts,
      );
      final status = await _ar.previewContinuous3dTrace(preview);
      if (!mounted) return;
      setState(() {
        if (status != 'PREVIEW_STARTED') _paused = wasPaused;
        _message = status == 'PREVIEW_STARTED'
            ? '3D TRACE PREVIEW: look around and back toward the stairs. '
              'BACK TO MAPPER preserves the ARCore session; resume or save next.'
            : 'Could not preview in AR: $status';
      });
    } catch (error) {
      if (mounted) setState(() {
        _paused = wasPaused;
        _message = '3D preview error: $error';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveAndStop() async {
    if (!_recording || _busy) return;
    final wasPaused = _paused;
    setState(() {
      _busy = true;
      _paused = true;
    });
    try {
      // A background draft must finish writing BEFORE the final recording
      // overwrites the same file ID. Never save stale points over the final.
      await _pendingDraftSave;
      final simplified = const MappingPathSimplifier().simplify(
        points: _points,
        markers: _markers,
        toleranceMeters: 0.10,
      );
      final analysis = Continuous3DTrace.analyze(
        points: simplified.points,
        markers: simplified.markers,
        segmentStarts: simplified.segmentStarts,
        startFloor: widget.startFloor,
      );
      if (analysis.pathMeters < 2.0) {
        throw StateError('Walk at least 2 metres of actual 3D route.');
      }
      final session = _sessionSnapshot(
        points: simplified.points,
        markers: simplified.markers,
        isDraft: false,
        rawPointCount: _points.length,
      );
      await _storage.save(session);
      if (_arStarted) await _ar.stop();
      if (!mounted) return;
      setState(() {
        _arStarted = false;
        _recording = false;
        _starting = false;
        _paused = false;
        _automaticRecoveryPending = false;
        _trackingInterrupted = false;
        _savedId = session.id;
        _message = 'SAVED CONTINUOUS 3D ROUTE: '
            '${analysis.pathMeters.toStringAsFixed(1)} m path, '
            '${analysis.netHeightMeters.toStringAsFixed(1)} m height delta, '
            '${analysis.visitedFloors.length} labeled floor(s). '
            'The XYZ geometry is saved separately; NO existing floor '
            'map or QR anchor was modified. Reopening AR accurately in a '
            'different session is a later localization milestone.';
      });
    } catch (error) {
      if (mounted) setState(() {
        _paused = wasPaused;
        _message = 'Cannot save 3D route: $error';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _discard() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _pendingDraftSave;
      if (_arStarted) await _ar.stop();
      final id = _recordingId;
      if (id != null && _draftSavedPoints > 0) {
        // Explicit discard should remove the last offline draft too.
        await _storage.delete(id);
      }
      if (!mounted) return;
      setState(() {
        _arStarted = false;
        _starting = false;
        _recording = false;
        _paused = false;
        _trackingInterrupted = false;
        _automaticRecoveryPending = false;
        _points.clear();
        _markers.clear();
        _message = '3D recording discarded. Existing venue unchanged.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = _points.isEmpty ? 0.0
        : _points.last.upMeters - _points.first.upMeters;
    final summary = _points.length >= 2
        ? Continuous3DTrace.analyze(
            points: _points,
            markers: _markers,
            startFloor: widget.startFloor,
          )
        : null;
    final status = _trackingInterrupted
        ? 'TRACKING UNCERTAIN'
        : _paused ? 'PAUSED'
        : _recording ? 'RECORDING 3D'
        : _starting ? 'LOCKING $_stableSamples/$_requiredStableSamples'
        : 'STOPPED';

    return Scaffold(
      appBar: AppBar(
        title: const Text('V10 • Continuous 3D'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 30),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'ONE ARCORE SESSION • REAL XYZ PATH',
                    style: TextStyle(
                      color: _blue, fontWeight: FontWeight.w900, fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Corridor → Staircase → Upstairs',
                    style: TextStyle(
                      fontWeight: FontWeight.w900, fontSize: 21,
                    ),
                  ),
                  const SizedBox(height: 9),
                  Text(
                    'START → WALK → FINISH & SAVE. '
                    'Keep ARCore running through the actual stairs. '
                    'Floor labels are optional: one tap at a landing, '
                    'without keyboard dialogs or re-calibration.',
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'EXPERIMENT: saved 3D geometry is NOT automatically '
                    're-localizable after ARCore restarts and does not '
                    'overwrite the old 2D venue graph.',
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 9,
            children: [
              _metric('STATUS', status),
              _metric('CURRENT', _floorName(_floor)),
              _metric('HEIGHT DELTA', '${height.toStringAsFixed(1)} m'),
              _metric('PATH', '${(summary?.pathMeters ?? 0).toStringAsFixed(1)} m'),
              _metric('SAMPLES', '${_points.length}'),
              _metric('TRACKING PAUSES', '$_trackingInterruptions'),
            ],
          ),
          const SizedBox(height: 13),
          const Text(
            'MEASURED ELEVATION PROFILE',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Container(
            height: 184,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: const Color(0xFF0D1527),
            ),
            padding: const EdgeInsets.all(12),
            child: CustomPaint(
              painter: _ElevationProfile(
                points: List.unmodifiable(_points),
                floorMarkers: List.unmodifiable(_markers),
              ),
              child: const SizedBox.expand(),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Ascent: ${(summary?.ascentMeters ?? 0).toStringAsFixed(1)} m '
            '• Descent: ${(summary?.descentMeters ?? 0).toStringAsFixed(1)} m'
            ' • Marked floors: ${summary?.visitedFloors.map(_floorName).join(' → ') ?? _floorName(_floor)}',
            style: const TextStyle(color: Colors.white60, fontSize: 11),
          ),
          const SizedBox(height: 14),
          Card(
            color: _trackingInterrupted
                ? const Color(0x553F2814) : null,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(_message, style: const TextStyle(height: 1.45)),
            ),
          ),
          if (_recording) ...[
            const SizedBox(height: 6),
            Text(
              _draftError != null
                  ? 'Offline draft not saved: $_draftError'
                  : _draftSavedPoints > 0
                      ? 'Offline safety copy: $_draftSavedPoints points saved'
                      : 'Offline safety copy starts automatically after recording.',
              style: TextStyle(
                color: _draftError == null
                    ? const Color(0xFF3DDC97)
                    : const Color(0xFFFFC978),
                fontSize: 11,
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (!_arStarted && !_starting) ...[
            FilledButton.icon(
              onPressed: _busy ? null : _startRecording,
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(_savedId == null
                  ? 'START CONTINUOUS 3D RECORDING'
                  : 'RECORD ANOTHER 3D ROUTE'),
            ),
            if (_savedId != null) ...[
              const SizedBox(height: 9),
              const Text(
                'Saved offline. View the trace in Saved Mappings. '
                'It is protected from APPLY TO FLOOR until V11.',
                style: TextStyle(color: _green),
              ),
            ],
          ] else if (_starting) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 10),
            Text(
              'Stabilizing ARCore: $_stableSamples/$_requiredStableSamples',
            ),
            TextButton(
              onPressed: _busy ? null : _discard,
              child: const Text('CANCEL'),
            ),
          ] else if (_recording) ...[
            FilledButton.icon(
              onPressed: _busy || _trackingInterrupted ? null : _togglePause,
              icon: Icon(_paused
                  ? Icons.play_arrow_rounded : Icons.pause_rounded),
              label: Text(_paused ? 'RESUME NEAR LAST POINT'
                  : 'PAUSE RECORDING (OPTIONAL)'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy || _paused || _trackingInterrupted
                  ? null : _markNextFloor,
              icon: const Icon(Icons.layers_rounded),
              label: const Text('REACHED NEXT FLOOR (OPTIONAL)'),
            ),
            if (_markers.any((m) => m.type == 'floor_level')) ...[
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: _busy ? null : _undoLastFloor,
                icon: const Icon(Icons.undo_rounded),
                label: const Text('UNDO LAST FLOOR LABEL'),
              ),
            ],
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: !_trackingInterrupted && !_busy &&
                      _points.length >= 3
                  ? _previewInAr : null,
              icon: const Icon(Icons.view_in_ar_rounded),
              label: const Text('PREVIEW 3D LINE IN LIVE AR'),
            ),
            const SizedBox(height: 5),
            const Text(
              'Preview pauses automatically; no separate PAUSE tap. '
              'Return to mapper to RESUME or SAVE. '
              'Do not interact with the phone while on the stairs.',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _busy || _points.length < 2
                  ? null : _saveAndStop,
              icon: const Icon(Icons.save_rounded),
              label: Text(_trackingInterrupted
                  ? 'SAVE TRUSTED ROUTE SO FAR'
                  : 'FINISH & SAVE 3D ROUTE'),
            ),
            if (_trackingInterrupted) ...[
              const SizedBox(height: 7),
              const Text(
                'Tracking does not match the last trusted point. '
                'Saving preserves only measured data up to that point; '
                'it never connects an uncertain gap.',
                style: TextStyle(color: Color(0xFFFFC978), fontSize: 11),
              ),
            ],
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _busy ? null : _discard,
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('DISCARD EXPERIMENT'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _metric(String label, String value) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(
          color: const Color(0xFF131D31),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(
              color: Colors.white54, fontSize: 10,
            )),
            const SizedBox(height: 4),
            Text(value, style: const TextStyle(
              fontWeight: FontWeight.w800, fontSize: 14,
            )),
          ],
        ),
      );
}

/// A real side-elevation profile: X = accumulated 3D path length,
/// Y = relative ARCore height. No invented stairs or per-floor offsets.
class _ElevationProfile extends CustomPainter {
  const _ElevationProfile({
    required this.points,
    required this.floorMarkers,
  });

  final List<MappingPoint> points;
  final List<MappingMarker> floorMarkers;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 17.0;
    final grid = Paint()
      ..color = const Color(0x224D6E91)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = pad + i * (size.height - 2 * pad) / 4;
      canvas.drawLine(Offset(pad, y),
          Offset(size.width - pad, y), grid);
    }
    if (points.length < 2) return;

    final cumulative = <double>[0];
    var minH = points.first.upMeters;
    var maxH = points.first.upMeters;
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1];
      final b = points[i];
      final dx = b.xMeters - a.xMeters;
      final dy = b.yMeters - a.yMeters;
      final dz = b.upMeters - a.upMeters;
      cumulative.add(cumulative.last + math.sqrt(
          dx * dx + dy * dy + dz * dz));
      minH = math.min(minH, b.upMeters);
      maxH = math.max(maxH, b.upMeters);
    }
    final spanX = math.max(1.0, cumulative.last);
    final spanY = math.max(0.5, maxH - minH);
    Offset project(int i) => Offset(
      pad + cumulative[i] / spanX * (size.width - 2 * pad),
      size.height - pad -
          (points[i].upMeters - minH) / spanY * (size.height - 2 * pad),
    );
    final path = Path();
    final start = project(0);
    path.moveTo(start.dx, start.dy);
    for (var i = 1; i < points.length; i++) {
      final p = project(i);
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF66B7FF)
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(start, 5,
        Paint()..color = const Color(0xFF3DDC97));
    canvas.drawCircle(project(points.length - 1), 5,
        Paint()..color = const Color(0xFFFFC978));
    for (final marker in floorMarkers) {
      if (marker.type != 'floor_level' ||
          marker.pointIndex < 0 ||
          marker.pointIndex >= points.length) continue;
      final p = project(marker.pointIndex);
      canvas.drawCircle(p, 7,
          Paint()..color = const Color(0xFFBC9BFF));
    }
  }

  @override
  bool shouldRepaint(_ElevationProfile oldDelegate) => true;
}
