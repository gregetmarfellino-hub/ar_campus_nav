import 'package:flutter/material.dart';

import '../models/anchor_point.dart';
import '../models/destination.dart';
import '../models/route_result.dart';
import '../models/venue.dart';
import '../services/floor_navigation_plan.dart';
import '../widgets/venue_map.dart';
import 'ar_navigation_screen.dart';

enum _FloorHandoffPhase { followFloor, travelPortal, finished }

/// V9's offline, explicit floor-by-floor AR navigation controller.
///
/// One native ARCore session is started per *single-floor* section. The
/// staircase/elevator is traversed physically without AR guidance and the
/// next floor starts from an independently verified physical landing.
/// Neither floor changes nor AR re-localization are inferred automatically.
class MultiFloorNavigationScreen extends StatefulWidget {
  const MultiFloorNavigationScreen({
    super.key,
    required this.venue,
    required this.destination,
    required this.fullRoute,
    this.initialAnchor,
  });

  final Venue venue;
  final Destination destination;
  final RouteResult fullRoute;
  final AnchorPoint? initialAnchor;

  @override
  State<MultiFloorNavigationScreen> createState() =>
      _MultiFloorNavigationScreenState();
}

class _MultiFloorNavigationScreenState
    extends State<MultiFloorNavigationScreen> {
  late final FloorNavigationPlan _plan;

  int _stageIndex = 0;
  _FloorHandoffPhase _phase = _FloorHandoffPhase.followFloor;
  bool _confirmedAtExit = false;
  bool _confirmedAtNextLanding = false;
  bool _arGuideVisited = false;
  bool _openingAr = false;

  @override
  void initState() {
    super.initState();
    _plan = FloorNavigationPlan.fromRoute(widget.fullRoute);
  }

  String _floorName(int floor) =>
      floor < 0 ? 'Basement ${floor.abs()}' : 'Floor $floor';

  FloorNavigationStage get _stage => _plan.stages[_stageIndex];

  AnchorPoint? _anchorForCurrentStart() {
    final id = _stage.entryNodeId;
    final floor = _stage.floor;
    if (widget.initialAnchor?.nodeId == id &&
        widget.initialAnchor?.floor == floor) {
      return widget.initialAnchor;
    }
    // An optional, physically mapped visual checkpoint can re-localize the
    // next floor. An ordinary provisional floor origin is NOT an AR anchor.
    for (final anchor in widget.venue.anchors) {
      if (anchor.nodeId == id &&
          anchor.floor == floor &&
          (anchor.offlineVisualReady || anchor.visualPoseReady)) {
        return anchor;
      }
    }
    return null; // Explicit manual alignment, never use another floor's QR.
  }

  Future<void> _launchFloorAr() async {
    if (_openingAr || !_stage.hasWalk ||
        _phase != _FloorHandoffPhase.followFloor) {
      return;
    }

    final section = _stage;
    final anchor = _anchorForCurrentStart();
    if (_stageIndex > 0 && anchor == null) {
      final proceed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text('Re-align on ${_floorName(section.floor)}'),
              content: Text(
                'Stand at the REAL ${section.route.nodes.first.label} '
                'landing you just confirmed. This saved floor is in a '
                'different ARCore world frame from the previous floor.\n\n'
                'The next AR camera starts a fresh local session. '
                'Face the first REAL mapped corridor and tap '
                'FACE PATH & START once — no 2-metre walk or QR required.\n\n'
                'This trusts where you stand and point the camera. '
                'Compare the first arrow with the REAL corridor; stop '
                'and RE-ALIGN if it does not match.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Not at the landing'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Start fresh AR'),
                ),
              ],
            ),
          ) ??
          false;
      if (!mounted || !proceed) return;
    }

    final exit = section.route.nodes.last;
    final destination = section.isFinal
        ? widget.destination
        : Destination(
            id: 'v9_portal_${exit.id}',
            name: '${exit.label} (${_floorName(exit.floor)})',
            nodeId: exit.id,
            category: section.transitionAfter?.transitionType ?? 'stairs',
          );

    setState(() => _openingAr = true);
    try {
      await Navigator.of(context).push<ArNavigationResult>(
        MaterialPageRoute<ArNavigationResult>(
          builder: (_) => ArNavigationScreen(
            venue: widget.venue,
            destination: destination,
            initialRoute: section.route,
            initialAnchor: anchor,
          ),
        ),
      );
      if (!mounted) return;
      setState(() {
        _arGuideVisited = true;
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open floor-local AR: $error')),
      );
    } finally {
      if (mounted) setState(() => _openingAr = false);
    }
  }

  void _confirmFloorExit() {
    if (!_confirmedAtExit ||
        _phase != _FloorHandoffPhase.followFloor) {
      return;
    }
    setState(() {
      _confirmedAtExit = false;
      _phase = _stage.transitionAfter == null
          ? _FloorHandoffPhase.finished
          : _FloorHandoffPhase.travelPortal;
    });
  }

  void _confirmFloorLanding() {
    if (!_confirmedAtNextLanding ||
        _phase != _FloorHandoffPhase.travelPortal ||
        _stage.transitionAfter == null ||
        _stageIndex >= _plan.stages.length - 1) {
      return;
    }
    final portal = _stage.transitionAfter!;
    final next = _plan.stages[_stageIndex + 1];
    if (portal.to.id != next.entryNodeId ||
        portal.to.floor != next.floor) {
      throw StateError('The next floor does not match the saved portal.');
    }
    setState(() {
      _stageIndex++;
      _phase = _FloorHandoffPhase.followFloor;
      _confirmedAtNextLanding = false;
      _confirmedAtExit = false;
      _arGuideVisited = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_phase == _FloorHandoffPhase.finished) {
      return Scaffold(
        appBar: AppBar(title: const Text('Multi-floor navigation')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(25),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.check_circle_outline_rounded,
                  color: Color(0xFF3DDC97), size: 68,
                ),
                const SizedBox(height: 15),
                const Text(
                  'Route completed (manually confirmed)',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'You confirmed arrival at ${widget.destination.name} '
                  'on ${_floorName(_stage.floor)}. '
                  'This is your confirmation, not automatic floor detection.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.done_rounded),
                  label: const Text('FINISH'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final stage = _stage;
    final transition = stage.transitionAfter;
    final portalType = transition?.transitionType == 'elevator'
        ? 'elevator' : 'stairs';
    final nextFloor = transition?.to.floor;
    final isTravel = _phase == _FloorHandoffPhase.travelPortal;
    if (isTravel && transition == null) {
      throw StateError('Missing mapped floor portal during handoff.');
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Multi-floor AR navigation'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 30),
        children: [
          Text(
            widget.destination.name,
            style: const TextStyle(
              fontSize: 24, fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Section ${_stageIndex + 1} / ${_plan.floorCount}'
            ' • ${_floorName(stage.floor)}',
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < _plan.stages.length; i++)
                Chip(
                  avatar: Icon(
                    i < _stageIndex
                        ? Icons.check_circle_rounded
                        : i == _stageIndex
                            ? Icons.navigation_rounded
                            : Icons.layers_rounded,
                    size: 17,
                  ),
                  label: Text(_floorName(_plan.stages[i].floor)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (!isTravel) ...[
            _infoCard(
              icon: Icons.route_rounded,
              title: 'FOLLOW THIS FLOOR',
              detail:
                  'From: ${stage.route.nodes.first.label}\n'
                  'To: ${stage.route.nodes.last.label}\n'
                  'Recorded corridor: '
                  '${stage.route.totalDistanceMeters.toStringAsFixed(1)} m',
            ),
            const SizedBox(height: 12),
            VenueMap(
              venue: widget.venue,
              route: stage.route,
              floor: stage.floor,
              currentNodeId: stage.entryNodeId,
              height: 330,
            ),
            const SizedBox(height: 13),
            if (stage.hasWalk)
              FilledButton.icon(
                onPressed: _openingAr ? null : _launchFloorAr,
                icon: const Icon(Icons.view_in_ar_rounded),
                label: Text(
                  _openingAr
                      ? 'OPENING AR...'
                      : _arGuideVisited
                          ? 'RESTART THIS FLOOR AR'
                          : 'START AR ON ${_floorName(stage.floor).toUpperCase()}',
                ),
              )
            else
              const Text(
                'No corridor to walk on this floor. You are at the '
                'mapped transition point; verify it physically.',
                style: TextStyle(color: Colors.white70),
              ),
            const SizedBox(height: 10),
            _infoCard(
              icon: Icons.info_outline_rounded,
              title: 'PHYSICAL CONFIRMATION REQUIRED',
              detail: stage.isFinal
                  ? 'Only confirm after physically reaching the final '
                    'destination. AR arrival alone may be inaccurate.'
                  : 'Stop at the real ${stage.route.nodes.last.label}. '
                    'Do not follow AR arrows onto the stairs; the floor '
                    'transition is handled separately.',
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _confirmedAtExit,
              onChanged: (value) => setState(
                () => _confirmedAtExit = value ?? false,
              ),
              title: Text(
                stage.isFinal
                    ? 'I am physically at ${widget.destination.name}'
                    : 'I am physically at ${stage.route.nodes.last.label}',
              ),
              subtitle: const Text(
                'Manual confirmation; the app cannot verify this automatically.',
              ),
            ),
            const SizedBox(height: 5),
            FilledButton.icon(
              onPressed: _confirmedAtExit ? _confirmFloorExit : null,
              icon: Icon(
                stage.isFinal
                    ? Icons.flag_rounded
                    : Icons.stairs_rounded,
              ),
              label: Text(
                stage.isFinal
                    ? 'CONFIRM DESTINATION REACHED'
                    : 'CONTINUE TO FLOOR TRANSITION',
              ),
            ),
          ] else ...[
            _infoCard(
              icon: portalType == 'elevator'
                  ? Icons.elevator_rounded
                  : Icons.stairs_rounded,
              title: 'AR PAUSED — CHANGE FLOORS',
              detail:
                  'Take the $portalType from '
                  '${transition!.from.label} (${_floorName(transition.from.floor)}) '
                  'to ${transition!.to.label} '
                  '(${_floorName(transition!.to.floor)}).\n\n'
                  'Estimated travel: '
                  '${transition!.distanceMeters.toStringAsFixed(1)} m.\n'
                  'Use actual stair/elevator signs. Do NOT follow '
                  'a horizontal AR ribbon between floors.',
            ),
            const SizedBox(height: 14),
            _infoCard(
              icon: Icons.my_location_rounded,
              title: 'NEXT: RE-LOCALIZE ON ${_floorName(nextFloor!).toUpperCase()}',
              detail: 'Once you reach the matching landing, confirm that '
                  'specific physical spot. V9 then starts a NEW ARCore '
                  'session for the next floor. If there is no saved visual '
                  'reference, stand at the correct landing, face the first '
                  'real corridor and tap FACE PATH & START. '
                  'No QR or 2-metre walk is required.',
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _confirmedAtNextLanding,
              onChanged: (value) => setState(
                () => _confirmedAtNextLanding = value ?? false,
              ),
              title: Text(
                'I have reached ${transition!.to.label} '
                'on ${_floorName(nextFloor!)}',
              ),
              subtitle: const Text(
                'I can identify this exact real-world landing.',
              ),
            ),
            FilledButton.icon(
              onPressed: _confirmedAtNextLanding
                  ? _confirmFloorLanding : null,
              icon: const Icon(Icons.layers_rounded),
              label: Text('CONTINUE ON ${_floorName(nextFloor!).toUpperCase()}'),
            ),
          ],
          const SizedBox(height: 16),
          const Text(
            'V9 is an experimental route handoff. Floor changes and '
            'manual checkpoint confirmations are user-controlled; '
            'ARCore drift is not automatically corrected.',
            style: TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _infoCard({
    required IconData icon,
    required String title,
    required String detail,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: const Color(0xFF72A7FF)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(detail, style: const TextStyle(height: 1.4)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
