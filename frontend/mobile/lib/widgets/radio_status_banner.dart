import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';

import '../communication/wifi_direct_manager.dart';

/// Shown inside Victim/Helper mode while Bluetooth or Location is switched
/// off — granting the permission earlier doesn't mean the radio is actually
/// on, and silently advertising/scanning into a disabled radio (no beacon
/// ever goes out, no scan ever finds anything) looked identical to "nothing
/// is wrong" from the activity log alone.
class RadioStatusBanner extends StatefulWidget {
  const RadioStatusBanner({super.key});

  @override
  State<RadioStatusBanner> createState() => _RadioStatusBannerState();
}

class _RadioStatusBannerState extends State<RadioStatusBanner> {
  bool _bluetoothOff = false;
  bool _locationOff = false;
  bool _wifiOff = false;
  String? _wifiAssociatedSsid;
  // Tri-state: null until the OS broadcast confirming this has arrived —
  // deliberately not treated as "disabled" until we actually know, since a
  // false positive here would tell the user their hardware is broken when
  // it's just that nothing's reported in yet.
  bool? _p2pUnsupported;
  StreamSubscription<BluetoothAdapterState>? _btSub;
  Timer? _locationPoll;
  Timer? _wifiPoll;

  @override
  void initState() {
    super.initState();
    _btSub = FlutterBluePlus.adapterState.listen((state) {
      if (!mounted) return;
      setState(() => _bluetoothOff = state != BluetoothAdapterState.on);
      _afterStateChange();
    });
    _checkLocation();
    _locationPoll = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _checkLocation(),
    );
    _checkWifiAssociation();
    _wifiPoll = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _checkWifiAssociation(),
    );
  }

  Future<void> _checkLocation() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!mounted) return;
    setState(() => _locationOff = !enabled);
    _afterStateChange();
  }

  // Confirmed on real hardware: Wi-Fi Direct needs the Wi-Fi radio ON, but
  // NOT associated to a regular network — while connected to an access
  // point, peer discovery and group formation become unreliable (flaky on a
  // flagship chipset, broken outright on a budget one), since both share the
  // same radio and most chipsets can't run them together reliably.
  Future<void> _checkWifiAssociation() async {
    final info = await WiFiDirectManager.getStaInfo();
    if (!mounted) return;
    final enabled = info?['enabled'] as bool? ?? true;
    final associated = info?['associated'] as bool? ?? false;
    setState(() {
      _wifiOff = !enabled;
      _wifiAssociatedSsid = (enabled && associated)
          ? (info?['ssid'] as String?)
          : null;
      _p2pUnsupported = (info?['p2pEnabled'] as bool?) == false ? true : null;
    });
    _afterStateChange();
  }

  String? get _problemText {
    if (_bluetoothOff) return 'Bluetooth is off';
    if (_locationOff) return 'Location is off';
    if (_wifiOff) return 'Wi-Fi is off';
    if (_wifiAssociatedSsid != null) {
      return 'Wi-Fi connected to "$_wifiAssociatedSsid" — disconnect it';
    }
    if (_p2pUnsupported == true) return 'Wi-Fi Direct unavailable';
    return null;
  }

  // Runs after every state check so the persistent foreground notification
  // (visible even with the app backgrounded / screen off, unlike the in-app
  // amber banner which only helps if someone's looking at THIS device's
  // screen) always reflects current radio health. The on-screen warning
  // itself stays the existing inline amber banner rendered in build() — no
  // pop-up SnackBar, which looked out of place.
  void _afterStateChange() {
    final problem = _problemText;
    unawaited(
      WiFiDirectManager.updateMeshStatus(problem ?? 'Mesh radio active...'),
    );
  }

  @override
  void dispose() {
    _btSub?.cancel();
    _locationPoll?.cancel();
    _wifiPoll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_bluetoothOff &&
        !_locationOff &&
        !_wifiOff &&
        _wifiAssociatedSsid == null &&
        _p2pUnsupported != true) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.amber, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_bluetoothOff)
            _WarningRow(
              text: 'Bluetooth is off — turn it on to use this mode.',
              actionLabel: 'Turn on',
              onAction: () => FlutterBluePlus.turnOn(),
            ),
          if (_locationOff)
            _WarningRow(
              text:
                  'Location services are off — turn them on to use this mode.',
              actionLabel: 'Settings',
              onAction: () => Geolocator.openLocationSettings(),
            ),
          if (_wifiOff)
            _WarningRow(
              text: 'Wi-Fi is off — turn it on to use this mode.',
              actionLabel: 'Wi-Fi Settings',
              onAction: () => WiFiDirectManager.openWifiSettings(),
            ),
          if (_wifiAssociatedSsid != null)
            _WarningRow(
              text:
                  'Wi-Fi is connected to "$_wifiAssociatedSsid" — disconnect '
                  'from it (but leave Wi-Fi turned on) for reliable transfers.',
              actionLabel: 'Wi-Fi Settings',
              onAction: () => WiFiDirectManager.openWifiSettings(),
            ),
          if (_p2pUnsupported == true)
            _WarningRow(
              text:
                  'This phone reports Wi-Fi Direct as unavailable — nearby '
                  'transfers may not work. Try turning Wi-Fi off and on.',
              actionLabel: 'Wi-Fi Settings',
              onAction: () => WiFiDirectManager.openWifiSettings(),
            ),
        ],
      ),
    );
  }
}

class _WarningRow extends StatelessWidget {
  const _WarningRow({
    required this.text,
    required this.actionLabel,
    required this.onAction,
  });

  final String text;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: Colors.amber,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
            ),
            child: Text(
              actionLabel,
              style: const TextStyle(color: Colors.amberAccent, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
