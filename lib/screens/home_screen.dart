import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/anchor_point.dart';
import '../models/destination.dart';
import '../models/nav_node.dart';
import '../models/venue.dart';
import '../services/anchor_codec.dart';
import '../services/route_engine.dart';
import '../services/venue_loader.dart';
import '../widgets/venue_map.dart';
import 'anchor_qr_screen.dart';
import 'spatial_mapping_screen.dart';
import 'mapping_sessions_screen.dart';
import 'qr_anchor_scanner_screen.dart';
import 'route_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _demoPackage = 'assets/venues/demo_campus';

  final VenueLoader _loader = const VenueLoader();
  final RouteEngine _routeEngine = const RouteEngine();
  final AnchorCodec _anchorCodec = const AnchorCodec();

  Venue? _venue;
  String? _startNodeId;
  AnchorPoint? _activeAnchor;
  String _query = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadVenue();
  }

  Future<void> _loadVenue() async {
    try {
      final venue = await _loader.load(_demoPackage);
      if (!mounted) return;

      setState(() {
        _venue = venue;
        _startNodeId = venue.defaultStartNodeId;
        _activeAnchor = null;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    }
  }

  Future<bool> _scanAnchor() async {
    final venue = _venue;
    if (venue == null) return false;

    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => const QrAnchorScannerScreen(),
      ),
    );

    if (!mounted || raw == null) return false;

    try {
      final anchor = _anchorCodec.resolve(
        venue: venue,
        rawValue: raw,
      );

      setState(() {
        _startNodeId = anchor.nodeId;
        _activeAnchor = anchor;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Location confirmed: ${anchor.label}. Start navigation before moving away.',
          ),
        ),
      );
      return true;
    } on FormatException catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
      return false;
    } catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not use this anchor: $error')),
      );
      return false;
    }
  }

  Future<void> _openAnchorQrLibrary({String? initialAnchorId}) async {
    final venue = _venue;
    if (venue == null) return;

    final selected = await Navigator.of(context).push<AnchorPoint>(
      MaterialPageRoute<AnchorPoint>(
        builder: (_) => AnchorQrScreen(
          venue: venue,
          initialAnchorId: initialAnchorId,
        ),
      ),
    );

    if (!mounted || selected == null) return;

    setState(() {
      _startNodeId = selected.nodeId;
      _activeAnchor = selected;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          selected.visualPoseReady
              ? 'AR start target set: ${selected.label}. AR will confirm '
                  'the physical QR pose when guidance opens.'
              : 'Legacy start target set: ${selected.label}. Manual '
                  'direction alignment is still required.',
        ),
      ),
    );
  }

  Future<void> _openMapper() async {
    final venue = _venue;
    if (venue == null) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SpatialMappingScreen(
          venue: venue,
          initialAnchor: _activeAnchor,
        ),
      ),
    );

    if (!mounted) return;
    await _loadVenue();
  }

  Future<void> _openSavedMappings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const MappingSessionsScreen(
          packagePath: _demoPackage,
        ),
      ),
    );

    if (!mounted) return;
    await _loadVenue();
  }



  AnchorPoint? _anchorForStartNode(Venue venue) {
    final nodeId = _startNodeId;
    if (nodeId == null) return null;

    AnchorPoint? visualFallback;
    AnchorPoint? fallback;
    for (final anchor in venue.anchors) {
      if (anchor.nodeId != nodeId) continue;
      if (anchor.persistentPoseReady) return anchor;
      if (anchor.visualPoseReady) visualFallback ??= anchor;
      fallback ??= anchor;
    }
    return visualFallback ?? fallback;
  }

  Future<void> _openRoute(Destination destination) async {
    final venue = _venue;
    if (venue == null) return;

    // A visual-ready anchor does NOT need the old standalone scanner first.
    // It is only an expected physical target here; ARCore confirms its pose
    // inside the AR camera when navigation starts.
    var routeAnchor = _activeAnchor ?? _anchorForStartNode(venue);

    if (routeAnchor == null || !routeAnchor.visualPoseReady) {
      final choice = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        backgroundColor: const Color(0xFF111A2E),
        builder: (sheetContext) {
          final selected = routeAnchor;
          return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(
                        Icons.location_searching_rounded,
                        color: Color(0xFFF9C74F),
                      ),
                      SizedBox(width: 10),
                      Text(
                        'CHOOSE LOCALIZATION',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.7,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    selected == null
                        ? 'This start has no visual-ready QR. Use the legacy '
                            'scanner to choose a known location, or continue '
                            'with manual preview.'
                        : 'The selected QR is a legacy position-only anchor. '
                            'It can identify the location, but AR still needs '
                            'manual direction calibration until this anchor is '
                            're-mapped with visual facing.',
                    style: const TextStyle(
                      color: Colors.white70,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () =>
                          Navigator.of(sheetContext).pop('scan'),
                      icon: const Icon(Icons.qr_code_scanner_rounded),
                      label: const Text('SCAN LEGACY LOCATION'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          Navigator.of(sheetContext).pop('preview'),
                      icon: const Icon(Icons.science_outlined),
                      label: const Text('CONTINUE IN MANUAL PREVIEW'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );

      if (!mounted || choice == null) return;

      if (choice == 'scan') {
        final confirmed = await _scanAnchor();
        if (!mounted || !confirmed) return;
        routeAnchor = _activeAnchor;
      } else {
        routeAnchor = _activeAnchor;
      }
    }

    final startNodeId = routeAnchor?.nodeId ?? _startNodeId;
    if (startNodeId == null) return;

    try {
      final route = _routeEngine.shortestPath(
        venue: venue,
        startNodeId: startNodeId,
        destinationNodeId: destination.nodeId,
      );

      if (!mounted) return;

      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RouteScreen(
            venue: venue,
            destination: destination,
            initialRoute: route,
            initialAnchor: routeAnchor,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }


  Destination _navigationTargetForNode(Venue venue, NavNode node) {
    for (final destination in venue.destinations) {
      if (destination.nodeId == node.id) {
        return destination;
      }
    }

    final category = switch (node.type) {
      'stairs' => 'stairs',
      'anchor' => 'anchor',
      'waypoint' => 'waypoint',
      _ => 'place',
    };

    return Destination(
      id: 'marker_${node.id}',
      name: node.label,
      nodeId: node.id,
      category: category,
      description: 'Mapped point on Floor ${node.floor}',
    );
  }

  AnchorPoint? _anchorForNode(Venue venue, NavNode node) {
    AnchorPoint? fallback;
    for (final anchor in venue.anchors) {
      if (anchor.nodeId != node.id) continue;
      if (anchor.visualPoseReady) return anchor;
      fallback ??= anchor;
    }
    return fallback;
  }

  String _markerKind(Venue venue, NavNode node) {
    if (venue.destinations.any((item) => item.nodeId == node.id) ||
        node.type == 'destination') {
      return 'Destination';
    }
    if (node.type == 'stairs') return 'Stairs';
    if (_anchorForNode(venue, node) != null || node.type == 'anchor') {
      return 'QR anchor';
    }
    return 'Waypoint';
  }

  IconData _markerIcon(Venue venue, NavNode node) {
    return switch (_markerKind(venue, node)) {
      'Destination' => Icons.flag_rounded,
      'Stairs' => Icons.stairs_rounded,
      'QR anchor' => Icons.qr_code_2_rounded,
      _ => Icons.add_location_alt_rounded,
    };
  }

  Color _markerColor(Venue venue, NavNode node) {
    return switch (_markerKind(venue, node)) {
      'Destination' => const Color(0xFFFF6B8A),
      'Stairs' => const Color(0xFFF9C74F),
      'QR anchor' => const Color(0xFF3DDC97),
      _ => const Color(0xFFCBA6F7),
    };
  }

  void _setStartFromNode(Venue venue, NavNode node) {
    final anchor = _anchorForNode(venue, node);

    setState(() {
      _startNodeId = node.id;
      _activeAnchor = anchor;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          anchor == null
              ? 'Start point set: ${node.label}'
              : anchor.visualPoseReady
                  ? 'AR start target: ${node.label}. The AR camera will '
                      'confirm its QR pose.'
                  : 'Legacy AR start target: ${node.label}.',
        ),
      ),
    );
  }

  Future<void> _showAnchorPayload(AnchorPoint anchor) async {
    await _openAnchorQrLibrary(initialAnchorId: anchor.id);
  }

  void _showSemanticNodeActions(NavNode node) {
    final venue = _venue;
    if (venue == null) return;

    final kind = _markerKind(venue, node);
    final icon = _markerIcon(venue, node);
    final color = _markerColor(venue, node);
    final isCurrent = node.id == _startNodeId;

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color(0xFF111A2E),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: color.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Icon(icon, color: color),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            node.label,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '$kind • Floor ${node.floor}',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isCurrent)
                      const _Badge(
                        icon: Icons.my_location_rounded,
                        text: 'CURRENT',
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      _openRoute(_navigationTargetForNode(venue, node));
                    },
                    icon: const Icon(Icons.navigation_rounded),
                    label: const Text('NAVIGATE HERE'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      _setStartFromNode(venue, node);
                    },
                    icon: Icon(
                      kind == 'QR anchor'
                          ? Icons.my_location_rounded
                          : Icons.trip_origin_rounded,
                    ),
                    label: Text(
                      kind == 'QR anchor'
                          ? 'USE AS AR START'
                          : 'SET AS START POINT',
                    ),
                  ),
                ),
                if (_anchorForNode(venue, node) case final anchor?) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        _showAnchorPayload(anchor);
                      },
                      icon: const Icon(Icons.qr_code_2_rounded),
                      label: const Text('SHOW LOCATION QR'),
                    ),
                  ),
                ],
                if (kind == 'Stairs') ...[
                  const SizedBox(height: 10),
                  const Text(
                    'Floor transition point. Multi-floor routing will connect '
                    'this marker to its matching stairs layer later.',
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final venue = _venue;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.explore_rounded, color: Color(0xFF72A7FF)),
            SizedBox(width: 10),
            Text(
              'AR Campus Nav',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
          ],
        ),
      ),
      body: _error != null
          ? _ErrorState(message: _error!, onRetry: _loadVenue)
          : venue == null
              ? const Center(child: CircularProgressIndicator())
              : _buildLoaded(venue),
    );
  }

  Widget _buildLoaded(Venue venue) {
    final startNodes = venue.nodes
        .where((node) => node.type != 'restricted')
        .toList(growable: false);

    final normalizedQuery = _query.trim().toLowerCase();
    final destinations = venue.destinations.where((destination) {
      if (normalizedQuery.isEmpty) return true;
      return destination.name.toLowerCase().contains(normalizedQuery) ||
          destination.category.toLowerCase().contains(normalizedQuery);
    }).toList(growable: false);

    final activeAnchor = _activeAnchor;
    final routeStartAnchor = activeAnchor ?? _anchorForStartNode(venue);
    final persistentStartReady =
        routeStartAnchor?.persistentPoseReady == true;

    return ListView(
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
                  _Badge(icon: Icons.offline_bolt_rounded, text: 'OFFLINE'),
                  SizedBox(width: 8),
                  _Badge(icon: Icons.inventory_2_rounded, text: 'VENUE MODULE'),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                venue.name,
                style: const TextStyle(
                  fontSize: 27,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.7,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                venue.description,
                style: const TextStyle(color: Colors.white60, height: 1.4),
              ),
              const SizedBox(height: 16),
              Text(
                '${venue.nodes.length} nodes  •  ${venue.edges.length} paths  •  '
                '${venue.destinations.length} destinations  •  '
                '${venue.anchors.length} anchors',
                style: const TextStyle(
                  color: Color(0xFF9DBEF7),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        VenueMap(
          venue: venue,
          floor: 1,
          height: 310,
          currentNodeId: _startNodeId,
          onSemanticNodeTap: _showSemanticNodeActions,
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: venue.anchors.isEmpty
                ? null
                : () => _openAnchorQrLibrary(),
            icon: const Icon(Icons.qr_code_2_rounded),
            label: Text(
              venue.anchors.isEmpty
                  ? 'NO LOCATION QRS YET'
                  : 'LOCATION QR CODES (${venue.anchors.length})',
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _openMapper,
            icon: const Icon(Icons.route_rounded),
            label: const Text('SPATIAL MAP / RECORD THIS FLOOR'),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _openSavedMappings,
            icon: const Icon(Icons.folder_copy_rounded),
            label: const Text('REVIEW SAVED MAPPINGS'),
          ),
        ),

        const SizedBox(height: 18),
        Text(
          persistentStartReady
              ? 'AR START'
              : activeAnchor == null
                  ? 'LOCATION'
                  : 'YOU ARE HERE',
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        if (persistentStartReady)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0x143DDC97),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0x333DDC97)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.view_in_ar_rounded,
                  color: Color(0xFF3DDC97),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'AR start portal ready',
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${routeStartAnchor!.label} has a persistent start portal. '
                        'Choose a destination; AR resolves it near the mapped '
                        'entrance and activates the saved route.',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          )
        else if (activeAnchor != null)
          _AnchorStatus(anchor: activeAnchor)
        else
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0x14F9C74F),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0x33F9C74F)),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, color: Color(0xFFF9C74F)),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'No persistent start portal yet. Map this route with the '
                    'Spatial Mapper for seamless AR startup.',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (!persistentStartReady) ...[
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _scanAnchor,
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: Text(
              activeAnchor == null
                  ? 'LEGACY SCAN LOCATION'
                  : 'SCAN ANOTHER LEGACY LOCATION',
            ),
          ),
        ],
        const SizedBox(height: 14),
        const Text(
          'PREVIEW / TEST START',
          style: TextStyle(
            color: Colors.white38,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 7),
        DropdownButtonFormField<String>(
          key: ValueKey(_startNodeId),
          initialValue: _startNodeId,
          isExpanded: true,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.science_outlined),
          ),
          items: [
            for (final node in startNodes)
              DropdownMenuItem<String>(
                value: node.id,
                child: Text(node.label),
              ),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              _startNodeId = value;
              _activeAnchor = null;
            });
          },
        ),
        const SizedBox(height: 22),
        const Text(
          'WHERE DO YOU WANT TO GO?',
          style: TextStyle(
            color: Colors.white54,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          onChanged: (value) => setState(() => _query = value),
          decoration: const InputDecoration(
            hintText: 'Search destinations...',
            prefixIcon: Icon(Icons.search_rounded),
          ),
        ),
        const SizedBox(height: 12),
        if (destinations.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Center(
              child: Text(
                'No matching destinations.',
                style: TextStyle(color: Color(0x73FFFFFF)),
              ),
            ),
          )
        else
          for (final destination in destinations)
            _DestinationCard(
              destination: destination,
              node: venue.nodeById(destination.nodeId),
              onTap: () => _openRoute(destination),
            ),
      ],
    );
  }
}

