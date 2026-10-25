import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/anchor_point.dart';
import '../models/venue.dart';
import '../services/anchor_codec.dart';

class AnchorQrScreen extends StatefulWidget {
  const AnchorQrScreen({
    super.key,
    required this.venue,
    this.initialAnchorId,
  });

  final Venue venue;
  final String? initialAnchorId;

  @override
  State<AnchorQrScreen> createState() => _AnchorQrScreenState();
}

class _AnchorQrScreenState extends State<AnchorQrScreen> {
  final AnchorCodec _codec = const AnchorCodec();

  late String _anchorId;

  @override
  void initState() {
    super.initState();

    final anchors = widget.venue.anchors;
    if (anchors.isEmpty) {
      _anchorId = '';
      return;
    }

    final requested = widget.initialAnchorId;
    _anchorId = requested != null &&
            anchors.any((anchor) => anchor.id == requested)
        ? requested
        : anchors.first.id;
  }

  AnchorPoint? get _anchor {
    if (_anchorId.isEmpty) return null;
    for (final anchor in widget.venue.anchors) {
      if (anchor.id == _anchorId) return anchor;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final anchor = _anchor;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Location QR',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: anchor == null
          ? const _EmptyAnchors()
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                const Text(
                  'DEPLOYMENT ANCHOR',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 10),
                if (widget.venue.anchors.length > 1)
                  DropdownButtonFormField<String>(
                    initialValue: anchor.id,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.location_on_rounded),
                    ),
                    items: [
                      for (final item in widget.venue.anchors)
                        DropdownMenuItem(
                          value: item.id,
                          child: Text('${item.label} • Floor ${item.floor}'),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _anchorId = value);
                    },
                  )
                else
                  _AnchorHeader(anchor: anchor),
                const SizedBox(height: 18),
                _QrCard(
                  venue: widget.venue,
                  anchor: anchor,
                  payload: _codec.encode(
                    venue: widget.venue,
                    anchor: anchor,
                  ),
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(15),
                  decoration: BoxDecoration(
                    color: const Color(0x14F9C74F),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0x33F9C74F)),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.push_pin_rounded,
                        color: Color(0xFFF9C74F),
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Install this QR at the exact physical place where '
                          'the anchor was mapped. Moving the QR changes the '
                          'meaning of the location and will shift AR navigation.',
                          style: TextStyle(
                            color: Colors.white70,
                            height: 1.45,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    final payload = _codec.encode(
                      venue: widget.venue,
                      anchor: anchor,
                    );
                    await Clipboard.setData(ClipboardData(text: payload));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Location QR payload copied.'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('COPY QR PAYLOAD'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop(anchor);
                  },
                  icon: const Icon(Icons.science_outlined),
                  label: const Text('TEST FROM THIS ANCHOR'),
                ),
                const SizedBox(height: 8),
                const Text(
                  'TEST FROM THIS ANCHOR bypasses camera scanning. Use it only '
                  'while physically standing at this mapped anchor. For the '
                  'real visitor flow, scan the QR with SCAN LOCATION.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ],
            ),
    );
  }
}

class _AnchorHeader extends StatelessWidget {
  const _AnchorHeader({required this.anchor});

  final AnchorPoint anchor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
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
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Floor ${anchor.floor} • ${anchor.id}',
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

class _QrCard extends StatelessWidget {
  const _QrCard({
    required this.venue,
    required this.anchor,
    required this.payload,
  });

  final Venue venue;
  final AnchorPoint anchor;
  final String payload;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF111A2E),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0x333DDC97)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
            ),
            child: QrImageView(
              data: payload,
              version: QrVersions.auto,
              size: 250,
              backgroundColor: Colors.white,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: Colors.black,
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Colors.black,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            anchor.label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '${venue.name} • Floor ${anchor.floor}',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'AR CAMPUS NAV • SCAN LOCATION',
            style: TextStyle(
              color: Color(0xFF9DBEF7),
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyAnchors extends StatelessWidget {
  const _EmptyAnchors();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.qr_code_2_rounded,
              size: 58,
              color: Colors.white30,
            ),
            SizedBox(height: 14),
            Text(
              'No location anchors yet',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Record a floor and add a QR anchor marker first.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}
