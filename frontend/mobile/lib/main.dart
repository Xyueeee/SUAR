import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';

import 'map/offline_download_manager.dart';
import 'screens/dashboard_screen.dart';
import 'services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FMTCObjectBoxBackend().initialise();
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
    // Light is the default everywhere. Screens reached through "Emergency
    // Mode" hardcode their own dark colours (OLED battery saving) regardless
    // of this theme — see VictimModeScreen/HelperModeScreen/ModeSelectionScreen.
    // The app's accent blue (matches the Dashboard "Device Test" card). Applied
    // to dialog buttons + text-field cursors/selection so every popup reads in
    // the same blue instead of the Material-3 default purple.
    const accentInk = Color(0xFF3E6FA8);
    return MaterialApp(
      title: 'SUAR',
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: Colors.white,
        useMaterial3: true,
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: accentInk),
        ),
        textSelectionTheme: TextSelectionThemeData(
          cursorColor: accentInk,
          selectionColor: accentInk.withValues(alpha: 0.3),
          selectionHandleColor: accentInk,
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}
