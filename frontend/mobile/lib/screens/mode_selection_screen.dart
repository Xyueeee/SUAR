import 'package:flutter/material.dart';

import '../permissions.dart';
import 'helper_mode_screen.dart';
import 'victim_mode_screen.dart';

/// "4.1.2 SUAR Emergency Mode - Choose Mode" (Figma node 7:346).
/// Pure picker — permission checks happen here; the actual mesh
/// controllers live in the screens this navigates to.
class ModeSelectionScreen extends StatefulWidget {
  const ModeSelectionScreen({super.key});

  @override
  State<ModeSelectionScreen> createState() => _ModeSelectionScreenState();
}

class _ModeSelectionScreenState extends State<ModeSelectionScreen> {
  bool _requesting = false;

  Future<void> _enterMode(Widget Function() screenBuilder) async {
    if (_requesting) return;
    setState(() => _requesting = true);
    bool granted = false;
    try {
      // requestMeshPermissions() itself no longer throws on the known
      // permission_handler "already running" failure (see its doc), but this
      // try/finally is the actual fix for the freeze reported on real
      // hardware: the old code reset _requesting only on the line AFTER the
      // await, so any exception escaping that await (this one, or any other)
      // skipped the reset and left every mode card permanently disabled
      // (busy: true) for the rest of the app session — confirmed via logcat
      // showing the unhandled PlatformException with no recovery. finally
      // guarantees the guard releases no matter how this await ends.
      granted = await requestMeshPermissions();
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
    if (!mounted) return;

    if (!granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Bluetooth and Wi-Fi Direct permissions are required. '
            'Tap again to retry.',
          ),
        ),
      );
      return;
    }
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => screenBuilder()));
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
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.chevron_left, color: Colors.white),
                  ),
                  const Text(
                    'Choose Emergency Mode',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _ModeCard(
                label: 'Victim Mode',
                color: const Color(0xFFEAACAC),
                icon: Icons.health_and_safety,
                busy: _requesting,
                onTap: () => _enterMode(() => const VictimModeScreen()),
              ),
              const SizedBox(height: 8),
              const Text(
                'Select Victim Mode if you are in need of help.\n\n'
                'Your phone will now act as a beacon for the helpers to locate and assist you. '
                'This mode will provide your estimated location and other vital information for '
                'the helpers to provide appropriate help to you.',
                style: TextStyle(color: Colors.white, fontSize: 15),
              ),
              const SizedBox(height: 16),
              _ModeCard(
                label: 'Helper Mode',
                color: const Color(0xFFA7C7E7),
                icon: Icons.engineering,
                busy: _requesting,
                onTap: () => _enterMode(() => const HelperModeScreen()),
              ),
              const SizedBox(height: 8),
              const Text(
                'Select Helper Mode if you are able to help others.\n\n'
                'Your phone will now actively search for victim beacon signals to provide you '
                'estimated location of help needed. This mode will also forward your picked up '
                'signal to other helpers nearby.',
                style: TextStyle(color: Colors.white, fontSize: 15),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.label,
    required this.color,
    required this.icon,
    required this.busy,
    required this.onTap,
  });

  final String label;
  final Color color;
  final IconData icon;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: busy ? null : onTap,
      child: Container(
        width: double.infinity,
        height: 120,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 48, color: Colors.black),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 24,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
