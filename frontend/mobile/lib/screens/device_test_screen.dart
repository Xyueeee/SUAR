import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

import '../communication/wifi_direct_manager.dart';
import '../theme.dart' show kPanelDark;
import '../map/map_constants.dart';
import '../permissions.dart';
import '../sensing/device_sensor_probe.dart';
import '../sensing/sensor_live.dart';
import '../sensing/sensor_types.dart';

/// 4.1.6 SUAR Device Test (Figma node 13:649). A sensor self-test: on open it
/// runs every sensor once and shows a pass/fail status; tapping a row expands
/// it and streams a live, interpreted reading (collapsed rows hold no
/// subscription, so they cost nothing). Modernised from the static Figma mock.
class DeviceTestScreen extends StatefulWidget {
  const DeviceTestScreen({super.key});

  @override
  State<DeviceTestScreen> createState() => _DeviceTestScreenState();
}

/// ok = works · needsAction = actionable by the user (grant mic, turn a radio
/// on) · absent = hardware genuinely missing · restricted = hardware exists but
/// the OS only exposes a system-protected variant apps can't read (e.g.
/// Samsung's "Palm" proximity sensor).
enum _Status { checking, ok, needsAction, absent, restricted }

// Uniform list-item metrics so the page reads as one consistent list.
const double _titleSize = 16;
const double _descSize = 11.5; // small gray sensor description
const double _valueSize = 14;

class _DeviceTestScreenState extends State<DeviceTestScreen> {
  final DeviceSensorProbe _probe = DeviceSensorProbe();

  final Map<DeviceSensor, _Status> _status = {
    for (final s in DeviceSensor.values) s: _Status.checking,
  };
  final Set<DeviceSensor> _expanded = {};
  final Map<DeviceSensor, StreamSubscription<String>> _subs = {};
  final Map<DeviceSensor, String> _live = {};
  ProximityInfo _proximity = ProximityInfo.unknown;
  bool _proximityRestricted = false;

  static const Color _okGreen = Color(0xFF3FB836);
  static const Color _actionAmber = Color(0xFFE0A500);
  static const Color _absentRed = Color(0xFFD64545);

  @override
  void initState() {
    super.initState();
    _runInitialTest();
  }

  @override
  void dispose() {
    for (final sub in _subs.values) {
      sub.cancel();
    }
    super.dispose();
  }

  Future<void> _runInitialTest() async {
    final info = await _probe.getSensorInfo('proximity');
    final maxRange = (info['maxRange'] as num?)?.toDouble() ?? 5.0;
    final resolution = (info['resolution'] as num?)?.toDouble() ?? maxRange;
    final proxName = (info['name'] as String?)?.toLowerCase() ?? '';
    // Samsung (and some other OEMs) only expose a "palm"/gesture proximity
    // sensor to apps — the real physical one is wired solely to the system
    // screen-off wake lock, so apps can't read near/far. Detect by name.
    _proximityRestricted =
        proxName.contains('palm') || proxName.contains('gesture');
    _proximity = ProximityInfo(
      maxRange: maxRange,
      continuous: maxRange > 5.0 && resolution > 0 && resolution < maxRange,
    );

    final results = <DeviceSensor, _Status>{};
    for (final s in DeviceSensor.values) {
      if (s.source == SensorSource.sensorsPlus ||
          s.source == SensorSource.nativePoll) {
        final v = await _probe.readOnce(s.nativeKey!, timeoutMs: 800);
        results[s] = v != null ? _Status.ok : _Status.absent;
      }
    }
    if (_proximityRestricted) {
      results[DeviceSensor.proximity] = _Status.restricted;
    }
    results[DeviceSensor.microphone] = await Permission.microphone.isGranted
        ? _Status.ok
        : _Status.needsAction;
    results[DeviceSensor.gps] = await Geolocator.isLocationServiceEnabled()
        ? _Status.ok
        : _Status.needsAction;
    results[DeviceSensor.wifi] =
        await _probe.isWifiEnabled() ? _Status.ok : _Status.needsAction;
    results[DeviceSensor.bluetooth] =
        await _isBluetoothOn() ? _Status.ok : _Status.needsAction;

    if (!mounted) return;
    setState(() => _status.addAll(results));
  }

  Future<bool> _isBluetoothOn() async {
    try {
      final state = await FlutterBluePlus.adapterState.first
          .timeout(const Duration(seconds: 2));
      return state == BluetoothAdapterState.on;
    } catch (_) {
      return false;
    }
  }

