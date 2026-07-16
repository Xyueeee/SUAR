/// Opportunistic backend sync (Increment 5 / backlog #1). No connectivity
/// plugin — it simply attempts the request; success means we were online.
///   - Victim: pushes its own bundle so far-away victims surface on the
///     dashboard even without a Helper in radio range.
///   - Helper: pushes all unsynced bundles, then pulls bundles created in the
///     last 24 hours so nearby Helpers converge on the same picture.
/// Dedup is by bundleId server-side, so re-pushing the same bundle is harmless.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../map/map_constants.dart' show bundleInactiveThreshold;
import '../models/distress_bundle_model.dart';
import '../services/device_identity.dart';
import '../storage/sqlite_repository.dart';

class SyncService {
  Future<String?> _baseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final u = prefs.getString(backendSyncUrlPrefKey)?.trim();
    if (u == null || u.isEmpty) return null;
    return u.endsWith('/') ? u.substring(0, u.length - 1) : u;
  }

  // sensorReadings is whatever the bundle is carrying: the Victim's own live
  // bundle keeps the latest snapshot in memory (rebuilt every triage cycle),
  // and syncLocalBundles re-attaches a stored bundle's readings from SQLite
  // before pushing. Extra keys inside each reading map (readingId, bundleId)
  // are ignored by the backend's Pydantic model.
  Map<String, dynamic> _bundleJson(DistressBundleModel b) => {
        'bundleId': b.bundleId,
        'deviceId': b.deviceId,
        'priorityScore': b.priorityScore,
        'priorityTier': b.priorityTier,
        'estimatedLat': b.estimatedLat,
        'estimatedLng': b.estimatedLng,
        'accuracyMeters': b.accuracyMeters,
        'estimatedAltitude': b.estimatedAltitude,
        'hopCount': b.hopCount,
        'createdAt': b.createdAt.toUtc().toIso8601String(),
        'updatedAt': b.updatedAt.toUtc().toIso8601String(),
        'sensorReadings': b.sensorReadings,
        'relayLogs': const [],
      };

  /// POSTs bundles to /sync. Returns true on HTTP 200. Swallows offline errors.
  Future<bool> pushBundles(String deviceId, String mode, List<DistressBundleModel> bundles) async {
    final base = await _baseUrl();
    if (base == null || bundles.isEmpty) return false;
    final hardwareId = await DeviceIdentity.androidId();
    final payload = {
      'device': {
        'deviceId': deviceId,
        'applicationMode': mode,
        'applicationVersion': appVersion,
        'hardwareId': ?hardwareId,
      },
      'bundles': bundles.map(_bundleJson).toList(),
    };
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.postUrl(Uri.parse('$base/sync'));
      req.headers.set('content-type', 'application/json');
      req.headers.set('ngrok-skip-browser-warning', 'true');
      req.add(utf8.encode(jsonEncode(payload)));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      await resp.drain();
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Helper pull: stores bundles created within the last 24 hours. Returns
  /// count stored. Backend rows use lowercase keys (Supabase), mapped here.
  Future<int> pullRecent(SQLiteRepository repo) async {
    final base = await _baseUrl();
    if (base == null) return 0;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    List<dynamic> rows;
    try {
      final req = await client.getUrl(Uri.parse('$base/bundles'));
      req.headers.set('ngrok-skip-browser-warning', 'true');
      final resp = await req.close().timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return 0;
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! List) return 0;
      rows = decoded;
    } catch (_) {
      return 0;
    } finally {
      client.close(force: true);
    }
    final cutoff = DateTime.now().toUtc().subtract(const Duration(hours: 24));
    var n = 0;
    for (final r in rows) {
      if (r is! Map) continue;
      final created = DateTime.tryParse((r['created_at'] ?? '').toString());
      if (created == null || created.toUtc().isBefore(cutoff)) continue;
      try {
        await repo.saveBundle(_fromBackend(r));
        n++;
      } catch (_) {/* skip malformed row */}
    }
    return n;
  }

  /// Pushes every unsynced local bundle to the backend, then either marks it
  /// synced (still active — keep it for map/relay use) or deletes it locally
  /// (inactive — backend now holds the only copy worth keeping). Shared by
  /// HelperController's own sync loop and the background geofence/notice
  /// check-in, so local bundles upload on ANY backend touch, not only while
  /// the Helper screen happens to be open. Returns count pushed (0 offline).
  Future<int> syncLocalBundles(
      SQLiteRepository repo, String deviceId, String mode) async {
    final unsynced = await repo.getUnsyncedBundles();
    if (unsynced.isEmpty) return 0;
    // Bundles loaded from SQLite carry no readings (fromMap doesn't join the
    // SensorReading table) — re-attach each bundle's stored snapshot so the
    // cloud sensor_reading table actually gets populated.
    for (final b in unsynced) {
      b.sensorReadings = (await repo.getReadingsForBundle(b.bundleId))
          .map((r) => r.toJson())
          .toList();
    }
    if (!await pushBundles(deviceId, mode, unsynced)) return 0;
    for (final b in unsynced) {
      if (DateTime.now().toUtc().difference(b.createdAt.toUtc()) >
          bundleInactiveThreshold) {
        await repo.deleteBundle(b.bundleId);
      } else {
        await repo.markAsSynced(b.bundleId);
      }
    }
    return unsynced.length;
  }

  DistressBundleModel _fromBackend(Map r) => DistressBundleModel(
        bundleId: (r['distress_bundle_id'] ?? '').toString(),
        deviceId: (r['device_id'] ?? '').toString(),
        priorityScore: (r['priority_score'] as num?)?.toDouble() ?? 0,
        priorityTier: (r['priority_tier'] ?? 'None').toString(),
        estimatedLat: (r['estimated_lat'] as num?)?.toDouble(),
        estimatedLng: (r['estimated_lng'] as num?)?.toDouble(),
        accuracyMeters: (r['accuracy_meters'] as num?)?.toDouble(),
        estimatedAltitude: (r['estimated_altitude'] as num?)?.toDouble(),
        hopCount: (r['hop_count'] as num?)?.toInt() ?? 0,
        isSynced: true,
        createdAt: DateTime.tryParse((r['created_at'] ?? '').toString()) ?? DateTime.now().toUtc(),
        updatedAt: DateTime.tryParse((r['updated_at'] ?? '').toString()) ?? DateTime.now().toUtc(),
      );
}
