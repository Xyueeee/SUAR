import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../map/map_constants.dart';
import '../sensing/location_estimator.dart';
import '../widgets/back_chevron.dart';
import '../widgets/validated_text_dialog.dart';

/// Settings > Debugging Options > Location — live view of the Increment 4
/// location path, plus a spoof control. Drives the SAME [LocationEstimator] a
/// Victim uses (not a parallel Geolocator call), so what shows here is exactly
/// what a bundle would carry and what the Helper map would draw. The spoof is
/// static + persisted, so a pin dropped here also makes a real Victim bundle
/// carry these coords — testing the whole map/ring/altitude path from one phone
/// without going outdoors for a GPS lock.
class LocationDebugScreen extends StatefulWidget {
  const LocationDebugScreen({super.key});

  @override
  State<LocationDebugScreen> createState() => _LocationDebugScreenState();
}

class _LocationDebugScreenState extends State<LocationDebugScreen> {
  final LocationEstimator _estimator = LocationEstimator();
  final MapController _map = MapController();
  Timer? _ticker;
  bool _started = false;
  bool _didCenter = false;
  String _permission = '…';
  String _service = '…';

  // Mirror the Helper map's accuracy-ring clamp so the circle here matches what
  // a coordinator would actually see.
  static const double _minRing = 8;
  static const double _maxRing = 500;

