import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:latlong2/latlong.dart';

import 'map_constants.dart';

class ActiveDownload {
  ActiveDownload({required this.storeName, this.isQueued = false});

  final String storeName;
  DownloadProgress? progress;
  bool isPaused = false;
  bool isQueued;
}

/// Tracks in-progress region downloads at the app level (not tied to any
/// screen), so navigating away from RegionDownloadScreen doesn't lose
/// progress. Caps concurrent downloads at [maxParallel]; extras queue.
///
/// Does NOT survive a full app process kill — that would need a foreground
/// service driving the download, not just an app-level singleton. On app
/// restart, [resumeFailedDownloads] best-effort resumes anything FMTC's own
/// recovery log finds left over from an unexpected stop.
class OfflineDownloadManager extends ChangeNotifier {
  OfflineDownloadManager._();
  static final OfflineDownloadManager instance = OfflineDownloadManager._();

  static const int maxParallel = 2;

  final Map<String, ActiveDownload> active = {};
  final List<String> _queue = [];
  final Map<String, DownloadableRegion> _queuedRegions = {};

  Future<void> startNewRegion({
    required String storeName,
    required LatLngBounds bounds,
    required int minZoom,
    required int maxZoom,
  }) async {
    await FMTCStore(storeName).manage.create();
    await _saveBoundsAndEnqueue(
      storeName: storeName,
      bounds: bounds,
      minZoom: minZoom,
      maxZoom: maxZoom,
    );
  }

  /// Re-downloads an existing store with new (e.g. resized) bounds.
  ///
  /// Resets the store first: FMTC's downloader only ever adds tiles, so a
  /// shrunk box would otherwise leave the old, now out-of-bounds tiles
  /// sitting in storage forever. There's no per-tile "prune to new bounds"
  /// API exposed, so a full reset + redownload is the only way to actually
  /// reclaim that space — worth it given low-storage devices are an explicit
  /// target here, even though it means losing the skip-existing-tiles speed
  /// benefit for the part of the box that didn't change.
  Future<void> updateBounds({
    required String storeName,
    required LatLngBounds bounds,
    required int minZoom,
    required int maxZoom,
  }) async {
    await FMTCStore(storeName).manage.reset();
    await _saveBoundsAndEnqueue(
      storeName: storeName,
      bounds: bounds,
      minZoom: minZoom,
      maxZoom: maxZoom,
    );
  }

  Future<void> _saveBoundsAndEnqueue({
    required String storeName,
    required LatLngBounds bounds,
    required int minZoom,
    required int maxZoom,
  }) async {
    final store = FMTCStore(storeName);
    await store.metadata.setBulk(
      kvs: {
        'north': bounds.north.toString(),
        'south': bounds.south.toString(),
        'east': bounds.east.toString(),
        'west': bounds.west.toString(),
        'minZoom': minZoom.toString(),
        'maxZoom': maxZoom.toString(),
      },
    );

    final region = RectangleRegion(bounds).toDownloadable(
      minZoom: minZoom,
      maxZoom: maxZoom,
      options: TileLayer(
        urlTemplate: osmTileUrlTemplate,
        userAgentPackageName: osmUserAgentPackageName,
      ),
    );
    _enqueue(storeName, region);
  }

  Future<void> updateExisting(FMTCStore store) async {
    final metadata = await store.metadata.read;
    final north = double.tryParse(metadata['north'] ?? '');
    final south = double.tryParse(metadata['south'] ?? '');
    final east = double.tryParse(metadata['east'] ?? '');
    final west = double.tryParse(metadata['west'] ?? '');
    final minZoom = double.tryParse(metadata['minZoom'] ?? '')?.round();
    final maxZoom = double.tryParse(metadata['maxZoom'] ?? '')?.round();
    if (north == null ||
        south == null ||
        east == null ||
        west == null ||
        minZoom == null ||
        maxZoom == null) {
      throw StateError(
        'Store "${store.storeName}" has no saved bounds to update from.',
      );
    }

    final region =
        RectangleRegion(
          LatLngBounds(LatLng(north, east), LatLng(south, west)),
        ).toDownloadable(
          minZoom: minZoom,
          maxZoom: maxZoom,
          options: TileLayer(
            urlTemplate: osmTileUrlTemplate,
            userAgentPackageName: osmUserAgentPackageName,
          ),
        );
    _enqueue(store.storeName, region);
  }

  /// Best-effort resume of downloads interrupted by an app crash/kill, using
  /// FMTC's own recovery log. Only catches what FMTC recorded — does not
  /// resume anything if the app was closed cleanly (recovery entry is
  /// cleared on normal completion or cancellation).
  Future<void> resumeFailedDownloads() async {
    final recoverable = await FMTCRoot.recovery.recoverableRegions;
    for (final entry in recoverable.failedOnly) {
      final region = entry.toDownloadable(
        TileLayer(
          urlTemplate: osmTileUrlTemplate,
          userAgentPackageName: osmUserAgentPackageName,
        ),
      );
      _enqueue(entry.storeName, region);
    }
  }

  void _enqueue(String storeName, DownloadableRegion region) {
    if (active.containsKey(storeName)) return;
    if (active.length >= maxParallel) {
      active[storeName] = ActiveDownload(storeName: storeName, isQueued: true);
      _queue.add(storeName);
      _queuedRegions[storeName] = region;
      notifyListeners();
      return;
    }
    _begin(storeName, region);
  }

  void _begin(String storeName, DownloadableRegion region) {
    final store = FMTCStore(storeName);
    // skipExistingTiles: re-downloading after resizing/editing a region (the
    // common case for _begin) shouldn't re-fetch tiles already sitting in
    // the store — only the newly-uncovered area needs fresh requests. Harmless
    // for a brand-new store too, since nothing exists yet to skip.
    final result = store.download.startForeground(
      region: region,
      instanceId: storeName,
      skipExistingTiles: true,
    );
    active[storeName] = ActiveDownload(storeName: storeName);
    notifyListeners();

    result.downloadProgress.listen(
      (progress) {
        active[storeName]?.progress = progress;
        notifyListeners();
      },
      onDone: () {
        active.remove(storeName);
        notifyListeners();
        _startNextQueued();
      },
    );
  }

  void _startNextQueued() {
    if (_queue.isEmpty) return;
    final next = _queue.removeAt(0);
    final region = _queuedRegions.remove(next);
    active.remove(next);
    if (region != null) _begin(next, region);
  }

  Future<void> pause(String storeName) async {
    final download = active[storeName];
    if (download == null || download.isQueued) return;
    await FMTCStore(storeName).download.pause(instanceId: storeName);
    download.isPaused = true;
    notifyListeners();
  }

  void resume(String storeName) {
    final download = active[storeName];
    if (download == null || download.isQueued) return;
    FMTCStore(storeName).download.resume(instanceId: storeName);
    download.isPaused = false;
    notifyListeners();
  }

  Future<void> cancel(String storeName) async {
    if (_queue.remove(storeName)) {
      _queuedRegions.remove(storeName);
      active.remove(storeName);
      notifyListeners();
      return;
    }
    await FMTCStore(storeName).download.cancel(instanceId: storeName);
    active.remove(storeName);
    notifyListeners();
    _startNextQueued();
  }
}
