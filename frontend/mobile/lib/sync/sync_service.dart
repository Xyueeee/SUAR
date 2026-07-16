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

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../map/map_constants.dart' show isBundleActive;
import '../models/distress_bundle_model.dart';
import '../services/device_identity.dart';
import '../storage/sqlite_repository.dart';

enum _PushDisposition { accepted, splitRequired, retryLater }

class _PushAttempt {
  const _PushAttempt(this.disposition, {this.permanentRejection = false});

  final _PushDisposition disposition;
  final bool permanentRejection;
}

class SyncService {
  static const int _maxBundlesPerRequest = 5000;

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

  /// POSTs bundles to /sync. Returns true only when every bundle was accepted.
  /// Swallows offline and malformed-response errors so callers can retry later.
  Future<bool> pushBundles(
    String deviceId,
    String mode,
    List<DistressBundleModel> bundles,
  ) async {
    final attempt = await _postBundles(deviceId, mode, bundles);
    return attempt.disposition == _PushDisposition.accepted;
  }

  Future<_PushAttempt> _postBundles(
    String deviceId,
    String mode,
    List<DistressBundleModel> bundles,
  ) async {
    final base = await _baseUrl();
    if (base == null || bundles.isEmpty) {
      return const _PushAttempt(_PushDisposition.retryLater);
    }
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
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode == 422) {
        return _classify422(body);
      }
      if (resp.statusCode == 413) {
        return const _PushAttempt(_PushDisposition.splitRequired);
      }
      if (resp.statusCode != 200) {
        return const _PushAttempt(_PushDisposition.retryLater);
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map || decoded['errors'] is! num) {
        return const _PushAttempt(_PushDisposition.retryLater);
      }
      final errors = (decoded['errors'] as num).toInt();
      if (errors == 0) {
        return const _PushAttempt(_PushDisposition.accepted);
      }
      // If every item failed, this is likely a transient backend/Supabase
      // outage rather than one poison sibling. Avoid recursively exploding a
      // 5,000-item batch into thousands of immediate retries. A future cycle
      // can try again; a later mixed batch will still isolate partial errors.
      if (errors >= bundles.length) {
        return const _PushAttempt(_PushDisposition.retryLater);
      }
      return const _PushAttempt(_PushDisposition.splitRequired);
    } catch (_) {
      return const _PushAttempt(_PushDisposition.retryLater);
    } finally {
      client.close(force: true);
    }
  }

  /// Decides whether an HTTP 422 is worth bisecting. FastAPI validation
  /// errors carry loc paths like ["body", "bundles", 3, "estimatedLat"] or
  /// ["body", "device", "deviceId"]. Bisection only helps when EVERY reported
  /// error points at a specific bundle index: a rejected device object rides
  /// along unchanged in every sub-request, so splitting a 5,000-bundle batch
  /// over it would burn up to 2n-1 doomed requests in one sync cycle. Device
  /// errors and unclassifiable 422 bodies are retried later instead.
  static _PushAttempt _classify422(String body) {
    try {
      final decoded = jsonDecode(body);
      final detail = decoded is Map ? decoded['detail'] : null;
      if (detail is List && detail.isNotEmpty) {
        for (final entry in detail) {
          final loc = entry is Map ? entry['loc'] : null;
          final pointsAtOneBundle = loc is List &&
              loc.length >= 3 &&
              loc[0] == 'body' &&
              loc[1] == 'bundles' &&
              loc[2] is int;
          if (!pointsAtOneBundle) {
            return const _PushAttempt(_PushDisposition.retryLater);
          }
        }
        return const _PushAttempt(
          _PushDisposition.splitRequired,
          permanentRejection: true,
        );
      }
    } catch (_) {
      // Unparseable body: fall through to the conservative choice.
    }
    return const _PushAttempt(_PushDisposition.retryLater);
  }

  /// Helper pull: stores bundles updated within the last 24 hours. Returns
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
    var n = 0;
    for (final r in rows) {
      if (r is! Map) continue;
      try {
        final bundle = _fromBackend(r);
        // Defense in depth if an older backend deployment still returns rows
        // outside the server-side updated_at filter.
        if (!isBundleActive(bundle.updatedAt)) continue;
        if (!isPlausibleBundle(bundle)) {
          debugPrint(
            '[Sync] Skipping implausible backend bundle ${bundle.bundleId}',
          );
          continue;
        }
        await repo.saveBundle(bundle);
        n++;
      } catch (_) {
        /* skip malformed row */
      }
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
    SQLiteRepository repo,
    String deviceId,
    String mode,
  ) async {
    final all = await repo.getUnsyncedBundles();
    if (all.isEmpty) return 0;
    // Bundles loaded from SQLite carry no readings (fromMap doesn't join the
    // SensorReading table) — re-attach each bundle's stored snapshot so the
    // cloud sensor_reading table actually gets populated.
    final readable = <DistressBundleModel>[];
    for (final b in all) {
      try {
        b.sensorReadings = (await repo.getReadingsForBundle(
          b.bundleId,
        )).map((r) => r.toJson()).toList();
        readable.add(b);
      } catch (e) {
        // A damaged reading snapshot must not prevent unrelated bundles from
        // reaching validation and sync. Leave this bundle for a later retry.
        debugPrint(
          '[Sync] Could not load readings for ${b.bundleId}; skipping: $e',
        );
      }
    }
    // Defense in depth behind the mesh-receipt gate (isPlausibleBundle at
    // DTNManager.onBundleReceived / the pull path): the backend 422s the WHOLE
    // /sync request over one out-of-bounds bundle, and pushBundles requires
    // errors == 0 — so one bad row stored before that gate existed (or gone
    // bad locally) would starve every other bundle's sync forever. Drop it
    // instead: it can never be accepted, so retrying is pure loss.
    final unsynced = <DistressBundleModel>[];
    for (final b in readable) {
      if (isPlausibleBundle(b)) {
        unsynced.add(b);
      } else {
        debugPrint(
          '[Sync] Deleting implausible local bundle ${b.bundleId}: '
          'fails backend /sync bounds and would block the whole batch',
        );
        await repo.deleteBundle(b.bundleId);
      }
    }
    if (unsynced.isEmpty) return 0;

    // Respect SyncRequest.bundles.max_length and isolate mixed failures.
    // A successful batch is one request; only a response proving at least one
    // bundle failed is bisected. Valid siblings then become synced even when
    // one permanent poison item remains retryable by itself.
    final accepted = <DistressBundleModel>[];
    for (
      var start = 0;
      start < unsynced.length;
      start += _maxBundlesPerRequest
    ) {
      final requestedEnd = start + _maxBundlesPerRequest;
      final end = requestedEnd < unsynced.length
          ? requestedEnd
          : unsynced.length;
      accepted.addAll(
        await _pushWithIsolation(
          deviceId,
          mode,
          unsynced.sublist(start, end),
          repo,
        ),
      );
    }
    for (final b in accepted) {
      if (!isBundleActive(b.updatedAt)) {
        await repo.deleteBundle(b.bundleId);
      } else {
        await repo.markAsSynced(b.bundleId);
      }
    }
    return accepted.length;
  }

  Future<List<DistressBundleModel>> _pushWithIsolation(
    String deviceId,
    String mode,
    List<DistressBundleModel> bundles,
    SQLiteRepository repo,
  ) async {
    if (bundles.isEmpty) return const [];
    final attempt = await _postBundles(deviceId, mode, bundles);
    switch (attempt.disposition) {
      case _PushDisposition.accepted:
        return bundles;
      case _PushDisposition.retryLater:
        return const [];
      case _PushDisposition.splitRequired:
        if (bundles.length == 1) {
          final bundle = bundles.single;
          // Never delete here. Every bundle in this list already passed the
          // isPlausibleBundle partition, so a single-bundle 422 can only mean
          // the Dart mirror has drifted from backend/models.py (fix the
          // mirror, not the data) or the DEVICE payload itself is being
          // rejected — in which case EVERY request 422s and deleting singles
          // here would wipe the whole local queue. Bisection has already
          // isolated it, so keeping it costs one small retry per cycle.
          debugPrint(
            attempt.permanentRejection
                ? '[Sync] Bundle ${bundle.bundleId} rejected by backend '
                    'validation (HTTP 422) despite passing the local mirror: '
                    'check isPlausibleBundle against backend/models.py. '
                    'Keeping it unsynced.'
                : '[Sync] Bundle ${bundle.bundleId} failed backend processing; '
                    'leaving it unsynced for retry',
          );
          return const [];
        }
        final midpoint = bundles.length ~/ 2;
        final left = await _pushWithIsolation(
          deviceId,
          mode,
          bundles.sublist(0, midpoint),
          repo,
        );
        final right = await _pushWithIsolation(
          deviceId,
          mode,
          bundles.sublist(midpoint),
          repo,
        );
        return [...left, ...right];
    }
  }

  DistressBundleModel _fromBackend(Map r) {
    final bundleId = (r['distress_bundle_id'] ?? '').toString().trim();
    final deviceId = (r['device_id'] ?? '').toString().trim();
    final createdAt = DateTime.tryParse((r['created_at'] ?? '').toString());
    final updatedAt = DateTime.tryParse((r['updated_at'] ?? '').toString());
    if (bundleId.isEmpty ||
        deviceId.isEmpty ||
        createdAt == null ||
        updatedAt == null) {
      throw const FormatException(
        'Backend bundle is missing an ID or valid timestamp',
      );
    }
    return DistressBundleModel(
      bundleId: bundleId,
      deviceId: deviceId,
      priorityScore: (r['priority_score'] as num?)?.toDouble() ?? 0,
      priorityTier: (r['priority_tier'] ?? 'None').toString(),
      estimatedLat: (r['estimated_lat'] as num?)?.toDouble(),
      estimatedLng: (r['estimated_lng'] as num?)?.toDouble(),
      accuracyMeters: (r['accuracy_meters'] as num?)?.toDouble(),
      estimatedAltitude: (r['estimated_altitude'] as num?)?.toDouble(),
      hopCount: (r['hop_count'] as num?)?.toInt() ?? 0,
      isSynced: true,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}
