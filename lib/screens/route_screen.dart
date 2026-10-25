import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/anchor_point.dart';
import '../models/destination.dart';
import '../models/route_result.dart';
import '../models/venue.dart';
import '../services/anchor_codec.dart';
import '../services/direction_guidance.dart';
import '../services/route_engine.dart';
import '../widgets/venue_map.dart';
import 'ar_navigation_screen.dart';
import 'qr_anchor_scanner_screen.dart';

class RouteScreen extends StatefulWidget {
  const RouteScreen({
    super.key,
    required this.venue,
    required this.destination,
    required this.initialRoute,
    this.initialAnchor,
  });

  final Venue venue;
  final Destination destination;
  final RouteResult initialRoute;
  final AnchorPoint? initialAnchor;

  @override
  State<RouteScreen> createState() => _RouteScreenState();
}

class _RouteScreenState extends State<RouteScreen> {
  final RouteEngine _routeEngine = const RouteEngine();
  final AnchorCodec _anchorCodec = const AnchorCodec();

  late RouteResult _route;
  AnchorPoint? _anchor;

  @override
  void initState() {
    super.initState();
    _route = widget.initialRoute;
    _anchor = widget.initialAnchor;
  }

  Future<void> _scanCheckpoint() async {
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

      final route = _routeEngine.shortestPath(
        venue: widget.venue,
        startNodeId: anchor.nodeId,
        destinationNodeId: widget.destination.nodeId,
      );

      setState(() {
        _anchor = anchor;
        _route = route;
      });

      final arrived = anchor.nodeId == widget.destination.nodeId;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            arrived
                ? 'Destination confirmed: ${anchor.label}'
                : 'Location updated: ${anchor.label}. Route recalculated.',
          ),
        ),
      );
    } on FormatException catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not use this anchor: $error')),
      );
    }
  }

  Future<void> _openArGuide() async {
    if (_route.legs.isEmpty) return;

    final result = await Navigator.of(context).push<ArNavigationResult>(
      MaterialPageRoute<ArNavigationResult>(
        builder: (_) => ArNavigationScreen(
          venue: widget.venue,
          destination: widget.destination,
          initialRoute: _route,
          initialAnchor: _anchor,
          initialMapToCompassOffset: null,
        ),
      ),
    );

    if (!mounted || result == null) return;

    setState(() {
      _route = result.route;
      _anchor = result.anchor;
    });
  }

  String _stepTitle(int legIndex, RouteLeg leg) {
    if (legIndex == _route.legs.length - 1) {
      return 'Arrive at ${leg.to.label}';
    }

    if (legIndex == 0) {
      return 'Continue to ${leg.to.label}';
    }

    final previous = _route.legs[legIndex - 1];
    final previousBearing = DirectionGuidance.mapBearingDegrees(
      previous.from,
      previous.to,
    );
    final currentBearing = DirectionGuidance.mapBearingDegrees(
      leg.from,
      leg.to,
    );
    final turn = DirectionGuidance.normalizeSigned(
      currentBearing - previousBearing,
    );

    final instruction = DirectionGuidance.relativeInstruction(turn);
    return '$instruction toward ${leg.to.label}';
  }

  @override
  Widget build(BuildContext context) {
    final route = _route;
    final start = route.nodes.first;
    final end = route.nodes.last;
    final anchor = _anchor;
    final arrived = start.id == widget.destination.nodeId;
    final visibleLegIndices = <int>[
      for (var i = 0; i < route.legs.length; i++)
        if (route.legs[i].to.label != 'Recorded path' &&
            route.legs[i].to.type != 'path')
          i,
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Route Preview',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 30),
        children: [
          Text(
            widget.destination.name,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.7,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            arrived
                ? 'You are at the destination.'
                : '${start.label} → ${end.label}',
            style: TextStyle(
              color: arrived ? const Color(0xFF3DDC97) : Colors.white54,
              fontWeight: arrived ? FontWeight.w700 : FontWeight.normal,
            ),
          ),
          const SizedBox(height: 14),
          _AnchorCard(
            anchor: anchor,
            manualStartLabel: start.label,
            onScan: _scanCheckpoint,
          ),
          const SizedBox(height: 14),
          _SpatialAlignmentCard(anchor: anchor),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: arrived ? null : _openArGuide,
              icon: const Icon(Icons.view_in_ar_rounded),
              label: Text(
                anchor == null
                    ? 'START AR MANUAL PREVIEW'
                    : anchor.visualPoseReady
                        ? 'START AR & LOCK QR'
                        : 'START AR + MANUAL ALIGN',
              ),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 15),
                backgroundColor: const Color(0xFF72A7FF),
                foregroundColor: const Color(0xFF07101E),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          VenueMap(
            venue: widget.venue,
            route: route,
            floor: end.floor,
            height: 390,
            currentNodeId: start.id,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _MetricCard(
                  icon: Icons.straighten_rounded,
                  label: 'Distance',
                  value: '${route.totalDistanceMeters.toStringAsFixed(0)} m',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _MetricCard(
                  icon: Icons.route_rounded,
                  label: 'Segments',
                  value: '${route.legs.length}',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _MetricCard(
                  icon: Icons.layers_rounded,
                  label: 'Floor',
                  value: '${end.floor}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          const Text(
            'GUIDANCE STEPS',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          _StepTile(
            index: 0,
            title: arrived
                ? 'Destination confirmed at ${start.label}'
                : 'Start at ${start.label}',
            subtitle: anchor == null
                ? 'Start point selected manually.'
                : anchor.visualPoseReady
                    ? 'AR camera will confirm this visual QR pose.'
                    : 'Legacy QR start; direction still needs calibration.',
            isLast: route.legs.isEmpty,
          ),
          for (var stepIndex = 0;
              stepIndex < visibleLegIndices.length;
              stepIndex++)
            _StepTile(
              index: stepIndex + 1,
              title: _stepTitle(
                visibleLegIndices[stepIndex],
                route.legs[visibleLegIndices[stepIndex]],
              ),
              subtitle: visibleLegIndices[stepIndex] ==
                      route.legs.length - 1
                  ? 'Final mapped point'
                  : 'Semantic checkpoint',
              isLast: stepIndex == visibleLegIndices.length - 1,
            ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0x1472A7FF),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0x3372A7FF)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.explore_rounded, color: Color(0xFF72A7FF)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    anchor?.visualPoseReady == true
                        ? 'Point the AR camera at the deployed 16 cm QR. '
                            'ARCore will measure its physical position and '
                            'orientation directly; no 2–3 m calibration walk '
                            'is required.'
                        : anchor != null
                            ? 'This is a legacy position-only QR. ARCore still '
                                'needs the manual 2–3 m direction calibration. '
                                'Re-map the anchor with visual facing to remove '
                                'that step.'
                            : 'Manual preview assumes you are physically at the '
                                'selected start and still requires the 2–3 m '
                                'direction calibration.',
                    style: const TextStyle(
                      color: Colors.white70,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SpatialAlignmentCard extends StatelessWidget {
  const _SpatialAlignmentCard({required this.anchor});

  final AnchorPoint? anchor;

  @override
  Widget build(BuildContext context) {
    final value = anchor;
    final visualReady = value?.visualPoseReady ?? false;
    final hasAnchor = value != null;

    final title = visualReady
        ? 'VISUAL QR LOCALIZATION'
        : hasAnchor
            ? 'LEGACY QR + MANUAL DIRECTION'
            : 'MANUAL PREVIEW MODE';
    final color = visualReady
        ? const Color(0xFF3DDC97)
        : const Color(0xFFF9C74F);

    final message = visualReady
        ? 'Expected QR: ${value.label}. Open AR and point the camera at that '
            'physical 16 cm marker. ARCore will lock both position and '
            'direction from the marker pose.'
        : hasAnchor
            ? 'The QR identifies ${value.label}, but this older anchor has no '
                'verified installation facing. Navigation falls back to the '
                '2–3 m direction walk.'
            : 'No physical anchor is selected. AR assumes you are standing '
                'exactly on the selected map start and uses manual alignment.';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: visualReady
            ? const Color(0x143DDC97)
            : const Color(0x14F9C74F),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            visualReady
                ? Icons.center_focus_strong_rounded
                : hasAnchor
                    ? Icons.qr_code_2_rounded
                    : Icons.science_outlined,
            color: color,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  message,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 11,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AnchorCard extends StatelessWidget {
  const _AnchorCard({
    required this.anchor,
    required this.manualStartLabel,
    required this.onScan,
  });

  final AnchorPoint? anchor;
  final String manualStartLabel;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final value = anchor;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: value == null
            ? const Color(0x101E88E5)
            : const Color(0x143DDC97),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: value == null
              ? const Color(0x3372A7FF)
              : const Color(0x333DDC97),
        ),
      ),
      child: Row(
        children: [
          Icon(
            value == null ? Icons.my_location_rounded : Icons.qr_code_2_rounded,
            color: value == null
                ? const Color(0xFF72A7FF)
                : const Color(0xFF3DDC97),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value == null
                      ? 'Manual preview start'
                      : value.visualPoseReady
                          ? 'Visual QR target'
                          : 'Legacy QR start',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  value == null
                      ? manualStartLabel
                      : '${value.label} • Floor ${value.floor}',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: onScan,
            icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
            label: Text(
              value == null
                  ? 'SCAN LOCATION'
                  : value.visualPoseReady
                      ? 'SCANNER FALLBACK'
                      : 'UPDATE LOCATION',
            ),
          ),
        ],
      ),
    );
  }
}

class _OrientationCard extends StatelessWidget {
  const _OrientationCard({
    required this.route,
    required this.deviceHeading,
    required this.targetBearing,
    required this.relativeTurn,
    required this.calibrated,
    required this.headingError,
    required this.onCalibrate,
  });

  final RouteResult route;
  final double? deviceHeading;
  final double? targetBearing;
  final double? relativeTurn;
  final bool calibrated;
  final String? headingError;
  final VoidCallback onCalibrate;

  @override
  Widget build(BuildContext context) {
    final arrived = route.legs.isEmpty;
    final firstLeg = arrived ? null : route.legs.first;
    final heading = deviceHeading;
    final bearing = targetBearing;
    final turn = relativeTurn;

    String status;
    Color statusColor;

    if (arrived) {
      status = 'Destination reached';
      statusColor = const Color(0xFF3DDC97);
    } else if (headingError != null) {
      status = 'Heading unavailable';
      statusColor = const Color(0xFFF9C74F);
    } else if (heading == null) {
      status = 'Waiting for compass…';
      statusColor = Colors.white54;
    } else if (!calibrated) {
      status = 'Calibration required';
      statusColor = const Color(0xFFF9C74F);
    } else if (turn != null) {
      status = DirectionGuidance.relativeInstruction(turn);
      statusColor = const Color(0xFF72A7FF);
    } else {
      status = 'Ready';
      statusColor = const Color(0xFF72A7FF);
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF121A2D),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0x223B82F6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.explore_rounded, color: Color(0xFF72A7FF)),
              const SizedBox(width: 9),
              const Expanded(
                child: Text(
                  'LIVE ORIENTATION',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: statusColor.withValues(alpha: 0.30)),
                ),
                child: Text(
                  status.toUpperCase(),
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (arrived)
            const Text(
              'No orientation guidance is needed at the destination.',
              style: TextStyle(color: Colors.white60),
            )
          else ...[
            Row(
              children: [
                SizedBox(
                  width: 84,
                  height: 84,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0x0F72A7FF),
                          border: Border.all(color: const Color(0x3372A7FF)),
                        ),
                      ),
                      Transform.rotate(
                        angle: (turn ?? 0) * math.pi / 180,
                        child: Icon(
                          Icons.navigation_rounded,
                          size: 48,
                          color: calibrated
                              ? const Color(0xFF72A7FF)
                              : Colors.white24,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        firstLeg == null
                            ? '—'
                            : 'Next: ${firstLeg.to.label}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        firstLeg == null
                            ? '—'
                            : '${firstLeg.distanceMeters.toStringAsFixed(0)} m remaining on this segment',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        heading == null
                            ? 'Device heading: —'
                            : 'Device heading: ${heading.toStringAsFixed(0)}° '
                                '${DirectionGuidance.compassPoint(heading)}',
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        bearing == null
                            ? 'Route bearing: calibrate first'
                            : 'Route bearing: ${bearing.toStringAsFixed(0)}° '
                                '${DirectionGuidance.compassPoint(bearing)}',
                        style: const TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                      if (turn != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          DirectionGuidance.relativeAngleLabel(turn),
                          style: const TextStyle(
                            color: Color(0xFF8EB7FF),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: heading == null ? null : onCalibrate,
                icon: const Icon(Icons.center_focus_strong_rounded),
                label: Text(
                  calibrated ? 'Recalibrate facing route' : 'Calibrate facing route',
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Stand at the known checkpoint, face the real next path, then calibrate. '
              'This aligns the portable venue graph with the phone compass without '
              'assuming that the hand-drawn map is true north.',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 10,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF121A2D),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x223B82F6)),
      ),
      child: Column(
        children: [
          Icon(icon, color: const Color(0xFF72A7FF), size: 20),
          const SizedBox(height: 8),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
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

class _StepTile extends StatelessWidget {
  const _StepTile({
    required this.index,
    required this.title,
    required this.subtitle,
    required this.isLast,
  });

  final int index;
  final String title;
  final String subtitle;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 32,
            child: Column(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isLast
                        ? const Color(0xFF3DDC97)
                        : const Color(0xFF72A7FF),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '$index',
                    style: const TextStyle(
                      color: Color(0xFF07101E),
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: const Color(0x334B648B),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Color(0x73FFFFFF), fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
