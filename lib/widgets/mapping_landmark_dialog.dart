import 'package:flutter/material.dart';

/// One small optional location tag while recording continuous 3D geometry.
/// A QR reference means a physically installed / printed ID, NOT a persistent
/// virtual ARCore anchor that magically relocalizes after a fresh session.
class MappingLandmarkInput {
  const MappingLandmarkInput(this.type, this.label);
  final String type;
  final String label;
}

class MappingLandmarkDialog extends StatefulWidget {
  const MappingLandmarkDialog({super.key});

  @override
  State<MappingLandmarkDialog> createState() => _MappingLandmarkDialogState();
}

class _MappingLandmarkDialogState extends State<MappingLandmarkDialog> {
  String _type = 'destination';
  String _name = '';
  String? _error;

  void _save() {
    final label = _name.trim();
    if (label.length < 2 || label.length > 80) {
      setState(() => _error = 'Enter a 2–80 character location name.');
      return;
    }
    Navigator.of(context).pop(MappingLandmarkInput(_type, label));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Mark physical location'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Stop at the actual door, landing, or reference marker. '
                'This tag attaches to the latest measured 3D point. '
                'Recording is temporarily paused while naming it.',
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 5,
                children: [
                  for (final entry in const <(String, String)>[
                    ('destination', 'Room / place'),
                    ('anchor', 'QR reference'),
                    ('stairs', 'Stairs'),
                    ('elevator', 'Elevator'),
                  ])
                    ChoiceChip(
                      label: Text(entry.$2),
                      selected: _type == entry.$1,
                      onSelected: (_) => setState(() {
                        _type = entry.$1;
                        _error = null;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                autofocus: true,
                initialValue: _name,
                maxLength: 80,
                decoration: InputDecoration(
                  labelText: 'Location name',
                  hintText: 'E.g. Lab Komputer 2',
                  errorText: _error,
                ),
                onChanged: (value) => _name = value,
                onFieldSubmitted: (_) => _save(),
              ),
              if (_type == 'anchor')
                const Text(
                  'A QR ID will be generated when this route is published. '
                  'Print/place that QR at THIS measured landmark. '
                  'A QR scan identifies the location but does not yet '
                  'measure the phone pose or align a new ARCore session.',
                  style: TextStyle(
                    color: Color(0xFFF9C74F),
                    fontSize: 12,
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.add_location_alt_rounded),
            label: const Text('Save location'),
          ),
        ],
      );
}
