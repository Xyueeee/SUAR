/// Danger-zone proximity alerts. Fetches admin geofences, checks the device's
/// location against each (circle or polygon), and fires an OS notification on
/// entry. Re-arms when you leave a zone so re-entry alerts again. Offline-safe:
/// any failure (no URL, no fix, no permission) is a quiet no-op.
///
/// Also owns the background poll for warning/critical notices ([_checkUrgentNotices])
/// — unrelated to geofences, but background monitoring only needed one
/// periodic timer, so notices ride along on it instead of running their own.
/// The admin-pushed triage default and the debug-options password lock
/// ([TriageConfig.fetchRemoteDefault], [DebugLockService.refresh]) piggyback
/// on the same timer for the same reason.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../content/doc_service.dart';
import '../sensing/triage_config.dart';
import '../storage/sqlite_repository.dart';
import '../sync/sync_service.dart';
import 'debug_lock_service.dart';
import 'notification_service.dart';

const String _bgMonitoringPrefKey = 'suar_bg_geofence_enabled';

/// Whether continuous background hazard-zone monitoring is allowed to run.
/// Persisted; user-facing toggle lives in Settings. Defaults on — this is the
/// existing behaviour, just made optional (Android requires a persistent
/// notification for the foreground service this drives, so some users may
/// prefer to opt out and only get checked while Dashboard is open).
final ValueNotifier<bool> backgroundGeofenceEnabled = ValueNotifier<bool>(true);

Future<void> loadBackgroundGeofencePref() async {
  final p = await SharedPreferences.getInstance();
  backgroundGeofenceEnabled.value = p.getBool(_bgMonitoringPrefKey) ?? true;
}

Future<void> setBackgroundGeofenceEnabled(bool value) async {
  backgroundGeofenceEnabled.value = value;
  final p = await SharedPreferences.getInstance();
  await p.setBool(_bgMonitoringPrefKey, value);
  if (value) {
    await GeofenceService.instance.startBackgroundMonitoring();
  } else {
    GeofenceService.instance.stopBackgroundMonitoring();
  }
}

class GeofenceService {
  GeofenceService._();
  static final GeofenceService instance = GeofenceService._();

  final Set<String> _inside = {}; // zones we've already alerted for (until exit)
  List<Map<String, dynamic>> _cachedZones = [];
  StreamSubscription<Position>? _bgSub;
  Timer? _zoneRefreshTimer;
  final SyncService _syncService = SyncService();

  /// Zones the device is currently physically inside, recomputed on every
  /// [_evaluate] call (foreground [check] or the background position
  /// stream). Distinct from [_inside] (a one-shot entry-alert dedup set) —
  /// this reflects live "am I in one right now", for the Dashboard's
  /// persistent in-app card, and clears the moment the device leaves.
  final ValueNotifier<List<Map<String, dynamic>>> insideZones = ValueNotifier(const []);

