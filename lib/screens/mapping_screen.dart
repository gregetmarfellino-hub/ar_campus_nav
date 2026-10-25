import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/anchor_point.dart';
import '../models/mapping_session.dart';
import '../models/venue.dart';
import '../services/anchor_codec.dart';
import '../services/heading_service.dart';
import '../services/mapping_storage.dart';
import '../services/step_sensor_service.dart';
import 'qr_anchor_scanner_screen.dart';

class MappingScreen extends StatefulWidget {
  const MappingScreen({
    super.key,
    required this.venue,
    this.initialAnchor,
  });

  final Venue venue;
  final AnchorPoint? initialAnchor;

  @override
  State<MappingScreen> createState() => _MappingScreenState();
}

class _MappingScreenState extends State<MappingScreen> {
  static const Color _blue = Color(0xFF72A7FF);
  static const Color _green = Color(0xFF3DDC97);
  static const Color _yellow = Color(0xFFF9C74F);

  final HeadingService _headingService = const HeadingService();
  final StepSensorService _stepSensor = const StepSensorService();
  final MappingStorage _storage = const MappingStorage();
  final AnchorCodec _anchorCodec = const AnchorCodec();

  StreamSubscription<double>? _headingSubscription;
  StreamSubscription<StepEvent>? _stepSubscription;

  AnchorPoint? _startAnchor;
  int _floor = 1;
  double _stepLengthMeters = 0.70;
  double? _deviceHeading;
  double? _originHeading;
  String? _headingError;

  bool _recording = false;
  bool _paused = false;
  bool _sensorAvailable = false;
  bool _sensorChecked = false;

  int _steps = 0;
  double _xMeters = 0;
  double _yMeters = 0;

  final List<MappingPoint> _points = <MappingPoint>[];
  final List<MappingMarker> _markers = <MappingMarker>[];

  String? _savedPath;
  String? _savedJson;

