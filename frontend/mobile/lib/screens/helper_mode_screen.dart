import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../controllers/helper_controller.dart';
import '../map/map_constants.dart';
import '../models/distress_bundle_model.dart';
import '../widgets/mesh_activity_card.dart';
import '../widgets/radio_status_banner.dart';

class _PinPlacement {
  _PinPlacement({
    required this.bundle,
    required this.point,
    required this.isApproximate,
  });

  final DistressBundleModel bundle;
  final LatLng point;
  final bool isApproximate;
}

/// "4.1.4 SUAR Emergency Mode - Helper Mode" (Figma node 10:191).
class HelperModeScreen extends StatefulWidget {
  const HelperModeScreen({super.key});

  @override
  State<HelperModeScreen> createState() => _HelperModeScreenState();
}

class _HelperModeScreenState extends State<HelperModeScreen> {
  final HelperController _controller = HelperController();
  final MapController _mapController = MapController();
  final List<LogEntry> _log = [];
  List<DistressBundleModel> _bundles = const [];
  LatLng? _userLocation;
  _PinPlacement? _selectedPin;
  // Separate from "Locating…" (_userLocation == null, a GPS concern) — this
  // is "no map tiles exist for here, offline or not pre-downloaded", a
  // completely different reason the map can look blank. Conflating the two
  // made "Locating…" spin forever on a screen that was never going to
  // change, since no GPS fix was ever going to fix a missing tile.
  bool _tilesUnavailable = false;
  StreamSubscription<String>? _statusSub;
  StreamSubscription<List<DistressBundleModel>>? _bundleSub;
  StreamSubscription<Position>? _positionSub;
  Timer? _staleCheckTimer;