  @override
  void initState() {
    super.initState();
    _begin();
    // Poll the estimator's cached fix once a second — the same sync read
    // (lastFix) the VictimController does each triage cycle.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final fix = _estimator.lastFix;
      if (fix != null && !_didCenter) {
        try {
          _map.move(LatLng(fix.latitude, fix.longitude), 16);
          _didCenter = true;
        } catch (_) {
          // Map not laid out yet — try again next tick.
        }
      }
      setState(() {});
    });
  }

  Future<void> _begin() async {
    final started = await _estimator.start();
    final perm = await Geolocator.checkPermission();
    final service = await Geolocator.isLocationServiceEnabled();
    if (!mounted) return;
    setState(() {
      _started = started;
      _permission = perm.name;
      _service = service ? 'On' : 'Off';
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _estimator.dispose();
    _map.dispose();
    super.dispose();
  }

  // --- Spoof actions ----------------------------------------------------

  Future<void> _dropSpoofAt(LatLng p) async {
    final cur = LocationEstimator.spoof;
    await LocationEstimator.setSpoof(
      latitude: p.latitude,
      longitude: p.longitude,
      accuracyMeters: cur?.accuracyMeters ?? 20,
      altitude: cur?.altitude,
    );
    if (mounted) setState(() {});
  }

  Future<void> _toggleSpoof(bool on) async {
    if (on) {
      final seed = _estimator.lastFix;
      final p = seed != null
          ? LatLng(seed.latitude, seed.longitude)
          : _mapCenterOrDefault();
      await LocationEstimator.setSpoof(
        latitude: p.latitude,
        longitude: p.longitude,
        accuracyMeters: 20,
      );
    } else {
      await LocationEstimator.clearSpoof();
      // Resume real GPS now that the override is gone.
      await _begin();
    }
    if (mounted) setState(() {});
  }

  /// Recenter on the current fix — the spoof point when spoofing, else GPS.
  void _recenterMap() {
    final f = _estimator.lastFix;
    if (f == null) return;
    try {
      _map.move(LatLng(f.latitude, f.longitude), 16);
    } catch (_) {
      // Map not laid out yet — nothing to recenter onto.
    }
  }

  LatLng _mapCenterOrDefault() {
    try {
      return _map.camera.center;
    } catch (_) {
      return defaultMapCenter;
    }
  }

  Future<void> _editSpoofAccuracy() async {
    final cur = LocationEstimator.spoof;
    if (cur == null) return;
    final s = await showValidatedTextDialog(
      context: context,
      title: 'Spoof accuracy (± m)',
      confirmLabel: 'Set',
      initialValue: cur.accuracyMeters.toStringAsFixed(0),
      hintText: 'e.g. 20',
      validate: (v) async =>
          (double.tryParse(v) ?? -1) > 0 ? null : 'Enter a positive number',
    );
    if (s == null) return;
    await LocationEstimator.setSpoof(
      latitude: cur.latitude,
      longitude: cur.longitude,
      accuracyMeters: double.parse(s),
      altitude: cur.altitude,
    );
    if (mounted) setState(() {});
  }

  Future<void> _editSpoofAltitude() async {
    final cur = LocationEstimator.spoof;
    if (cur == null) return;
    final s = await showValidatedTextDialog(
      context: context,
      title: 'Spoof altitude (m)',
      confirmLabel: 'Set',
      initialValue: cur.altitude?.toStringAsFixed(0) ?? '',
      hintText: 'blank = unknown',
      allowEmpty: true,
      validate: (v) async =>
          v.isEmpty || double.tryParse(v) != null ? null : 'Enter a number',
    );
    if (s == null) return;
    await LocationEstimator.setSpoof(
      latitude: cur.latitude,
      longitude: cur.longitude,
      accuracyMeters: cur.accuracyMeters,
      altitude: s.isEmpty ? null : double.parse(s),
    );
    if (mounted) setState(() {});
  }

  // --- Build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fix = _estimator.lastFix;
    final hasFix = fix != null;
    final spoofing = LocationEstimator.isSpoofing;
    final accuracy = (fix != null && !fix.accuracyMeters.isNaN)
        ? '±${fix.accuracyMeters.round()} m'
        : 'unknown';
    final altitude = (fix?.altitude != null)
        ? '~${fix!.altitude!.round()} m'
        : 'unknown';
    final age = fix == null
        ? '—'
        : '${DateTime.now().difference(fix.at).inSeconds}s ago';

    return Scaffold(
      appBar: AppBar(
        leading: const BackChevron(),
        title: const Text('Location'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              height: 220,
              child: Stack(
                children: [
                  FlutterMap(
                    mapController: _map,
                    options: MapOptions(
                      initialCenter: hasFix
                          ? LatLng(fix.latitude, fix.longitude)
                          : defaultMapCenter,
                      initialZoom: 16,
                      minZoom: minMapZoom,
                      maxZoom: maxMapZoom,
                      // Tap to drop / move the spoof pin (auto-enables spoofing).
                      onTap: (_, latlng) => _dropSpoofAt(latlng),
                      interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                      ),
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: osmTileUrlTemplate,
                        userAgentPackageName: osmUserAgentPackageName,
                        tileProvider: FMTCTileProvider.allStores(
                          allStoresStrategy: BrowseStoreStrategy.read,
                          loadingStrategy: BrowseLoadingStrategy.cacheFirst,
                        ),
                      ),
                      if (hasFix) ...[
                        CircleLayer(
                          circles: [
                            CircleMarker(
                              point: LatLng(fix.latitude, fix.longitude),
                              radius: fix.accuracyMeters.isNaN
                                  ? _minRing
                                  : fix.accuracyMeters.clamp(
                                      _minRing,
                                      _maxRing,
                                    ),
                              useRadiusInMeter: true,
                              color:
                                  (spoofing ? const Color(0xFFA7C7E7) : Colors.blue)
                                      .withValues(alpha: 0.15),
                              borderStrokeWidth: 1,
                              borderColor:
                                  (spoofing ? const Color(0xFFA7C7E7) : Colors.blue)
                                      .withValues(alpha: 0.7),
                            ),
                          ],
                        ),
                        MarkerLayer(
                          markers: [
                            Marker(
                              point: LatLng(fix.latitude, fix.longitude),
                              width: 22,
                              height: 22,
                              child: Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: spoofing
                                      ? const Color(0xFFA7C7E7)
                                      : Colors.blue,
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
                      ],
                    ],
                  ),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: GestureDetector(
                      onTap: _recenterMap,
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
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Tap the map to drop / move a spoof pin.',
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.45), fontSize: 12),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Spoof location (testing)',
              style: TextStyle(color: cs.onSurface, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              'Override real GPS everywhere, including Victim bundles',
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.54)),
            ),
            value: spoofing,
            onChanged: _toggleSpoof,
          ),
          if (spoofing) ...[
            _editRow(
              context,
              'Spoof accuracy',
              '±${LocationEstimator.spoof!.accuracyMeters.round()} m',
              _editSpoofAccuracy,
            ),
            _editRow(
              context,
              'Spoof altitude',
              LocationEstimator.spoof!.altitude != null
                  ? '${LocationEstimator.spoof!.altitude!.round()} m'
                  : 'unknown',
              _editSpoofAltitude,
            ),
          ],
          Divider(height: 28, color: cs.onSurface.withValues(alpha: 0.12)),
          _section(context, 'Estimator'),
          _row(context, 'start() result', _started ? 'tracking' : 'unavailable'),
          _row(context, 'Permission', _permission),
          _row(context, 'Location service', _service),
          const SizedBox(height: 16),
          _section(context, 'Latest fix'),
          _row(context, 'Source', hasFix ? fix.source : '—'),
          _row(context, 'Latitude',
              hasFix ? fix.latitude.toStringAsFixed(6) : 'acquiring…'),
          _row(context, 'Longitude',
              hasFix ? fix.longitude.toStringAsFixed(6) : 'acquiring…'),
          _row(context, 'Accuracy', accuracy),
          _row(context, 'Altitude', altitude),
          _row(context, 'Fix age', age),
          const SizedBox(height: 16),
          _section(context, 'Bundle would carry'),
          _row(context, 'estimatedLat',
              hasFix ? fix.latitude.toStringAsFixed(6) : 'null'),
          _row(context, 'estimatedLng',
              hasFix ? fix.longitude.toStringAsFixed(6) : 'null'),
          _row(context, 'accuracyMeters',
              (hasFix && !fix.accuracyMeters.isNaN)
                  ? fix.accuracyMeters.toStringAsFixed(1)
                  : 'null'),
          _row(context, 'estimatedAltitude',
              fix?.altitude != null
                  ? fix!.altitude!.toStringAsFixed(1)
                  : 'null'),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'Helper map draws the ring at accuracyMeters, clamped 8–500 m. '
              'A null fix shows as an approximate pin near the Helper instead. '
              'GPS altitude is coarse (±10-30 m). A floor hint, not a count.',
              style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.45), fontSize: 12),
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: Geolocator.openLocationSettings,
            icon: Icon(Icons.gps_fixed, color: cs.onSurface),
            label: Text('Open location settings',
                style: TextStyle(color: cs.onSurface)),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: Geolocator.openAppSettings,
            icon: Icon(Icons.settings_outlined, color: cs.onSurface),
            label: Text('Open app permissions',
                style: TextStyle(color: cs.onSurface)),
          ),
        ],
      ),
    );
  }

  Widget _section(BuildContext context, String label) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: cs.onSurface.withValues(alpha: 0.54),
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label,
                style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.54), fontSize: 14)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _editRow(
      BuildContext context, String label, String value, VoidCallback onEdit) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 130,
              child: Text(label,
                  style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.54),
                      fontSize: 14)),
            ),
            Expanded(
              child: Text(value,
                  style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
            ),
            Icon(Icons.edit_outlined,
                size: 16,
                color: cs.onSurface.withValues(alpha: 0.38)),
          ],
        ),
      ),
    );
  }
}
