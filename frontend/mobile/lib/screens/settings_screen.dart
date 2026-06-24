import 'package:flutter/material.dart';

import '../widgets/back_chevron.dart';
import 'debug_options_screen.dart';
import 'offline_map_management_screen.dart';

/// Reached from the gear icon on the Dashboard. Two entries: offline map
/// regions, and dev-only debugging tools (backend URL override, local DB
/// viewer) tucked behind their own screen so they don't clutter this one.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        leading: const BackChevron(),
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.map_outlined, color: Colors.black),
            title: const Text(
              'Offline Map Management',
              style: TextStyle(color: Colors.black),
            ),
            subtitle: const Text(
              'Download, rename, or delete map regions',
              style: TextStyle(color: Colors.black54),
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const OfflineMapManagementScreen(),
              ),
            ),
          ),
          const Divider(
            color: Colors.black12,
            height: 1,
            indent: 16,
            endIndent: 16,
          ),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined, color: Colors.black),
            title: const Text(
              'Debugging Options',
              style: TextStyle(color: Colors.black),
            ),
            subtitle: const Text(
              'Backend sync URL, local database viewer',
              style: TextStyle(color: Colors.black54),
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DebugOptionsScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
