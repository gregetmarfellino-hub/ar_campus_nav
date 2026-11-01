import 'package:flutter/material.dart';

import '../models/nav_edge.dart';
import '../models/nav_node.dart';
import '../models/venue.dart';
import '../services/venue_graph_editor.dart';
import '../services/venue_override_storage.dart';
import '../widgets/venue_graph_canvas.dart';

/// Edit the persistent venue graph produced from SAVED walk recordings.
/// No ARCore session is opened here; original recordings are never modified.
class VenueGraphEditorScreen extends StatefulWidget {
  const VenueGraphEditorScreen({
    super.key,
    required this.venue,
    required this.currentDocument,
  });

  final Venue venue;
  final VenueOverrideDocument? currentDocument;

  @override
  State<VenueGraphEditorScreen> createState() => _VenueGraphEditorScreenState();
}

class _VenueGraphEditorScreenState extends State<VenueGraphEditorScreen> {
  static const Color _green = Color(0xFF3DDC97);
  final VenueGraphEditor _editor = const VenueGraphEditor();
  final VenueOverrideStorage _storage = const VenueOverrideStorage();

  late Venue _working;
  late Venue _lastSaved;
  late int _floor;
  late Map<int, VenueGraphViewport> _viewports;
  VenueOverrideDocument? _currentDocument;
  final List<Venue> _undo = [];
  final List<Venue> _redo = [];
  String? _selectedId;
  String? _connectSourceId;
  bool _connectMode = false;
  bool _insertMode = false;
  bool _saving = false;
  Venue? _dragBefore;

  bool get _dirty => !identical(_working, _lastSaved);
  List<int> get _floors {
    final available = <int>{
      ..._working.floors,
      for (final node in _working.nodes) node.floor,
    }.toList()..sort();
    return available;
  }

  @override
  void initState() {
    super.initState();
    _working = widget.venue;
    _lastSaved = widget.venue;
    _currentDocument = widget.currentDocument;
    _floor = _floors.contains(1) ? 1 : _floors.first;
    _viewports = {
      for (final floor in _floors)
        floor: VenueGraphViewport.forFloor(widget.venue, floor),
    };
  }

  String _floorName(int floor) =>
      floor < 0 ? 'Basement ${floor.abs()}' : 'Floor $floor';

  NavNode? get _selectedNode {
    for (final node in _working.nodes) {
      if (node.id == _selectedId) return node;
    }
    return null;
  }

  List<NavEdge> get _selectedEdges {
    final id = _selectedId;
    if (id == null) return const [];
    return _working.edges
        .where((edge) => edge.from == id || edge.to == id)
        .toList(growable: false);
  }

  bool _canMove(String id) {
    if (id == _working.defaultStartNodeId) return false;
    return !_editor.isAnchored(_working, id);
  }

  void _pushUndo(Venue previous) {
    _undo.add(previous);
    if (_undo.length > 50) _undo.removeAt(0);
    _redo.clear();
  }

  void _commit(Venue next, {String? select}) {
    if (identical(next, _working)) return;
    setState(() {
      _pushUndo(_working);
      _working = next;
      if (select != null) _selectedId = select;
    });
  }

  void _changeFloor(int floor) {
    setState(() {
      _floor = floor;
      _selectedId = null;
      _connectMode = false;
      _insertMode = false;
      _connectSourceId = null;
    });
  }

  void _undoChange() {
    if (_undo.isEmpty) return;
    setState(() {
      _redo.add(_working);
      _working = _undo.removeLast();
      _selectedId = null;
      _connectSourceId = null;
      _connectMode = false;
      _insertMode = false;
    });
  }

