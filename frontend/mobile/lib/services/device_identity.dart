/// Settings.Secure.ANDROID_ID — a per-app-install, per-device value that
/// survives a normal reinstall (same signing key, same device/user), unlike
/// [deviceIdPrefKey] (a random UUID regenerated whenever SharedPreferences is
/// cleared or the app is reinstalled). Sent alongside deviceId on every sync
/// so the admin console can tell "same physical phone, new install" apart
/// from "genuinely new phone". No special permission needed, and not PII —
/// unlike IMEI, which Android 10+ blocks 3rd-party apps from reading anyway.
library;

import 'package:flutter/services.dart';

class DeviceIdentity {
  DeviceIdentity._();

  static const _channel = MethodChannel('suar/device_identity');
  static String? _cached;

  /// Null on any failure (channel missing, non-Android platform) — callers
  /// treat this as optional metadata, never gating sync on it.
  static Future<String?> androidId() async {
    if (_cached != null) return _cached;
    try {
      final id = await _channel.invokeMethod<String>('getAndroidId');
      if (id != null && id.isNotEmpty) _cached = id;
      return _cached;
    } catch (_) {
      return null;
    }
  }
}
