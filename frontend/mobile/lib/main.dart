import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';

import 'constants.dart';
import 'map/offline_download_manager.dart';
import 'screens/dashboard_screen.dart';
import 'services/notification_service.dart';
import 'theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FMTCObjectBoxBackend().initialise();
  await loadThemeMode();
  await loadDetailedLogging();
  await ensureDeviceId();
  // Best-effort resume of anything interrupted by a crash/kill last session.
  unawaited(OfflineDownloadManager.instance.resumeFailedDownloads());
  // Notifications channels + permission (non-blocking; never gates startup).
  unawaited(NotificationService.instance.init());
  runApp(const SuarApp());
}

class SuarApp extends StatelessWidget {
  const SuarApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Emergency Mode screens (Victim/Helper/ModeSelection) hardcode their own
    // dark colours (OLED battery saving) regardless of this theme.
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (context, mode, _) => MaterialApp(
        title: 'SUAR',
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: mode,
        home: const DashboardScreen(),
      ),
    );
  }
}
