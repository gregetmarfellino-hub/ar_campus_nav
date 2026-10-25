import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/ar_pose_service.dart';

class WorldTrackingScreen extends StatefulWidget {
  const WorldTrackingScreen({super.key});

  @override
  State<WorldTrackingScreen> createState() => _WorldTrackingScreenState();
}

class _WorldTrackingScreenState extends State<WorldTrackingScreen> {
  final ArPoseService _service = const ArPoseService();
  final List<Offset> _trace = <Offset>[];

  StreamSubscription<ArPose>? _subscription;
  ArPose _pose = const ArPose(tracking: 'STOPPED');
  String _availability = 'CHECKING';
  String? _message;
  bool _starting = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _checkAvailability();
  }

  Future<void> _checkAvailability() async {
    try {
      final availability = await _service.availability();
      if (!mounted) return;
      setState(() => _availability = availability);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _availability = 'ERROR';
        _message = error.toString();
      });
    }
  }

  Future<void> _start() async {
    if (_starting || _started) return;

    setState(() {
      _starting = true;
      _message = null;
    });

    try {
      final permission = await _service.ensureCameraPermission();
      if (!permission) {
        if (!mounted) return;
        setState(() {
          _starting = false;
          _message = 'Camera permission is required for ARCore tracking.';
        });
        return;
      }

      final result = await _service.start();
      if (!mounted) return;

      if (result == 'INSTALL_REQUESTED') {
        setState(() {
          _starting = false;
          _message = 'ARCore installation/update was requested. Return here and tap Start again after it finishes.';
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

      await _subscription?.cancel();
      _subscription = _service.poses.listen(
        _onPose,
        onError: (Object error) {
          if (!mounted) return;
          setState(() => _message = error.toString());
        },
      );

      setState(() {
        _started = true;
        _starting = false;
        _pose = const ArPose(tracking: 'INITIALIZING');
        _trace
          ..clear()
          ..add(Offset.zero);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _message = error.toString();
      });
    }
  }

  void _onPose(ArPose pose) {
    if (!mounted) return;

    if (pose.isTracking) {
      final point = Offset(pose.x, -pose.z);
      if (_trace.isEmpty || (_trace.last - point).distance >= 0.03) {
        _trace.add(point);
        if (_trace.length > 1200) {
          _trace.removeRange(0, _trace.length - 1200);
        }
      }
    }

    setState(() {
      _pose = pose;
      if (pose.errorMessage != null) {
        _message = '${pose.errorCode ?? 'ARCore'}: ${pose.errorMessage}';
      }
    });
  }

  Future<void> _resetOrigin() async {
    await _service.resetOrigin();
    if (!mounted) return;
    setState(() {
      _trace
        ..clear()
        ..add(Offset.zero);
      _pose = const ArPose(tracking: 'RESETTING_ORIGIN');
      _message = 'Origin will reset on the next tracked frame.';
    });
  }

  void _clearTrace() {
    setState(() {
      _trace
        ..clear()
        ..add(Offset(_pose.x, -_pose.z));
    });
  }

  Future<void> _stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await _service.stop();
    if (!mounted) return;
    setState(() {
      _started = false;
      _pose = const ArPose(tracking: 'STOPPED');
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _service.stop();
    super.dispose();
  }

  double get _relativeYawDegrees {
    final sinyCosp = 2 * (_pose.qw * _pose.qy + _pose.qx * _pose.qz);
    final cosyCosp = 1 - 2 * (_pose.qy * _pose.qy + _pose.qz * _pose.qz);
    var degrees = math.atan2(sinyCosp, cosyCosp) * 180 / math.pi;
    if (degrees < 0) degrees += 360;
    return degrees;
  }

  Color get _trackingColor {
    return switch (_pose.tracking) {
      'TRACKING' => const Color(0xFF3DDC97),
      'PAUSED' || 'STOPPED' => Colors.white38,
      'ERROR' => const Color(0xFFFF6B8A),
      _ => const Color(0xFFF9C74F),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'AR World Tracking Lab',
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
                const Text(
                  'PASS 6 · WORLD POSE',
                  style: TextStyle(
                    color: Color(0xFF9DBEF7),
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Does the phone know where it moved?',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'ARCore establishes a local origin, then reports the camera pose in real-world meters. This test intentionally does not navigate yet.',
                  style: TextStyle(color: Colors.white60, height: 1.45),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _StatusChip(
                      label: _availability.replaceAll('_', ' '),
                      color: _availability.contains('SUPPORTED')
                          ? const Color(0xFF72A7FF)
                          : Colors.white38,
                    ),
                    _StatusChip(
                      label: _pose.tracking.replaceAll('_', ' '),
                      color: _trackingColor,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: _Metric(label: 'X · RIGHT', value: '${_pose.x.toStringAsFixed(2)} m')),
              const SizedBox(width: 10),
              Expanded(child: _Metric(label: 'Y · UP', value: '${_pose.y.toStringAsFixed(2)} m')),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _Metric(label: 'Z · ARCORE', value: '${_pose.z.toStringAsFixed(2)} m')),
              const SizedBox(width: 10),
              Expanded(child: _Metric(label: 'FORWARD', value: '${_pose.forward.toStringAsFixed(2)} m')),
            ],
          ),
          const SizedBox(height: 10),
          _Metric(
            label: 'HORIZONTAL DISPLACEMENT FROM ORIGIN',
            value: '${_pose.horizontalDistance.toStringAsFixed(2)} m',
          ),
          const SizedBox(height: 10),
          _Metric(
            label: 'RELATIVE FACING FROM ORIGIN',
            value: '${_relativeYawDegrees.toStringAsFixed(0)}°',
          ),
          const SizedBox(height: 16),
          Container(
            height: 330,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: const Color(0xFF0D1527),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0x223B82F6)),
            ),
            child: CustomPaint(
              painter: _TracePainter(
                points: List<Offset>.unmodifiable(_trace),
                current: Offset(_pose.x, -_pose.z),
                facingRadians: _relativeYawDegrees * math.pi / 180,
              ),
              child: const SizedBox.expand(),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Top-down trace · +X is right · forward is -Z',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
          if (_message != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: const Color(0x1FF9C74F),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0x44F9C74F)),
              ),
              child: Text(
                _message!,
                style: const TextStyle(color: Color(0xFFF9D976), height: 1.4),
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (!_started)
            FilledButton.icon(
              onPressed: _starting ? null : _start,
              icon: _starting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.view_in_ar_rounded),
              label: Text(_starting ? 'STARTING ARCORE...' : 'START WORLD TRACKING'),
            )
          else ...[
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _resetOrigin,
                    icon: const Icon(Icons.my_location_rounded),
                    label: const Text('RESET ORIGIN'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _clearTrace,
                    icon: const Icon(Icons.layers_clear_rounded),
                    label: const Text('CLEAR TRACE'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _stop,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('STOP TRACKING'),
            ),
          ],
          const SizedBox(height: 18),
          const Text(
            'TEST: reset origin while standing still. Walk 2–3 meters forward, stop, then walk back near the starting point. Horizontal displacement should rise and return close to 0 m.',
            style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.45),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFF111A2E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x223B82F6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}

class _TracePainter extends CustomPainter {
  const _TracePainter({
    required this.points,
    required this.current,
    required this.facingRadians,
  });

  final List<Offset> points;
  final Offset current;
  final double facingRadians;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = const Color(0x102A4A78)
      ..strokeWidth = 1;

    for (double x = 0; x <= size.width; x += 36) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (double y = 0; y <= size.height; y += 36) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    if (points.isEmpty) {
      _drawCenterText(canvas, size, 'Start tracking to create a world-space trace');
      return;
    }

    var minX = points.first.dx;
    var maxX = points.first.dx;
    var minY = points.first.dy;
    var maxY = points.first.dy;
    for (final point in points) {
      minX = math.min(minX, point.dx);
      maxX = math.max(maxX, point.dx);
      minY = math.min(minY, point.dy);
      maxY = math.max(maxY, point.dy);
    }

    minX = math.min(minX, current.dx);
    maxX = math.max(maxX, current.dx);
    minY = math.min(minY, current.dy);
    maxY = math.max(maxY, current.dy);

    const padding = 40.0;
    final spanX = math.max(2.0, maxX - minX);
    final spanY = math.max(2.0, maxY - minY);
    final scale = math.min(
      (size.width - padding * 2) / spanX,
      (size.height - padding * 2) / spanY,
    );
    final centerWorld = Offset((minX + maxX) / 2, (minY + maxY) / 2);
    final centerScreen = Offset(size.width / 2, size.height / 2);

    Offset map(Offset point) {
      return centerScreen + (point - centerWorld) * scale;
    }

    if (points.length > 1) {
      final path = Path();
      final first = map(points.first);
      path.moveTo(first.dx, first.dy);
      for (final point in points.skip(1)) {
        final mapped = map(point);
        path.lineTo(mapped.dx, mapped.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF56C7FF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    final origin = map(Offset.zero);
    canvas.drawCircle(origin, 8, Paint()..color = const Color(0xFF3DDC97));

    final currentPoint = map(current);
    canvas.drawCircle(
      currentPoint,
      15,
      Paint()
        ..color = const Color(0x66FF6B8A)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    canvas.save();
    canvas.translate(currentPoint.dx, currentPoint.dy);
    canvas.rotate(facingRadians);
    final arrow = Path()
      ..moveTo(0, -16)
      ..lineTo(10, 10)
      ..lineTo(0, 6)
      ..lineTo(-10, 10)
      ..close();
    canvas.drawPath(
      arrow,
      Paint()..color = const Color(0xFFFF6B8A),
    );
    canvas.restore();
  }

  void _drawCenterText(Canvas canvas, Size size, String text) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(color: Colors.white30, fontSize: 12),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 60);

    painter.paint(
      canvas,
      Offset(
        (size.width - painter.width) / 2,
        (size.height - painter.height) / 2,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant _TracePainter oldDelegate) => true;
}
