import 'package:flutter/material.dart';

import '../models/mapping_session.dart';
import '../models/venue.dart';
import '../services/venue_mapping_service.dart';
import '../services/continuous_3d_trace.dart';
import '../services/venue_override_storage.dart';
import '../services/venue_3d_graph_service.dart';
import '../widgets/mapping_session_map.dart';

class MappingReviewScreen extends StatefulWidget {
  const MappingReviewScreen({
    super.key,
    required this.session,
    required this.currentVenue,
  });

  final MappingSession session;
  final Venue currentVenue;

  @override
  State<MappingReviewScreen> createState() => _MappingReviewScreenState();
}

class _MappingReviewScreenState extends State<MappingReviewScreen> {
  final VenueMappingService _mappingService = const VenueMappingService();
  final VenueOverrideStorage _overrideStorage = const VenueOverrideStorage();

  VenueOverrideDocument? _document;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadOverride();
  }

  Future<void> _loadOverride() async {
    final document = await _overrideStorage.load(widget.currentVenue.id);
    if (!mounted) return;
    setState(() {
      _document = document;
      _loading = false;
    });
  }

  Future<void> _publishContinuous3D() async {
    final session = widget.session;
    if (!session.isContinuous3D || session.isDraft3D || _busy) return;
    final already = _document?.isContinuous3D == true &&
        _document!.appliedSessionIds.contains(session.id);
    if (already) return;
    final accepted = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Publish measured 3D campus map?'),
            content: const Text(
              'This replaces the ACTIVE sample/previous venue with a '
              'connected graph built from the one real 3D route: rooms, '
              'stairs, height, and QR location IDs. Your original recordings '
              'remain saved. A backup of the current venue is created first. '
              'Other independent ARCore sessions cannot be merged without '
              'verified physical alignment. QR labels identify a location '
              'but do not yet relocalize an ARCore camera.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Publish 3D campus graph'),
              ),
            ],
          ),
        ) ??
        false;
    if (!accepted || !mounted) return;
    setState(() => _busy = true);
    try {
      final venue = const Venue3DGraphService().build(
        template: widget.currentVenue,
        session: session,
      );
      final current = _document ??
          VenueOverrideDocument(
            venue: widget.currentVenue,
            coordinateSpace: 'sample',
            appliedSessionIds: const [],
            updatedAt: DateTime.now(),
          );
      // Do not destroy the previous graph when the new recording is published.
      await _overrideStorage.saveGraphBackup(current);
      await _overrideStorage.save(VenueOverrideDocument(
        venue: venue,
        coordinateSpace: 'world_xyz_3d',
        appliedSessionIds: [session.id],
        updatedAt: DateTime.now(),
      ));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '3D campus graph published! The active map now contains '
            'your measured rooms, QR landmarks, stairs and XYZ heights.',
          ),
        ),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not publish 3D graph: $error')),
      );
    }
  }

  Future<void> _apply() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Replace Floor ${widget.session.floor}?'),
            content: const Text(
              'This recording will become the active geometry for this floor. '
              'Other floors are preserved. You can restore the bundled sample '
              'from Saved Mappings if needed.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Apply recording'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed || !mounted) return;

    setState(() => _busy = true);

    try {
      final venue = _mappingService.applySession(
        venue: widget.currentVenue,
        session: widget.session,
      );

      final document = VenueOverrideDocument(
        venue: venue,
        coordinateSpace: 'world_meters',
        appliedSessionIds: <String>[widget.session.id],
        updatedAt: DateTime.now(),
      );

      await _overrideStorage.save(document);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Recording applied to the venue.'),
        ),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not apply recording: $error')),
      );
    }
  }

  Future<void> _merge() async {
    final currentDocument = _document;
    if (currentDocument == null || !currentDocument.usesRecordedMeters) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Apply one recording first. Merge needs an existing recorded venue.',
          ),
        ),
      );
      return;
    }

    if (currentDocument.appliedSessionIds.contains(widget.session.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This recording is already part of the active venue.'),
        ),
      );
      return;
    }

    setState(() => _busy = true);

    try {
      final venue = _mappingService.mergeSession(
        venue: currentDocument.venue,
        session: widget.session,
      );

      final document = VenueOverrideDocument(
        venue: venue,
        coordinateSpace: 'world_meters',
        appliedSessionIds: <String>[
          ...currentDocument.appliedSessionIds,
          widget.session.id,
        ],
        updatedAt: DateTime.now(),
      );

      await _overrideStorage.save(document);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Recording merged into the venue.')),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not merge recording: $error')),
      );
    }
  }

  String _dateLabel(DateTime value) {
    final y = value.year.toString().padLeft(4, '0');
    final m = value.month.toString().padLeft(2, '0');
    final d = value.day.toString().padLeft(2, '0');
    final hh = value.hour.toString().padLeft(2, '0');
    final mm = value.minute.toString().padLeft(2, '0');
    return '$y-$m-$d  $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final trace = session.isContinuous3D
        ? Continuous3DTrace.analyze(
            points: session.points,
            markers: session.markers,
            segmentStarts: session.segmentStarts,
            startFloor: session.floor,
          )
        : null;
    final spatialAlignmentReady =
        session.isSpatial &&
        _document != null &&
        _mappingService.hasSpatialAlignment(
          venue: _document!.venue,
          session: session,
        );
    final canMerge =
        !_loading &&
        _document != null &&
        _document!.usesRecordedMeters &&
        (!session.isSpatial || spatialAlignmentReady);
    final alreadyApplied =
        _document?.appliedSessionIds.contains(session.id) ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Review Mapping',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 32),
        children: [
          MappingSessionMap(session: session),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _Metric(
                  value: session.isSpatial
                      ? '${session.points.length}'
                      : '${session.points.length - 1}',
                  label: session.isSpatial ? 'Geometry pts' : 'Steps',
                ),
              ),
              Expanded(
                child: _Metric(
                  value: '${session.totalDistanceMeters.toStringAsFixed(1)} m',
                  label: 'Distance',
                ),
              ),
              Expanded(
                child: _Metric(
                  value: session.isContinuous3D
                      ? '${trace!.netHeightMeters.toStringAsFixed(1)} m'
                      : '${session.markers.length}',
                  label: session.isContinuous3D ? 'Height Δ' : 'Markers',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (session.segmentCount > 1) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                  '${session.segmentCount} separate path sections recorded. '
                  'The preview deliberately leaves the gaps OPEN. '
                  'Apply this mapping first, then open Saved Mappings → '
                  'EDIT SAVED VENUE WAYPOINTS and use ALIGN SECTIONS '
                  'only at matching physical junctions. '
                  'Unconnected destinations will not route until linked.',
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 6),
          _InfoCard(
            children: [
              _InfoRow(
                label: session.isContinuous3D ? 'Floor span' : 'Floor',
                value: session.isContinuous3D
                    ? trace!.visitedFloors.map((floor) =>
                        floor < 0 ? 'B${floor.abs()}' : 'F$floor').join(' → ')
                    : 'Floor ${session.floor}',
              ),
              _InfoRow(
                label: 'Separate sections',
                value: '${session.segmentCount}',
              ),
              _InfoRow(
                label: 'Geometry',
                value: session.isContinuous3D
                    ? 'V10 measured XYZ (one ARCore session)'
                    : session.isSpatial ? 'ARCore spatial' : 'Legacy step + compass',
              ),
              _InfoRow(
                label: 'Start anchor',
                value: session.startAnchorLabel ?? 'No anchor',
              ),
              _InfoRow(
                label: 'Created',
                value: _dateLabel(session.createdAt),
              ),
              _InfoRow(
                label: 'Origin heading',
                value: '${session.originHeadingDegrees.toStringAsFixed(0)}°',
              ),
              if (session.isSpatial)
                _InfoRow(
                  label: 'Mapping quality',
                  value: session.qualityLabel,
                ),
              if (session.isSpatial)
                _InfoRow(
                  label: 'Geometry reduction',
                  value: '${session.effectiveRawPointCount} raw → '
                      '${session.points.length} saved',
                ),
              if (session.isSpatial)
                _InfoRow(
                  label: 'Tracking pauses',
                  value: '${session.trackingInterruptions}',
                ),
              if (session.isSpatial)
                _InfoRow(
                  label: 'Pose jumps blocked',
                  value: '${session.rejectedPoseJumps}',
                ),
            ],
          ),
          const SizedBox(height: 18),
          const Text(
            'MARKERS',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          if (session.markers.isEmpty)
            const _EmptyMarkers()
          else
            for (final marker in session.markers)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(_markerIcon(marker.type)),
                  title: Text(
                    marker.label,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    marker.referenceAnchorId == null
                        ? '${marker.type.toUpperCase()} · Floor ${marker.floor}'
                        : 'KNOWN ANCHOR · Floor ${marker.floor} · '
                            '${marker.referenceAnchorId}',
                  ),
                ),
              ),
          const SizedBox(height: 16),
          if (alreadyApplied)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0x143DDC97),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0x333DDC97)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.check_circle_rounded, color: Color(0xFF3DDC97)),
                  SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      'This session is already part of the active venue.',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),
          if (alreadyApplied) const SizedBox(height: 12),
          if (session.isContinuous3D) ...[
            Card(
              color: const Color(0x22166485),
              child: Padding(
                padding: const EdgeInsets.all(15),
                child: Text(
                  'V11 UNIFIED 3D CAMPUS ROUTE — '
                  '${trace!.pathMeters.toStringAsFixed(1)} m XYZ path, '
                  '${trace.netHeightMeters.toStringAsFixed(1)} m net height, '
                  '${trace.ascentMeters.toStringAsFixed(1)} m total ascent.\n\n'
                  session.isDraft3D
                      ? 'AUTOSAVED SAFETY DRAFT: this is not a completed '
                          'route. It remains available after a crash, but '
                          'cannot replace the active campus graph.'
                      : 'Publish this continuous route as the active '
                          '3D campus venue. It keeps actual XYZ heights, '
                          'room labels, stair links and printed QR IDs. '
                          'The existing venue is backed up. '
                          'QR scanning alone does not relocalize a new '
                          'ARCore camera; alignment is not yet verified.',
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy || session.isDraft3D || alreadyApplied
                  ? null : _publishContinuous3D,
              icon: const Icon(Icons.account_tree_rounded),
              label: Text(
                session.isDraft3D
                    ? 'DRAFT — FINISH A ROUTE FIRST'
                    : alreadyApplied
                        ? '3D GRAPH ALREADY PUBLISHED'
                        : 'PUBLISH 3D CAMPUS GRAPH',
              ),
            ),
          ] else ...[
          FilledButton.icon(
            onPressed: _busy ? null : _apply,
            icon: const Icon(Icons.layers_rounded),
            label: Text('APPLY TO FLOOR ${session.floor}'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy || !canMerge || alreadyApplied ? null : _merge,
            icon: const Icon(Icons.merge_rounded),
            label: const Text('MERGE INTO ACTIVE VENUE'),
          ),
          const SizedBox(height: 8),
          Text(
            session.isSpatial
                ? spatialAlignmentReady
                    ? 'Two known anchors are available. Merge will solve one '
                        'rigid rotation + translation and connect this route '
                        'into the existing venue graph.'
                    : 'Spatial merge needs two known anchors. Start from one '
                        'existing anchor, then mark another existing anchor '
                        'while recording using QR anchor → Reference existing.'
                : canMerge
                    ? 'Merge aligns this recording to its existing start QR '
                        'anchor and keeps the current venue geometry.'
                    : 'Apply one recording first. That establishes the real '
                        'meter-based coordinate frame used by later merges.',
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 10,
              height: 1.4,
            ),
          ),
          ],
          if (_busy) ...[
            const SizedBox(height: 18),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }

  static IconData _markerIcon(String type) {
    return switch (type) {
      'destination' => Icons.flag_rounded,
      'stairs' => Icons.stairs_rounded,
      'floor_level' => Icons.layers_rounded,
      'anchor' => Icons.qr_code_2_rounded,
      _ => Icons.add_location_alt_rounded,
    };
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(color: Colors.white38, fontSize: 10),
        ),
      ],
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF111A2E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x223B82F6)),
      ),
      child: Column(children: children),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyMarkers extends StatelessWidget {
  const _EmptyMarkers();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF111A2E),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Text(
        'No semantic markers were added to this recording.',
        style: TextStyle(color: Colors.white54, fontSize: 11),
      ),
    );
  }
}
