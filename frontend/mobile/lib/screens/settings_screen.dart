import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/back_chevron.dart';
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

// ─── Shared option card ───────────────────────────────────────────────────────

class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.icon,
    required this.label,
    required this.description,
    required this.selected,
    required this.preview,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String description;
  final bool selected;
  final Widget preview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: selected
              ? kAccentPale.withValues(alpha: 0.15)
              : (dark ? kPanelDark : cs.onSurface.withValues(alpha: 0.05)),
          border: Border.all(
            color: selected
                ? kAccentInk.withValues(alpha: 0.7)
                : cs.onSurface.withValues(alpha: 0.18),
            width: selected ? 1.5 : 1.0,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            preview,
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon,
                          size: 18,
                          color: selected
                              ? kAccentInk
                              : cs.onSurface.withValues(alpha: 0.7)),
                      const SizedBox(width: 8),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.normal,
                          color: selected ? kAccentInk : cs.onSurface,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.6)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(Icons.check_circle,
                color: selected ? kAccentInk : Colors.transparent, size: 20),
          ],
        ),
      ),
    );
  }
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
                _OptionCard(
                  icon: opt.$2,
                  label: opt.$3,
                  description: opt.$4,
                  selected: mode == opt.$1,
                  preview: _ThemePreview(themeMode: opt.$1),
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

/// Mini phone-frame mockup showing the colour palette for each ThemeMode.
class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.themeMode});
  final ThemeMode themeMode;

  @override
  Widget build(BuildContext context) {
    final systemDark =
        MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final previewDark = switch (themeMode) {
      ThemeMode.dark   => true,
      ThemeMode.light  => false,
      ThemeMode.system => systemDark,
    };

    final bg    = previewDark ? const Color(0xFF111111) : const Color(0xFFF5F5F5);
    final panel = previewDark ? kPanelDark              : const Color(0xFFE0E0E0);
    final text  = previewDark ? Colors.white70          : Colors.black54;

    return Container(
      width: 52,
      height: 80,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        children: [
          Container(height: 6, color: panel),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Container(
              height: 18,
              decoration: BoxDecoration(
                color: kAccentInk.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 3),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Container(
              height: 12,
              decoration: BoxDecoration(
                color: panel,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          const SizedBox(height: 3),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Container(
              height: 10,
              width: 28,
              decoration: BoxDecoration(
                color: text.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
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
              _OptionCard(
                icon: Icons.chat_bubble_outline,
                label: 'Plain language',
                description:
                    'Simple status updates, easy to understand at a glance. Recommended for most users.',
                selected: !detailed,
                preview: _LogPreview(detailed: false),
                onTap: () => setDetailedLogging(false),
              ),
              const SizedBox(height: 12),
              _OptionCard(
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
