import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/anchor_point.dart';
import '../models/destination.dart';
import '../models/route_result.dart';
import '../models/venue.dart';
import '../services/ar_pose_service.dart';
import '../services/anchor_codec.dart';
import '../services/route_engine.dart';
import '../services/visual_anchor_spec.dart';
import 'qr_anchor_scanner_screen.dart';

class ArNavigationResult {
  const ArNavigationResult({
    required this.route,
    required this.anchor,
    required this.mapToCompassOffset,
  });

  final RouteResult route;
  final AnchorPoint? anchor;
  final double? mapToCompassOffset;
}

/// Pass 7 world-space AR navigation.
///
/// Flutter prepares the selected graph route in a route-local meter frame.
/// Native ARCore owns the camera while navigation is active, aligns that
/// meter frame to the user's real starting pose, and renders breadcrumbs.
class ArNavigationScreen extends StatefulWidget {
  const ArNavigationScreen({
    super.key,
    required this.venue,
    required this.destination,
    required this.initialRoute,
    this.initialAnchor,
    this.initialMapToCompassOffset,
  });

  final Venue venue;
  final Destination destination;
  final RouteResult initialRoute;
  final AnchorPoint? initialAnchor;
  final double? initialMapToCompassOffset;

  @override
  State<ArNavigationScreen> createState() => _ArNavigationScreenState();
}

class _ArNavigationScreenState extends State<ArNavigationScreen> {
  final ArPoseService _ar = const ArPoseService();
  final AnchorCodec _anchorCodec = const AnchorCodec();
  final RouteEngine _routeEngine = const RouteEngine();

  StreamSubscription<ArPose>? _poseSubscription;
  late RouteResult _route;
  AnchorPoint? _anchor;

  String _status = 'Preparing ARCore...';
  bool _starting = true;
  bool _nativeClosed = false;
  bool _handlingReanchor = false;
  bool _arrived = false;

