import 'package:flutter/material.dart';

import '../services/app_lock.dart';
import '../services/geofence_service.dart';
import '../theme.dart';
import '../widgets/back_chevron.dart';
import '../widgets/option_card.dart';
import 'debug_options_screen.dart';
import 'offline_map_management_screen.dart';

/// Reached from the gear icon on the Dashboard.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = cs.onSurface;
    return Scaffold(
      appBar: AppBar(
        leading: const BackChevron(),
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          // ── Appearance ────────────────────────────────────────────────────
          ValueListenableBuilder<ThemeMode>(
            valueListenable: appThemeMode,
            builder: (context, mode, _) {
              final label = switch (mode) {
                ThemeMode.light  => 'Light',
                ThemeMode.dark   => 'Dark',
                ThemeMode.system => 'System default',
              };
              return ListTile(
                leading: Icon(Icons.brightness_6_outlined, color: fg),
                title: Text('Appearance', style: TextStyle(color: fg)),
                subtitle: Text(label,
                    style: TextStyle(color: fg.withValues(alpha: 0.54))),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const _AppearancePage()),
                ),
              );
            },
          ),
          Divider(
              color: fg.withValues(alpha: 0.12),
              height: 1,
              indent: 16,
              endIndent: 16),
          // ── Offline maps ──────────────────────────────────────────────────
          ListTile(
            leading: Icon(Icons.map_outlined, color: fg),
            title: Text('Offline Map Management', style: TextStyle(color: fg)),
            subtitle: Text(
              'Download, rename, or delete map regions',
              style: TextStyle(color: fg.withValues(alpha: 0.54)),
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => const OfflineMapManagementScreen()),
            ),
          ),
          Divider(
              color: fg.withValues(alpha: 0.12),
              height: 1,
              indent: 16,
              endIndent: 16),
          // ── Logging ───────────────────────────────────────────────────────
          ValueListenableBuilder<bool>(
            valueListenable: detailedLogging,
            builder: (context, detailed, _) => ListTile(
              leading: Icon(Icons.article_outlined, color: fg),
              title: Text('Activity Log', style: TextStyle(color: fg)),
              subtitle: Text(
                detailed ? 'Detailed (technical)' : 'Plain language',
                style: TextStyle(color: fg.withValues(alpha: 0.54)),
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const _LoggingPage()),
              ),
            ),
          ),
          Divider(
              color: fg.withValues(alpha: 0.12),
              height: 1,
              indent: 16,
              endIndent: 16),
          // ── Background hazard alerts ────────────────────────────────────────
          ValueListenableBuilder<bool>(
            valueListenable: backgroundGeofenceEnabled,
            builder: (context, enabled, _) => ListTile(
              leading: Icon(Icons.shield_outlined, color: fg),
              title: Text('Background Hazard Alerts', style: TextStyle(color: fg)),
              subtitle: Text(
                enabled ? 'On' : 'Off',
                style: TextStyle(color: fg.withValues(alpha: 0.54)),
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const _BackgroundAlertsPage()),
              ),
            ),
          ),
          Divider(
              color: fg.withValues(alpha: 0.12),
              height: 1,
              indent: 16,
              endIndent: 16),
          // ── Security (device-lock gate) ───────────────────────────────────
          ListTile(
            leading: Icon(Icons.lock_outline, color: fg),
            title: Text('Security', style: TextStyle(color: fg)),
            subtitle: Text(
              'Lock sensitive actions behind your device lock',
              style: TextStyle(color: fg.withValues(alpha: 0.54)),
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const _SecurityPage()),
            ),
          ),
          Divider(
              color: fg.withValues(alpha: 0.12),
              height: 1,
              indent: 16,
              endIndent: 16),
          // ── Debugging (last — developer-only) ─────────────────────────────
          ListTile(
            leading: Icon(Icons.bug_report_outlined, color: fg),
            title: Text('Debugging Options', style: TextStyle(color: fg)),
            subtitle: Text(
              'Backend sync URL, local database viewer',
              style: TextStyle(color: fg.withValues(alpha: 0.54)),
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

/// Enabling a lock is free; disabling it requires passing the device lock, so a
/// bystander cannot simply switch the protection off. Fail-open still applies
/// (AppLock.authenticate returns true when the device cannot authenticate).
Future<void> _toggleLock({
  required bool enable,
  required Future<void> Function(bool) setter,
}) async {
  if (!enable) {
    final ok = await AppLock.authenticate('Confirm to turn off this lock');
    if (!ok) return; // stay enabled
  }
  await setter(enable);
}

// ─── Appearance page ──────────────────────────────────────────────────────────

class _AppearancePage extends StatelessWidget {
  const _AppearancePage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackChevron(),
        title: const Text('Appearance'),
      ),
      body: ValueListenableBuilder<ThemeMode>(
        valueListenable: appThemeMode,
        builder: (context, mode, _) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Choose how the app looks. Dark mode uses an OLED-friendly '
                'black background that saves battery on supported screens.',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 20),
              for (final opt in const [
                (ThemeMode.light, Icons.light_mode_outlined, 'Light',
                  'Bright white background. Best for outdoor use in sunlight.'),
                (ThemeMode.system, Icons.brightness_auto_outlined,
                  'System default',
                  'Follows your phone\'s display setting. Switches automatically between light and dark.'),
                (ThemeMode.dark, Icons.dark_mode_outlined, 'Dark',
                  'Deep black background. Easier on the eyes at night and extends battery life on OLED screens.'),
              ]) ...[
                OptionCard(
                  icon: opt.$2,
                  label: opt.$3,
                  description: opt.$4,
                  selected: mode == opt.$1,
                  preview: ThemePreview(themeMode: opt.$1),
                  onTap: () => setThemeMode(opt.$1),
                ),
                const SizedBox(height: 12),
              ],
            ],
          );
        },
      ),
    );
  }
}

