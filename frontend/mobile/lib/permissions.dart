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
