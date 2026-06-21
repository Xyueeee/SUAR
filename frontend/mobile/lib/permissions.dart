import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// Requests the BLE/Wi-Fi Direct permissions needed before entering Victim
/// or Helper mode, branching on the API 31/33 split (CLAUDE.md Section 5).
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

  final statuses = await permissions.toList().request();
  if (statuses.values.every((s) => s.isGranted)) return true;

  // Android sometimes reports a stale denial in the .request() result right
  // after a multi-permission dialog sequence closes; re-query actual status
  // once before treating it as a real denial.
  final recheck = await Future.wait(permissions.map((p) => p.status));
  return recheck.every((s) => s.isGranted);
}
