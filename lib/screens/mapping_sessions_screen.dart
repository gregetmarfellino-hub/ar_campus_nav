import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/mapping_session.dart';
import '../models/nav_node.dart';
import '../models/venue.dart';
import '../services/mapping_storage.dart';
import '../services/venue_loader.dart';
import '../services/venue_override_storage.dart';
import '../services/venue_project_bundle.dart';
import '../services/venue_project_transfer.dart';
import 'mapping_review_screen.dart';
import 'venue_graph_editor_screen.dart';

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
  final VenueProjectTransfer _projectTransfer = const VenueProjectTransfer();

  List<MappingSession> _sessions = const [];
  Venue? _venue;
  VenueOverrideDocument? _document;
  bool _hasGraphBackup = false;
  bool _loading = true;
  bool _projectBusy = false;
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
      final backup = await _overrideStorage.loadGraphBackup(venue.id);

      if (!mounted) return;
      setState(() {
        _venue = venue;
        _sessions = sessions.where((item) => item.venueId == venue.id).toList();
        _document = document;
        _hasGraphBackup = backup != null;
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

  Future<void> _createProject() async {
    if (_projectBusy) return;
    var draftName = '';
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create independent campus project'),
        content: TextField(
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(
            labelText: 'Building / project name',
            hintText: 'E.g. Engineering Building',
          ),
          onChanged: (value) => draftName = value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(draftName.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.length < 2 || !mounted) return;
    setState(() => _projectBusy = true);
    try {
      final id = 'campus_${DateTime.now().microsecondsSinceEpoch}';
      final venue = Venue(
        id: id,
        name: name,
        description: 'Offline user-created venue. Walk and publish a 3D mapping.',
        defaultStartNodeId: 'project_origin',
        floors: const [1],
        nodes: const [
          NavNode(
            id: 'project_origin',
            label: 'Not mapped yet',
            floor: 1,
            x: 0,
            y: 0,
            type: 'waypoint',
          ),
        ],
        edges: const [],
        destinations: const [],
        anchors: const [],
      );
      await _overrideStorage.save(VenueOverrideDocument(
        venue: venue,
        coordinateSpace: 'sample',
        appliedSessionIds: const [],
        updatedAt: DateTime.now(),
      ));
      await _overrideStorage.selectProject(id);
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(
          'Project $name created. Return Home and start the V11 mapper.',
        )),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create project: $error')),
      );
    } finally {
      if (mounted) setState(() => _projectBusy = false);
    }
  }

  Future<void> _switchProject() async {
    if (_projectBusy) return;
    setState(() => _projectBusy = true);
    try {
      final projects = await _overrideStorage.listProjects();
      if (!mounted) return;
      final id = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        builder: (sheetContext) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(
                title: Text('Switch offline project'),
                subtitle: Text('Other saved projects stay on this phone.'),
              ),
              for (final item in projects)
                ListTile(
                  title: Text(item.venue.name),
                  subtitle: Text(
                    '${item.venue.nodes.length} nodes · '
                    '${item.venue.anchors.length} checkpoints',
                  ),
                  trailing: item.venue.id == _venue?.id
                      ? const Icon(Icons.check_circle)
                      : null,
                  onTap: () => Navigator.of(sheetContext).pop(item.venue.id),
                ),
              ListTile(
                title: const Text('Bundled demo campus'),
                onTap: () => Navigator.of(sheetContext).pop('__demo__'),
              ),
            ],
          ),
        ),
      );
      if (id == null) return;
      await _overrideStorage.selectProject(id == '__demo__' ? null : id);
      await _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not switch project: $error')),
      );
    } finally {
      if (mounted) setState(() => _projectBusy = false);
    }
  }

  VenueProjectBundle _exportBundle() {
    final venue = _venue;
    if (venue == null) throw StateError('No campus project loaded.');
    return VenueProjectBundle(
      document: _document ??
          VenueOverrideDocument(
            venue: venue,
            coordinateSpace: 'sample',
            appliedSessionIds: const [],
            updatedAt: DateTime.now(),
          ),
      recordings: _sessions,
    );
  }

  Future<void> _shareProject() async {
    if (_projectBusy) return;
    setState(() => _projectBusy = true);
    try {
      final project = _exportBundle();
      final opened = await _projectTransfer.shareFile(
        name: project.suggestedFileName,
        content: project.encode(),
      );
      if (!mounted) return;
      if (opened) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(
            'Choose an app to send the portable offline project file.',
          )),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not share project: $error')),
      );
    } finally {
      if (mounted) setState(() => _projectBusy = false);
    }
  }

  Future<void> _exportProject() async {
    if (_projectBusy) return;
    setState(() => _projectBusy = true);
    try {
      final project = _exportBundle();
      final uri = await _projectTransfer.saveFile(
        name: project.suggestedFileName,
        content: project.encode(),
      );
      if (!mounted) return;
      if (uri != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Offline project JSON saved to selected folder.')),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not export project: $error')),
      );
    } finally {
      if (mounted) setState(() => _projectBusy = false);
    }
  }

  Future<void> _importProject() async {
    if (_projectBusy) return;
    setState(() => _projectBusy = true);
    try {
      final raw = await _projectTransfer.pickFile();
      if (raw == null || !mounted) return;
      final project = VenueProjectBundle.decode(raw);
      final venue = project.document.venue;
      final existing = await _overrideStorage.load(venue.id);
      if (!mounted) return;

      final proceed = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('Import offline campus project?'),
              content: Text(
                '${venue.name}\n'
                '${venue.nodes.length} route nodes · ${venue.edges.length} links\n'
                '${venue.anchors.length} QR checkpoints · '
                '${project.recordings.length} recordings\n\n'
                'The saved routes and QR IDs will work offline. '
                'Live AR still requires physical camera localization.\n\n'
                '${existing == null ? 'This project will be added to the phone.' : 'A project with this ID already exists. Importing will replace its active graph; its previous graph will be backed up.'}',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Import project'),
                ),
              ],
            ),
          ) ??
          false;
      if (!proceed || !mounted) return;

      // Preflight ALL recording collisions before any file is overwritten.
      for (final session in project.recordings) {
        final saved = await _mappingStorage.load(session.id);
        if (saved != null &&
            jsonEncode(saved.toJson()) != jsonEncode(session.toJson())) {
          throw StateError(
            'Recording ID ${session.id} already exists with different data. '
            'Import cancelled to protect existing mappings.',
          );
        }
      }

      if (existing != null) await _overrideStorage.saveGraphBackup(existing);
      for (final session in project.recordings) {
        if (await _mappingStorage.load(session.id) == null) {
          await _mappingStorage.save(session);
        }
      }
      await _overrideStorage.save(project.document);
      // Only switch Home AFTER the graph and recordings were safely written.
      await _overrideStorage.selectProject(venue.id);
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(
          'Imported ${venue.name} offline. Select a checkpoint to plan a route.',
        )),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not import project: $error')),
      );
    } finally {
      if (mounted) setState(() => _projectBusy = false);
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


  Future<void> _openGraphEditor() async {
    final venue = _venue;
    if (venue == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => VenueGraphEditorScreen(
          venue: venue,
          currentDocument: _document,
        ),
      ),
    );
    if (changed == true) await _reload();
  }

  Future<void> _restoreGraphBackup() async {
    final venue = _venue;
    if (venue == null) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Restore previous venue graph?'),
            content: const Text(
              'This restores the graph saved immediately before the latest '
              'manual venue edit. Walk recordings are unaffected. '
              'The current graph is also retained as the next backup.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Restore previous'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    try {
      final backup = await _overrideStorage.loadGraphBackup(venue.id);
      if (backup == null) {
        throw StateError('There is no saved graph backup.');
      }
      final current = _document ??
          VenueOverrideDocument(
            venue: venue,
            coordinateSpace: 'sample',
            appliedSessionIds: const [],
            updatedAt: DateTime.now(),
          );
      await _overrideStorage.save(backup);
      await _overrideStorage.saveGraphBackup(current);
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Previous venue graph restored.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not restore venue graph: $error')),
      );
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
      await _overrideStorage.selectProject(null);
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

    const order = <String>['destination', 'anchor', 'floor_level', 'stairs', 'elevator', 'waypoint'];
    final parts = <String>[];
    for (final type in order) {
      final count = counts[type] ?? 0;
      if (count == 0) continue;
      final label = switch (type) {
        'destination' => 'dest',
        'waypoint' => 'waypoint',
        'stairs' => 'stairs',
        'anchor' => 'QR',
        'floor_level' => 'floors',
        'elevator' => 'elevator',
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
    final is3D = document?.isContinuous3D ?? false;

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
                                    is3D
                                        ? 'V11 measured 3D venue active'
                                        : isRecorded
                                            ? 'Recorded venue active'
                                            : 'Bundled sample active',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    is3D
                                        ? '${_venue?.nodes.length ?? 0} XYZ nodes • '
                                            '${_venue?.destinations.length ?? 0} destinations • '
                                            '${_venue?.anchors.length ?? 0} QR references'
                                        : isRecorded
                                            ? '${document!.appliedSessionIds.length} recording(s) applied'
                                            : 'Publish a 3D recording to replace the demo venue.',
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
                      const Text(
                        'PORTABLE OFFLINE PROJECT',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Share the campus graph with another Android phone. '
                        'The file contains XYZ routes, floors, destinations, '
                        'QR checkpoints, offline visual references and recordings.',
                        style: TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: _projectBusy ? null : _createProject,
                        icon: const Icon(Icons.add_circle_outline_rounded),
                        label: const Text('CREATE NEW CAMPUS PROJECT'),
                      ),
                      const SizedBox(height: 7),
                      OutlinedButton.icon(
                        onPressed: _projectBusy ? null : _switchProject,
                        icon: const Icon(Icons.swap_horiz_rounded),
                        label: const Text('SWITCH SAVED PROJECT'),
                      ),
                      const SizedBox(height: 7),
                      FilledButton.icon(
                        onPressed: _projectBusy || _venue == null ? null : _shareProject,
                        icon: const Icon(Icons.share_rounded),
                        label: const Text('SHARE MAPPING PROJECT'),
                      ),
                      const SizedBox(height: 7),
                      OutlinedButton.icon(
                        onPressed: _projectBusy || _venue == null ? null : _exportProject,
                        icon: const Icon(Icons.save_alt_rounded),
                        label: const Text('SAVE PROJECT FILE (.ARNAV.JSON)'),
                      ),
                      const SizedBox(height: 7),
                      OutlinedButton.icon(
                        onPressed: _projectBusy ? null : _importProject,
                        icon: const Icon(Icons.file_open_rounded),
                        label: const Text('IMPORT SHARED PROJECT FILE'),
                      ),
                      if (_projectBusy) ...[
                        const SizedBox(height: 8),
                        const LinearProgressIndicator(),
                      ],
                      const SizedBox(height: 14),
                      if (!is3D)
                        FilledButton.icon(
                          onPressed: _venue == null ? null : _openGraphEditor,
                          icon: const Icon(Icons.edit_road_rounded),
                          label: const Text('EDIT SAVED VENUE WAYPOINTS'),
                        )
                      else
                        const Text(
                          'Full XYZ height is preserved. Editing with the '
                          'old flat waypoint tool is disabled to protect '
                          'the new 3D venue.',
                          style: TextStyle(color: Colors.white60, fontSize: 12),
                        ),
                      if (_hasGraphBackup) ...[
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _restoreGraphBackup,
                          icon: const Icon(Icons.restore_rounded),
                          label: const Text('RESTORE PREVIOUS GRAPH'),
                        ),
                      ],
                      const SizedBox(height: 8),
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
                                session.isDraft3D
                                    ? '3D SAFETY DRAFT · ${session.totalDistanceMeters.toStringAsFixed(1)} m'
                                    : session.isContinuous3D
                                        ? 'UNIFIED 3D ROUTE · ${session.totalDistanceMeters.toStringAsFixed(1)} m'
                                    : 'Floor ${session.floor} · ${session.totalDistanceMeters.toStringAsFixed(1)} m',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              subtitle: Text(
                                '${session.isDraft3D ? 'Auto-saved partial XYZ • not a finished route' : session.isContinuous3D ? 'Live XYZ + height' : session.isSpatial ? 'ARCore spatial' : 'Legacy step'} · '
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
