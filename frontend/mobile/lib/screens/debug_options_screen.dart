import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/back_chevron.dart';
import '../widgets/validated_text_dialog.dart';
import 'debug_database_screen.dart';
import 'location_debug_screen.dart';
import 'triage_logic_screen.dart';

const String backendSyncUrlPrefKey = 'suar_backend_sync_url';

/// Settings > Debugging Options — dev-only tools that don't belong in front
/// of an end user: the ngrok backend URL override, and a viewer for the
/// on-device SQLite store.
class DebugOptionsScreen extends StatefulWidget {
  const DebugOptionsScreen({super.key});

  @override
  State<DebugOptionsScreen> createState() => _DebugOptionsScreenState();
}

class _DebugOptionsScreenState extends State<DebugOptionsScreen> {
  String? _backendUrl;

  @override
  void initState() {
    super.initState();
    _loadBackendUrl();
  }

  Future<void> _loadBackendUrl() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _backendUrl = prefs.getString(backendSyncUrlPrefKey));
  }

  Future<void> _editBackendUrl() async {
    final newUrl = await showValidatedTextDialog(
      context: context,
      title: 'Backend Sync URL',
      confirmLabel: 'Save',
      initialValue: _backendUrl ?? '',
      hintText: 'https://xxxx.ngrok-free.app',
      allowEmpty: true,
      validate: (value) async {
        if (!value.startsWith('http://') && !value.startsWith('https://')) {
          return 'Must start with http:// or https://';
        }
        return null;
      },
    );
    if (newUrl == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(backendSyncUrlPrefKey, newUrl);
    if (!mounted) return;
    setState(() => _backendUrl = newUrl);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        leading: const BackChevron(),
        title: const Text('Debugging Options'),
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.cloud_outlined, color: Colors.black),
            title: const Text(
              'Backend Sync URL',
              style: TextStyle(color: Colors.black),
            ),
            subtitle: Text(
              _backendUrl?.isNotEmpty == true
                  ? _backendUrl!
                  : 'Not set (dev/testing only)',
              style: const TextStyle(color: Colors.black54),
            ),
            onTap: _editBackendUrl,
          ),
          const Divider(
            color: Colors.black12,
            height: 1,
            indent: 16,
            endIndent: 16,
          ),
          ListTile(
            leading: const Icon(Icons.storage_outlined, color: Colors.black),
            title: const Text(
              'Local Database',
              style: TextStyle(color: Colors.black),
            ),
            subtitle: const Text(
              'View or clear the on-device SQLite store',
              style: TextStyle(color: Colors.black54),
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DebugDatabaseScreen()),
            ),
          ),
          const Divider(
            color: Colors.black12,
            height: 1,
            indent: 16,
            endIndent: 16,
          ),
          ListTile(
            leading: const Icon(Icons.tune_outlined, color: Colors.black),
            title: const Text(
              'Triage Logic',
              style: TextStyle(color: Colors.black),
            ),
            subtitle: const Text(
              'Sensor weights, tiers and override rules',
              style: TextStyle(color: Colors.black54),
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const TriageLogicScreen()),
            ),
          ),
          const Divider(
            color: Colors.black12,
            height: 1,
            indent: 16,
            endIndent: 16,
          ),
          ListTile(
            leading: const Icon(Icons.location_on_outlined, color: Colors.black),
            title: const Text(
              'Location',
              style: TextStyle(color: Colors.black),
            ),
            subtitle: const Text(
              'Live GPS fix, accuracy and bundle values',
              style: TextStyle(color: Colors.black54),
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LocationDebugScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