  @override
  void initState() {
    super.initState();
    _startAnchor = widget.initialAnchor ??
        (widget.venue.anchors.isEmpty ? null : widget.venue.anchors.first);
    _floor = _startAnchor?.floor ??
        (widget.venue.floors.isEmpty ? 1 : widget.venue.floors.first);
    _headingSubscription = _headingService.headings.listen(
      (heading) {
        if (!mounted) return;
        setState(() {
          _deviceHeading = heading;
          _headingError = null;
        });
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() => _headingError = error.toString());
      },
    );
    _checkStepSensor();
  }

  @override
  void dispose() {
    _headingSubscription?.cancel();
    _stepSubscription?.cancel();
    super.dispose();
  }

  Future<void> _checkStepSensor() async {
    try {
      final available = await _stepSensor.isAvailable();
      if (!mounted) return;
      setState(() {
        _sensorAvailable = available;
        _sensorChecked = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sensorAvailable = false;
        _sensorChecked = true;
      });
    }
  }

  Future<void> _scanStartAnchor() async {
    if (_recording) return;
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
        SnackBar(content: Text('Mapping origin: ${anchor.label}')),
      );
    } on FormatException catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    }
  }

  Future<void> _startRecording() async {
    final heading = _deviceHeading;
    if (heading == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Waiting for a usable compass heading.')),
      );
      return;
    }

    var permissionGranted = false;
    if (_sensorAvailable) {
      try {
        permissionGranted = await _stepSensor.ensurePermission();
      } catch (_) {
        permissionGranted = false;
      }
    }

    await _stepSubscription?.cancel();

    setState(() {
      _originHeading = heading;
      _recording = true;
      _paused = false;
      _steps = 0;
      _xMeters = 0;
      _yMeters = 0;
      _points
        ..clear()
        ..add(
          MappingPoint(
            xMeters: 0,
            yMeters: 0,
            headingDegrees: heading,
            stepIndex: 0,
            timestampMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      _markers.clear();
      _savedPath = null;
      _savedJson = null;
    });

    if (_sensorAvailable && permissionGranted) {
      _stepSubscription = _stepSensor.events.listen(
        (event) => _recordStep(event.timestampMs),
        onError: (Object error) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Step sensor unavailable. Use Manual step · debug. $error',
              ),
            ),
          );
        },
      );
    }
  }

  void _recordStep(int timestampMs) {
    if (!_recording || _paused) return;
    final heading = _deviceHeading;
    final origin = _originHeading;
    if (heading == null || origin == null) return;

    final relative = _normalizeSigned(heading - origin);
    final radians = relative * math.pi / 180;
    final nextX = _xMeters + math.sin(radians) * _stepLengthMeters;
    final nextY = _yMeters + math.cos(radians) * _stepLengthMeters;

    if (!mounted) return;
    setState(() {
      _steps += 1;
      _xMeters = nextX;
      _yMeters = nextY;
      _points.add(
        MappingPoint(
          xMeters: nextX,
          yMeters: nextY,
          headingDegrees: heading,
          stepIndex: _steps,
          timestampMs: timestampMs,
        ),
      );
    });
  }

  void _manualStep() {
    _recordStep(DateTime.now().millisecondsSinceEpoch);
  }

  double _normalizeSigned(double degrees) {
    var value = degrees % 360;
    if (value > 180) value -= 360;
    if (value < -180) value += 360;
    return value;
  }

  Future<void> _addMarker(String type) async {
    if (!_recording || _points.isEmpty) return;

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
          xMeters: _xMeters,
          yMeters: _yMeters,
          pointIndex: _points.length - 1,
        ),
      );
    });
  }

  Future<void> _finishAndSave() async {
    if (!_recording || _points.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Record at least one step first.')),
      );
      return;
    }

    await _stepSubscription?.cancel();
    _stepSubscription = null;

    final now = DateTime.now();
    final session = MappingSession(
      id: 'floor_${_floor}_${now.millisecondsSinceEpoch}',
      venueId: widget.venue.id,
      venueName: widget.venue.name,
      floor: _floor,
      createdAt: now,
      startAnchorId: _startAnchor?.id,
      startAnchorLabel: _startAnchor?.label,
      originHeadingDegrees: _originHeading ?? 0,
      stepLengthMeters: _stepLengthMeters,
      points: List<MappingPoint>.unmodifiable(_points),
      markers: List<MappingMarker>.unmodifiable(_markers),
    );

    try {
      final path = await _storage.save(session);
      final prettyJson = const JsonEncoder.withIndent('  ').convert(
        session.toJson(),
      );
      if (!mounted) return;
      setState(() {
        _recording = false;
        _paused = false;
        _savedPath = path;
        _savedJson = prettyJson;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Floor mapping saved offline.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save mapping: $error')),
      );
    }
  }

  Future<void> _copyJson() async {
    final json = _savedJson;
    if (json == null) return;
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Mapping JSON copied.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final heading = _deviceHeading;
    final origin = _originHeading;
    final relativeHeading = heading == null || origin == null
        ? null
        : _normalizeSigned(heading - origin);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Walk Mapper',
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.route_rounded, color: _blue),
                    SizedBox(width: 8),
                    Text(
                      'FLOOR AUTHORING MODE',
                      style: TextStyle(
                        color: Color(0xFFB9D0FA),
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  widget.venue.name,
                  style: const TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Walk the real corridor once. Each detected step becomes a '
                  'local path point. Add rooms, junctions, stairs, and QR '
                  'checkpoints while you are standing at them.',
                  style: TextStyle(color: Colors.white60, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _section('START / FLOOR'),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey(_startAnchor?.id),
                  initialValue: _startAnchor?.id,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Start anchor',
                    prefixIcon: Icon(Icons.qr_code_2_rounded),
                  ),
                  items: [
                    for (final anchor in widget.venue.anchors)
                      DropdownMenuItem(
                        value: anchor.id,
                        child: Text(anchor.label),
                      ),
                  ],
                  onChanged: _recording
                      ? null
                      : (value) {
                          if (value == null) return;
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
                onPressed: _recording ? null : _scanStartAnchor,
                icon: const Icon(Icons.qr_code_scanner_rounded),
              ),
            ],
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<int>(
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
            onChanged: _recording
                ? null
                : (value) {
                    if (value != null) setState(() => _floor = value);
                  },
          ),
          const SizedBox(height: 18),
          _section('STEP CALIBRATION'),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: _cardDecoration(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Estimated step length: '
                        '${_stepLengthMeters.toStringAsFixed(2)} m',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    _StatusPill(
                      text: !_sensorChecked
                          ? 'CHECKING'
                          : _sensorAvailable
                              ? 'STEP SENSOR'
                              : 'MANUAL FALLBACK',
                      color: _sensorAvailable ? _green : _yellow,
                    ),
                  ],
                ),
                Slider(
                  min: 0.45,
                  max: 1.00,
                  divisions: 55,
                  value: _stepLengthMeters,
                  onChanged: _recording
                      ? null
                      : (value) => setState(() => _stepLengthMeters = value),
                ),
                const Text(
                  'This is an approximate pedestrian-dead-reckoning mapper. '
                  'QR anchors will be used later to correct accumulated drift.',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _section('LIVE RECORDING'),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: _cardDecoration(),
            child: Column(
              children: [
                Row(
                  children: [
                    _Metric(label: 'Steps', value: '$_steps'),
                    _Metric(
                      label: 'Distance',
                      value: '${(_steps * _stepLengthMeters).toStringAsFixed(1)} m',
                    ),
                    _Metric(label: 'Markers', value: '${_markers.length}'),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        heading == null
                            ? 'Compass: waiting…'
                            : 'Compass: ${heading.toStringAsFixed(0)}°'
                                '${relativeHeading == null ? '' : '  •  local ${relativeHeading.toStringAsFixed(0)}°'}',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                    if (_headingError != null)
                      const Icon(Icons.warning_amber_rounded, color: _yellow),
                  ],
                ),
                const SizedBox(height: 14),
                SizedBox(
                  height: 300,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFF0E1729),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: CustomPaint(
                      painter: _MappingPathPainter(
                        points: _points,
                        markers: _markers,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                if (!_recording)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _startRecording,
                      icon: const Icon(Icons.fiber_manual_record_rounded),
                      label: const Text('START WALK RECORDING'),
                    ),
                  )
                else ...[
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => setState(() => _paused = !_paused),
                          icon: Icon(
                            _paused
                                ? Icons.play_arrow_rounded
                                : Icons.pause_rounded,
                          ),
                          label: Text(_paused ? 'Resume' : 'Pause'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _manualStep,
                          icon: const Icon(Icons.directions_walk_rounded),
                          label: const Text('Manual step · debug'),
                        ),
                      ),
                    ],
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
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: _green,
                        foregroundColor: Colors.black,
                      ),
                      onPressed: _finishAndSave,
                      icon: const Icon(Icons.save_rounded),
                      label: const Text('FINISH & SAVE FLOOR MAPPING'),
                    ),
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
                        'Mapping saved',
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

  Widget _section(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 8),
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

  BoxDecoration _cardDecoration() {
    return BoxDecoration(
      color: const Color(0xFF111B2F),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0x2672A7FF)),
    );
  }

  Widget _markerButton(String type, IconData icon) {
    final label = switch (type) {
      'destination' => 'Destination',
      'stairs' => 'Stairs',
      'anchor' => 'QR anchor',
      _ => 'Waypoint',
    };
    return OutlinedButton.icon(
      onPressed: _paused ? null : () => _addMarker(type),
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: Colors.white38, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 8,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _MappingPathPainter extends CustomPainter {
  const _MappingPathPainter({
    required this.points,
    required this.markers,
  });

  final List<MappingPoint> points;
  final List<MappingMarker> markers;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = const Color(0x143A4B68)
      ..strokeWidth = 1;
    for (var x = 20.0; x < size.width; x += 40) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (var y = 20.0; y < size.height; y += 40) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (points.isEmpty) {
      final painter = TextPainter(
        text: const TextSpan(
          text: 'Walk path will appear here',
          style: TextStyle(color: Colors.white30, fontSize: 13),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        Offset(
          (size.width - painter.width) / 2,
          (size.height - painter.height) / 2,
        ),
      );
      return;
    }

    var minX = points.first.xMeters;
    var maxX = points.first.xMeters;
    var minY = points.first.yMeters;
    var maxY = points.first.yMeters;

    for (final point in points) {
      minX = math.min(minX, point.xMeters);
      maxX = math.max(maxX, point.xMeters);
      minY = math.min(minY, point.yMeters);
      maxY = math.max(maxY, point.yMeters);
    }
    for (final marker in markers) {
      minX = math.min(minX, marker.xMeters);
      maxX = math.max(maxX, marker.xMeters);
      minY = math.min(minY, marker.yMeters);
      maxY = math.max(maxY, marker.yMeters);
    }

    const pad = 34.0;
    final spanX = math.max(4.0, maxX - minX);
    final spanY = math.max(4.0, maxY - minY);
    final scale = math.min(
      (size.width - pad * 2) / spanX,
      (size.height - pad * 2) / spanY,
    );

    Offset project(double x, double y) {
      final px = pad + (x - minX) * scale;
      final py = size.height - pad - (y - minY) * scale;
      return Offset(px, py);
    }

    final path = Path();
    final start = project(points.first.xMeters, points.first.yMeters);
    path.moveTo(start.dx, start.dy);
    for (final point in points.skip(1)) {
      final p = project(point.xMeters, point.yMeters);
      path.lineTo(p.dx, p.dy);
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF63C7FF)
        ..strokeWidth = 5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    canvas.drawCircle(start, 7, Paint()..color = const Color(0xFF3DDC97));

    final end = project(points.last.xMeters, points.last.yMeters);
    canvas.drawCircle(end, 6, Paint()..color = const Color(0xFF72A7FF));

    for (final marker in markers) {
      final p = project(marker.xMeters, marker.yMeters);
      final color = switch (marker.type) {
        'destination' => const Color(0xFFFF6B8A),
        'stairs' => const Color(0xFFF9C74F),
        'anchor' => const Color(0xFF3DDC97),
        _ => const Color(0xFFCBA6F7),
      };
      canvas.drawCircle(p, 8, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _MappingPathPainter oldDelegate) {
    return oldDelegate.points != points || oldDelegate.markers != markers;
  }
}
