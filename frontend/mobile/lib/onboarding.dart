import 'package:shared_preferences/shared_preferences.dart';

const _kSeenOnboarding = 'seenOnboarding';
const _kShowDashboardTourOnce = 'showDashboardTourOnce';

Future<bool> hasSeenOnboarding() async {
  final p = await SharedPreferences.getInstance();
  return p.getBool(_kSeenOnboarding) ?? false;
}

/// Marks onboarding done and arms the one-time dashboard help tour. Called
/// only from the final "Get Started" tap, never per-page, so quitting the
/// app mid-onboarding simply restarts the flow from page one next launch.
Future<void> completeOnboarding() async {
  final p = await SharedPreferences.getInstance();
  await p.setBool(_kSeenOnboarding, true);
  await p.setBool(_kShowDashboardTourOnce, true);
}

/// Debug-only: clears both flags so onboarding replays as if first launch.
Future<void> resetOnboarding() async {
  final p = await SharedPreferences.getInstance();
  await p.remove(_kSeenOnboarding);
  await p.remove(_kShowDashboardTourOnce);
}

/// Returns true only the first time this is called after onboarding
/// completes, then consumes the flag so later app opens don't re-fire it.
Future<bool> consumeShowDashboardTourOnce() async {
  final p = await SharedPreferences.getInstance();
  final show = p.getBool(_kShowDashboardTourOnce) ?? false;
  if (show) await p.setBool(_kShowDashboardTourOnce, false);
  return show;
}
