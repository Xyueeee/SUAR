import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Requests the BLE/Wi-Fi Direct permissions needed before entering Victim
/// or Helper mode, branching on the API 31/33 split (CLAUDE.md Section 5).
///
/// Never throws. permission_handler's native side tracks a single in-flight
/// request as a static/global lock with no public reset API — if a previous
/// request was abandoned (Activity recreated mid-dialog, app backgrounded
/// during the OS permission prompt, user cancelling out of the sequence),
/// that lock can outlive the Dart call that started it. Every later attempt
/// then throws PlatformException("already running") immediately — a known,
/// long-standing upstream issue (Baseflow/flutter-permission-handler #245,
/// #316, #950, #1222). Confirmed on real hardware (Samsung): this propagated
/// unhandled out of the caller, which never got to reset its "busy" flag —
/// the mode-selection screen froze permanently, every mode card disabled,
/// from a single denied/cancelled permission prompt.
Future<bool> requestMeshPermissions() async {
  int sdkInt = 0;
  try {
    sdkInt = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
  } catch (_) {
    // Not running on Android — nothing to request.
  }

  final permissions = <Permission>{};
  if (sdkInt >= 31) {
    permissions.addAll([
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
    ]);
  } else {
    permissions.add(Permission.locationWhenInUse);
  }

  if (sdkInt >= 33) {
    permissions.add(Permission.nearbyWifiDevices);
  } else {
    permissions.add(Permission.locationWhenInUse);
  }

  try {
    final statuses = await permissions.toList().request();
    if (statuses.values.every((s) => s.isGranted)) return true;
  } on PlatformException catch (e) {
    // See this function's doc — a stuck native lock from a previous,
    // abandoned request. Fall through to the status recheck below: if an
    // earlier attempt actually did get granted before things got stuck, this
    // still reports success instead of forcing the user through a now-
    // pointless extra prompt; otherwise it correctly reports "not granted"
    // so the caller can show a retry-friendly message instead of crashing.
    assert(() {
      // ignore: avoid_print
      print('[permissions] request() threw, falling back to status check: $e');
      return true;
    }());
  }

  // Android sometimes reports a stale denial in the .request() result right
  // after a multi-permission dialog sequence closes; re-query actual status
  // once before treating it as a real denial. Also the fallback path for the
  // PlatformException above.
  final recheck = await Future.wait(permissions.map((p) => p.status));
  return recheck.every((s) => s.isGranted);
}

/// Returns true if any of the mesh permissions are permanently denied —
/// meaning the OS will never show a dialog on retry, so the app must direct
/// the user to App Settings instead.
Future<bool> meshPermsPermanentlyDenied() async {
  final statuses = await Future.wait([
    Permission.bluetoothScan.status,
    Permission.bluetoothAdvertise.status,
    Permission.bluetoothConnect.status,
    Permission.nearbyWifiDevices.status,
    Permission.locationWhenInUse.status,
  ]);
  return statuses.any((s) => s.isPermanentlyDenied);
}

/// Per-permission grant status for onboarding's display rows. Branches on the
/// same API 31/33 splits as [requestMeshPermissions]: a permission that isn't
/// applicable on this device's Android version reads as granted (there is
/// nothing to grant) instead of a misleading "not granted".
Future<({bool bluetooth, bool nearbyWifi, bool location})>
    meshPermissionStatuses() async {
  int sdkInt = 0;
  try {
    sdkInt = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
  } catch (_) {
    // Not running on Android — nothing to check.
  }

  bool bluetooth;
  if (sdkInt >= 31) {
    final statuses = await Future.wait([
      Permission.bluetoothScan.status,
      Permission.bluetoothAdvertise.status,
      Permission.bluetoothConnect.status,
    ]);
    bluetooth = statuses.every((s) => s.isGranted);
  } else {
    bluetooth = true; // BLUETOOTH/BLUETOOTH_ADMIN are normal permissions pre-31.
  }

  final nearbyWifi = sdkInt >= 33
      ? (await Permission.nearbyWifiDevices.status).isGranted
      : true; // Wi-Fi Direct discovery relies on Location instead, pre-33.

  final location = (await Permission.locationWhenInUse.status).isGranted;

  return (bluetooth: bluetooth, nearbyWifi: nearbyWifi, location: location);
}

/// Requests location access on its own, independent of [requestMeshPermissions]
/// (which only bundles location in for API < 31/33 devices — on newer devices
/// BLE and Wi-Fi Direct don't need it at all, so it's never requested there).
/// The app still wants location for danger-zone proximity alerts and GPS
/// regardless of API level, so onboarding requests it explicitly. Never
/// throws (same stuck-native-lock guard as above).
Future<bool> requestLocationPermission() async {
  try {
    final status = await Permission.locationWhenInUse.request();
    if (status.isGranted) return true;
  } on PlatformException catch (e) {
    assert(() {
      // ignore: avoid_print
      print('[permissions] location request() threw, falling back to status: $e');
      return true;
    }());
  }
  return await Permission.locationWhenInUse.status.isGranted;
}

/// Requests microphone access for ambient-sound triage / the Device Test page.
///
/// Deliberately separate from [requestMeshPermissions]: the mic is OPTIONAL.
/// Denial must never block the app — the triage engine simply omits the
/// microphone term, and the
/// Device Test page shows the microphone row as unavailable. Never throws
/// (same stuck-native-lock guard as above).
Future<bool> requestMicPermission() async {
  try {
    final status = await Permission.microphone.request();
    if (status.isGranted) return true;
  } on PlatformException catch (e) {
    assert(() {
      // ignore: avoid_print
      print('[permissions] mic request() threw, falling back to status: $e');
      return true;
    }());
  }
  return await Permission.microphone.status.isGranted;
}
