import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';

import '../communication/wifi_direct_manager.dart';

/// Shown inside Victim/Helper mode while Bluetooth or Location is switched
/// off, granting the permission earlier doesn't mean the radio is actually
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
  // Tri-state: null until the OS broadcast confirming this has arrived,
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
  // NOT associated to a regular network. While connected to an access
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

  // Short, one-line summaries, what the persistent notification and the
  // collapsed banner row both show. Kept deliberately tiny so they never wrap
  // awkwardly on a small screen; the full explanation lives behind a popup,
  // not an inline expansion, so the rest of the screen (the activity log
  // underneath) never gets pushed out of view on a small phone.
  String? get _problemText {
    if (_bluetoothOff) return 'Bluetooth is off';
    if (_locationOff) return 'Location is off';
    if (_wifiOff) return 'Wi-Fi is off';
    if (_wifiAssociatedSsid != null) {
      return 'Connected to Wi-Fi, performance may be impacted';
    }
    if (_p2pUnsupported == true) return 'Wi-Fi Direct unavailable';
    return null;
  }

  // The longer plain-language explanation, shown only in the details popup
  // (banner) or the expanded notification. Separated from the summary so the
  // collapsed view stays one short line.
  String? get _detailText {
    if (_bluetoothOff) {
      return 'Bluetooth is off. Turn it on so nearby phones '
          'can find each other.';
    }
    if (_locationOff) {
      return 'Location is off. Android needs it on for nearby '
          'sharing to work. Your location is not shared with anyone.';
    }
    if (_wifiOff) {
      return 'Wi-Fi is off. Turn it on (you do not need to join a '
          'network) so nearby sharing can work.';
    }
    if (_wifiAssociatedSsid != null) {
      return 'This phone is joined to the Wi-Fi network '
          '"$_wifiAssociatedSsid". Keep Wi-Fi switched on, but leave that '
          'network. Staying joined can slow down or block sharing with '
          'nearby phones.';
    }
    if (_p2pUnsupported == true) {
      return 'This phone reports nearby sharing as unavailable. Try turning '
          'Wi-Fi off and on again.';
    }
    return null;
  }

  // Whether the current problem has a "go to Wi-Fi settings" fix, drives the
  // notification action button (see updateMeshStatus).
  bool get _wifiActionable =>
      _wifiOff || _wifiAssociatedSsid != null || _p2pUnsupported == true;

  // Runs after every state check so the persistent foreground notification
  // (visible even with the app backgrounded / screen off, unlike the in-app
  // amber banner which only helps if someone's looking at THIS device's
  // screen) always reflects current radio health. The on-screen warning
  // itself stays the existing inline amber banner rendered in build(), no
  // pop-up SnackBar, which looked out of place.
  void _afterStateChange() {
    final problem = _problemText;
    unawaited(
      WiFiDirectManager.updateMeshStatus(
        problem ?? 'Mesh radio active...',
        detail: _detailText,
        // Only attach the "Wi-Fi settings" action when that's actually the
        // fix, a plain "Mesh radio active" notification gets no button.
        wifiAction: problem != null && _wifiActionable,
      ),
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
              summary: 'Bluetooth is off',
              details:
                  'Bluetooth is off. Turn it on so nearby phones can find '
                  'each other.',
              actionLabel: 'Turn on',
              onAction: () => FlutterBluePlus.turnOn(),
            ),
          if (_locationOff)
            _WarningRow(
              summary: 'Location is off',
              details:
                  'Location is off. Android needs it on for nearby sharing. '
                  'Your location is not shared with anyone.',
              actionLabel: 'Settings',
              onAction: () => Geolocator.openLocationSettings(),
            ),
          if (_wifiOff)
            _WarningRow(
              summary: 'Wi-Fi is off',
              details:
                  'Wi-Fi is off. Turn it on (you do not need to join a '
                  'network) so nearby sharing can work.',
              actionLabel: 'Wi-Fi settings',
              onAction: () => WiFiDirectManager.openWifiSettings(),
            ),
          if (_wifiAssociatedSsid != null)
            _WarningRow(
              summary: 'Connected to Wi-Fi, performance may be impacted',
              details:
                  'This phone is joined to the Wi-Fi network '
                  '"$_wifiAssociatedSsid". Keep Wi-Fi switched on, but leave '
                  'that network. Staying joined can slow down or block '
                  'sharing with nearby phones.',
              actionLabel: 'Wi-Fi settings',
              onAction: () => WiFiDirectManager.openWifiSettings(),
            ),
          if (_p2pUnsupported == true)
            _WarningRow(
              summary: 'Nearby sharing unavailable',
              details:
                  'This phone reports nearby sharing as unavailable. Try '
                  'turning Wi-Fi off and on again.',
              actionLabel: 'Wi-Fi settings',
              onAction: () => WiFiDirectManager.openWifiSettings(),
            ),
        ],
      ),
    );
  }
}

/// One compact, screen-size-safe warning row. Tapping it opens a small popup
/// dialog with the full explanation and the fix button, instead of expanding
/// inline. An inline expansion was tried first and still grew tall enough on
/// a small phone to push the activity log below it out of view, a popup
/// floats above the screen instead of resizing it, so the rest of the layout
/// never moves.
class _WarningRow extends StatelessWidget {
  const _WarningRow({
    required this.summary,
    required this.details,
    required this.actionLabel,
    required this.onAction,
  });

  final String summary;
  final String details;
  final String actionLabel;
  final VoidCallback onAction;

  void _openDetails(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Row(
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              color: Colors.amber,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                summary,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
          ],
        ),
        content: Text(
          details,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.85),
            fontSize: 13.5,
            height: 1.3,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              onAction();
            },
            child: Text(
              actionLabel,
              style: const TextStyle(color: Colors.amberAccent),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        onTap: () => _openDetails(context),
        borderRadius: BorderRadius.circular(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              color: Colors.amber,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                summary,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.info_outline, color: Colors.white70, size: 16),
          ],
        ),
      ),
    );
  }
}