  void _redoChange() {
    if (_redo.isEmpty) return;
    setState(() {
      _undo.add(_working);
      _working = _redo.removeLast();
      _selectedId = null;
      _connectSourceId = null;
      _connectMode = false;
      _insertMode = false;
    });
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$error')),
    );
  }

  void _tapNode(String? id) {
    if (_connectMode) {
      if (id == null) return;
      final source = _connectSourceId;
      if (source == null) {
        setState(() {
          _connectSourceId = id;
          _selectedId = id;
        });
        return;
      }
      if (source == id) {
        setState(() {
          _connectSourceId = null;
          _connectMode = false;
        });
        return;
      }
      try {
        final changed = _editor.connectNodes(
          _working,
          from: source,
          to: id,
        );
        _commit(changed, select: id);
        setState(() {
          _connectMode = false;
          _connectSourceId = null;
        });
      } catch (error) {
        _showError(error);
      }
      return;
    }
    setState(() => _selectedId = id);
  }

  void _insert(String from, String to, Offset meters) {
    try {
      final id = 'graph_point_${DateTime.now().microsecondsSinceEpoch}';
      final changed = _editor.insertWaypoint(
        _working,
        from: from,
        to: to,
        newNodeId: id,
        x: meters.dx,
        y: meters.dy,
      );
      _commit(changed, select: id);
      setState(() => _insertMode = false);
    } catch (error) {
      _showError(error);
    }
  }

  void _startDrag(String id) {
    if (_canMove(id)) _dragBefore = _working;
  }

  void _drag(String id, Offset meters) {
    if (!_canMove(id)) return;
    try {
      final changed = _editor.moveNode(
        _working,
        nodeId: id,
        x: meters.dx,
        y: meters.dy,
      );
      if (!identical(changed, _working)) {
        setState(() => _working = changed);
      }
    } catch (error) {
      _showError(error);
    }
  }

  void _finishDrag() {
    final previous = _dragBefore;
    _dragBefore = null;
    if (previous != null && !identical(previous, _working)) {
      setState(() => _pushUndo(previous));
    }
  }

  Future<void> _rename() async {
    final selected = _selectedNode;
    if (selected == null || !_canMove(selected.id)) return;
    final controller = TextEditingController(text: selected.label);
    final label = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename mapped point'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(labelText: 'Label'),
          onSubmitted: (value) => Navigator.pop(ctx, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || label == null) return;
    try {
      _commit(_editor.renameNode(_working, selected.id, label));
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _editCoordinates() async {
    final selected = _selectedNode;
    if (selected == null || !_canMove(selected.id)) return;
    final xField = TextEditingController(
      text: selected.x.toStringAsFixed(2),
    );
    final yField = TextEditingController(
      text: selected.y.toStringAsFixed(2),
    );
    final coordinates = await showDialog<(String, String)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Position: ${selected.label}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Coordinates are metres in the saved venue frame. '
              'This moves the selected point, NOT the physical AR anchor.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: xField,
              keyboardType: const TextInputType.numberWithOptions(
                signed: true, decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'X (metres)'),
            ),
            TextField(
              controller: yField,
              keyboardType: const TextInputType.numberWithOptions(
                signed: true, decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Y (metres)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              ctx, (xField.text, yField.text),
            ),
            child: const Text('Move point'),
          ),
        ],
      ),
    );
    xField.dispose();
    yField.dispose();
    if (!mounted || coordinates == null) return;
    final x = double.tryParse(coordinates.$1.trim());
    final y = double.tryParse(coordinates.$2.trim());
    if (x == null || y == null || !x.isFinite || !y.isFinite) {
      _showError('Enter valid numerical X and Y metre coordinates.');
      return;
    }
    try {
      _commit(_editor.moveNode(
        _working, nodeId: selected.id, x: x, y: y,
      ));
    } catch (error) {
      _showError(error);
    }
  }

  void _removeEdge(NavEdge edge) {
    try {
      _commit(_editor.disconnectNodes(
        _working,
        from: edge.from,
        to: edge.to,
      ));
    } catch (error) {
      _showError(error);
    }
  }

  void _deleteWaypoint() {
    final selected = _selectedNode;
    if (selected == null) return;
    try {
      _commit(_editor.deleteUnusedWaypoint(_working, selected.id));
      setState(() => _selectedId = null);
    } catch (error) {
      _showError(error);
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Discard unsaved venue edits?'),
            content: const Text(
              'The saved graph is unchanged. Your original walk recordings '
              'will stay on the phone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep editing'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Discard edits'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _save() async {
    if (_saving || !_dirty) return;
    try {
      _editor.validate(_working);
      final unreachable = _editor.unreachableDestinations(_working);
      final warning = unreachable.isEmpty
          ? 'This will update the active venue used by navigation. '
              'Raw walk recordings remain unchanged, and the previous graph '
              'will be backed up for restoration.'
          : 'WARNING: ${unreachable.length} destination(s) cannot be reached '
              'from the venue start (${unreachable.take(4).join(', ')}). '
              'You can still save this disconnected graph, and restore the '
              'previous graph if necessary.';
      final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Save edited venue graph?'),
              content: Text(warning),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Save venue'),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirmed || !mounted) return;
      setState(() => _saving = true);

      // Backup the exact active graph (and applied recording IDs) BEFORE the
      // write. If backup fails, the new edits are not committed.
      final previous = _currentDocument ??
          VenueOverrideDocument(
            venue: _lastSaved,
            coordinateSpace: 'sample',
            appliedSessionIds: const [],
            updatedAt: DateTime.now(),
          );
      await _storage.saveGraphBackup(previous);
      final updated = VenueOverrideDocument(
        venue: _working,
        coordinateSpace: previous.coordinateSpace,
        appliedSessionIds: previous.appliedSessionIds,
        updatedAt: DateTime.now(),
      );
      await _storage.save(updated);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      _showError(error);
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedNode;
    final locked = selected != null && !_canMove(selected.id);
    final canvasViewport = _viewports[_floor] ??
        VenueGraphViewport.forFloor(_working, _floor);
    final floorNodes = _working.nodes
        .where((node) => node.floor == _floor)
        .length;
    final floorEdges = _working.edges.where((edge) {
      final from = _working.nodeById(edge.from);
      final to = _working.nodeById(edge.to);
      return from.floor == _floor && to.floor == _floor;
    }).length;

    return PopScope(
      canPop: !_dirty && !_saving,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || _saving) return;
        if (await _confirmDiscard() && context.mounted) {
          // PopScope blocks leaving dirty editors, including a programmatic
          // pop. Mark the discarded in-memory changes clean first.
          setState(() => _lastSaved = _working);
          // PopScope's route-scoped PopEntry updates its canPop notifier
          // during the NEXT widget build. Popping immediately would be
          // blocked again and repeatedly reopen the discard confirmation.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).pop(false);
          });
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_dirty ? 'Venue Editor • Unsaved' : 'Venue Editor'),
          actions: [
            IconButton(
              tooltip: 'Undo',
              onPressed: _undo.isEmpty || _saving ? null : _undoChange,
              icon: const Icon(Icons.undo_rounded),
            ),
            IconButton(
              tooltip: 'Redo',
              onPressed: _redo.isEmpty || _saving ? null : _redoChange,
              icon: const Icon(Icons.redo_rounded),
            ),
            TextButton.icon(
              onPressed: _dirty && !_saving ? _save : null,
              icon: _saving
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_rounded),
              label: const Text('SAVE'),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
          children: [
            Text(
              'EDITING: ${widget.venue.name}',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'These are the ACTUAL saved venue waypoints and route '
              'connections. Drag an ordinary point to correct the map. '
              'Anchor points stay locked to protect AR localization.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    key: ValueKey(_floor),
                    initialValue: _floor,
                    decoration: const InputDecoration(
                      labelText: 'Editing floor',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final floor in _floors)
                        DropdownMenuItem(
                          value: floor,
                          child: Text(_floorName(floor)),
                        ),
                    ],
                    onChanged: _saving
                        ? null
                        : (floor) {
                            if (floor != null) _changeFloor(floor);
                          },
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('$floorNodes points',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text('$floorEdges paths',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white54)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                ChoiceChip(
                  label: const Text('SELECT / DRAG'),
                  avatar: const Icon(Icons.open_with_rounded, size: 17),
                  selected: !_connectMode && !_insertMode,
                  onSelected: (_) => setState(() {
                    _connectMode = false;
                    _insertMode = false;
                    _connectSourceId = null;
                  }),
                ),
                ChoiceChip(
                  label: const Text('CONNECT TWO'),
                  avatar: const Icon(Icons.add_link_rounded, size: 17),
                  selected: _connectMode,
                  onSelected: (_) => setState(() {
                    _connectMode = !_connectMode;
                    _insertMode = false;
                    _connectSourceId = null;
                  }),
                ),
                ChoiceChip(
                  label: const Text('INSERT ON PATH'),
                  avatar: const Icon(Icons.add_circle_outline, size: 17),
                  selected: _insertMode,
                  onSelected: (_) => setState(() {
                    _insertMode = !_insertMode;
                    _connectMode = false;
                    _connectSourceId = null;
                  }),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _connectMode
                  ? _connectSourceId == null
                      ? 'Tap the first mapped point to connect.'
                      : 'Now tap the SECOND point on this floor.'
                  : _insertMode
                      ? 'Tap a blue line to split it with a new waypoint.'
                      : 'Tap a dot to select. Drag blue or yellow dots to move.',
              style: const TextStyle(color: _green, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Container(
              height: 365,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: const Color(0xFF0D1527),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0x5572A7FF)),
              ),
              child: VenueGraphCanvas(
                venue: _working,
                floor: _floor,
                viewport: canvasViewport,
                selectedNodeId: _selectedId,
                connectMode: _connectMode,
                insertMode: _insertMode,
                canMove: _canMove,
                onTapNode: _tapNode,
                onDragStartNode: _startDrag,
                onDragNode: _drag,
                onDragEndNode: _finishDrag,
                onInsertWaypoint: _insert,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Blue = saved path · Green = fixed AR anchor · '
              'Yellow = destination · Purple = stairs',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
            const SizedBox(height: 16),
            if (selected == null)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Select any existing path dot, mapped waypoint, '
                    'destination, or staircase to inspect its connections.',
                  ),
                ),
              )
            else
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(selected.label,
                          style: const TextStyle(
                              fontWeight: FontWeight.w900, fontSize: 18)),
                      const SizedBox(height: 4),
                      Text(
                        '${selected.type} • ${_floorName(selected.floor)} • '
                        '(${selected.x.toStringAsFixed(2)}, '
                        '${selected.y.toStringAsFixed(2)}) metres',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white54),
                      ),
                      if (locked) ...[
                        const SizedBox(height: 8),
                        const Text(
                          'LOCKED: This point defines an AR reference or '
                          'the venue start. It cannot be dragged or deleted.',
                          style: TextStyle(color: Color(0xFF3DDC97),
                              fontSize: 12),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: locked ? null : _rename,
                            icon: const Icon(Icons.edit_rounded, size: 17),
                            label: const Text('Rename'),
                          ),
                          OutlinedButton.icon(
                            onPressed: locked ? null : _editCoordinates,
                            icon: const Icon(Icons.straighten_rounded,
                                size: 17),
                            label: const Text('Edit X/Y'),
                          ),
                          OutlinedButton.icon(
                            onPressed: locked ? null : _deleteWaypoint,
                            icon: const Icon(Icons.delete_outline_rounded,
                                size: 17),
                            label: const Text('Delete unused'),
                          ),
                        ],
                      ),
                      const Divider(height: 20),
                      Text(
                        'CONNECTED SEGMENTS (${_selectedEdges.length})',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 12),
                      ),
                      if (_selectedEdges.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text('No connections. Use CONNECT TWO.'),
                        ),
                      for (final edge in _selectedEdges)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            _working.nodeById(
                              edge.from == selected.id
                                  ? edge.to : edge.from,
                            ).label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${edge.distanceMeters.toStringAsFixed(1)} m '
                            '${edge.bidirectional ? "• both ways" : "• one way"}'
                            '${edge.accessible ? "" : " • blocked"}',
                          ),
                          trailing: IconButton(
                            tooltip: 'Disconnect this path (undo available)',
                            onPressed: () => _removeEdge(edge),
                            icon: const Icon(Icons.link_off_rounded),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
            const Text(
              'Changes are local to this venue and remain offline. '
              'SAVE writes the active graph only after backing up its '
              'previous state. Original mapping session files are preserved. '
              'Stairs across floors are a separate Pass 8 feature.',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
