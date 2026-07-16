import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';

/// A single position estimate carried on a distress bundle. [accuracyMeters]
/// is the device's own reported ± radius (Position.accuracy) — the same number
/// the Device Test page shows as "±N m" — so a Helper can draw the uncertainty
/// circle at the real size the GPS chip claims, not a guessed constant.
///
/// [altitude] is GPS height in metres (null when the chip didn't report a
/// usable one). It's the only cheap signal that distinguishes victims stacked
/// at the same lat/lng but different floors (a collapsed building) — GPS
/// altitude error is large (often ±10-30 m), so treat it as a coarse hint, not
/// a floor count. ponytail: barometer-fused altitude would be tighter but needs
/// a sea-level-pressure reference to calibrate; deferred until a demo needs it.
class LocationFix {
  const LocationFix({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.source,
    required this.at,
    this.altitude,
  });

  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final double? altitude;

  /// 'gps' = a live fix this session; 'cached' = OS last-known position;
  /// 'spoof' = a manually-set test location (see [LocationEstimator.setSpoof]).
  final String source;
  final DateTime at;

  factory LocationFix.fromPosition(Position p, String source) => LocationFix(
    latitude: p.latitude,
    longitude: p.longitude,
    // Some chipsets report 0/negative accuracy when they don't actually
    // know it — treat that as "unknown" rather than a perfect fix.
    accuracyMeters: p.accuracy > 0 ? p.accuracy : double.nan,
    // Only trust altitude the chip claims to know (altitudeAccuracy > 0) —
    // otherwise a flat 0.0 reads as "sea level" when it really means
    // "no idea".
    altitude: p.altitudeAccuracy > 0 ? p.altitude : null,
    source: source,
    at: p.timestamp,
  );
}

/// Victim-side location source (FR 4.x). Provides the best currently-available
/// position + its accuracy so [VictimController] can stamp it onto the bundle.
///
/// ponytail: GPS + in-memory last-known cache only. Dead-reckoning (accel+gyro
/// integration) and RSSI-proximity trilateration — the other two FR 4.x
/// fallbacks — are deferred: the Helper map already drops a GPS-less victim
/// near the Helper's own position as a coarse "within radio range" stand-in,
/// which covers the offline/no-fix case without a full inertial nav system.
class LocationEstimator {
  StreamSubscription<Position>? _sub;
  LocationFix? _last;
  int _session = 0;

  // --- Test spoof (shared across all instances) -------------------------
  // A manually-set location that overrides real GPS everywhere — so a pin
  // dropped in the Location debug page also makes a real Victim bundle carry
  // those coords, letting the whole map/ring/altitude path be tested from one
  // phone without going outdoors for a lock. Static so the debug page's
  // instance and the Victim's instance share it; persisted so it survives the
  // debug page closing and a later switch into Victim mode.
  static LocationFix? _spoof;
  static const _spoofEnabledKey = 'suar_spoof_enabled';
  static const _spoofLatKey = 'suar_spoof_lat';
  static const _spoofLngKey = 'suar_spoof_lng';
  static const _spoofAccKey = 'suar_spoof_acc';
  static const _spoofAltKey = 'suar_spoof_alt';

  static bool get isSpoofing => _spoof != null;
  static LocationFix? get spoof => _spoof;

  /// Latest known fix without awaiting — spoof wins when set, else the cached
  /// GPS value. Null until the first one lands.
  LocationFix? get lastFix {
    final spoof = _spoof;
    if (spoof != null) return spoof;
    final fix = _last;
    if (fix == null) return null;
    if (fix.source == 'cached' && !_isWithinLastKnownMaxAge(fix.at)) {
      return null;
    }
    return fix;
  }

  void _log(String line) => debugPrint('[Location] $line');

