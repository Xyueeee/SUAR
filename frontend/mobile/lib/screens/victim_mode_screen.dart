import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/victim_controller.dart';
import '../widgets/mesh_activity_card.dart';
import '../widgets/radio_status_banner.dart';

/// "4.1.3 SUAR Emergency Mode - Victim Mode" (Figma node 7:847).
class VictimModeScreen extends StatefulWidget {
  const VictimModeScreen({super.key});

  @override
  State<VictimModeScreen> createState() => _VictimModeScreenState();
}

class _VictimModeScreenState extends State<VictimModeScreen> {
  final VictimController _controller = VictimController();
  final List<LogEntry> _log = [];
  StreamSubscription<String>? _statusSub;

  @override
  void initState() {
    super.initState();
    _statusSub = _controller.statusStream.listen((line) {
      if (!mounted) return;
      setState(() => _log.add(LogEntry(line)));
    });
    _controller.startVictimMode();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    // stopVictimMode is async and still emits to statusStream while
    // stopping; dispose() must wait for it, or it closes the stream
    // out from under the in-flight stop and crashes ("Cannot add new
    // events after calling close").
    unawaited(_controller.stopVictimMode().whenComplete(_controller.dispose));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 21, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(
                          Icons.chevron_left,
                          color: Colors.white,
                        ),
                      ),
                      const Text(
                        'Victim Mode',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.circle, size: 8, color: Colors.redAccent),
                        SizedBox(width: 6),
                        Text(
                          'Broadcasting',
                          style: TextStyle(color: Colors.white, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Victim mode is now active.\n\n'
                'Your phone is now currently actively broadcasting your SOS signal to all '
                'nearby available helpers.',
                style: TextStyle(color: Colors.white, fontSize: 15),
              ),
              const SizedBox(height: 16),
              const RadioStatusBanner(),
              Expanded(child: MeshActivityCard(lines: _log)),
            ],
          ),
        ),
      ),
    );
  }
}
