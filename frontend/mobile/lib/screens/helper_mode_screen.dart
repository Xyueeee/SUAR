import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../constants.dart';
import '../controllers/helper_controller.dart';
import '../help/help_tour.dart';
import '../log_translator.dart';
import '../theme.dart';
import '../map/map_constants.dart';
import '../models/distress_bundle_model.dart';
import '../sensing/location_estimator.dart';
import '../services/geofence_service.dart';
import '../sensing/triage_calculator.dart' show TriageFlag;
import '../widgets/marquee_text.dart';
import '../widgets/mesh_activity_card.dart';
import '../widgets/radio_status_banner.dart';

class _PinPlacement {
  _PinPlacement({
    required this.bundle,
    required this.point,
    required this.isApproximate,
    required this.ringRadiusMeters,
  });

  final DistressBundleModel bundle;
  // Not final: the declutter pass nudges near-coincident pins apart for
  // legibility (see _declutterPins) before they're drawn.
  LatLng point;
  final bool isApproximate;

  /// Radius of the translucent uncertainty circle drawn under the pin. For a
  /// real GPS pin this is the bundle's reported ± accuracy (clamped to stay
  /// legible); for an approximate pin it's the fixed "somewhere near here"
  /// zone. See [_HelperModeScreenState._estimateZoneRadiusMeters].
  final double ringRadiusMeters;
}

/// "4.1.4 SUAR Emergency Mode - Helper Mode" (Figma node 10:191).
class HelperModeScreen extends StatefulWidget {
  const HelperModeScreen({super.key});

  @override
  State<HelperModeScreen> createState() => _HelperModeScreenState();
}

