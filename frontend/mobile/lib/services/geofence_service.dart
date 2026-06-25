/// Danger-zone proximity alerts. Fetches admin geofences, checks the device's
/// location against each (circle or polygon), and fires an OS notification on
/// entry. Re-arms when you leave a zone so re-entry alerts again. Offline-safe:
/// any failure (no URL, no fix, no permission) is a quiet no-op.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import 'notification_service.dart';

class GeofenceService {
  final Set<String> _inside = {}; // zones we've already alerted for (until exit)

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

  /// One proximity sweep. Call periodically while the app is in the foreground.
  Future<void> check() async {
    final zones = await _fetchZones();
    if (zones.isEmpty) return;
    final pos = await _position();
    if (pos == null) return;
    for (final z in zones) {
      if (z['isactive'] == false) continue;
      final id = (z['geofenceid'] ?? '').toString();
      final inside = _isInside(z, pos.latitude, pos.longitude);
      if (inside && !_inside.contains(id)) {
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
      } else if (!inside) {
        _inside.remove(id); // re-arm for next entry
      }
    }
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
