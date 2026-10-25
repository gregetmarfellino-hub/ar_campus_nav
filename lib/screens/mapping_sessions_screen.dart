import 'package:flutter/material.dart';

import '../models/mapping_session.dart';
import '../models/venue.dart';
import '../services/mapping_storage.dart';
import '../services/venue_loader.dart';
import '../services/venue_override_storage.dart';
import 'mapping_review_screen.dart';

class MappingSessionsScreen extends StatefulWidget {
  const MappingSessionsScreen({
    super.key,
    required this.packagePath,
  });

  final String packagePath;

  @override
  State<MappingSessionsScreen> createState() => _MappingSessionsScreenState();
}

class _MappingSessionsScreenState extends State<MappingSessionsScreen> {
  final MappingStorage _mappingStorage = const MappingStorage();
  final VenueLoader _venueLoader = const VenueLoader();
  final VenueOverrideStorage _overrideStorage = const VenueOverrideStorage();

  List<MappingSession> _sessions = const [];
  Venue? _venue;
  VenueOverrideDocument? _document;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final venue = await _venueLoader.load(widget.packagePath);
      final sessions = await _mappingStorage.listSessions();
      final document = await _overrideStorage.load(venue.id);

      if (!mounted) return;
      setState(() {
        _venue = venue;
        _sessions = sessions.where((item) => item.venueId == venue.id).toList();
        _document = document;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _openSession(MappingSession session) async {
    final venue = _venue;
    if (venue == null) return;

    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => MappingReviewScreen(
          session: session,
          currentVenue: venue,
        ),
      ),
    );

    if (changed == true) {
      await _reload();
    }
  }


  Future<void> _deleteSession(MappingSession session) async {
    final wasApplied =
        _document?.appliedSessionIds.contains(session.id) ?? false;

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete saved mapping?'),
            content: Text(
              wasApplied
                  ? 'This removes the saved recording JSON from the phone. '
                      'The active venue keeps the geometry already generated '
                      'from this recording.'
                  : 'This removes the saved recording JSON from the phone. '
                      'This cannot be undone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton.tonal(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed || !mounted) return;

    try {
      await _mappingStorage.delete(session.id);
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved mapping deleted.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete mapping: $error')),
      );
    }
  }

  Future<void> _restoreBundled() async {
    final venue = _venue;
    if (venue == null) return;

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Restore bundled sample?'),
            content: const Text(
              'The Home map will return to the bundled demo venue. '
              'Saved walk recordings stay on the phone and can be applied again.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Restore'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed || !mounted) return;

    try {
      final bundled = await _venueLoader.loadBundled(widget.packagePath);
      await _overrideStorage.save(
        VenueOverrideDocument(
          venue: bundled,
          coordinateSpace: 'sample',
          appliedSessionIds: const [],
          updatedAt: DateTime.now(),
        ),
      );
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bundled sample restored.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not restore sample: $error')),
      );
    }
  }

  String _markerSummary(MappingSession session) {
    if (session.markers.isEmpty) return '0 markers';

    final counts = <String, int>{};
    for (final marker in session.markers) {
      counts[marker.type] = (counts[marker.type] ?? 0) + 1;
    }

    const order = <String>['destination', 'waypoint', 'stairs', 'anchor'];
    final parts = <String>[];
    for (final type in order) {
      final count = counts[type] ?? 0;
      if (count == 0) continue;
      final label = switch (type) {
        'destination' => 'dest',
        'waypoint' => 'waypoint',
        'stairs' => 'stairs',
        'anchor' => 'anchor',
        _ => type,
      };
      parts.add('$count $label');
    }

    return '${session.markers.length} markers · ${parts.join(' · ')}';
  }

  String _dateLabel(DateTime value) {
    final m = value.month.toString().padLeft(2, '0');
    final d = value.day.toString().padLeft(2, '0');
    final hh = value.hour.toString().padLeft(2, '0');
    final mm = value.minute.toString().padLeft(2, '0');
    return '${value.year}-$m-$d $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final document = _document;
    final isRecorded = document?.usesRecordedMeters ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Saved Mappings',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 32),
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF111A2E),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isRecorded
                                ? const Color(0x333DDC97)
                                : const Color(0x3372A7FF),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isRecorded
                                  ? Icons.route_rounded
                                  : Icons.inventory_2_rounded,
                              color: isRecorded
                                  ? const Color(0xFF3DDC97)
                                  : const Color(0xFF72A7FF),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    isRecorded
                                        ? 'Recorded venue active'
                                        : 'Bundled sample active',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    isRecorded
                                        ? '${document!.appliedSessionIds.length} recording(s) applied'
                                        : 'Apply a recording to replace the sample floor.',
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
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _restoreBundled,
                        icon: const Icon(Icons.restart_alt_rounded),
                        label: const Text('RESTORE BUNDLED SAMPLE'),
                      ),
                      const SizedBox(height: 22),
                      const Text(
                        'OFFLINE RECORDINGS',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (_sessions.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: const Color(0xFF111A2E),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: const Text(
                            'No saved walk recordings yet.',
                            style: TextStyle(color: Colors.white54),
                          ),
                        )
                      else
                        for (final session in _sessions)
                          Card(
                            margin: const EdgeInsets.only(bottom: 10),
                            child: ListTile(
                              onTap: () => _openSession(session),
                              leading: const CircleAvatar(
                                child: Icon(Icons.route_rounded),
                              ),
                              title: Text(
                                'Floor ${session.floor} · ${session.totalDistanceMeters.toStringAsFixed(1)} m',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              subtitle: Text(
                                '${session.isSpatial ? 'ARCore spatial' : 'Legacy step'} · '
                                '${_markerSummary(session)}\n'
                                '${_dateLabel(session.createdAt)} · '
                                'Start: ${session.startAnchorLabel ?? 'No anchor'}',
                              ),
                              isThreeLine: true,
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: 'Delete saved mapping',
                                    onPressed: () => _deleteSession(session),
                                    icon: const Icon(
                                      Icons.delete_outline_rounded,
                                      color: Color(0xFFF38BA8),
                                    ),
                                  ),
                                  const Icon(Icons.chevron_right_rounded),
                                ],
                              ),
                            ),
                          ),
                    ],
                  ),
                ),
    );
  }
}
