import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../onboarding.dart';
import '../widgets/back_chevron.dart';
import '../widgets/validated_text_dialog.dart';
import 'debug_database_screen.dart';
import 'location_debug_screen.dart';
import 'onboarding_screen.dart';
import 'triage_logic_screen.dart';

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
  String _conn = 'checking'; // checking | connected | unreachable | unset

  @override
  void initState() {
    super.initState();
    _loadBackendUrl();
  }

  Future<void> _loadBackendUrl() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _backendUrl = prefs.getString(backendSyncUrlPrefKey));
    _ping();
  }

  /// Lightweight reachability check against the backend's /health.
  Future<void> _ping() async {
    final url = _backendUrl?.trim();
    if (url == null || url.isEmpty) {
      if (mounted) setState(() => _conn = 'unset');
      return;
    }
    if (mounted) setState(() => _conn = 'checking');
    final base = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    var ok = false;
    try {
      final req = await client.getUrl(Uri.parse('$base/health'));
      req.headers.set('ngrok-skip-browser-warning', 'true');
      final resp = await req.close().timeout(const Duration(seconds: 8));
      ok = resp.statusCode == 200;
    } catch (_) {
      ok = false;
    } finally {
      client.close(force: true);
    }
    if (mounted) setState(() => _conn = ok ? 'connected' : 'unreachable');
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
    _ping();
  }

  String _connLabel() {
    switch (_conn) {
      case 'connected':
        return 'Connected';
      case 'unreachable':
        return 'Not reachable. Tap to fix.';
      case 'unset':
        return 'Not set. Tap to add.';
      default:
        return 'Checking…';
    }
  }

  Color _connColor(ColorScheme cs) {
    switch (_conn) {
      case 'connected':
        return const Color(0xFF2E9E3F);
      case 'unreachable':
        return const Color(0xFFD64545);
      case 'unset':
        return cs.onSurface.withValues(alpha: 0.45);
      default:
        return const Color(0xFFE0A800);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final connColor = _connColor(cs);
    return Scaffold(
      appBar: AppBar(
        leading: const BackChevron(),
        title: const Text('Debugging Options'),
      ),
      body: ListView(
        children: [
          ListTile(
            leading: Icon(Icons.cloud_outlined, color: cs.onSurface),
            title: Text('Backend Sync URL', style: TextStyle(color: cs.onSurface)),
            subtitle: Text(_connLabel(), style: TextStyle(color: connColor)),
            trailing: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(color: connColor, shape: BoxShape.circle),
            ),
            onTap: _editBackendUrl,
          ),
          Divider(color: cs.onSurface.withValues(alpha: 0.12), height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: Icon(Icons.replay_outlined, color: cs.onSurface),
            title: Text('Replay Onboarding', style: TextStyle(color: cs.onSurface)),
            subtitle: Text('Reset first-launch flags and restart the walkthrough',
                style: TextStyle(color: cs.onSurface.withValues(alpha: 0.54))),
            onTap: () async {
              await resetOnboarding();
              if (!context.mounted) return;
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const OnboardingScreen()),
                (route) => false,
              );
            },
          ),
          Divider(color: cs.onSurface.withValues(alpha: 0.12), height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: Icon(Icons.storage_outlined, color: cs.onSurface),
            title: Text('Local Database', style: TextStyle(color: cs.onSurface)),
            subtitle: Text('View or clear the on-device SQLite store',
                style: TextStyle(color: cs.onSurface.withValues(alpha: 0.54))),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DebugDatabaseScreen()),
            ),
          ),
          Divider(color: cs.onSurface.withValues(alpha: 0.12), height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: Icon(Icons.tune_outlined, color: cs.onSurface),
            title: Text('Triage Logic', style: TextStyle(color: cs.onSurface)),
            subtitle: Text('Sensor weights, tiers and override rules',
                style: TextStyle(color: cs.onSurface.withValues(alpha: 0.54))),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const TriageLogicScreen()),
            ),
          ),
          Divider(color: cs.onSurface.withValues(alpha: 0.12), height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: Icon(Icons.location_on_outlined, color: cs.onSurface),
            title: Text('Location', style: TextStyle(color: cs.onSurface)),
            subtitle: Text('Live GPS fix, accuracy and bundle values',
                style: TextStyle(color: cs.onSurface.withValues(alpha: 0.54))),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LocationDebugScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