class _HelperModeScreenState extends State<HelperModeScreen>
    with WidgetsBindingObserver {
  final HelperController _controller = HelperController();
  final MapController _mapController = MapController();
  final List<LogEntry> _rawLog = [];
  final List<LogEntry> _displayLog = [];
  String? _lastDisplayedTriage;
  List<DistressBundleModel> _bundles = const [];
  LatLng? _userLocation;
  _PinPlacement? _selectedPin;
  bool _selfInfoOpen = false;
  Map<String, dynamic>? _selectedZone;
  bool _mapMinimized = false;
  // User-actionable reason there's no GPS dot, distinct from a fix that's
  // simply still pending. Null while normally locating; set when the user
  // denied the location permission or switched location services off — both
  // of which otherwise left the map spinning "Locating…" forever with no hint
  // that it needs THEM to fix something. _gpsBlockIsPermission picks which
  // settings page the action button opens (app permissions vs the system
  // location toggle).
  String? _gpsBlockReason;
  bool _gpsBlockIsPermission = false;
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
  Timer? _scanHeartbeatTimer;
  DateTime _lastActivityTime = DateTime.now();

  // Admin-drawn danger zones (geofences) — fetched once on open, same source
  // the background GeofenceService alerts use, so what's drawn here matches
  // what would trigger a proximity notification.
  final _geofenceService = GeofenceService.instance;
  List<Map<String, dynamic>> _geofences = const [];
  bool _disposed = false;

  // Help tour targets
  final _kRadioPill = GlobalKey();
  final _kMap = GlobalKey();
  final _kMeshCard = GlobalKey();
  late final HelpTourController _help = HelpTourController([
    HelpStep(
      targetKey: _kRadioPill,
      title: 'Your connection status',
      body: const [
        'Searching means you are listening for people who need help.',
        'It changes to Connecting then Receiving as a victim signal comes in.',
      ],
    ),
    HelpStep(
      targetKey: _kMap,
      title: 'Live map',
      body: const [
        'Each pin is a victim your phone has picked up nearby.',
        'A pin found through another helper shows its relay hop, not a direct detection.',
        'Shaded areas are admin-marked danger zones.',
      ],
      ensureVisible: () async {
        if (_mapMinimized && mounted) {
          setState(() => _mapMinimized = false);
          // Let the 200ms expand animation settle before measuring.
          await Future<void>.delayed(const Duration(milliseconds: 260));
        }
      },
    ),
    HelpStep(
      targetKey: _kMeshCard,
      title: 'Activity log',
      body: const [
        'A running record of signals received and relayed, in plain language.',
        'Collected data uploads on its own once the internet is back, no manual step.',
        'Switch to technical detail in Settings if you prefer.',
      ],
    ),
  ]);

  @override
  void initState() {
    super.initState();
    // So didChangeAppLifecycleState fires — lets the map retry GPS after the
    // user fixes a denied permission / off location service in Settings and
    // returns, instead of staying stuck on the reason badge until the screen
    // is reopened.
    WidgetsBinding.instance.addObserver(this);
    unawaited(WakelockPlus.enable());
    _statusSub = _controller.statusStream.listen(_addLogLine);
    _bundleSub = _controller.bundleStream.listen((bundles) {
      if (!mounted) return;
      setState(() => _bundles = bundles);
    });
    _controller.startHelperMode();
    _centerOnUserLocation();
    unawaited(_loadGeofences());
    // _victimPins re-filters by age on every build, but a quiet Helper (no
    // nearby BLE/Wi-Fi activity) might not rebuild for a long time on its
    // own — without this, a pin could sit on the map well past
    // staleBundleMapThreshold simply because nothing else triggered a
    // repaint. A minute is frequent enough against an hour-scale threshold
    // without doing meaningful extra work.
    _staleCheckTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    // Heartbeat: if no real activity for 25 s, add a "still scanning" entry
    // to the display log only — keeps the card from looking frozen during
    // quiet periods when no victims or helpers are nearby.
    _scanHeartbeatTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted) return;
      if (DateTime.now().difference(_lastActivityTime).inSeconds < 12) return;
      setState(() {
        _displayLog.add(LogEntry('Still scanning for people who need help…'));
        _lastActivityTime = DateTime.now();
      });
    });
  }

  Future<void> _loadGeofences() async {
    final zones = await _geofenceService.fetchZones();
    if (_disposed || !mounted) return;
    setState(() => _geofences = zones);
  }

  Color _geofenceColor(Map z) {
    switch ((z['severity'] ?? 'warning').toString()) {
      case 'danger':
        return const Color(0xFFD64545);
      case 'info':
        return const Color(0xFF3E6FA8);
      default: // warning
        return const Color(0xFFE0A800);
    }
  }

  List<LatLng> _geofencePolygonPoints(Map z) {
    final geom = z['geometry'];
    if (geom is! List) return const [];
    return geom
        .whereType<List>()
        .where((p) => p.length >= 2)
        .map((p) => LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()))
        .toList();
  }

  LatLng? _geofenceCircleCenter(Map z) {
    final geom = z['geometry'];
    if (geom is! Map) return null;
    final c = geom['center'];
    if (c is! List || c.length < 2) return null;
    return LatLng((c[0] as num).toDouble(), (c[1] as num).toDouble());
  }

  double _geofenceCircleRadius(Map z) {
    final geom = z['geometry'];
    if (geom is! Map) return 0;
    return (geom['radius_m'] as num?)?.toDouble() ?? 0;
  }

  LatLng? _geofenceLabelPoint(Map z) {
    if (z['shape'] == 'circle') return _geofenceCircleCenter(z);
    final pts = _geofencePolygonPoints(z);
    if (pts.isEmpty) return null;
    final lat = pts.map((p) => p.latitude).reduce((a, b) => a + b) / pts.length;
    final lng = pts.map((p) => p.longitude).reduce((a, b) => a + b) / pts.length;
    return LatLng(lat, lng);
  }

  /// Same card design as [_buildBundlePopup]/[_buildSelfPopup] — anchored
  /// above the tapped marker, name + close X, one subtitle line, a "Details"
  /// button into the same dark bottom-sheet pattern.
  Widget _buildZonePopup(Map z, Size mapSize) {
    final point = _geofenceLabelPoint(z);
    if (point == null) return const SizedBox.shrink();
    final screenPoint = _mapController.camera.latLngToScreenOffset(point);
    final anchor = _popupAnchor(screenPoint, mapSize, _popupGap);
    final name = (z['name'] ?? 'Hazard zone').toString();
    return Positioned(
      left: anchor.left,
      bottom: anchor.bottom,
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
                      name,
                      style: const TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => setState(() => _selectedZone = null),
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
                '${(z['hazardtype'] ?? 'hazard').toString()} · '
                '${(z['severity'] ?? 'warning').toString()}'
                '${z['isactive'] == false ? ' · inactive' : ''}',
                style: const TextStyle(color: Colors.black54, fontSize: 12),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 30,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey.shade800,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () {
                    setState(() => _selectedZone = null);
                    _showZoneDetail(z);
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

  void _showZoneDetail(Map z) {
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
              (z['name'] ?? 'Hazard zone').toString(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            _DetailRow('Hazard type', (z['hazardtype'] ?? '—').toString()),
            _DetailRow('Severity', (z['severity'] ?? '—').toString()),
            _DetailRow('Shape', (z['shape'] ?? '—').toString()),
            _DetailRow('Active', z['isactive'] == false ? 'No' : 'Yes'),
            if (z['createdat'] != null)
              _DetailRow('Created', z['createdat'].toString()),
            if (z['updatedat'] != null)
              _DetailRow('Updated', z['updatedat'].toString()),
          ],
        ),
      ),
    );
  }

  void _addLogLine(String raw) {
    if (!mounted) return;
    setState(() {
      _rawLog.add(LogEntry(raw));
      final translated = translateLog(raw);
      if (translated == null) return;
      // Suppress repeated same-tier health-check lines.
      if (translated.startsWith('Triage updated:')) {
        if (translated == _lastDisplayedTriage) return;
        _lastDisplayedTriage = translated;
      }
      _displayLog.add(LogEntry(translated));
      _lastActivityTime = DateTime.now();
    });
  }

  void _logLine(String line) {
    // GPS/location lines originate here, not in a controller — mirror to
    // logcat the same way controllers do, otherwise a logcat-only capture
    // (no screenshot of the in-app activity card) can never show them.
    debugPrint('[HelperScreen] $line');
    _addLogLine(line);
  }

  Future<void> _centerOnUserLocation() async {
    // Re-entrant: a lifecycle-resume retry can call this while an earlier
    // attempt's stream is still active — drop the old one so a fix isn't
    // delivered twice and the subscription isn't leaked.
    await _positionSub?.cancel();
    _positionSub = null;
    // Spoof overrides real GPS everywhere, including the Helper's own blue dot —
    // so a location set in the debug page drives both the victim bundles AND
    // this map's centre. loadSpoof() populates the static from prefs in case
    // this screen is the first thing to touch it after an app restart.
    await LocationEstimator.loadSpoof();
    if (LocationEstimator.isSpoofing) {
      final s = LocationEstimator.spoof!;
      if (!mounted) return;
      setState(() {
        _gpsBlockReason = null;
        _userLocation = LatLng(s.latitude, s.longitude);
      });
      try {
        _mapController.move(_userLocation!, _recenterZoom);
      } catch (_) {
        // Map not laid out yet — initialCenter covers it; the dot still shows.
      }
      _logLine(
        'Using spoofed location (testing): '
        '${s.latitude.toStringAsFixed(5)}, ${s.longitude.toStringAsFixed(5)}',
      );
      return;
    }
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
          'Location permission not granted, map stays at default center.',
        );
        if (mounted) {
          setState(() {
            _gpsBlockReason =
                'Location permission denied, the map can\'t '
                'show your position or place victims near you.';
            _gpsBlockIsPermission = true;
          });
        }
        return;
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        _logLine('Location services (GPS) are off on this device.');
        if (mounted) {
          setState(() {
            _gpsBlockReason =
                'GPS / location is off, turn it on for the map '
                'to track your position.';
            _gpsBlockIsPermission = false;
          });
        }
        return;
      }
      // Permission granted and service on — clear any earlier block badge.
      if (mounted && _gpsBlockReason != null) {
        setState(() => _gpsBlockReason = null);
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

  /// Zoom the map settles at once a GPS fix arrives and it recenters on the
  /// user (see _applyPosition). defaultMapZoom (12) is only the pre-fix KL
  /// overview — by the time the user is looking at the page it's already here,
  /// so the "recenter" button and the GPS-fix recenter must use THIS, not
  /// defaultMapZoom, to count as "back to the view it opened at".
  static const double _recenterZoom = 15;

  void _applyPosition(
    Position position, {
    required String label,
    required bool recenter,
  }) {
    final location = LatLng(position.latitude, position.longitude);
    if (recenter) _mapController.move(location, _recenterZoom);
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from Settings (where they may have granted location / turned
    // GPS on) — only retry if we're still blocked and have no fix yet, so a
    // healthy live position stream isn't needlessly torn down and restarted.
    if (state == AppLifecycleState.resumed &&
        _gpsBlockReason != null &&
        _userLocation == null) {
      _centerOnUserLocation();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _help.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _statusSub?.cancel();
    _bundleSub?.cancel();
    _positionSub?.cancel();
    _staleCheckTimer?.cancel();
    _scanHeartbeatTimer?.cancel();
    _mapController.dispose();
    unawaited(WakelockPlus.disable());
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

  /// Only the latest bundle per deviceId. A bundle now carries real GPS coords
  /// (estimatedLat/Lng + accuracyMeters) from the victim's LocationEstimator
  /// whenever a fix was available; when it wasn't (permission denied, no lock
  /// yet, GPS off), those are null and the bundle is placed near this Helper's
  /// own position as a rough "within radio range" stand-in rather than hidden
  /// from the map entirely.
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
      // Separate from the updatedAt check above: a helper-to-helper relay of
      // an old bundle, or a Victim's app just left running, keeps bumping
      // updatedAt without the underlying event actually being recent. Gate on
      // createdAt too so a genuinely stale event can't reappear on the map.
      if (DateTime.now().difference(bundle.createdAt) >
          bundleInactiveThreshold) {
        continue;
      }
      if (!seenDevices.add(bundle.deviceId)) continue;
      final hasGps = bundle.estimatedLat != null && bundle.estimatedLng != null;
      final point = hasGps
          ? LatLng(bundle.estimatedLat!, bundle.estimatedLng!)
          : _jitter(_userLocation ?? defaultMapCenter, bundle.deviceId);
      // Real GPS pin → draw the chip's reported ± accuracy as the ring (so a
      // tight fix is a small circle and a rough one a big circle), clamped so a
      // 3 m fix is still visible and a 2 km fix doesn't swallow the map. A GPS
      // pin whose chip reported no accuracy falls back to a small default ring.
      // Approximate pin (no fix) → the fixed "near the Helper" zone.
      final double ringRadiusMeters;
      if (!hasGps) {
        ringRadiusMeters = _estimateZoneRadiusMeters;
      } else if (bundle.accuracyMeters != null) {
        ringRadiusMeters = bundle.accuracyMeters!.clamp(
          _minAccuracyRingMeters,
          _maxAccuracyRingMeters,
        );
      } else {
        ringRadiusMeters = _minAccuracyRingMeters;
      }
      pins.add(
        _PinPlacement(
          bundle: bundle,
          point: point,
          isApproximate: !hasGps,
          ringRadiusMeters: ringRadiusMeters,
        ),
      );
    }
    _declutterPins(pins);
    return pins;
  }

  /// How far apart to fan victims that share (almost) the same point.
  static const double _declutterSpreadMeters = 9;

  /// Several victims at the same spot — multiple people in one building, or
  /// just within each other's GPS noise — would otherwise render as one
  /// stacked dot/label. Fan each group onto a small circle around its centroid
  /// so all are tappable. The offset (≤ a few metres) is within GPS accuracy,
  /// so it trades sub-noise precision for legibility; altitude (detail sheet)
  /// is the real differentiator for genuinely-stacked floors.
  void _declutterPins(List<_PinPlacement> pins) {
    final groups = <String, List<_PinPlacement>>{};
    for (final pin in pins) {
      // ~11 m grid (4 decimal places) — close enough to count as "same spot".
      final key = '${pin.point.latitude.toStringAsFixed(4)},'
          '${pin.point.longitude.toStringAsFixed(4)}';
      (groups[key] ??= []).add(pin);
    }
    for (final group in groups.values) {
      if (group.length < 2) continue;
      var clat = 0.0, clng = 0.0;
      for (final p in group) {
        clat += p.point.latitude;
        clng += p.point.longitude;
      }
      clat /= group.length;
      clng /= group.length;
      final metresPerDegLng = 111320 * math.cos(clat * math.pi / 180);
      for (var k = 0; k < group.length; k++) {
        final angle = 2 * math.pi * k / group.length;
        final dLat = _declutterSpreadMeters / 111320 * math.cos(angle);
        final dLng = metresPerDegLng == 0
            ? 0.0
            : _declutterSpreadMeters / metresPerDegLng * math.sin(angle);
        group[k].point = LatLng(clat + dLat, clng + dLng);
      }
    }
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

  /// Both the self dot and victim dots are now the same 22px circle (white
  /// border + shadow), so one shared gap clears either: dot radius 11 +
  /// border 2 = 13px to the visual edge, plus a small margin so the popup's
  /// rounded card doesn't visually kiss the dot.
  static const double _popupGap = 18;

  /// "Zoning" radius (metres) drawn around a victim pin that has no real GPS
  /// fix — the bundle arrived over Wi-Fi Direct so the victim is within radio
  /// range, but its exact spot is unknown, so this coarse circle near the
  /// Helper stands in for it.
  static const double _estimateZoneRadiusMeters = 60;

  /// Clamp bounds for the real GPS ± accuracy ring: a few-metre fix still draws
  /// a visible circle, and a wildly-uncertain fix can't swallow the whole map.
  static const double _minAccuracyRingMeters = 8;
  static const double _maxAccuracyRingMeters = 500;

  /// Anchors a popup by its bottom edge a fixed [gap] above the marker's
  /// screen point instead of guessing the popup's height, so the popup grows
  /// upward as its content grows and never extends down over the marker it
  /// points at.
  ({double left, double bottom}) _popupAnchor(
    Offset screenPoint,
    Size mapSize,
    double gap,
  ) {
    final left = (screenPoint.dx - _popupWidth / 2).clamp(
      8.0,
      mapSize.width - _popupWidth - 8.0,
    );
    final bottom = (mapSize.height - screenPoint.dy + gap).clamp(
      8.0,
      mapSize.height - 8.0,
    );
    return (left: left, bottom: bottom);
  }

  /// Small "tap a pin, see a brief card above it" popup (Waze-style) — a
  /// quick glance without committing to the full bottom sheet.
  Widget _buildBundlePopup(_PinPlacement pin, Size mapSize) {
    final bundle = pin.bundle;
    final screenPoint = _mapController.camera.latLngToScreenOffset(pin.point);
    final anchor = _popupAnchor(screenPoint, mapSize, _popupGap);
    return Positioned(
      left: anchor.left,
      bottom: anchor.bottom,
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
                      'Victim-${deviceNameSuffix(bundle.deviceId)}',
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
                    : bundle.accuracyMeters != null
                        ? '${bundle.priorityTier} priority · ±${bundle.accuracyMeters!.round()} m'
                        : '${bundle.priorityTier} priority',
                style: const TextStyle(color: Colors.black54, fontSize: 12),
              ),
              // At-a-glance safety-flag icons — tap Details for the full labels.
              if (bundle.flags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 6,
                    children: [
                      for (final f in bundle.flags)
                        Icon(_flagIcon(f), size: 16, color: _flagColor(f)),
                    ],
                  ),
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

  /// Small popup above the blue "you are here" dot, mirrors
  /// _buildBundlePopup's styling so a coordinator on a multi-helper job can
  /// tap either dot and get the same kind of quick "who is this" glance.
  Widget _buildSelfPopup(Size mapSize) {
    final location = _userLocation;
    if (location == null) return const SizedBox.shrink();
    final screenPoint = _mapController.camera.latLngToScreenOffset(location);
    final anchor = _popupAnchor(screenPoint, mapSize, _popupGap);
    final id = _controller.deviceId;
    final name = id == null ? 'Helper' : 'Helper-${deviceNameSuffix(id)}';
    return Positioned(
      left: anchor.left,
      bottom: anchor.bottom,
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
                      name,
                      style: const TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => setState(() => _selfInfoOpen = false),
                    child: const Icon(
                      Icons.close,
                      size: 16,
                      color: Colors.black45,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'This is you (Helper Mode)',
                style: TextStyle(color: Colors.black54, fontSize: 12),
              ),
              if (id != null) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: 30,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey.shade800,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: () => _showSelfDetail(name, id),
                    child: const Text(
                      'Details',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Full device ID behind a tap, the popup itself only ever shows the
  /// 4-character nickname, this is for cases where the full ID is needed
  /// (e.g. reading it out to a coordinator over radio).
  void _showSelfDetail(String name, String id) {
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
              name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            const _DetailRow('Role', 'This is you (Helper Mode)'),
            _DetailRow('Full device ID', id),
          ],
        ),
      ),
    );
  }


  void _showBundleDetail(DistressBundleModel bundle) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (_, scrollCtrl) => SingleChildScrollView(
          controller: scrollCtrl,
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
            _DetailRow(
              'Nickname',
              'Victim-${deviceNameSuffix(bundle.deviceId)}',
            ),
            _DetailRow('Device', bundle.deviceId),
            _DetailRow(
              'Priority',
              '${bundle.priorityTier} (${bundle.priorityScore.toStringAsFixed(2)})',
            ),
            _DetailRow(
              'Location',
              bundle.estimatedLat != null && bundle.estimatedLng != null
                  ? '${bundle.estimatedLat!.toStringAsFixed(5)}, '
                      '${bundle.estimatedLng!.toStringAsFixed(5)}'
                      '${bundle.accuracyMeters != null ? ' (±${bundle.accuracyMeters!.round()} m)' : ''}'
                  : 'Approximate (no GPS fix). Shown near this Helper.',
            ),
            if (bundle.estimatedAltitude != null)
              _DetailRow(
                'Altitude',
                '~${bundle.estimatedAltitude!.round()} m (GPS estimate, '
                    'uncalibrated. Coarse floor hint only, not a reliable height).',
              ),
            _DetailRow('Hop count', '${bundle.hopCount}'),
            _DetailRow('Created', bundle.createdAt.toLocal().toString()),
            _DetailRow(
              'Updated',
              '${bundle.updatedAt.toLocal()} (${_ageLabel(bundle.updatedAt)})',
            ),
            _DetailRow('Synced', bundle.isSynced ? 'Yes' : 'No'),
            if (bundle.flags.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                'Safety flags',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [for (final f in bundle.flags) _flagChip(f)],
              ),
            ],
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
                    'device, may already be resolved.',
              ),
          ],
        ),
        ),
      ),
    );
  }

  // Fall / faint / critical battery are life-or-comms-critical (red); low
  // battery is a caution (amber).
  Color _flagColor(String flag) => (flag == TriageFlag.fall ||
          flag == TriageFlag.faint ||
          flag == TriageFlag.criticalBattery)
      ? const Color(0xFFFF6B6B)
      : const Color(0xFFE0A500);

  IconData _flagIcon(String flag) => switch (flag) {
        TriageFlag.fall => Icons.personal_injury,
        TriageFlag.faint => Icons.airline_seat_flat,
        TriageFlag.criticalBattery => Icons.battery_alert,
        TriageFlag.lowBattery => Icons.battery_2_bar,
        _ => Icons.warning_amber_rounded,
      };

  Widget _flagChip(String flag) {
    final label = TriageFlag.labels[flag] ?? flag;
    final color = _flagColor(flag);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_flagIcon(flag), size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
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
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(
                      Icons.chevron_left,
                      color: Colors.white,
                    ),
                  ),
                  const Expanded(
                    child: MarqueeText(
                      'Helper Mode',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  HelpButton(controller: _help, color: Colors.white70),
                  ValueListenableBuilder<String>(
                    valueListenable: _controller.radioLabel,
                    builder: (ctx, status, _) {
                      final dotColor = switch (status) {
                        'Receiving'  => Colors.amber,
                        'Connecting' => const Color(0xFF4CAF50),
                        'BT Link'    => const Color(0xFF6AA8D5),
                        _            => const Color(0xFFE05555),
                      };
                      final label = status == 'BT Link' ? 'Connecting' : status;
                      return Container(
                        key: _kRadioPill,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 7, height: 7,
                              decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
                            ),
                            const SizedBox(width: 5),
                            Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
                          ],
                        ),
                      );
                    },
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
              Align(
                alignment: Alignment.centerRight,
                child: InkWell(
                  onTap: () => setState(() => _mapMinimized = !_mapMinimized),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          // Hidden: filled map ("tap to bring the map back").
                          // Shown: outlined map ("tap to put it away").
                          _mapMinimized ? Icons.map : Icons.map_outlined,
                          color: Colors.white70,
                          size: 18,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _mapMinimized ? 'Show map' : 'Hide map',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              // Letting the user collapse the map (instead of just hiding the
              // toggle) frees up the screen for the activity log below, the
              // map is the single biggest space consumer on this screen and
              // isn't always what's needed at a glance. Swapping the child to
              // SizedBox.shrink() (rather than keeping FlutterMap mounted at
              // zero height) fully unmounts it while hidden, no more tile
              // fetches or location-triggered rebuilds running in the
              // background — actually paused, not just invisible.
              AnimatedSize(
                key: _kMap,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                alignment: Alignment.topCenter,
                child: _mapMinimized
                    ? const SizedBox(width: double.infinity)
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(25),
                        child: SizedBox(
                          height: 340,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final mapSize = Size(
                                constraints.maxWidth,
                                constraints.maxHeight,
                              );
                              // Re-resolve the open victim card against THIS
                              // build's fresh pin list (by bundleId), not the
                              // _PinPlacement captured on tap. _victimPins
                              // re-mints placements every build and a bundle's
                              // point moves when a newer/relayed copy arrives,
                              // so the captured object's .point went stale and
                              // the card stayed pinned where the dot used to be
                              // while the dot jumped. Looking it up live makes
                              // the card track the dot. Gone from the list ⇒ no
                              // card (the victim aged out / was cleared).
                              _PinPlacement? selectedLivePin;
                              if (_selectedPin != null) {
                                for (final p in pins) {
                                  if (p.bundle.bundleId ==
                                      _selectedPin!.bundle.bundleId) {
                                    selectedLivePin = p;
                                    break;
                                  }
                                }
                              }
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
                                      interactionOptions:
                                          const InteractionOptions(
                                            flags:
                                                InteractiveFlag.all &
                                                ~InteractiveFlag.rotate,
                                          ),
                                      // The popup's screen position is recomputed from the
                                      // camera on every build (see _buildBundlePopup), so it
                                      // tracks the pin as the map is panned/zoomed instead of
                                      // being dismissed. This empty setState just forces that
                                      // rebuild (and keeps the radar backdrop's range-ring
                                      // labels live as the user pans/zooms).
                                      onPositionChanged: (_, _) {
                                        if (mounted) setState(() {});
                                      },
                                    ),
                                    children: [
                                      TileLayer(
                                        urlTemplate: osmTileUrlTemplate,
                                        userAgentPackageName:
                                            osmUserAgentPackageName,
                                        tileProvider:
                                            FMTCTileProvider.allStores(
                                              allStoresStrategy:
                                                  BrowseStoreStrategy.read,
                                              loadingStrategy:
                                                  BrowseLoadingStrategy
                                                      .cacheFirst,
                                            ),
                                        // Offline + no pre-downloaded region for this
                                        // area means every tile fails — surfaced as a
                                        // banner (see _tilesUnavailable) instead of
                                        // leaving a blank dark rectangle with no
                                        // explanation.
                                        errorTileCallback:
                                            (tile, error, stackTrace) {
                                              if (_tilesUnavailable) return;
                                              setState(
                                                () => _tilesUnavailable = true,
                                              );
                                            },
                                      ),
                                      // Admin-drawn danger zones — drawn right above
                                      // tiles so victim pins/rings always stay on top.
                                      PolygonLayer(
                                        polygons: [
                                          for (final z in _geofences)
                                            if (z['isactive'] != false &&
                                                z['shape'] == 'polygon')
                                              Polygon(
                                                points: _geofencePolygonPoints(
                                                  z,
                                                ),
                                                color: _geofenceColor(
                                                  z,
                                                ).withValues(alpha: 0.18),
                                                borderColor: _geofenceColor(
                                                  z,
                                                ).withValues(alpha: 0.8),
                                                borderStrokeWidth: 2,
                                              ),
                                        ],
                                      ),
                                      CircleLayer(
                                        circles: [
                                          for (final z in _geofences)
                                            if (z['isactive'] != false &&
                                                z['shape'] == 'circle' &&
                                                _geofenceCircleCenter(z) !=
                                                    null)
                                              CircleMarker(
                                                point: _geofenceCircleCenter(
                                                  z,
                                                )!,
                                                radius: _geofenceCircleRadius(
                                                  z,
                                                ),
                                                useRadiusInMeter: true,
                                                color: _geofenceColor(
                                                  z,
                                                ).withValues(alpha: 0.18),
                                                borderStrokeWidth: 2,
                                                borderColor: _geofenceColor(
                                                  z,
                                                ).withValues(alpha: 0.8),
                                              ),
                                        ],
                                      ),
                                      // Tappable hazard icon per zone (name/type/severity
                                      // on tap) — a real tap-hit-test on the polygon/circle
                                      // shape itself needs flutter_map's hitNotifier
                                      // plumbing; a small marker at the zone's centre
                                      // reuses the same Marker+GestureDetector pattern
                                      // already used for victim/self dots below, for a
                                      // fraction of the code.
                                      MarkerLayer(
                                        markers: [
                                          for (final z in _geofences)
                                            if (z['isactive'] != false &&
                                                _geofenceLabelPoint(z) != null)
                                              Marker(
                                                point: _geofenceLabelPoint(
                                                  z,
                                                )!,
                                                width: 26,
                                                height: 26,
                                                child: GestureDetector(
                                                  onTap: () => setState(() {
                                                    _selectedZone = z;
                                                    // Same one-card-at-a-time
                                                    // rule as self/victim.
                                                    _selectedPin = null;
                                                    _selfInfoOpen = false;
                                                  }),
                                                  child: Container(
                                                    decoration: BoxDecoration(
                                                      shape: BoxShape.circle,
                                                      color: _geofenceColor(z),
                                                      border: Border.all(
                                                        color: Colors.white,
                                                        width: 2,
                                                      ),
                                                      boxShadow: const [
                                                        BoxShadow(
                                                          color:
                                                              Colors.black38,
                                                          blurRadius: 3,
                                                        ),
                                                      ],
                                                    ),
                                                    child: const Icon(
                                                      Icons
                                                          .warning_amber_rounded,
                                                      color: Colors.white,
                                                      size: 15,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                        ],
                                      ),
                                      // Translucent "zoning" rings for pins without a
                                      // real GPS fix. Drawn first — before BOTH marker
                                      // layers below — so every dot (self included)
                                      // always paints on top of every ring, regardless
                                      // of whose ring it is; otherwise a ring that
                                      // happens to overlap a nearby dot visually buries
                                      // it. Not tappable (flutter_map's CircleLayer has
                                      // no hit-testing of its own), so it never blocks a
                                      // tap meant for a dot either.
                                      CircleLayer(
                                        circles: [
                                          // A ring under every pin now: a real
                                          // GPS pin's ring is the chip's ±
                                          // accuracy (so the circle's real-world
                                          // size IS the uncertainty), an
                                          // approximate pin's is the coarse
                                          // near-Helper zone. A solid border
                                          // reads as "measured", a dashed-looking
                                          // fainter one as "approximate".
                                          for (final pin in pins)
                                            CircleMarker(
                                              point: pin.point,
                                              radius: pin.ringRadiusMeters,
                                              useRadiusInMeter: true,
                                              color: _VictimMarker.colorForTier(
                                                pin.bundle.priorityTier,
                                              ).withValues(alpha: 0.15),
                                              borderStrokeWidth: 1,
                                              borderColor:
                                                  _VictimMarker.colorForTier(
                                                    pin.bundle.priorityTier,
                                                  ).withValues(
                                                    alpha: pin.isApproximate
                                                        ? 0.4
                                                        : 0.7,
                                                  ),
                                            ),
                                        ],
                                      ),
                                      if (_userLocation != null)
                                        MarkerLayer(
                                          markers: [
                                            Marker(
                                              point: _userLocation!,
                                              width: 22,
                                              height: 22,
                                              child: GestureDetector(
                                                onTap: () => setState(() {
                                                  _selfInfoOpen =
                                                      !_selfInfoOpen;
                                                  // Only one info card open at
                                                  // a time — opening this one
                                                  // dismisses any victim/zone
                                                  // card.
                                                  if (_selfInfoOpen) {
                                                    _selectedPin = null;
                                                    _selectedZone = null;
                                                  }
                                                }),
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
                                            ),
                                          ],
                                        ),
                                      MarkerLayer(
                                        markers: [
                                          for (final pin in pins)
                                            Marker(
                                              point: pin.point,
                                              // Wide enough for an "Victim-XXXX" label
                                              // below the dot without wrapping.
                                              width: 84,
                                              // Dot (22) + spacing (3) + label line
                                              // (~12), with a few px of slack.
                                              height: 44,
                                              // Anchors the dot's centre (not the label
                                              // beneath it) to the geo-point. flutter_map's
                                              // alignment.y measures from the point DOWN to
                                              // the box's bottom edge, not from the box's top
                                              // — positive y pulls the box up so the point
                                              // lands inside it. With height 44 and a 22px
                                              // dot at the top, the dot's centre sits at
                                              // Alignment(0, 0.5).
                                              alignment: const Alignment(
                                                0,
                                                0.5,
                                              ),
                                              child: GestureDetector(
                                                onTap: () => setState(() {
                                                  _selectedPin = pin;
                                                  // Only one info card open at
                                                  // a time — opening this one
                                                  // dismisses the self/zone
                                                  // card.
                                                  _selfInfoOpen = false;
                                                  _selectedZone = null;
                                                }),
                                                // Selecting a pin focuses it — every
                                                // other victim dot fades back a bit so
                                                // the selected one (and its popup) reads
                                                // clearly against the rest of the mesh.
                                                // The self/blue dot is unaffected, it
                                                // lives in its own MarkerLayer above.
                                                // Compared by bundleId, not identity —
                                                // _victimPins mints a fresh
                                                // _PinPlacement every build, so the
                                                // stored _selectedPin is never the same
                                                // instance as this build's pin even when
                                                // it's the same victim.
                                                child: AnimatedOpacity(
                                                  duration: const Duration(
                                                    milliseconds: 150,
                                                  ),
                                                  opacity:
                                                      _selectedPin == null ||
                                                          _selectedPin!
                                                                  .bundle
                                                                  .bundleId ==
                                                              pin
                                                                  .bundle
                                                                  .bundleId
                                                      ? 1.0
                                                      : 0.35,
                                                  child: _VictimMarker(
                                                    bundle: pin.bundle,
                                                    isApproximate:
                                                        pin.isApproximate,
                                                  ),
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
                                  if (_userLocation != null)
                                    Positioned(
                                      top: 8,
                                      right: 8,
                                      child: GestureDetector(
                                        // Matches the zoom the map recenters to
                                        // on GPS fix (_recenterZoom), i.e. the
                                        // view the user is actually looking at
                                        // after the page settles — not the
                                        // far-out pre-fix defaultMapZoom.
                                        onTap: () => _mapController.move(
                                          _userLocation!,
                                          _recenterZoom,
                                        ),
                                        child: Container(
                                          padding: const EdgeInsets.all(8),
                                          decoration: const BoxDecoration(
                                            color: Colors.black54,
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(
                                            Icons.my_location,
                                            color: Colors.white,
                                            size: 18,
                                          ),
                                        ),
                                      ),
                                    ),
                                  // Stacked in one column (not two independently
                                  // positioned corners) — two badges anchored to
                                  // opposite corners visually collided once the
                                  // "no map" text (long) and "Locating…" (short) were
                                  // both showing at once on a narrow map width.
                                  if (_userLocation == null ||
                                      _tilesUnavailable)
                                    Positioned(
                                      bottom: 8,
                                      left: 8,
                                      right: 8,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          // GPS blocked by the user (denied permission
                                          // or location service off) is shown as an
                                          // actionable badge instead of the "Locating…"
                                          // spinner — the spinner implied "just wait",
                                          // but waiting never resolves a denial; this
                                          // tells them what's wrong and opens the right
                                          // settings page to fix it.
                                          if (_gpsBlockReason != null)
                                            _MapStatusBadge(
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  const Icon(
                                                    Icons.location_off,
                                                    color: Colors.amber,
                                                    size: 14,
                                                  ),
                                                  const SizedBox(width: 6),
                                                  Flexible(
                                                    child: Text(
                                                      _gpsBlockReason!,
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 12,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 4),
                                                  GestureDetector(
                                                    onTap: () =>
                                                        _gpsBlockIsPermission
                                                        ? Geolocator.openAppSettings()
                                                        : Geolocator.openLocationSettings(),
                                                    child: const Text(
                                                      'Settings',
                                                      style: TextStyle(
                                                        color:
                                                            Colors.amberAccent,
                                                        fontSize: 12,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            )
                                          else if (_userLocation == null)
                                            _MapStatusBadge(
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  const SizedBox(
                                                    width: 10,
                                                    height: 10,
                                                    child:
                                                        CircularProgressIndicator(
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
                                  if (selectedLivePin != null)
                                    _buildBundlePopup(selectedLivePin, mapSize),
                                  if (_selfInfoOpen) _buildSelfPopup(mapSize),
                                  if (_selectedZone != null)
                                    _buildZonePopup(_selectedZone!, mapSize),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 16),
              const RadioStatusBanner(),
              Expanded(
                child: ValueListenableBuilder<bool>(
                  valueListenable: detailedLogging,
                  builder: (_, detailed, x) => MeshActivityCard(
                    key: _kMeshCard,
                    lines: detailed ? _rawLog : _displayLog,
                    fontSize: 12,
                  ),
                ),
              ),
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
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(meters % 1000 == 0 ? 0 : 1)}km';
    }
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

/// A victim pin is the same solid dot regardless of GPS confidence — a name
/// doesn't fit inside a 22px circle, so it's printed below instead. Whether
/// the bundle has a real GPS fix or not is shown separately, via the
/// translucent zoning ring drawn by the CircleLayer behind this marker (see
/// the victim MarkerLayer's parent Stack child order).
class _VictimMarker extends StatelessWidget {
  const _VictimMarker({required this.bundle, required this.isApproximate});

  final DistressBundleModel bundle;
  final bool isApproximate;

  static Color colorForTier(String tier) {
    switch (tier) {
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

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colorForTier(bundle.priorityTier),
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 4)],
          ),
        ),
        const SizedBox(height: 3),
        Text(
          'Victim-${deviceNameSuffix(bundle.deviceId)}',
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
            fontSize: 10,
            // White halo instead of a solid background pill — keeps the
            // black text readable over dark tiles without boxing the name.
            shadows: [
              Shadow(color: Colors.white, blurRadius: 3),
              Shadow(color: Colors.white, blurRadius: 3),
            ],
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
