import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';

import 'constants.dart';
import 'map/offline_download_manager.dart';
import 'onboarding.dart';
import 'screens/dashboard_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/app_lock.dart';
import 'services/notification_service.dart';
import 'theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FMTCObjectBoxBackend().initialise();
  await loadThemeMode();
  await loadDetailedLogging();
  await AppLock.load();
  await ensureDeviceId();
  final seenOnboarding = await hasSeenOnboarding();
  // Best-effort resume of anything interrupted by a crash/kill last session.
  unawaited(OfflineDownloadManager.instance.resumeFailedDownloads());
  // Notification channels only (non-blocking; never gates startup). The
  // runtime permission prompt is requested once, from onboarding.
  unawaited(NotificationService.instance.init());
  runApp(SuarApp(seenOnboarding: seenOnboarding));
}

class SuarApp extends StatelessWidget {
  const SuarApp({super.key, required this.seenOnboarding});

  final bool seenOnboarding;

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
        home: seenOnboarding ? const DashboardScreen() : const OnboardingScreen(),
      ),
    );
  }
}