// ─── Background hazard alerts page ────────────────────────────────────────────

class _BackgroundAlertsPage extends StatelessWidget {
  const _BackgroundAlertsPage();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = cs.onSurface;
    return Scaffold(
      appBar: AppBar(
        leading: const BackChevron(),
        title: const Text('Background Hazard Alerts'),
      ),
      body: ValueListenableBuilder<bool>(
        valueListenable: backgroundGeofenceEnabled,
        builder: (context, enabled, _) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'When on, SUAR keeps checking your location against '
                'admin-marked hazard zones even while the app is in the '
                'background, and alerts you the moment you enter one. '
                'Android requires a small ongoing notification while this '
                'runs, it just says SUAR is checking, nothing more.',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 12),
              const Text(
                'When off, hazard checks only run while the Dashboard is '
                'open on screen, and stop as soon as you leave the app.',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 20),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: fg.withValues(alpha: 0.18)),
                  borderRadius: BorderRadius.circular(14),
                ),
                clipBehavior: Clip.antiAlias,
                child: SwitchListTile(
                  title: Text('Enable background alerts', style: TextStyle(color: fg)),
                  value: enabled,
                  onChanged: setBackgroundGeofenceEnabled,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ─── Security page ────────────────────────────────────────────────────────────

class _SecurityPage extends StatelessWidget {
  const _SecurityPage();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = cs.onSurface;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        leading: const BackChevron(),
        title: const Text('Security'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Ask for your phone\'s lock (PIN, pattern, password, or biometric) '
            'before these actions, so they can\'t be done by whoever is holding '
            'the phone.',
            style: TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 20),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: cs.onSurface.withValues(alpha: 0.18)),
              borderRadius: BorderRadius.circular(14),
            ),
            clipBehavior: Clip.antiAlias,
            child: Material(
              // A plain Container `color` here would paint over the
              // SwitchListTiles' ink layer, hiding their splashes/background
              // highlight (Flutter's "ListTile ink splashes may be invisible"
              // warning) — Material composites the fill and ink correctly.
              color: dark ? kPanelDark : cs.onSurface.withValues(alpha: 0.05),
              child: Column(
                children: [
                  ValueListenableBuilder<bool>(
                    valueListenable: AppLock.requireExitVictim,
                    builder: (context, on, _) => SwitchListTile(
                      secondary: Icon(Icons.exit_to_app, color: fg),
                      title: Text('Lock exit from Victim Mode', style: TextStyle(color: fg)),
                      subtitle: Text(
                        'Confirm before leaving victim mode',
                        style: TextStyle(color: fg.withValues(alpha: 0.54)),
                      ),
                      activeThumbColor: kAccentInk,
                      value: on,
                      onChanged: (v) => _toggleLock(
                        enable: v,
                        setter: AppLock.setRequireExitVictim,
                      ),
                    ),
                  ),
                  Divider(height: 1, indent: 16, endIndent: 16, color: fg.withValues(alpha: 0.12)),
                  ValueListenableBuilder<bool>(
                    valueListenable: AppLock.requireMedicalEdit,
                    builder: (context, on, _) => SwitchListTile(
                      secondary: Icon(Icons.medical_information_outlined, color: fg),
                      title: Text('Lock editing Medical Info', style: TextStyle(color: fg)),
                      subtitle: Text(
                        'Confirm before editing your medical info',
                        style: TextStyle(color: fg.withValues(alpha: 0.54)),
                      ),
                      activeThumbColor: kAccentInk,
                      value: on,
                      onChanged: (v) => _toggleLock(
                        enable: v,
                        setter: AppLock.setRequireMedicalEdit,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'If your phone has no lock set up, these toggles have no effect.',
            style: TextStyle(color: fg.withValues(alpha: 0.5), fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ─── Logging page ─────────────────────────────────────────────────────────────

class _LoggingPage extends StatelessWidget {
  const _LoggingPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackChevron(),
        title: const Text('Activity Log'),
      ),
      body: ValueListenableBuilder<bool>(
        valueListenable: detailedLogging,
        builder: (context, detailed, _) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Choose what the activity log shows during Victim and Helper mode.',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 20),
              OptionCard(
                icon: Icons.chat_bubble_outline,
                label: 'Plain language',
                description:
                    'Simple status updates, easy to understand at a glance. Recommended for most users.',
                selected: !detailed,
                preview: _LogPreview(detailed: false),
                onTap: () => setDetailedLogging(false),
              ),
              const SizedBox(height: 12),
              OptionCard(
                icon: Icons.terminal,
                label: 'Detailed (technical)',
                description:
                    'Raw protocol events: BLE scans, Wi-Fi handshakes, packet counts. Useful for debugging.',
                selected: detailed,
                preview: _LogPreview(detailed: true),
                onTap: () => setDetailedLogging(true),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Mini mock of the MeshActivityCard showing example log lines.
class _LogPreview extends StatelessWidget {
  const _LogPreview({required this.detailed});
  final bool detailed;

  static const _plain = [
    'Searching for helpers…',
    'Helper found nearby',
    'Sending your data…',
    'Data sent successfully',
  ];

  static const _technical = [
    'BLE_ADV_START uuid=F00D',
    'GATT_CONN rssi=-68 ok',
    'WIFIP2P_CONNECT peer=SOS',
    'BUNDLE_TX 312B ok hop=1',
  ];

  @override
  Widget build(BuildContext context) {
    final lines = detailed ? _technical : _plain;
    return Container(
      width: 52,
      height: 80,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
      ),
      clipBehavior: Clip.hardEdge,
      padding: const EdgeInsets.all(5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                line,
                style: TextStyle(
                  color: detailed
                      ? const Color(0xFF62E24B)
                      : Colors.white70,
                  fontSize: 5,
                  fontFamily: detailed ? 'monospace' : null,
                  height: 1.3,
                ),
                maxLines: 1,
                overflow: TextOverflow.clip,
              ),
            ),
        ],
      ),
    );
  }
}
