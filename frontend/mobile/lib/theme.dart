import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide theming. Dark mode = black backgrounds + white text; the pastel
/// accent fills (emergency pink, card blue, amber) are kept unchanged since
/// black text stays readable on them in both modes.

// Accent blue (dialog buttons, links) and the pale switch/card blue.
const Color kAccentInk = Color(0xFF3E6FA8);
const Color kAccentPale = Color(0xFFA7C7E7);

/// Dark-mode panel/card background — matches the victim-mode log card shade
/// (white@10% blended over 0xFF111111 ≈ RGB 41,41,41). Use this constant on
/// every grey panel so all backgrounds are perceptually identical in dark mode.
const Color kPanelDark = Color(0xFF282828);

const String _themePrefKey = 'suar_theme_mode';
const String _detailedLoggingPrefKey = 'suar_detailed_logging';

/// Whether the mesh-activity log shows raw technical lines (true) or the
/// plain-language translation (false). Persisted in SharedPreferences.
final ValueNotifier<bool> detailedLogging = ValueNotifier<bool>(false);

Future<void> loadDetailedLogging() async {
  final p = await SharedPreferences.getInstance();
  detailedLogging.value = p.getBool(_detailedLoggingPrefKey) ?? false;
}

Future<void> setDetailedLogging(bool value) async {
  detailedLogging.value = value;
  final p = await SharedPreferences.getInstance();
  await p.setBool(_detailedLoggingPrefKey, value);
}

/// Live theme-mode notifier. [MaterialApp] listens; Settings changes it.
/// Defaults to system (follows OS dark/light preference).
final ValueNotifier<ThemeMode> appThemeMode =
    ValueNotifier<ThemeMode>(ThemeMode.system);

Future<void> loadThemeMode() async {
  final p = await SharedPreferences.getInstance();
  // Migrate old bool pref (suar_dark_mode) if present.
  final legacy = p.getBool('suar_dark_mode');
  if (legacy != null) {
    appThemeMode.value = legacy ? ThemeMode.dark : ThemeMode.light;
    await p.remove('suar_dark_mode');
    await p.setString(_themePrefKey, legacy ? 'dark' : 'light');
    return;
  }
  appThemeMode.value = _parse(p.getString(_themePrefKey) ?? 'system');
}

Future<void> setThemeMode(ThemeMode mode) async {
  appThemeMode.value = mode;
  final p = await SharedPreferences.getInstance();
  await p.setString(_themePrefKey, _key(mode));
}

ThemeMode _parse(String s) => switch (s) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

String _key(ThemeMode m) => switch (m) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      _ => 'system',
    };

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final bg = dark ? Colors.black : Colors.white;
  final fg = dark ? Colors.white : Colors.black;
  final base = ThemeData(brightness: brightness, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: bg,
    colorScheme: base.colorScheme.copyWith(surface: bg, onSurface: fg),
    appBarTheme: AppBarTheme(backgroundColor: bg, foregroundColor: fg, elevation: 0),
    dividerColor: fg.withValues(alpha: 0.12),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: kAccentInk),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: kAccentInk,
      selectionColor: kAccentInk.withValues(alpha: 0.3),
      selectionHandleColor: kAccentInk,
    ),
    // Pale-blue switches with thin modern bezels.
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? kAccentPale : null,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? kAccentPale.withValues(alpha: 0.5)
            : null,
      ),
      // Selected: no outline (filled track only). Unselected: thin 1.5 px.
      trackOutlineWidth: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? 0.0 : 1.5,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.transparent : null,
      ),
    ),
  );
}