  /// Best-effort: loads any saved spoof, requests permission, seeds from the OS
  /// last-known position, and opens a live GPS stream that keeps [lastFix]
  /// current. Returns false (never throws) if location is unavailable — the
  /// caller treats that as "no fix yet". When spoofing, skips GPS entirely.
  Future<bool> start() async {
    final session = ++_session;
    await loadSpoof();
    if (!_isCurrentSession(session)) return false;
    if (_spoof != null) {
      try {
        await _sub?.cancel();
      } catch (_) {
        // The stale GPS stream is best-effort cleanup; spoof remains usable.
      }
      if (!_isCurrentSession(session)) return false;
      _sub = null;
      _log('Spoof active. Skipping GPS, using set location.');
      return true;
    }
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (!_isCurrentSession(session)) return false;
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _log('Location permission not granted. Bundle will have no GPS.');
        return false;
      }
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!_isCurrentSession(session)) return false;
      if (!serviceEnabled) {
        _log('Location services off. Bundle will have no GPS.');
        return false;
      }

      // Instant, no radio wait — gives an immediate (if older) fix so the very
      // first triage cycle can already carry a location while the live stream
      // below is still acquiring its first lock.
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (!_isCurrentSession(session)) return false;
      if (lastKnown != null && _isWithinLastKnownMaxAge(lastKnown.timestamp)) {
        _last = LocationFix.fromPosition(lastKnown, 'cached');
      } else {
        if (_last?.source == 'cached') _last = null;
        if (lastKnown != null) {
          _log(
            'Ignoring last-known position older than '
            '${lastKnownPositionMaxAge.inMinutes} minutes.',
          );
        }
      }

      // start() can be re-entered (e.g. toggling the debug spoof back off) —
      // drop any existing stream first so a second one isn't leaked.
      await _sub?.cancel();
      if (!_isCurrentSession(session)) return false;
      // High accuracy = pure GPS, no network lookup — the only kind that
      // resolves offline (see the same reasoning in HelperModeScreen). A live
      // stream never "times out": it keeps emitting as fixes improve and as the
      // victim moves, so the bundle's location stays current each triage cycle.
      _sub =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 5,
            ),
          ).listen((p) {
            if (_isCurrentSession(session)) {
              _last = LocationFix.fromPosition(p, 'gps');
            }
          }, onError: (Object e) => _log('GPS stream error: $e'));
      return true;
    } catch (e) {
      _log('start failed: $e');
      return false;
    }
  }

  /// Returns the latest fix, falling back to a fresh last-known lookup if the
  /// stream hasn't produced one yet.
  Future<LocationFix?> currentFix() async {
    if (lastFix != null) return lastFix;
    try {
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null && _isWithinLastKnownMaxAge(lastKnown.timestamp)) {
        _last = LocationFix.fromPosition(lastKnown, 'cached');
      } else if (_last?.source == 'cached') {
        _last = null;
      }
    } catch (_) {
      // Best-effort — keep whatever (nothing) we had.
    }
    return lastFix;
  }

  Future<void> stop() async {
    _session++;
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
  }

  void dispose() {
    _session++;
    _sub?.cancel();
    _sub = null;
  }

  bool _isCurrentSession(int session) => session == _session;

  bool _isWithinLastKnownMaxAge(DateTime timestamp) =>
      DateTime.now().toUtc().difference(timestamp.toUtc()) <=
      lastKnownPositionMaxAge;

  // --- Spoof control (static; debug page only) --------------------------

  static Future<void> setSpoof({
    required double latitude,
    required double longitude,
    required double accuracyMeters,
    double? altitude,
  }) async {
    _spoof = LocationFix(
      latitude: latitude,
      longitude: longitude,
      accuracyMeters: accuracyMeters,
      altitude: altitude,
      source: 'spoof',
      at: DateTime.now(),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_spoofEnabledKey, true);
    await prefs.setDouble(_spoofLatKey, latitude);
    await prefs.setDouble(_spoofLngKey, longitude);
    await prefs.setDouble(_spoofAccKey, accuracyMeters);
    if (altitude != null) {
      await prefs.setDouble(_spoofAltKey, altitude);
    } else {
      await prefs.remove(_spoofAltKey);
    }
  }

  static Future<void> clearSpoof() async {
    _spoof = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_spoofEnabledKey);
    await prefs.remove(_spoofLatKey);
    await prefs.remove(_spoofLngKey);
    await prefs.remove(_spoofAccKey);
    await prefs.remove(_spoofAltKey);
  }

  static Future<void> loadSpoof() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_spoofEnabledKey) != true) {
      _spoof = null;
      return;
    }
    final lat = prefs.getDouble(_spoofLatKey);
    final lng = prefs.getDouble(_spoofLngKey);
    if (lat == null || lng == null) {
      _spoof = null;
      return;
    }
    _spoof = LocationFix(
      latitude: lat,
      longitude: lng,
      accuracyMeters: prefs.getDouble(_spoofAccKey) ?? 20,
      altitude: prefs.getDouble(_spoofAltKey),
      source: 'spoof',
      at: DateTime.now(),
    );
  }
}