class _AnchorStatus extends StatelessWidget {
  const _AnchorStatus({required this.anchor});

  final AnchorPoint anchor;

  @override
  Widget build(BuildContext context) {
    final heading = anchor.headingDegrees;

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0x143DDC97),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x333DDC97)),
      ),
      child: Row(
        children: [
          const Icon(Icons.location_on_rounded, color: Color(0xFF3DDC97)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  anchor.label,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  heading == null
                      ? 'Floor ${anchor.floor} • Heading not calibrated'
                      : 'Floor ${anchor.floor} • Heading ${heading.toStringAsFixed(0)}°',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
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

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x1672A7FF),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x3372A7FF)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: const Color(0xFF8EB7FF)),
          const SizedBox(width: 5),
          Text(
            text,
            style: const TextStyle(
              color: Color(0xFFB9D0FA),
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _DestinationCard extends StatelessWidget {
  const _DestinationCard({
    required this.destination,
    required this.node,
    required this.onTap,
  });

  final Destination destination;
  final NavNode node;
  final VoidCallback onTap;

  IconData get _icon {
    switch (destination.category) {
      case 'lab':
        return Icons.science_rounded;
      case 'stairs':
        return Icons.stairs_rounded;
      case 'entrance':
        return Icons.door_front_door_rounded;
      case 'landmark':
        return Icons.place_rounded;
      default:
        return Icons.location_on_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: const Color(0x1572A7FF),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(_icon, color: const Color(0xFF72A7FF)),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      destination.name,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      destination.description.isEmpty
                          ? 'Floor ${node.floor}'
                          : '${destination.description} • Floor ${node.floor}',
                      style: const TextStyle(
                        color: Color(0x73FFFFFF),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.white38),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 46),
            const SizedBox(height: 12),
            const Text(
              'Venue package could not be loaded.',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0x73FFFFFF), fontSize: 11),
            ),
            const SizedBox(height: 18),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