  @override
  void initState() {
    super.initState();

    _route = widget.initialRoute;
    _anchor = widget.initialAnchor;

    _poseSubscription = _ar.poses.listen(
      (pose) {
        if (!mounted) return;

        if (pose.tracking == 'NAV_CLOSED') {
          _nativeClosed = true;
          _finish();
          return;
        }

        if (pose.tracking == 'REANCHOR_REQUEST') {
          if (!_handlingReanchor) {
            unawaited(_reanchorFromQr());
          }
          return;
        }

        if (pose.tracking == 'PERSISTENT_PORTAL_RESOLVED') {
          setState(() {
            _status =
                'Start portal found. Center the floating QR in the camera to begin.';
          });
          return;
        }

        if (pose.tracking == 'PERSISTENT_PORTAL_ACTIVATED') {
          setState(() {
            _status = 'Start portal scanned. AR route activated.';
          });
          return;
        }
        if (pose.tracking == 'VISUAL_ANCHOR_LOCKED') {
          setState(() {
            _status =
                'Visual QR locked. Position + direction are anchored to the '
                'physical marker.';
          });
          return;
        }

        if (pose.tracking == 'ARRIVED') {
          setState(() {
            _arrived = true;
            _status = 'Destination reached.';
          });
          return;
        }

        if (pose.tracking == 'TRACKING') {
          if (_status != 'World tracking active') {
            setState(() => _status = 'World tracking active');
          }
          return;
        }

        if (pose.tracking == 'ERROR') {
          setState(() {
            _status = pose.errorMessage ?? 'ARCore tracking error.';
            _starting = false;
          });
        }
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _status = 'ARCore stream error: $error';
          _starting = false;
        });
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startNavigation();
    });
  }

  ({
    double forwardX,
    double forwardY,
    double rightX,
    double rightY,
  })? _routeFrameBasis() {
    final nodes = _route.nodes;
    if (nodes.length < 2) return null;

    final start = nodes.first;
    const preferredFitMeters = 2.5;
    final prefix = <({double x, double y})>[
      (x: start.x, y: start.y),
    ];

    var cumulative = 0.0;
    for (var i = 1; i < nodes.length; i++) {
      final previous = nodes[i - 1];
      final current = nodes[i];
      final dx = current.x - previous.x;
      final dy = current.y - previous.y;
      cumulative += math.sqrt(dx * dx + dy * dy);
      prefix.add((x: current.x, y: current.y));

      if (cumulative >= preferredFitMeters && prefix.length >= 4) {
        break;
      }
    }

    final end = prefix.last;
    final endDx = end.x - start.x;
    final endDy = end.y - start.y;
    final endDistance = math.sqrt(endDx * endDx + endDy * endDy);
    if (endDistance < 0.0001) return null;

    var meanX = 0.0;
    var meanY = 0.0;
    for (final point in prefix) {
      meanX += point.x;
      meanY += point.y;
    }
    meanX /= prefix.length;
    meanY /= prefix.length;

    var covXX = 0.0;
    var covXY = 0.0;
    var covYY = 0.0;
    for (final point in prefix) {
      final x = point.x - meanX;
      final y = point.y - meanY;
      covXX += x * x;
      covXY += x * y;
      covYY += y * y;
    }

    final angle = 0.5 * math.atan2(
      2.0 * covXY,
      covXX - covYY,
    );

    var forwardX = math.cos(angle);
    var forwardY = math.sin(angle);
    if (forwardX * endDx + forwardY * endDy < 0) {
      forwardX = -forwardX;
      forwardY = -forwardY;
    }

    return (
      forwardX: forwardX,
      forwardY: forwardY,
      rightX: -forwardY,
      rightY: forwardX,
    );
  }

  List<Map<String, dynamic>> _routeLocalPoints() {
    final nodes = _route.nodes;
    if (nodes.length < 2) return const [];

    final basis = _routeFrameBasis();
    if (basis == null) return const [];
    final start = nodes.first;

    return [
      for (final node in nodes)
        {
          'right': (node.x - start.x) * basis.rightX +
              (node.y - start.y) * basis.rightY,
          'forward': (node.x - start.x) * basis.forwardX +
              (node.y - start.y) * basis.forwardY,
          'label': node.label,
          'semantic': node.type != 'path',
        },
    ];
  }

  double? _visualAnchorRouteOffsetDegrees(AnchorPoint anchor) {
    if (!anchor.visualPoseReady) return null;
    final basis = _routeFrameBasis();
    if (basis == null) return null;

    var routeHeading =
        math.atan2(basis.forwardX, -basis.forwardY) * 180.0 / math.pi;
    routeHeading %= 360.0;
    if (routeHeading < 0) routeHeading += 360.0;

    var delta = routeHeading - anchor.headingDegrees!;
    while (delta > 180.0) delta -= 360.0;
    while (delta <= -180.0) delta += 360.0;
    return delta;
  }

  Future<Uint8List?> _visualAnchorPng(AnchorPoint anchor) async {
    final payload = _anchorCodec.encode(
      venue: widget.venue,
      anchor: anchor,
    );
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
    final size = VisualAnchorSpec.renderPixels;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      ui.Paint()..color = const Color(0xFFFFFFFF),
    );
    painter.paint(
      canvas,
      ui.Size(size.toDouble(), size.toDouble()),
    );
    final image = await recorder.endRecording().toImage(size, size);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) return null;
    return bytes.buffer.asUint8List(
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
  }

  Future<bool> _startNavigation() async {
    if (!mounted) return false;

    final startAnchor = _anchor != null &&
            _route.nodes.isNotEmpty &&
            _route.nodes.first.id == _anchor!.nodeId
        ? _anchor
        : null;
    final persistentAnchor =
        startAnchor?.persistentPoseReady == true ? startAnchor : null;
    final visualAnchor =
        persistentAnchor == null && startAnchor?.visualPoseReady == true
            ? startAnchor
            : null;
    final portalPreviewAnchor = persistentAnchor ?? visualAnchor;
    final points = _routeLocalPoints();
    if (points.length < 2) {
      setState(() {
        _status = 'This route does not contain enough spatial points.';
        _starting = false;
      });
      return false;
    }

    final permission = await _ar.ensureCameraPermission();
    if (!mounted) return false;

    if (!permission) {
      setState(() {
        _status = 'Camera permission is required for AR navigation.';
        _starting = false;
      });
      return false;
    }

    try {
      final visualPng = portalPreviewAnchor == null
          ? null
          : await _visualAnchorPng(portalPreviewAnchor);
      final result = await _ar.startNavigation(
        destinationName: widget.destination.name,
        startLabel: _route.nodes.first.label,
        anchorLocalized: _anchor != null,
        points: points,
        visualAnchorPng: visualPng,
        visualAnchorWidthMeters: portalPreviewAnchor == null
            ? null
            : VisualAnchorSpec.qrWidthMeters,
        visualAnchorLabel: portalPreviewAnchor?.label,
        visualAnchorRouteOffsetDegrees: visualAnchor == null
            ? null
            : _visualAnchorRouteOffsetDegrees(visualAnchor),
        cloudAnchorId: persistentAnchor?.cloudAnchorId,
      );
      if (!mounted) return false;

      setState(() {
        _status = switch (result) {
          'STARTED' => persistentAnchor != null
              ? 'Resolving the saved ${persistentAnchor.label} start portal. '
                  'Look around the mapped entrance area.'
              : visualAnchor != null
                  ? 'Visual localization ready. Point the AR camera at the '
                      '16 cm ${visualAnchor.label} QR and hold it steady until '
                      'the app locks position + direction.'
                  : _anchor == null
                      ? 'Manual preview: stand exactly at the selected map start, '
                          'tap SET START, walk 2–3 m along the first real path, then '
                          'LOCK DIRECTION.'
                      : 'This legacy anchor has no persistent portal. '
                          'Manual alignment remains available for old data.',
          'INSTALL_REQUESTED' =>
            'Install/update Google Play Services for AR, then retry.',
          _ => 'ARCore: $result',
        };
        _starting = false;
      });
      return result == 'STARTED';
    } catch (error) {
      if (!mounted) return false;
      setState(() {
        _status = 'Could not start spatial AR: $error';
        _starting = false;
      });
      return false;
    }
  }

  Future<void> _reanchorFromQr() async {
    if (_handlingReanchor || _arrived) return;

    setState(() {
      _handlingReanchor = true;
      _status = 'Pausing ARCore to scan a known location...';
    });

    try {
      // ARCore must fully release the camera before MobileScanner opens it.
      await _ar.stopNavigation();
      if (!mounted) return;

      final raw = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(
          builder: (_) => const QrAnchorScannerScreen(),
        ),
      );
      if (!mounted) return;

      if (raw == null) {
        setState(() {
          _status =
              'Location scan cancelled. Start the AR guide again when ready.';
          _starting = false;
        });
        return;
      }

      final anchor = _anchorCodec.resolve(
        venue: widget.venue,
        rawValue: raw,
      );

      final route = _routeEngine.shortestPath(
        venue: widget.venue,
        startNodeId: anchor.nodeId,
        destinationNodeId: widget.destination.nodeId,
      );

      if (!mounted) return;

      if (route.legs.isEmpty &&
          anchor.nodeId == widget.destination.nodeId) {
        setState(() {
          _anchor = anchor;
          _route = route;
          _arrived = true;
          _status = 'Destination confirmed by QR: ${anchor.label}';
        });
        return;
      }

      setState(() {
        _anchor = anchor;
        _route = route;
        _arrived = false;
        _starting = true;
        _status =
            'Anchor confirmed: ${anchor.label}. Restarting ARCore...';
      });

      final result = await _startNavigation();
      if (!mounted) return;

      if (result) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              anchor.visualPoseReady
                  ? 'Location confirmed at ${anchor.label}. Point the AR '
                      'camera at its 16 cm QR and hold steady for visual lock.'
                  : 'Location confirmed at ${anchor.label}. Tap SET START, '
                      'walk 2–3 m along the next real path, then '
                      'LOCK DIRECTION.',
            ),
          ),
        );
      }
    } on FormatException catch (error) {
      if (!mounted) return;
      setState(() {
        _status = error.message;
        _starting = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = 'Could not scan location: $error';
        _starting = false;
      });
    } finally {
      if (mounted) {
        setState(() => _handlingReanchor = false);
      }
    }
  }

  Future<void> _retry() async {
    setState(() {
      _starting = true;
      _status = 'Preparing ARCore...';
    });
    await _startNavigation();
  }

  void _finish() {
    if (!mounted) return;
    Navigator.of(context).pop(
      ArNavigationResult(
        route: _route,
        anchor: _anchor,
        mapToCompassOffset: widget.initialMapToCompassOffset,
      ),
    );
  }

  @override
  void dispose() {
    _poseSubscription?.cancel();
    if (!_nativeClosed) {
      unawaited(_ar.stopNavigation());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && !_nativeClosed) {
          unawaited(_ar.stopNavigation());
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF07101F),
        appBar: AppBar(
          title: const Text('Spatial AR Guide'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_starting)
                  const CircularProgressIndicator()
                else
                  const Icon(
                    Icons.view_in_ar_rounded,
                    color: Color(0xFF72A7FF),
                    size: 56,
                  ),
                const SizedBox(height: 18),
                Text(
                  widget.destination.name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white60,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 22),
                const Text(
                  'Persistent routes resolve their saved AR start portal '
                  'automatically. Center the floating QR portal to activate '
                  'guidance; legacy routes may still use older alignment modes.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
                if (_arrived) ...[
                  const SizedBox(height: 24),
                  const Icon(
                    Icons.check_circle_rounded,
                    color: Color(0xFF3DDC97),
                    size: 44,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Destination reached',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                ] else if (!_starting) ...[
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    onPressed: _handlingReanchor ? null : _retry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('RETRY ARCORE'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