  Future<void> _toggle(DeviceSensor sensor) async {
    if (_expanded.contains(sensor)) {
      await _subs.remove(sensor)?.cancel();
      setState(() {
        _expanded.remove(sensor);
        _live.remove(sensor);
      });
      return;
    }

    if (sensor == DeviceSensor.microphone && _status[sensor] != _Status.ok) {
      final granted = await requestMicPermission();
      if (!mounted) return;
      setState(() =>
          _status[sensor] = granted ? _Status.ok : _Status.needsAction);
      if (!granted) return;
    }

    setState(() => _expanded.add(sensor));

    // GPS renders its own live map widget (see _GpsExpanded) — no string stream.
    if (sensor == DeviceSensor.gps) return;

    // Restricted proximity (e.g. Samsung Palm) — nothing readable to stream;
    // the expanded row explains why.
    if (sensor == DeviceSensor.proximity && _proximityRestricted) return;

    if (sensor.source == SensorSource.connectivity) {
      await _refreshConnectivity(sensor);
      return;
    }

    final sub = liveSensorLabel(sensor, _probe, proximity: _proximity).listen(
      (label) {
        if (!mounted) return;
        setState(() => _live[sensor] = label);
      },
      onError: (_) {},
    );
    _subs[sensor] = sub;
  }