  Future<String?> _baseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final u = prefs.getString(backendSyncUrlPrefKey)?.trim();
    if (u == null || u.isEmpty) return null;
    return u.endsWith('/') ? u.substring(0, u.length - 1) : u;
  }

  /// Public so the Helper map can draw the same zones the proximity check
  /// alerts on, instead of duplicating the fetch/parse logic.
  Future<List<Map<String, dynamic>>> fetchZones() => _fetchZones();

  Future<List<Map<String, dynamic>>> _fetchZones() async {
    final base = await _baseUrl();
    if (base == null) return const [];
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse('$base/geofences'));
      req.headers.set('ngrok-skip-browser-warning', 'true');
      final resp = await req.close().timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return const [];
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! List) return const [];
      return decoded.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    } catch (_) {
      return const [];
    } finally {
      client.close(force: true);
    }
  }

  Future<Position?> _position() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getLastKnownPosition() ?? await Geolocator.getCurrentPosition();
    } catch (_) {
      return null;
    }
  }

  /// One proximity sweep, called automatically on Dashboard open, every 60s
  /// while foregrounded, and by pull-to-refresh — this is the app's one
  /// "opportunistic connect" check-in, not something a user has to hunt down
  /// a debug menu to trigger.
  Future<void> check() async {
    // Piggyback: any backend touch is a chance to flush locally-stored
    // bundles to the admin (see _syncLocalBundles), not just Helper-mode
    // ones. Unawaited so a slow/offline sync never delays the zone sweep.
    unawaited(_syncLocalBundles());
    // Triage default + debug lock run alongside the zone fetch (not after),
    // but ARE awaited before check() returns — so pull-to-refresh genuinely
    // waits for everything this check-in covers, not just zones, before its
    // spinner stops.
    final otherPulls = Future.wait([
      TriageConfig.fetchRemoteDefault(),
      DebugLockService.refresh(),
    ]);
    final zones = await _fetchZones();
    await otherPulls;
    if (zones.isEmpty) return;
    final pos = await _position();
    if (pos == null) return;
    await _evaluate(zones, pos);
  }

  /// Pushes whatever's unsynced in local storage to the backend on this
  /// check-in, regardless of whether Helper mode is currently running — see
  /// SyncService.syncLocalBundles. Offline/no-URL is a quiet no-op.
  Future<void> _syncLocalBundles() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final deviceId = prefs.getString(deviceIdPrefKey);
      if (deviceId == null) return;
      await _syncService.syncLocalBundles(SQLiteRepository(), deviceId, 'helper');
    } catch (_) {/* offline — try again next check-in */}
  }

  /// Starts a continuous Android foreground-service position stream so
  /// danger-zone alerts still fire while the app is backgrounded, not just
  /// while Dashboard is open — reuses the exact same [_evaluate] as [check],
  /// so entries/exits stay deduped through the shared [_inside] set no
  /// matter which path noticed them. No-op if already running or if
  /// location isn't granted/on (same quiet-failure philosophy as [check];
  /// this is called unconditionally at app startup).
  Future<void> startBackgroundMonitoring() async {
    if (_bgSub != null) return;
    if (!backgroundGeofenceEnabled.value) return;
    final perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
    if (!await Geolocator.isLocationServiceEnabled()) return;

    _cachedZones = await _fetchZones();
    // Piggybacks warning/critical notice polling on the same timer — notices
    // don't need a position fix at all, so they don't need their own
    // schedule, just a periodic tick while the app isn't in the foreground.
    _zoneRefreshTimer?.cancel();
    _zoneRefreshTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
      _cachedZones = await _fetchZones();
      await _checkUrgentNotices();
      await _syncLocalBundles();
      await TriageConfig.fetchRemoteDefault();
      await DebugLockService.refresh();
    });

    _bgSub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.high,
        // Zones are city-block-scale at smallest; no need to re-check on
        // every few metres of GPS jitter.
        distanceFilter: 25,
        // Android mandates a persistent notification for any foreground
        // location service — this can't be hidden, only kept low-key. Plain
        // wording, no alarming "danger zone" phrasing in the status bar
        // itself (the actual entry alert still says that, via NotificationService).
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'SUAR',
          notificationText: 'Checking for hazard zones nearby',
          notificationChannelName: 'Hazard Zone Monitoring',
          setOngoing: true,
        ),
      ),
    ).listen(
      (pos) {
        if (_cachedZones.isEmpty) return;
        _evaluate(_cachedZones, pos);
      },
      onError: (_) {}, // best-effort; see class doc comment
    );
  }

  /// Stops continuous background monitoring (Settings toggle turned off).
  /// Foreground checks via [check] are untouched.
  void stopBackgroundMonitoring() {
    _bgSub?.cancel();
    _bgSub = null;
    _zoneRefreshTimer?.cancel();
    _zoneRefreshTimer = null;
  }

  /// Same warning/critical → OS notification rule as the dashboard's notice
  /// banner (_NoticesBannerState._load), just runnable without a Dashboard
  /// mounted. Shares [DocService]'s notifiedNoticeIds bookkeeping, so a
  /// notice never double-notifies whichever path (this timer or opening the
  /// app) happens to see it first.
  Future<void> _checkUrgentNotices() async {
    final service = DocService();
    final all = await service.loadNotices();
    final notified = await service.notifiedNoticeIds();
    final toNotify = all
        .where((n) =>
            const ['warning', 'critical'].contains((n['severity'] ?? '').toString()) &&
            !notified.contains((n['noticeid'] ?? '').toString()))
        .toList();
    if (toNotify.isEmpty) return;
    for (final n in toNotify) {
      await NotificationService.instance.show(
        (n['title'] ?? '').toString(),
        (n['subtitle'] ?? '').toString(),
        high: true,
      );
    }
    await service.markNoticesNotified(toNotify.map((n) => (n['noticeid'] ?? '').toString()));
  }

  Future<void> _evaluate(List<Map<String, dynamic>> zones, Position pos) async {
    final currentlyInside = <Map<String, dynamic>>[];
    for (final z in zones) {
      if (z['isactive'] == false) continue;
      final id = (z['geofenceid'] ?? '').toString();
      // One zone with malformed geometry (bad admin edit / raw-JSON typo)
      // must not abort the whole sweep — the geometry casts in _isInside
      // throw on non-numeric values, and this also runs unawaited from the
      // background position stream listener.
      final bool inside;
      try {
        inside = _isInside(z, pos.latitude, pos.longitude);
      } catch (_) {
        continue;
      }
      if (inside) {
        currentlyInside.add(z);
        if (!_inside.contains(id)) {
          _inside.add(id);
          final name = (z['name'] ?? 'Danger zone').toString();
          final hazard = (z['hazardtype'] ?? 'hazard').toString();
          final sev = (z['severity'] ?? 'warning').toString();
          // info = quiet; warning/danger = heads-up alert.
          await NotificationService.instance.show(
            (sev == 'danger' ? 'Danger zone: ' : 'Hazard zone: ') + name,
            'You are entering a $hazard area. Stay alert and move to safety if you can.',
            high: sev != 'info',
          );
        }
      } else {
        _inside.remove(id); // re-arm for next entry
      }
    }
    insideZones.value = currentlyInside;
  }

  bool _isInside(Map z, double lat, double lng) {
    final shape = (z['shape'] ?? '').toString();
    final geom = z['geometry'];
    if (shape == 'circle' && geom is Map && geom['center'] is List) {
      final c = geom['center'] as List;
      if (c.length < 2) return false;
      final clat = (c[0] as num).toDouble();
      final clng = (c[1] as num).toDouble();
      final r = (geom['radius_m'] as num?)?.toDouble() ?? 0;
      return _haversineMeters(lat, lng, clat, clng) <= r;
    }
    if (geom is List && geom.length >= 3) {
      final poly = geom
          .whereType<List>()
          .where((p) => p.length >= 2)
          .map((p) => [(p[0] as num).toDouble(), (p[1] as num).toDouble()])
          .toList();
      return _pointInPolygon(lat, lng, poly);
    }
    return false;
  }

  // Ray casting over [lat, lng] points (y = lat, x = lng).
  bool _pointInPolygon(double lat, double lng, List<List<double>> poly) {
    var inside = false;
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final yi = poly[i][0], xi = poly[i][1];
      final yj = poly[j][0], xj = poly[j][1];
      final intersect = ((yi > lat) != (yj > lat)) &&
          (lng < (xj - xi) * (lat - yi) / ((yj - yi) == 0 ? 1e-12 : (yj - yi)) + xi);
      if (intersect) inside = !inside;
    }
    return inside;
  }

  double _haversineMeters(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = _rad(lat2 - lat1);
    final dLng = _rad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_rad(lat1)) * cos(_rad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  double _rad(double d) => d * pi / 180.0;
}
