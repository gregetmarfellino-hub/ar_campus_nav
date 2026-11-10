import 'package:flutter/material.dart';

/// A floor milestone in a continuous ARCore 3D recording.
///
/// The field manages its OWN controller internally. The calling screen must
/// not dispose a TextEditingController while the dialog's closing animation
/// still keeps the field mounted (the V10 red-screen regression).
class FloorArrivalDialog extends StatefulWidget {
  const FloorArrivalDialog({
    super.key,
    required this.currentFloor,
  });

  final int currentFloor;

  @override
  State<FloorArrivalDialog> createState() => _FloorArrivalDialogState();
}

class _FloorArrivalDialogState extends State<FloorArrivalDialog> {
  late String _draftFloor;
  String? _error;

  @override
  void initState() {
    super.initState();
    _draftFloor =
        '${widget.currentFloor == -1 ? 1 : widget.currentFloor + 1}';
  }

  void _submit() {
    final next = int.tryParse(_draftFloor.trim());
    if (next == null || next < -10 || next > 50 ||
        next == widget.currentFloor) {
      setState(() {
        _error = 'Choose a different whole-number floor (-10 to 50).';
      });
      return;
    }
    Navigator.of(context).pop(next);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Reached another floor?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Only mark the floor after physically reaching its landing. '
              'ARCore keeps recording the SAME 3D trajectory; this action '
              'does not jump, reset, or connect separate coordinate systems.',
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: _draftFloor,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(signed: true),
              decoration: InputDecoration(
                labelText: 'Floor reached',
                helperText: 'Example: -1 = Basement 1, 2 = Floor 2',
                errorText: _error,
              ),
              onChanged: (value) {
                _draftFloor = value;
                if (_error != null) setState(() => _error = null);
              },
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _submit,
            child: const Text('Mark landing'),
          ),
        ],
      );
}