  Future<void> _refreshConnectivity(DeviceSensor sensor) async {
    bool on;
    String detail;
    switch (sensor) {
      case DeviceSensor.wifi:
        on = await _probe.isWifiEnabled();
        if (!on) {
          detail = 'Off. Turn on Wi-Fi.';
        } else {
          final staInfo = await WiFiDirectManager.getStaInfo();
          final associated = staInfo?['associated'] as bool? ?? false;
          final ssid = (staInfo?['ssid'] as String?)?.trim();
          if (associated && ssid != null && ssid.isNotEmpty &&
              !ssid.toLowerCase().contains('unknown')) {
            detail = 'Connected: $ssid';
          } else if (associated) {
            detail = 'Connected';
          } else {
            detail = 'On, not connected to a network.';
          }
        }
        break;
      case DeviceSensor.bluetooth:
        on = await _isBluetoothOn();
        if (!on) {
          detail = 'Off. Turn on Bluetooth.';
        } else {
          // Reading connected devices needs BLUETOOTH_CONNECT on API 31+.
          if (!await Permission.bluetoothConnect.isGranted) {
            await Permission.bluetoothConnect.request();
          }
          final n = await _probe.bluetoothConnectedCount();
          detail = n > 0
              ? 'On · $n device${n == 1 ? '' : 's'} connected'
              : 'On · no devices connected';
        }
        break;
      default:
        on = false;
        detail = '';
    }
    if (!mounted) return;
    setState(() {
      _status[sensor] = on ? _Status.ok : _Status.needsAction;
      _live[sensor] = detail;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(7, 8, 21, 4),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.chevron_left, color: cs.onSurface),
                  ),
                  Text(
                    'Device Test',
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 23),
              child: Text(
                "Test your device's sensors to know if it's reliable for an "
                'emergency.',
                style: TextStyle(color: cs.onSurface, fontSize: 15),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(21, 0, 21, 24),
                children: [
                  for (final category in SensorCategory.values) ...[
                    _SensorCard(
                      category: category,
                      sensors: DeviceSensor.values
                          .where((s) => s.category == category)
                          .toList(),
                      statusOf: (s) => _status[s]!,
                      isExpanded: _expanded.contains,
                      liveOf: (s) => _live[s],
                      onTap: _toggle,
                      iconBuilder: _statusIcon,
                    ),
                    const SizedBox(height: 16),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusIcon(_Status status) {
    switch (status) {
      case _Status.checking:
        return const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case _Status.ok:
        return const Icon(Icons.check_circle, color: _okGreen, size: 22);
      case _Status.needsAction:
        return const Icon(Icons.error_outline, color: _actionAmber, size: 22);
      case _Status.restricted:
        return const Icon(Icons.cancel, color: _actionAmber, size: 22);
      case _Status.absent:
        return const Icon(Icons.cancel, color: _absentRed, size: 22);
    }
  }
}

class _SensorCard extends StatelessWidget {
  const _SensorCard({
    required this.category,
    required this.sensors,
    required this.statusOf,
    required this.isExpanded,
    required this.liveOf,
    required this.onTap,
    required this.iconBuilder,
  });

  final SensorCategory category;
  final List<DeviceSensor> sensors;
  final _Status Function(DeviceSensor) statusOf;
  final bool Function(DeviceSensor) isExpanded;
  final String? Function(DeviceSensor) liveOf;
  final void Function(DeviceSensor) onTap;
  final Widget Function(_Status) iconBuilder;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border.all(color: cs.onSurface.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            category.title,
            style: TextStyle(
              color: cs.onSurface,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            category.description,
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.6),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? kPanelDark
                  : cs.onSurface.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Column(
              children: [
                for (int i = 0; i < sensors.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 1,
                      indent: 14,
                      endIndent: 14,
                      color: cs.onSurface.withValues(alpha: 0.10),
                    ),
                  _SensorRow(
                    sensor: sensors[i],
                    status: statusOf(sensors[i]),
                    expanded: isExpanded(sensors[i]),
                    live: liveOf(sensors[i]),
                    onTap: () => onTap(sensors[i]),
                    iconBuilder: iconBuilder,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SensorRow extends StatelessWidget {
  const _SensorRow({
    required this.sensor,
    required this.status,
    required this.expanded,
    required this.live,
    required this.onTap,
    required this.iconBuilder,
  });

  final DeviceSensor sensor;
  final _Status status;
  final bool expanded;
  final String? live;
  final VoidCallback onTap;
  final Widget Function(_Status) iconBuilder;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(15),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sensor.label,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: _titleSize,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    sensor.description,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                      fontSize: _descSize,
                    ),
                  ),
                  if (expanded) _buildExpanded(context),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 2),
              child: iconBuilder(status),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpanded(BuildContext context) {
    if (sensor == DeviceSensor.gps) {
      return const Padding(
        padding: EdgeInsets.only(top: 10),
        child: _GpsExpanded(),
      );
    }
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        _expandedDetail(),
        style: TextStyle(
          color: cs.onSurface.withValues(alpha: 0.87),
          fontSize: _valueSize,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  String _expandedDetail() {
    if (sensor == DeviceSensor.microphone && status == _Status.needsAction) {
      return 'Tap to grant microphone access.';
    }
    if (status == _Status.restricted) {
      return 'Not readable by apps on this device. The system reserves this '
          'sensor to turn the screen off during calls, so it cannot be tested '
          'here.';
    }
    if (status == _Status.absent) {
      return 'Not available on this device.';
    }
    return live ?? 'Reading…';
  }
}

/// Live GPS readout: requests location, streams a fix, and shows the
/// coordinates over a compact OSM map (same offline tile store the rest of the
/// app uses). Self-contained so the screen's row logic stays simple.
class _GpsExpanded extends StatefulWidget {
  const _GpsExpanded();

  @override
  State<_GpsExpanded> createState() => _GpsExpandedState();
}

class _GpsExpandedState extends State<_GpsExpanded> {
  final MapController _map = MapController();
  StreamSubscription<Position>? _sub;
  Position? _pos;
  String? _blocked;
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        if (mounted) setState(() => _blocked = 'Location permission denied.');
        return;
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) setState(() => _blocked = 'Location services are off.');
        return;
      }
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) _apply(last);
      _sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen(_apply, onError: (_) {});
    } catch (e) {
      if (mounted) setState(() => _blocked = 'GPS unavailable.');
    }
  }

  void _apply(Position p) {
    if (!mounted) return;
    setState(() => _pos = p);
    if (_mapReady) {
      _map.move(LatLng(p.latitude, p.longitude), 16);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_blocked != null) {
      return Text(
        _blocked!,
        style: TextStyle(
            color: cs.onSurface.withValues(alpha: 0.87),
            fontSize: _valueSize,
            fontWeight: FontWeight.w600),
      );
    }
    final p = _pos;
    final center =
        p != null ? LatLng(p.latitude, p.longitude) : defaultMapCenter;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          p == null
              ? 'Acquiring fix…'
              : '${p.latitude.toStringAsFixed(5)}, '
                  '${p.longitude.toStringAsFixed(5)}  ·  ±${p.accuracy.round()} m',
          style: TextStyle(
            color: cs.onSurface.withValues(alpha: 0.87),
            fontSize: _valueSize,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: 150,
            child: FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: center,
                initialZoom: 16,
                onMapReady: () {
                  _mapReady = true;
                  if (_pos != null) {
                    _map.move(LatLng(_pos!.latitude, _pos!.longitude), 16);
                  }
                },
                interactionOptions:
                    const InteractionOptions(flags: InteractiveFlag.none),
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
                if (p != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: center,
                        width: 36,
                        height: 36,
                        child: const Icon(Icons.location_on,
                            color: Color(0xFFD64545), size: 36),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
