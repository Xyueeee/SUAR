import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';

import 'map/offline_download_manager.dart';
import 'screens/dashboard_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FMTCObjectBoxBackend().initialise();
  // Best-effort resume of anything interrupted by a crash/kill last session.
  unawaited(OfflineDownloadManager.instance.resumeFailedDownloads());
  runApp(const SuarApp());
}

class SuarApp extends StatelessWidget {
  const SuarApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Light is the default everywhere. Screens reached through "Emergency
    // Mode" hardcode their own dark colours (OLED battery saving) regardless
    // of this theme — see VictimModeScreen/HelperModeScreen/ModeSelectionScreen.
    return MaterialApp(
      title: 'SUAR',
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: Colors.white,
        useMaterial3: true,
      ),
      home: const DashboardScreen(),
    );
  }
}