  @override
  void initState() {
    super.initState();
    _statusSub = _controller.statusStream.listen((line) {
      if (!mounted) return;
      setState(() => _log.add(LogEntry(line)));
    });
    _bundleSub = _controller.bundleStream.listen((bundles) {
      if (!mounted) return;
      setState(() => _bundles = bundles);
    });
    _controller.startHelperMode();
    _centerOnUserLocation();
    // _victimPins re-filters by age on every build, but a quiet Helper (no
    // nearby BLE/Wi-Fi activity) might not rebuild for a long time on its
    // own — without this, a pin could sit on the map well past
    // staleBundleMapThreshold simply because nothing else triggered a
    // repaint. A minute is frequent enough against an hour-scale threshold
    // without doing meaningful extra work.
    _staleCheckTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _logLine(String line) {
    // GPS/location lines originate here, not in a controller — mirror to
    // logcat the same way controllers do, otherwise a logcat-only capture
    // (no screenshot of the in-app activity card) can never show them.
    debugPrint('[HelperScreen] $line');
    if (!mounted) return;
    setState(() => _log.add(LogEntry(line)));
  }

  Future<void> _centerOnUserLocation() async {
    try {
      var permission = await Geolocator.checkPermission();
      _logLine('Location permission: $permission');
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        _logLine('Location permission after request: $permission');
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _logLine(
          'Location permission not granted — map stays at default center.',
        );
        return;
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        _logLine('Location services (GPS) are off on this device.');
        return;
      }

      // A cached fix is instant and good enough just to recentre the map —
      // grab it first so the map isn't stuck at the default centre while
      // the stream below is still waiting on its first fix (confirmed on
      // real hardware: some chipsets indoors can take well over a minute to
      // get a first GPS lock — a one-shot getCurrentPosition() with any
      // fixed timeout was guaranteed to "fail" on those, even though the
      // hardware was never actually broken, just slow).
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null && mounted) {
        _applyPosition(lastKnown, label: 'last known fix', recenter: true);
      }

      // A live stream (vs. one-shot getCurrentPosition) never "times out" —
      // it just keeps the GPS radio listening and emits whenever a fix
      // becomes available, however long that takes, and keeps emitting
      // updates afterwards so the dot tracks the Helper moving around.
      //
      // Accuracy must be high/GPS-based, not medium — confirmed on real
      // hardware: medium/network-based positioning resolves via a lookup
      // against a location-service backend, which needs internet. A device
      // that's offline (the exact scenario this whole app is built for) can
      // NEVER get a fix that way, no matter how long it waits. Pure GPS
      // (high accuracy) needs no network at all, just a sky view — slower
      // indoors, but it will eventually resolve, which medium never will
      // when there's no connectivity. The earlier "medium works indoors"
      // finding was measured with internet available, which silently masked
      // this — it was network positioning succeeding, not GPS.
      _positionSub =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
            ),
          ).listen((position) {
            if (!mounted) return;
            // Only snap the camera to the very first live fix — once the
            // Helper has a location, later updates should move the dot, not
            // yank the map away from wherever they've since panned/zoomed to.
            _applyPosition(
              position,
              label: 'live fix',
              recenter: _userLocation == null,
            );
          }, onError: (Object e) => _logLine('GPS stream error: $e'));
    } catch (e) {
      _logLine('GPS fix failed: $e');
    }
  }

  void _applyPosition(
    Position position, {
    required String label,
    required bool recenter,
  }) {
    final location = LatLng(position.latitude, position.longitude);
    if (recenter) _mapController.move(location, 15);
    setState(() => _userLocation = location);
    // Routed through _logLine (not a direct _log.add) so a successful fix
    // is mirrored to logcat too — without this, a logcat-only capture could
    // never tell a real fix apart from one that never arrived, since both
    // looked identical (no GPS lines at all) from the log alone.
    _logLine(
      'GPS $label: ${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}',
    );
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _bundleSub?.cancel();
    _positionSub?.cancel();
    _staleCheckTimer?.cancel();
    _mapController.dispose();
    // See VictimModeScreen.dispose: stopHelperMode is async and still
    // emits to statusStream while stopping, so dispose() must wait for it.
    unawaited(_controller.stopHelperMode().whenComplete(_controller.dispose));
    super.dispose();
  }

  double _currentZoomOrDefault() {
    try {
      return _mapController.camera.zoom;
    } catch (_) {
      return defaultMapZoom;
    }
  }

  /// Null falls back to the widget's geometric center (see
  /// _RadarBackdropPainter) — there's no GPS dot to track yet.
  Offset? _userScreenOffset(Size mapSize) {
    final location = _userLocation;
    if (location == null) return null;
    try {
      return _mapController.camera.latLngToScreenOffset(location);
    } catch (_) {
      return null;
    }
  }

  /// Only the latest bundle per deviceId. Real GPS coords (estimatedLat/Lng)
  /// are null until LocationEstimator (Increment 4) lands — until then, a
  /// bundle that arrived at all means the victim is within Wi-Fi Direct
  /// range, so it's placed near this Helper's own position as a rough
  /// stand-in rather than hidden from the map entirely (a bundle had no way
  /// to show up — or even be counted — before this).
  List<_PinPlacement> get _victimPins {
    final seenDevices = <String>{};
    final pins = <_PinPlacement>[];
    for (final bundle in _bundles) {
      // Stale data is worse than no data — an hour-old pin on the map looks
      // exactly as "live" as one from 10 seconds ago, but the victim may
      // have already moved or been found. DTN relay (HelperController/
      // DTNManager) is untouched by this — only this device's own map
      // display hides it.
      if (DateTime.now().difference(bundle.updatedAt) >
          staleBundleMapThreshold) {
        continue;
      }
      if (!seenDevices.add(bundle.deviceId)) continue;
      final hasGps = bundle.estimatedLat != null && bundle.estimatedLng != null;
      final point = hasGps
          ? LatLng(bundle.estimatedLat!, bundle.estimatedLng!)
          : _jitter(_userLocation ?? defaultMapCenter, bundle.deviceId);
      pins.add(
        _PinPlacement(bundle: bundle, point: point, isApproximate: !hasGps),
      );
    }
    return pins;
  }

  /// Deterministic small offset so multiple GPS-less victims near the same
  /// fallback point don't render as one fully-overlapping pin.
  LatLng _jitter(LatLng base, String seed) {
    final h = seed.hashCode;
    final dLat = ((h % 1000) / 1000 - 0.5) * 0.001;
    final dLng = (((h ~/ 1000) % 1000) / 1000 - 0.5) * 0.001;
    return LatLng(base.latitude + dLat, base.longitude + dLng);
  }

  /// "go at your own risk" framing — a coordinator can't yet know server-side
  /// whether a victim has already been found (that requires Increment 4's
  /// sync fetch-back), so the best available signal is simply how old the
  /// data is and whether it's first-hand or relayed.
  static String _ageLabel(DateTime updatedAt) {
    final age = DateTime.now().difference(updatedAt);
    if (age.inSeconds < 90) return '${age.inSeconds}s ago';
    if (age.inMinutes < 90) return '${age.inMinutes}m ago';
    return '${age.inHours}h ago';
  }

  static const double _popupWidth = 190;

  /// Small "tap a pin, see a brief card above it" popup (Waze-style) — a
  /// quick glance without committing to the full bottom sheet.
  Widget _buildBundlePopup(_PinPlacement pin, Size mapSize) {
    final bundle = pin.bundle;
    final screenPoint = _mapController.camera.latLngToScreenOffset(pin.point);
    final left = (screenPoint.dx - _popupWidth / 2).clamp(
      8.0,
      mapSize.width - _popupWidth - 8.0,
    );
    final top = (screenPoint.dy - 110).clamp(8.0, mapSize.height - 130.0);
    final shortId = bundle.deviceId.replaceAll('-', '');
    return Positioned(
      left: left,
      top: top,
      width: _popupWidth,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        elevation: 6,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Victim ${shortId.length <= 4 ? shortId : shortId.substring(shortId.length - 4)}',
                      style: const TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => setState(() => _selectedPin = null),
                    child: const Icon(
                      Icons.close,
                      size: 16,
                      color: Colors.black45,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                pin.isApproximate
                    ? '${bundle.priorityTier} priority · approx. location'
                    : '${bundle.priorityTier} priority',
                style: const TextStyle(color: Colors.black54, fontSize: 12),
              ),
              Text(
                // hopCount > 0 means this bundle reached this device via DTN
                // relay, not a direct Wi-Fi Direct transfer — by the time it's
                // hopped, another Helper may already have it too, or the
                // victim may already be found. Surfacing both lets the user
                // judge for themselves rather than treating a relayed packet
                // as confirmed-fresh.
                'as of ${_ageLabel(bundle.updatedAt)}'
                '${bundle.hopCount > 0 ? ' · relayed (${bundle.hopCount} hop${bundle.hopCount == 1 ? '' : 's'})' : ''}',
                style: const TextStyle(color: Colors.black38, fontSize: 11),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 30,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    // Was a light blue that stood out oddly against this
                    // popup's white card — dark grey matches the rest of
                    // the app's black theme instead of introducing a
                    // one-off accent color just for this button.
                    backgroundColor: Colors.grey.shade800,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () {
                    setState(() => _selectedPin = null);
                    _showBundleDetail(bundle);
                  },
                  child: const Text('Details', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showBundleDetail(DistressBundleModel bundle) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Bundle ${bundle.bundleId}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            _DetailRow('Device', bundle.deviceId),
            _DetailRow(
              'Priority',
              '${bundle.priorityTier} (${bundle.priorityScore.toStringAsFixed(2)})',
            ),
            _DetailRow('Hop count', '${bundle.hopCount}'),
            _DetailRow('Created', bundle.createdAt.toLocal().toString()),
            _DetailRow(
              'Updated',
              '${bundle.updatedAt.toLocal()} (${_ageLabel(bundle.updatedAt)})',
            ),
            _DetailRow('Synced', bundle.isSynced ? 'Yes' : 'No'),
            // hopCount == 0 means this device detected the victim directly
            // over Wi-Fi Direct — first-hand and trustworthy. hopCount > 0
            // means it arrived via another Helper's relay, so this device
            // never confirmed it itself; once server fetch-back (Increment
            // 4) exists, an aged server-sourced bundle should get the same
            // treatment.
            if (bundle.hopCount > 0)
              const _DetailRow(
                'Caution',
                'Relayed via another Helper, not directly detected by this '
                    'device — may already be resolved.',
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pins = _victimPins;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 21, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(
                          Icons.chevron_left,
                          color: Colors.white,
                        ),
                      ),
                      const Text(
                        'Helper Mode',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.circle, size: 8, color: Colors.greenAccent),
                        SizedBox(width: 6),
                        Text(
                          'Searching',
                          style: TextStyle(color: Colors.white, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Helper mode is now active.\n\n'
                'Your phone is now currently actively searching and forwarding SOS signals.',
                style: TextStyle(color: Colors.white, fontSize: 15),
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(25),
                child: SizedBox(
                  height: 340,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final mapSize = Size(
                        constraints.maxWidth,
                        constraints.maxHeight,
                      );
                      return Stack(
                        children: [
                          // Faint grid + range rings, behind the map —
                          // shows through wherever a tile is missing
                          // (offline, not pre-downloaded) instead of a flat
                          // grey/black rectangle, so a gap reads as
                          // instrumentation missing imagery rather than
                          // "broken". Drawing the rings on top of the map
                          // instead was tried and wasn't actually visible
                          // enough to be worth obscuring tiles/pins for.
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _RadarGridPainter(
                                // _mapController.camera throws until the
                                // FlutterMap below has rendered at least
                                // once — true on this very first build,
                                // since both are built in the same pass.
                                zoom: _currentZoomOrDefault(),
                                latitude:
                                    _userLocation?.latitude ??
                                    defaultMapCenter.latitude,
                                // Rings track the user's actual GPS dot,
                                // not the widget's geometric center — those
                                // only coincide right after a fix first
                                // recentres the camera; panning or zooming
                                // afterwards (or never having a fix yet)
                                // moves them apart.
                                center: _userScreenOffset(mapSize),
                              ),
                            ),
                          ),
                          FlutterMap(
                            mapController: _mapController,
                            options: MapOptions(
                              initialCenter: defaultMapCenter,
                              initialZoom: defaultMapZoom,
                              // Transparent (not a flat fill) so the radar
                              // backdrop above shows through missing tiles —
                              // see the Positioned.fill comment above.
                              backgroundColor: Colors.transparent,
                              // OSM raster tiles bake labels into the image — they
                              // can't un-rotate independently of the tile, so the
                              // map stays north-up to keep place names readable.
                              interactionOptions: const InteractionOptions(
                                flags:
                                    InteractiveFlag.all &
                                    ~InteractiveFlag.rotate,
                              ),
                              // The popup's position is computed once, at tap time —
                              // panning/zooming after that would leave it pointing at
                              // the wrong spot, so just dismiss it instead. Also keeps
                              // the radar backdrop's range-ring labels live as the
                              // user pans/zooms.
                              onPositionChanged: (_, _) {
                                setState(() {
                                  if (_selectedPin != null) _selectedPin = null;
                                });
                              },
                            ),
                            children: [
                              TileLayer(
                                urlTemplate: osmTileUrlTemplate,
                                userAgentPackageName: osmUserAgentPackageName,
                                tileProvider: FMTCTileProvider.allStores(
                                  allStoresStrategy: BrowseStoreStrategy.read,
                                  loadingStrategy:
                                      BrowseLoadingStrategy.cacheFirst,
                                ),
                                // Offline + no pre-downloaded region for this
                                // area means every tile fails — surfaced as a
                                // banner (see _tilesUnavailable) instead of
                                // leaving a blank dark rectangle with no
                                // explanation.
                                errorTileCallback: (tile, error, stackTrace) {
                                  if (_tilesUnavailable) return;
                                  setState(() => _tilesUnavailable = true);
                                },
                              ),
                              if (_userLocation != null)
                                MarkerLayer(
                                  markers: [
                                    Marker(
                                      point: _userLocation!,
                                      width: 22,
                                      height: 22,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: Colors.blue,
                                          border: Border.all(
                                            color: Colors.white,
                                            width: 2,
                                          ),
                                          boxShadow: const [
                                            BoxShadow(
                                              color: Colors.black38,
                                              blurRadius: 4,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              MarkerLayer(
                                markers: [
                                  for (final pin in pins)
                                    Marker(
                                      point: pin.point,
                                      width: 56,
                                      // 56 was 1px short of the circle+label
                                      // Column's natural height, causing a
                                      // RenderFlex overflow on every pin.
                                      height: 60,
                                      // Anchors the circle (not the label beneath it) to the
                                      // geo-point — default center alignment would otherwise
                                      // put the midpoint of circle+label on the coordinate.
                                      alignment: const Alignment(0, -0.45),
                                      child: GestureDetector(
                                        onTap: () =>
                                            setState(() => _selectedPin = pin),
                                        child: _VictimMarker(
                                          bundle: pin.bundle,
                                          isApproximate: pin.isApproximate,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                          Positioned(
                            top: 8,
                            left: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${pins.length} victim bundle(s) received',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                          // Stacked in one column (not two independently
                          // positioned corners) — two badges anchored to
                          // opposite corners visually collided once the
                          // "no map" text (long) and "Locating…" (short) were
                          // both showing at once on a narrow map width.
                          if (_userLocation == null || _tilesUnavailable)
                            Positioned(
                              bottom: 8,
                              left: 8,
                              right: 8,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (_userLocation == null)
                                    _MapStatusBadge(
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const SizedBox(
                                            width: 10,
                                            height: 10,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white70,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          // A cold GPS chip with no cached
                                          // ephemeris data can genuinely take
                                          // several minutes for its first fix
                                          // ever, especially indoors — without
                                          // saying so, a long wait here reads
                                          // as the app being broken rather
                                          // than normal first-time GPS behavior.
                                          const Text(
                                            'Locating… (first fix can take a '
                                            'few min indoors)',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  if (_userLocation == null &&
                                      _tilesUnavailable)
                                    const SizedBox(height: 6),
                                  if (_tilesUnavailable)
                                    const _MapStatusBadge(
                                      child: Text(
                                        'No map downloaded for this area (offline)',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          if (_selectedPin != null)
                            _buildBundlePopup(_selectedPin!, mapSize),
                        ],
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const RadioStatusBanner(),
              Expanded(child: MeshActivityCard(lines: _log, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shared pill styling for the map's bottom-left status badges (Locating…,
/// no-map-downloaded) — kept as one widget so the two always look identical
/// and can be stacked without redefining the same decoration twice.
class _MapStatusBadge extends StatelessWidget {
  const _MapStatusBadge({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(10),
      ),
      child: child,
    );
  }
}

/// Faint grid + range rings drawn behind the map (see the Stack in
/// build()) — fills wherever a tile is missing instead of a flat fill, so a
/// gap reads as "instrumentation with no imagery here" rather than
/// "broken".
///
/// Ring distances are FIXED real-world values (100m/200m/.../10km), evenly
/// stepped at the small end rather than jumping straight from one to the
/// next — each ring's pixel radius is recomputed from the map's actual zoom
/// via the standard Web Mercator metres-per-pixel formula, so the rings
/// behave like a real radar/range-finder: zoom in and they spread apart
/// (each still means the same real distance); zoom out and more of the
/// smaller-distance rings stop fitting, replaced by the larger ones. Only
/// rings that fit legibly within the canvas are drawn.
class _RadarGridPainter extends CustomPainter {
  _RadarGridPainter({
    required this.zoom,
    required this.latitude,
    required this.center,
  });

  final double zoom;
  final double latitude;
  final Offset? center;

  static const _gridSpacing = 28.0;
  // 1-2-5 decade progression — the standard range-ring spacing on radar
  // displays and nautical/aviation charts. Linear 100/200/300/400/500
  // steps packed every ring into the same small radius at any reasonable
  // zoom; log-style 1-2-5 steps stay visually distinct out to 10km.
  static const _fixedDistancesMeters = [
    100.0,
    200.0,
    500.0,
    1000.0,
    2000.0,
    5000.0,
    10000.0,
  ];
  static const _minLegibleRadius = 16.0;

  double get _metersPerPixel =>
      156543.03392 * math.cos(latitude * math.pi / 180) / math.pow(2, zoom);

  String _formatDistance(double meters) {
    if (meters >= 1000)
      return '${(meters / 1000).toStringAsFixed(meters % 1000 == 0 ? 0 : 1)}km';
    return '${meters.round()}m';
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFF1A1A1A),
    );
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += _gridSpacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (var y = 0.0; y < size.height; y += _gridSpacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final ringCenter = center ?? size.center(Offset.zero);
    final maxRadius = size.longestSide * 0.75;
    final metersPerPixel = _metersPerPixel;
    final ringPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final meters in _fixedDistancesMeters) {
      final radius = meters / metersPerPixel;
      if (radius < _minLegibleRadius || radius > maxRadius) continue;
      canvas.drawCircle(ringCenter, radius, ringPaint);
      final label = _formatDistance(meters);
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.3),
            fontSize: 10,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        Offset(ringCenter.dx + 4, ringCenter.dy - radius - painter.height),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RadarGridPainter oldDelegate) =>
      oldDelegate.zoom != zoom ||
      oldDelegate.latitude != latitude ||
      oldDelegate.center != center;
}

class _VictimMarker extends StatelessWidget {
  const _VictimMarker({required this.bundle, required this.isApproximate});

  final DistressBundleModel bundle;
  final bool isApproximate;

  Color get _color {
    switch (bundle.priorityTier) {
      case 'Critical':
        return Colors.redAccent;
      case 'High':
        return Colors.orangeAccent;
      case 'Moderate':
        return Colors.amber;
      case 'Low':
        return Colors.lightGreenAccent;
      default:
        return Colors.grey;
    }
  }

  String get _shortId {
    final id = bundle.deviceId.replaceAll('-', '');
    return id.length <= 4
        ? id.toUpperCase()
        : id.substring(id.length - 4).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // Approximate (no real GPS yet) pins render lighter/more
            // translucent than confirmed-GPS pins, to visually flag the
            // uncertainty rather than implying an exact fix.
            color: _color.withValues(alpha: isApproximate ? 0.55 : 0.85),
            border: Border.all(
              color: Colors.white,
              width: 2,
              style: isApproximate ? BorderStyle.none : BorderStyle.solid,
            ),
            boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 4)],
          ),
          alignment: Alignment.center,
          child: Text(
            _shortId,
            style: const TextStyle(
              color: Colors.black,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Container(
          margin: const EdgeInsets.only(top: 2),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            isApproximate ? '~Victim' : 'Victim',
            style: const TextStyle(color: Colors.white, fontSize: 9),
          ),
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
