import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';

/// Optional password gate in front of Settings > Debugging Options. Admin
/// toggles it and sets the password remotely (web System Settings); the
/// device caches the enabled flag + password hash so the gate still works
/// offline (field testers may have no connectivity at all). Baked-in default
/// ("SUARadmin123." — note the trailing dot) applies before the device has
/// ever synced.
///
/// Low-stakes by design: this keeps casual users out of dev tools, it is not
/// a real auth boundary, so caching the hash on-device (rather than
/// verifying server-side every time) is an acceptable tradeoff for staying
/// usable offline.
class DebugLockService {
  DebugLockService._();

  static const String _enabledKey = 'suar_debug_lock_enabled';
  static const String _hashKey = 'suar_debug_lock_hash';
  static const String _defaultPassword = 'SUARadmin123.';
  static bool _unlockedForSession = false;

  static String _hash(String password) =>
      sha256.convert(utf8.encode(password)).toString();

  static Future<String?> _baseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final u = prefs.getString(backendSyncUrlPrefKey)?.trim();
    if (u == null || u.isEmpty) return null;
    return u.endsWith('/') ? u.substring(0, u.length - 1) : u;
  }

  /// Opportunistic pull, same shape as GeofenceService's zone fetch — any
  /// failure (no URL, offline, bad response) is a quiet no-op that leaves
  /// whatever was last cached (or the baked-in default) in place.
  static Future<void> refresh() async {
    final base = await _baseUrl();
    if (base == null) return;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(Uri.parse('$base/debug-lock'));
      req.headers.set('ngrok-skip-browser-warning', 'true');
      final resp = await req.close().timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return;
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map) return;
      final enabled = decoded['enabled'] as bool?;
      final passwordHash = decoded['password_hash'] as String?;
      if (enabled == null) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, enabled);
      if (passwordHash != null && passwordHash.isNotEmpty) {
        await prefs.setString(_hashKey, passwordHash);
      }
    } catch (_) {
      // offline — try again on the next background check-in
    } finally {
      client.close(force: true);
    }
  }

  /// Whether the gate is currently on. Defaults on, matching the admin
  /// default, until this device has synced at least once.
  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? true;
  }

  /// A successful password entry unlocks the developer tools only for this
  /// process. Nothing is written to disk, so a full app restart asks again.
  static bool get isUnlockedForSession => _unlockedForSession;

  static Future<bool> checkPassword(String entered) async {
    final prefs = await SharedPreferences.getInstance();
    final storedHash = prefs.getString(_hashKey) ?? _hash(_defaultPassword);
    final valid = _hash(entered) == storedHash;
    if (valid) _unlockedForSession = true;
    return valid;
  }
}
